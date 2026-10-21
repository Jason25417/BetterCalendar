//
//  LogSyncService.swift
//  BetterCalendar
//
//  DevLog → DeviceLog(CloudKit) → （macOS）容器纯文本 的搬运工（0.14）。
//  - 挂 DevLog.onAppend 收条目进缓冲；30s 节流 flush（error 级立即）；
//  - flush：追加进本设备今日 DeviceLog + 清 7 天前旧记录；
//  - macOS 每轮 flush 后把**全部设备**的 DeviceLog dump 到
//    Application Support/BetterCalendar/SyncedLogs/<设备>-<日>.log ——
//    Claude 从命令行直接读（iOS 日志经 CloudKit 同步到 Mac 后也在这里）。
//  - 0.72.1 热修（2026-10-20 B3 根因）：一条 DeviceLog 的 text 不得超过 recordTextLimit。
//    超过时 Core Data 会把 text 挪进 CKAsset 字段 `CD_text_ckAsset`——生产环境 schema 里没有这个字段，
//    服务器拒收（"Cannot create or modify field 'CD_text_ckAsset' in record 'CD_DeviceLog' in production schema"），
//    而 CloudKit 一批导出是原子的 → **整台设备的同步全部卡死**（导出全败、镜像不再导入）。
//    10-19 19:54 Mac 当天日志涨到 ~680KB 起 Mac 就再没导出/导入过（9 月、7 月同样的连续数天失败也是它）。
//    现在：同一天写满就续到下一段（dayKey 记成 `yyyy-MM-dd-part2`…），已经超限的旧记录在下次 flush 时拆段——不丢日志。
//

