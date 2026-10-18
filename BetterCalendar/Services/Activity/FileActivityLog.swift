//
//  FileActivityLog.swift
//  BetterCalendar
//
//  W13：设备活动记录的真实存储 = 本机容器里的按日 JSONL 文件（一行一条 ActivityEvent，只追加、不改写）。
//  - 路径：Application Support/BetterCalendar/ActivityLog/YYYY-MM-DD.jsonl（按事件发生时刻的本地日期分文件）。
//  - 格式：ISO 8601（带毫秒、UTC）时间 + 排序键，智能体侧（Node）直接按行读，不需要懂 Swift 的日期编码。
//  - 坏行（进程在写一半时被杀）读的时候跳过并计数，不让一行坏数据拖垮整天。
//  - 保留 90 天：这是**稳定性/体积边界**（防止文件无限长大、mirror 越拷越慢），不是产品规则；要更长改 retentionDays。
//  Mac：Mac 实时采集 + 从 iCloud 导入的 iPhone 事件都写这里；iPhone：快捷指令记下的也先写本机一份再上传。
//

import Foundation

/// 活动记录的 JSON 编解码（日文件、桥接镜像、iCloud 载荷共用同一份格式）。
nonisolated enum ActivityCodec {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func iso(_ date: Date) -> String { isoFractional.string(from: date) }
    static func date(_ s: String) -> Date? { isoFractional.date(from: s) ?? isoPlain.date(from: s) }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer(); try c.encode(iso(date))
        }
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer(), s = try c.decode(String.self)
            guard let date = date(s) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "不是 ISO 8601 时间：\(s)") }
            return date
        }
        return d
    }

    /// 一条 → 一行（不含换行）。
    static func line(_ e: ActivityEvent) throws -> Data { try encoder().encode(e) }

    /// 一段 JSONL → 记录 + 坏行数。
    static func decodeLines(_ data: Data) -> (events: [ActivityEvent], badLines: Int) {
        let d = decoder()
        var out: [ActivityEvent] = [], bad = 0
        for raw in data.split(separator: UInt8(ascii: "\n")) where !raw.isEmpty {
            if let e = try? d.decode(ActivityEvent.self, from: Data(raw)) { out.append(e) } else { bad += 1 }
        }
        return (out, bad)
    }
}

/// 日文件命名（本地日期）。Mac 镜像与保留期清理共用。
nonisolated struct ActivityDayFiles: Sendable {
    let root: URL
    var calendar: Calendar = .current

    private func formatter() -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar
        f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; return f
    }

    func dayKey(_ date: Date) -> String { formatter().string(from: date) }
    func url(forDay key: String) -> URL { root.appendingPathComponent("\(key).jsonl") }
    func date(ofDayKey key: String) -> Date? { formatter().date(from: key) }

    /// 目录里所有日文件（按日期升序；不认识的文件名忽略）。
    func allDays() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }
            .filter { date(ofDayKey: $0) != nil }.sorted()
    }

    /// 时间窗覆盖到的日期键（含两端所在的那天）。
    func days(covering window: DateInterval) -> [String] {
        var keys: [String] = []
        var day = calendar.startOfDay(for: window.start)
        let last = calendar.startOfDay(for: window.end)
        while day <= last, keys.count < 400 {   // 400 天 = 防失控上限
            keys.append(dayKey(day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
    }

    /// 早于保留期的日期键（retentionDays 天前的那天之前）。
    func expiredDays(now: Date, retentionDays: Int) -> [String] {
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now)) else { return [] }
        return allDays().filter { (date(ofDayKey: $0) ?? .distantFuture) < cutoff }
    }
}

actor FileActivityLog: ActivityLog {
    /// 保留天数：稳定性/体积边界（见文件头），不是产品规则。
    static let retentionDays = 90

    nonisolated let files: ActivityDayFiles
    private let retentionDays: Int
    /// 最近一次读到的坏行数（设置页状态行显示；0 = 没坏行）。
    private(set) var lastBadLines = 0

    init(root: URL, calendar: Calendar = .current, retentionDays: Int = FileActivityLog.retentionDays) {
        files = ActivityDayFiles(root: root, calendar: calendar)
        self.retentionDays = retentionDays
    }

    /// 生产路径：本机容器 Application Support/BetterCalendar/ActivityLog。
    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BetterCalendar/ActivityLog", isDirectory: true)
    }

    func append(_ events: [ActivityEvent]) async throws {
        guard !events.isEmpty else { return }
        try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        var byDay: [String: Data] = [:]
        for e in events {
            var line = try ActivityCodec.line(e); line.append(UInt8(ascii: "\n"))
            byDay[files.dayKey(e.at), default: Data()].append(line)
        }
        for (day, data) in byDay.sorted(by: { $0.key < $1.key }) {
            let url = files.url(forDay: day)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
                continue
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    func events(in window: DateInterval) async throws -> [ActivityEvent] {
        var out: [ActivityEvent] = [], bad = 0
        for day in files.days(covering: window) {
            let url = files.url(forDay: day)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let decoded = ActivityCodec.decodeLines(try Data(contentsOf: url))
            bad += decoded.badLines
            out += decoded.events.filter { window.contains($0.at) }
        }
        lastBadLines = bad
        return out.sorted { $0.at < $1.at }
    }

    /// 只追加窗口里还没有的（按 id 去重）：iCloud 导入、回填可能重放。返回真正写入的那些。
    @discardableResult
    func appendNew(_ events: [ActivityEvent]) async throws -> [ActivityEvent] {
        guard let lo = events.map(\.at).min(), let hi = events.map(\.at).max() else { return [] }
        var seen = Set(try await self.events(in: DateInterval(start: lo, end: hi)).map(\.id))
        let fresh = events.filter { seen.insert($0.id).inserted }
        try await append(fresh)
        return fresh
    }

    /// 同步追加（只给 App 即将退出时记「覆盖结束」用：那时等不了 actor）。
    nonisolated func appendSync(_ events: [ActivityEvent]) {
        guard !events.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
            for e in events {
                var line = try ActivityCodec.line(e); line.append(UInt8(ascii: "\n"))
                let url = files.url(forDay: files.dayKey(e.at))
                if FileManager.default.fileExists(atPath: url.path) {
                    let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
                    try h.seekToEnd(); try h.write(contentsOf: line)
                } else { try line.write(to: url, options: .atomic) }
            }
        } catch { DevLog.shared.warn("设备活动", "退出前写「记录结束」失败：\(error.localizedDescription)") }
    }

    /// 删掉超过保留期的日文件；返回删掉的日期键。
    @discardableResult
    func prune(now: Date) throws -> [String] {
        let expired = files.expiredDays(now: now, retentionDays: retentionDays)
        for day in expired { try FileManager.default.removeItem(at: files.url(forDay: day)) }
        return expired
    }
}
