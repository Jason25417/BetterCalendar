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
            guard let self else { return }
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

    /// 缓冲 → 本设备今日记录（追加）+ 清旧 + （macOS）dump 全部设备日志到纯文本。
    func flush(now: Date = .now) {
        let all = fetchAll()
        if !buffer.isEmpty {
            let key = DayContext.dayKey(now)
            let mine = all.first { $0.deviceID == Self.deviceID && $0.dayKey == key }
                ?? {
                    let d = DeviceLog(deviceID: Self.deviceID, deviceName: Self.deviceName, dayKey: key)
                    context.insert(d)
                    return d
                }()
            mine.text += buffer.joined(separator: "\n") + "\n"
            mine.modifiedAt = now
            buffer.removeAll()
        }
        // 保留 7 天（按 dayKey 字典序 = 时间序）
        let cutoff = DayContext.dayKey(now.addingTimeInterval(-7 * 86400))
        for old in all where old.dayKey < cutoff { context.delete(old) }
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
        let logs = fetchAll()
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            writeLogs(logs, to: base.appendingPathComponent("BetterCalendar/SyncedLogs", isDirectory: true))
        }
        if let dl = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            writeLogs(logs, to: dl.appendingPathComponent("BetterCalendar-logs", isDirectory: true))
        }
        #endif
    }

    private func writeLogs(_ logs: [DeviceLog], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for log in logs {
            let safeName = log.deviceName.replacingOccurrences(of: "/", with: "-")
            let url = dir.appendingPathComponent("\(safeName)-\(log.dayKey).log")
            try? log.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