import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class LogSyncService {
    private let context: ModelContext
    private var buffer: [String] = []
    private var timer: Timer?
    var dumpEnabled = true   // 测试关掉（别往真容器写文件）

    private static let deviceIDKey = "devicelog.deviceID"

    /// 单条记录 text 上限（UTF-8 字节）。实测：372KB / 481KB 导出正常，~680KB 起被拒（触发 CKAsset 外溢）。
    /// 取 200KB：离外溢线留足余量；不改 schema、不需要部署 CloudKit。
    nonisolated static let recordTextLimit = 200_000
    nonisolated static let partMarker = "-part"

    /// 续段的 dayKey：第 1 段就是 yyyy-MM-dd（与旧记录兼容），之后 yyyy-MM-dd-part2、-part3…
    nonisolated static func partKey(_ day: String, _ part: Int) -> String { part <= 1 ? day : "\(day)\(partMarker)\(part)" }
    /// dayKey → (日, 段号)。
    nonisolated static func parsePart(_ key: String) -> (day: String, part: Int) {
        guard let r = key.range(of: partMarker), let n = Int(key[r.upperBound...]) else { return (key, 1) }
        return (String(key[..<r.lowerBound]), n)
    }

    /// 按行切成每段 ≤ limit 字节（单行超长就按字符硬切）；各段按序拼回 == 原文（不丢字、不加字）。
    nonisolated static func chunks(_ text: String, limit: Int) -> [String] {
        guard text.utf8.count > limit else { return [text] }
        var lines: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            if let nl = text[start...].firstIndex(of: "\n") {
                let end = text.index(after: nl); lines.append(text[start..<end]); start = end
            } else { lines.append(text[start...]); break }
        }
        var out: [String] = []
        var cur = ""; var curBytes = 0
        for line in lines {
            var piece = line
            while !piece.isEmpty {
                let bytes = piece.utf8.count
                if curBytes + bytes <= limit { cur += piece; curBytes += bytes; break }
                if curBytes > 0 { out.append(cur); cur = ""; curBytes = 0; continue }
                // 单行就超过一段：按字符切出能放下的前缀
                var take = piece.startIndex, used = 0
                while take < piece.endIndex {
                    let c = piece[take].utf8.count
                    if used + c > limit { break }
                    used += c; take = piece.index(after: take)
                }
                if take == piece.startIndex { take = piece.index(after: take) }
                out.append(String(piece[..<take])); piece = piece[take...]
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static var deviceID: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: deviceIDKey) { return id }
        let id = UUID().uuidString
        d.set(id, forKey: deviceIDKey)
        return id
    }

    static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    init(context: ModelContext? = nil) {
        self.context = context ?? SharedModelContainer.shared.mainContext
    }

    /// 挂 DevLog 钩子 + 起 30s 节流；error 级立即 flush（崩前尽量落盘）。
    func start() {
        DevLog.shared.onAppend = { [weak self] entry in
            guard let self, entry.source != "行为" else { return }
            let tf = DateFormatter()
            tf.locale = Locale(identifier: "en_US_POSIX")
            tf.dateFormat = "HH:mm:ss"
            self.buffer.append("\(tf.string(from: entry.time)) [\(entry.level.rawValue.uppercased())] \(entry.source): \(entry.message)")
            if entry.level == .error { self.flush() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func fetchAll() -> [DeviceLog] {
        (try? context.fetch(FetchDescriptor<DeviceLog>())) ?? []
    }

    /// 缓冲 → 本设备今日记录（追加，写满续段）+ 拆开本设备超限的旧记录 + 清旧 + （macOS）dump 全部设备日志到纯文本。
    func flush(now: Date = .now) {
        var all = fetchAll()
        let limit = Self.recordTextLimit
        let me = Self.deviceID
        // ① 本设备已经超限的记录（0.72.1 之前写出的）→ 拆段：原记录留第一段，余下续到当天最后一段之后
        for oversized in all where oversized.deviceID == me && oversized.text.utf8.count > limit {
            let day = Self.parsePart(oversized.dayKey).day
            let pieces = Self.chunks(oversized.text, limit: limit)
            oversized.text = pieces[0]
            var next = (all.filter { $0.deviceID == me && Self.parsePart($0.dayKey).day == day }
                .map { Self.parsePart($0.dayKey).part }.max() ?? 1) + 1
            for piece in pieces.dropFirst() {
                let d = DeviceLog(deviceID: me, deviceName: oversized.deviceName, dayKey: Self.partKey(day, next),
                                  text: piece, modifiedAt: oversized.modifiedAt)
                context.insert(d); all.append(d); next += 1
            }
            DevLog.shared.warn("数据同步", "跨端日志 \(day) 超过单条上限，已拆成 \(pieces.count) 段（超限会让 iCloud 同步整台卡住）")
        }
        if !buffer.isEmpty {
            let key = DayContext.dayKey(now)
            let mineToday = all.filter { $0.deviceID == me && Self.parsePart($0.dayKey).day == key }
            var target = mineToday.max { Self.parsePart($0.dayKey).part < Self.parsePart($1.dayKey).part }
            var part = target.map { Self.parsePart($0.dayKey).part } ?? 1
            for piece in Self.chunks(buffer.joined(separator: "\n") + "\n", limit: limit) {
                if let t = target, t.text.utf8.count + piece.utf8.count <= limit {
                    t.text += piece; t.modifiedAt = now
                } else {
                    if target != nil { part += 1 }
                    let d = DeviceLog(deviceID: me, deviceName: Self.deviceName, dayKey: Self.partKey(key, part),
                                      text: piece, modifiedAt: now)
                    context.insert(d); all.append(d); target = d
                }
            }
            buffer.removeAll()
        }
        // 保留 7 天（按 dayKey 的日期部分字典序 = 时间序；续段跟着它那天走）
        let cutoff = DayContext.dayKey(now.addingTimeInterval(-7 * 86400))
        for old in all where Self.parsePart(old.dayKey).day < cutoff { context.delete(old) }
        try? context.save()
        dumpToFiles()
    }

    /// （macOS）全部设备日志 → 纯文本，命令行可读。写两处：
    /// ① 容器 Application Support/BetterCalendar/SyncedLogs/（沙盒内，受 TCC 保护、外部进程读不到）
    /// ② **`~/Downloads/BetterCalendar-logs/`**（需 downloads.read-write entitlement）——Claude/命令行直接可读，
    ///    **自动化拉取日志**：不用再手动 copy 到 Downloads（0.18.29）。
    private func dumpToFiles() {
        #if os(macOS)
        guard dumpEnabled else { return }
        // W19b 发现：在主线程同步写 ~/Downloads 时，系统等「下载」文件夹授权会把整个 App 卡死 → 先取出纯文本，写文件放后台
        let files = fetchAll().map { (name: $0.deviceName.replacingOccurrences(of: "/", with: "-") + "-\($0.dayKey).log", text: $0.text) }
        let fm = FileManager.default
        var dirs: [URL] = []
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(base.appendingPathComponent("BetterCalendar/SyncedLogs", isDirectory: true))
        }
        if let dl = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            dirs.append(dl.appendingPathComponent("BetterCalendar-logs", isDirectory: true))
        }
        Task.detached(priority: .utility) { Self.writeLogFiles(files, to: dirs) }
        #endif
    }

    nonisolated private static func writeLogFiles(_ files: [(name: String, text: String)], to dirs: [URL]) {
        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in files { try? f.text.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8) }
        }
    }
}
