//
//  SentinelIO.swift
//  BetterCalendar
//
//  SPEC §19 C1 W14：哨兵的两个出口。
//    - 决策日志（本机 JSONL，按月一个文件，App 沙盒的 Application Support/BetterCalendarSentinel/）：每次判断一行，
//      Jason 用来测误报/漏报、删减数据源。只记摘要哈希与大小，不记原文。
//    - 桥接目录（智能体工作区 bridge/）：叫醒时写 `events/…-sentinel_wake-….json` + 摘要原文 `runtime/sentinel/digest-….json`
//      （智能体按 digestRef 读）；每一拍写 `runtime/sentinel.json` 状态（心跳检查哨兵是否活着、有没有出错）。
//

#if os(macOS)
import Foundation

// MARK: 决策日志

@MainActor protocol SentinelDecisionLogging: AnyObject {
    func append(_ entry: SentinelDecisionEntry) throws
    /// since 之后的条目，按时间升序。
    func entries(since: Date) -> [SentinelDecisionEntry]
    /// 给人看的位置（面板显示）。
    var location: String { get }
}

@MainActor final class MemorySentinelDecisionLog: SentinelDecisionLogging {
    private(set) var rows: [SentinelDecisionEntry] = []
    var failNext: Error?
    let location = "内存（测试）"
    func append(_ entry: SentinelDecisionEntry) throws {
        if let e = failNext { failNext = nil; throw e }
        rows.append(entry)
    }
    func entries(since: Date) -> [SentinelDecisionEntry] { rows.filter { $0.at >= since }.sorted { $0.at < $1.at } }
}

@MainActor final class FileSentinelDecisionLog: SentinelDecisionLogging {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterCalendarSentinel", isDirectory: true)
    }
    var location: String { directory.path }

    private static let month: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f
    }()
    private func file(for date: Date) -> URL { directory.appendingPathComponent("decisions-\(Self.month.string(from: date)).jsonl") }

    func append(_ entry: SentinelDecisionEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(entry); line.append(0x0A)
        let url = file(for: entry.at)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    func entries(since: Date) -> [SentinelDecisionEntry] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        // 文件名按 yyyy-MM 排序，字符串比较即月份比较。
        let first = "decisions-\(Self.month.string(from: since)).jsonl"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("decisions-") && $0.hasSuffix(".jsonl") && $0 >= first }.sorted()
        let months = names.map { directory.appendingPathComponent($0) }
        return months.flatMap { url -> [SentinelDecisionEntry] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(SentinelDecisionEntry.self, from: Data($0)) }
        }.filter { $0.at >= since }.sorted { $0.at < $1.at }
    }
}

// MARK: 桥接目录

/// 桥接目录的访问口（生产 = AgentBridge.performInFolder；测试 = 临时目录）。没连 / 出错 → 抛出。
@MainActor protocol SentinelBridgeAccess: AnyObject {
    var isConnected: Bool { get }
    func withBridge(refreshContext: Bool, _ body: (AgentBridgeIO) throws -> Void) async throws
}

extension SentinelBridgeAccess {
    /// 智能体此刻忙不忙（防风暴：忙的时候哨兵不写新的叫醒，只攒着）：
    /// 调度器状态 runtime/status.json 是 running，或 events/ 里还有没处理的事件（它马上就要跑）。读不到 = 当作不忙（不因此卡住叫醒）。
    func agentBusy() async -> Bool {
        var busy = false
        try? await withBridge(refreshContext: false) { io in busy = SentinelBridgeFiles.agentBusy(root: io.root) }
        return busy
    }
}

extension AgentBridge: SentinelBridgeAccess {
    var isConnected: Bool { connected }
    func withBridge(refreshContext: Bool, _ body: (AgentBridgeIO) throws -> Void) async throws {
        try await performInFolder(refreshContext: refreshContext, body)
    }
}

/// 测试 / 开发用：直接读写一个目录。
@MainActor final class DirectorySentinelBridge: SentinelBridgeAccess {
    let io: AgentBridgeIO
    var isConnected = true
    var contextWrites = 0
    init(root: URL) { io = AgentBridgeIO(root: root) }
    func withBridge(refreshContext: Bool, _ body: (AgentBridgeIO) throws -> Void) async throws {
        guard isConnected else { throw AgentBridgeError.invalid("桥接目录未连接") }
        try io.prepare()
        if refreshContext { contextWrites += 1; try io.writeContext(["schemaVersion": 1, "synthetic": true]) }
        try body(io)
    }
}

/// 桥接目录里哨兵文件的布局（协议见智能体工作区 bridge/README.md）。
nonisolated enum SentinelBridgeFiles {
    static let wakeKind = "sentinel_wake"
    static let statusPath = "runtime/sentinel.json"
    static let digestDir = "runtime/sentinel"
    /// 摘要原文只留最近这么多份。
    static let keepDigests = 30

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMddHHmmss"; return f
    }()

    static func agentBusy(root: URL) -> Bool {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: root.appendingPathComponent("runtime/status.json")),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], o["state"] as? String == "running" { return true }
        let events = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("events").path)) ?? []
        return events.contains { $0.hasSuffix(".json") }
    }

    /// 写摘要原文 + 唤醒事件；返回事件 id。merged = 攒着时合并进来的其他理由（智能体一次看全）。
    static func writeWake(io: AgentBridgeIO, verdict: SentinelVerdict, digestText: String, digestHash: String, digestBytes: Int,
                          trigger: SentinelTrigger, judge: SentinelJudgeKind, decisionId: UUID, now: Date,
                          merged: [SentinelPendingWake.Reason] = []) throws -> String {
        let fm = FileManager.default
        let dir = io.root.appendingPathComponent(digestDir, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        let ref = "\(digestDir)/digest-\(stamp.string(from: now))-\(digestHash.prefix(12)).json"
        let digest: [String: Any] = ["schemaVersion": 1, "writtenAt": iso.string(from: now), "hash": digestHash, "bytes": digestBytes,
                                     "trigger": trigger.rawValue, "decisionId": decisionId.uuidString, "text": digestText,
                                     "note": "哨兵判断时看到的摘要原文（含设备活动里的 App/网站名：只供你理解情况，不要写进复盘、留底或给 Jason 的消息）"]
        try io.writeAtomic(SafeJSON.data(withJSONObject: digest, options: [.prettyPrinted, .sortedKeys]), to: ref)
        prune(dir)
        let payload: [String: Any] = ["reason": verdict.reason, "urgency": verdict.urgency.rawValue, "signals": verdict.signals,
                                      "trigger": trigger.rawValue, "judge": judge.rawValue, "digestRef": ref, "digestHash": digestHash,
                                      "digestBytes": digestBytes, "decisionId": decisionId.uuidString]
        var p = payload
        if let prob = verdict.probability { p["probability"] = (prob * 1000).rounded() / 1000 }
        if !merged.isEmpty {
            p["merged"] = merged.map { r -> [String: Any] in
                var o: [String: Any] = ["at": iso.string(from: r.at), "reason": r.reason, "urgency": r.urgency.rawValue, "signals": r.signals]
                if let prob = r.probability { o["probability"] = (prob * 1000).rounded() / 1000 }
                return o
            }
        }
        let summary = merged.count > 1 ? "哨兵（合并 \(merged.count) 条理由）：\(verdict.reason)" : "哨兵：\(verdict.reason)"
        return try io.writeEvent(kind: wakeKind, summary: summary, payload: p, at: now)
    }

    static func writeStatus(io: AgentBridgeIO, _ status: [String: Any]) throws {
        try FileManager.default.createDirectory(at: io.root.appendingPathComponent("runtime", isDirectory: true), withIntermediateDirectories: true)
        try io.writeAtomic(SafeJSON.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]), to: statusPath)
    }

    private static func prune(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path).filter({ $0.hasPrefix("digest-") }).sorted(),
              files.count > keepDigests else { return }
        for f in files.prefix(files.count - keepDigests) { try? fm.removeItem(at: dir.appendingPathComponent(f)) }
    }
}
#endif
