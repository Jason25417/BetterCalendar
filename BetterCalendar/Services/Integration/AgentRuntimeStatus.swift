//
//  AgentRuntimeStatus.swift
//  BetterCalendar
//
//  SPEC §19 批次 11：BetterCalendar 智能体运行时的可观测性（App 侧只读）。
//  调度器（智能体工作区 dispatch/dispatch.mjs v2）把这些写进桥接目录（协议见 bridge/README.md）：
//    - runtime/runs.jsonl：每次运行一行（耗时、成本、轮数、是否出错、是否续接…）；
//    - runtime/status.json：调度器状态、当前会话消耗与轮换阈值、最近一次致命错误；
//    - runtime/overreach-log.jsonl：越权记录镜像（原件在工作区根目录，App 沙盒读不到）；
//    - events/failed/：重试用完仍失败的事件（死信）+ .failure.json 原因。
//  这里只做解析 + 健康判断（纯函数，可测）；失败必须可见：判断出的告警由 AgentBridge 写 DevLog、面板醒目显示。
//

import Foundation

nonisolated enum AgentRuntimeJSON {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()

    /// JS `toISOString()` 带毫秒；App 自己写的不带。两种都认。
    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
    static func string(_ any: Any?) -> String? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return s
    }
    static func double(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
    static func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }
    static func bool(_ any: Any?) -> Bool? { (any as? NSNumber)?.boolValue }

    /// JSONL → 字典数组；坏行计数返回（不静默吞：面板会提示）。
    static func lines(_ data: Data) -> (rows: [[String: Any]], bad: Int) {
        var rows: [[String: Any]] = [], bad = 0
        for line in data.split(separator: 0x0A) where !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) {
            if let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { rows.append(o) } else { bad += 1 }
        }
        return (rows, bad)
    }
}

/// 一次调度运行（runtime/runs.jsonl 的一行）。
nonisolated struct AgentRunRecord: Identifiable, Equatable, Sendable {
    var id: String
    var at: Date
    var eventId: String?
    /// 事件种类；另有 rotation_handoff / lock_recovered / dispatcher / invalid
    var kind: String?
    var attempt: Int?
    var latencySeconds: Double?
    var resumed: Bool?
    var isError: Bool
    var timedOut: Bool
    var error: String?
    var willRetry: Bool
    var deadLettered: Bool
    var costUsd: Double?
    var numTurns: Int?
    var contextTokens: Int?
    var summary: String?
    var rotationReason: String?

    init?(_ o: [String: Any]) {
        guard let at = AgentRuntimeJSON.date(o["at"]) else { return nil }
        self.at = at
        eventId = AgentRuntimeJSON.string(o["eventId"])
        kind = AgentRuntimeJSON.string(o["kind"])
        id = AgentRuntimeJSON.string(o["runId"]) ?? "\(at.timeIntervalSince1970)-\(eventId ?? kind ?? "?")"
        attempt = AgentRuntimeJSON.int(o["attempt"])
        latencySeconds = AgentRuntimeJSON.double(o["latencyMs"]).map { $0 / 1000 }
        resumed = AgentRuntimeJSON.bool(o["resumed"])
        isError = AgentRuntimeJSON.bool(o["isError"]) ?? false
        timedOut = AgentRuntimeJSON.bool(o["timedOut"]) ?? false
        error = AgentRuntimeJSON.string(o["error"])
        willRetry = AgentRuntimeJSON.bool(o["willRetry"]) ?? false
        deadLettered = AgentRuntimeJSON.bool(o["deadLettered"]) ?? false
        costUsd = AgentRuntimeJSON.double(o["costUsd"])
        numTurns = AgentRuntimeJSON.int(o["numTurns"])
        contextTokens = AgentRuntimeJSON.int(o["contextTokens"])
        summary = AgentRuntimeJSON.string(o["summary"])
        rotationReason = AgentRuntimeJSON.string(o["rotationReason"])
    }

    var kindLabel: String {
        switch kind {
        case "rotation_handoff": "会话轮换交接"
        case "lock_recovered": "回收残留锁"
        case "dispatcher": "调度器"
        case "invalid": "无效事件"
        case let k?: k
        case nil: "—"
        }
    }
}

/// 调度器状态（runtime/status.json）。
nonisolated struct AgentDispatcherStatus: Equatable, Sendable {
    struct Session: Equatable, Sendable {
        var id: String
        var events: Int
        var costUsd: Double
        var turns: Int
        var contextTokens: Int?
    }
    struct Fatal: Equatable, Sendable {
        var at: Date?
        var message: String
    }
    struct Rotation: Equatable, Sendable {
        var at: Date?
        var reason: String
        var handoffOk: Bool
    }
    struct Thresholds: Equatable, Sendable {
        var costUsd: Double?
        var turns: Int?
        var contextTokens: Int?
        var events: Int?
    }
    var dispatcherVersion: Int
    var updatedAt: Date?
    /// running / idle
    var state: String
    var currentEvent: String?
    var session: Session?
    var thresholds: Thresholds
    var lastFatal: Fatal?
    var lastRotation: Rotation?
    var configWarnings: [String]

    init?(_ o: [String: Any]) {
        guard let state = AgentRuntimeJSON.string(o["state"]) else { return nil }
        self.state = state
        dispatcherVersion = AgentRuntimeJSON.int(o["dispatcherVersion"]) ?? 0
        updatedAt = AgentRuntimeJSON.date(o["updatedAt"])
        currentEvent = AgentRuntimeJSON.string(o["currentEvent"])
        if let s = o["session"] as? [String: Any], let id = AgentRuntimeJSON.string(s["id"]) {
            session = Session(id: id, events: AgentRuntimeJSON.int(s["events"]) ?? 0, costUsd: AgentRuntimeJSON.double(s["costUsd"]) ?? 0,
                              turns: AgentRuntimeJSON.int(s["turns"]) ?? 0, contextTokens: AgentRuntimeJSON.int(s["contextTokens"]))
        }
        let t = o["thresholds"] as? [String: Any] ?? [:]
        thresholds = Thresholds(costUsd: AgentRuntimeJSON.double(t["costUsd"]), turns: AgentRuntimeJSON.int(t["turns"]),
                                contextTokens: AgentRuntimeJSON.int(t["contextTokens"]), events: AgentRuntimeJSON.int(t["events"]))
        if let f = o["lastFatal"] as? [String: Any], let m = AgentRuntimeJSON.string(f["message"]) {
            lastFatal = Fatal(at: AgentRuntimeJSON.date(f["at"]), message: m)
        }
        if let r = o["lastRotation"] as? [String: Any], let reason = AgentRuntimeJSON.string(r["reason"]) {
            lastRotation = Rotation(at: AgentRuntimeJSON.date(r["at"]), reason: reason, handoffOk: AgentRuntimeJSON.bool(r["handoffOk"]) ?? false)
        }
        configWarnings = (o["configWarnings"] as? [String]) ?? []
    }

}

/// 死信：events/failed/<事件文件> + <同名>.failure.json。
nonisolated struct AgentDeadLetter: Identifiable, Equatable, Sendable {
    /// 事件文件名（重新排队 / 收起时用）
    var file: String
    var id: String { file }
    var eventId: String?
    var kind: String?
    var reason: String
    var attempts: Int?
    var failedAt: Date?

    init(file: String, failure: [String: Any]?) {
        self.file = file
        eventId = AgentRuntimeJSON.string(failure?["eventId"])
        kind = AgentRuntimeJSON.string(failure?["kind"])
        reason = AgentRuntimeJSON.string(failure?["reason"]) ?? "（没有找到失败原因文件）"
        attempts = AgentRuntimeJSON.int(failure?["attempts"])
        failedAt = AgentRuntimeJSON.date(failure?["failedAt"])
    }
}

/// 越权记录（智能体 log_overreach 写入，调度器镜像）。
nonisolated struct AgentOverreachRecord: Identifiable, Equatable, Sendable {
    var id: String { "\(atText)-\(what)" }
    var atText: String
    var at: Date?
    var what: String
    var why: String
    var result: String
    var eventId: String?

    init?(_ o: [String: Any]) {
        guard let what = AgentRuntimeJSON.string(o["what"]) else { return nil }
        self.what = what
        atText = AgentRuntimeJSON.string(o["at"]) ?? ""
        at = AgentRuntimeJSON.date(o["at"])
        why = AgentRuntimeJSON.string(o["why"]) ?? ""
        result = AgentRuntimeJSON.string(o["result"]) ?? ""
        eventId = AgentRuntimeJSON.string(o["eventId"])
    }
}

/// 一次读取到的运行时全貌。
nonisolated struct AgentRuntimeSnapshot: Equatable, Sendable {
    var status: AgentDispatcherStatus?
    /// 时间正序（最新在最后）
    var runs: [AgentRunRecord] = []
    var deadLetters: [AgentDeadLetter] = []
    var overreach: [AgentOverreachRecord] = []
    /// 还在 events/ 里等调度器处理的事件：文件名 + 修改时间
    var pendingEvents: [PendingEvent] = []
    /// 读取问题（坏行、坏文件），面板如实显示
    var readProblems: [String] = []

    struct PendingEvent: Equatable, Sendable {
        var file: String
        var modifiedAt: Date
    }
}

nonisolated struct AgentRuntimeAlert: Identifiable, Equatable, Sendable {
    enum Severity: String, Sendable { case warning, error }
    var severity: Severity
    var message: String
    /// 去重键：同一个问题只写一次 DevLog
    var key: String
    var id: String { key }
}

/// 健康判断（纯函数）：调度失败一律醒目可见。
nonisolated enum AgentRuntimeHealth {
    /// 事件在 events/ 里等多久还没被处理就算「调度器可能没在运行」。
    static let pendingTooLong: TimeInterval = 10 * 60
    /// 状态为 running 却多久没更新就算「可能卡住」（单次运行上限 6 分钟 × 重试 + 余量）。
    static let runningStale: TimeInterval = 25 * 60

    static func alerts(_ s: AgentRuntimeSnapshot, now: Date) -> [AgentRuntimeAlert] {
        var out: [AgentRuntimeAlert] = []
        if !s.deadLetters.isEmpty {
            let latest = s.deadLetters.max { ($0.failedAt ?? .distantPast) < ($1.failedAt ?? .distantPast) }!
            out.append(.init(severity: .error,
                             message: "有 \(s.deadLetters.count) 个智能体事件处理失败（已放进死信）。最近：\(latest.kind ?? latest.file) — \(latest.reason)",
                             key: "dead:" + s.deadLetters.map(\.file).sorted().joined(separator: ",")))
        }
        if let fatal = s.status?.lastFatal {
            let when = fatal.at.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            out.append(.init(severity: .error, message: "调度器出错：\(fatal.message)\(when)",
                             key: "fatal:\(fatal.at?.timeIntervalSince1970 ?? 0)"))
        }
        // 调度器正在运行且状态新鲜：排队久是因为前面的事件慢（单次最长数分钟 × 重试），不算没在运行。
        let dispatcherBusy = s.status.map { $0.state == "running" && $0.updatedAt.map { now.timeIntervalSince($0) <= runningStale } == true } ?? false
        let stale = dispatcherBusy ? [] : s.pendingEvents.filter { now.timeIntervalSince($0.modifiedAt) > pendingTooLong }
        if let oldest = stale.min(by: { $0.modifiedAt < $1.modifiedAt }) {
            let minutes = Int(now.timeIntervalSince(oldest.modifiedAt) / 60)
            out.append(.init(severity: .error,
                             message: "有 \(stale.count) 个事件等了 \(minutes) 分钟还没被处理：调度器可能没在运行（检查 LaunchAgent / Mac 是否睡眠）",
                             key: "pending:" + oldest.file))
        }
        if let st = s.status, st.state == "running", let updated = st.updatedAt, now.timeIntervalSince(updated) > runningStale {
            out.append(.init(severity: .warning,
                             message: "调度器显示「运行中」但 \(Int(now.timeIntervalSince(updated) / 60)) 分钟没有更新：可能卡住了",
                             key: "stuck:\(updated.timeIntervalSince1970)"))
        }
        // 最近一次运行出错、且既不会重试也没进死信（例如轮换交接失败）：单独提示。致命错误已由 lastFatal 覆盖。
        if let last = s.runs.last(where: { $0.kind != "lock_recovered" }), last.isError, !last.willRetry, !last.deadLettered,
           last.kind != "dispatcher" {
            out.append(.init(severity: .warning, message: "最近一次运行（\(last.kindLabel)）出错：\(last.error ?? "未知原因")",
                             key: "run:" + last.id))
        }
        for w in s.status?.configWarnings ?? [] {
            out.append(.init(severity: .warning, message: "调度器配置：\(w)", key: "config:" + w))
        }
        for p in s.readProblems {
            out.append(.init(severity: .warning, message: p, key: "read:" + p))
        }
        return out
    }
}

// MARK: - 桥接目录读取 / 死信操作

extension AgentBridgeIO {
    nonisolated static let runtimeRunsLimit = 50
    nonisolated static let overreachLimit = 50

    /// 读运行时全貌。任何单个文件读坏都不影响其他部分，问题记进 readProblems。
    nonisolated func readRuntime() -> AgentRuntimeSnapshot {
        var snap = AgentRuntimeSnapshot()
        let fm = FileManager.default
        let runtime = root.appendingPathComponent("runtime")

        if let data = try? Data(contentsOf: runtime.appendingPathComponent("status.json")) {
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let st = AgentDispatcherStatus(o) {
                snap.status = st
            } else {
                snap.readProblems.append("调度器状态文件 runtime/status.json 无法解析")
            }
        }
        if let data = try? Data(contentsOf: runtime.appendingPathComponent("runs.jsonl")) {
            let (rows, bad) = AgentRuntimeJSON.lines(data)
            let runs = rows.compactMap(AgentRunRecord.init)
            snap.runs = Array(runs.suffix(Self.runtimeRunsLimit))
            if bad + (rows.count - runs.count) > 0 { snap.readProblems.append("运行记录有 \(bad + rows.count - runs.count) 行无法解析") }
        }
        if let data = try? Data(contentsOf: runtime.appendingPathComponent("overreach-log.jsonl")) {
            let (rows, bad) = AgentRuntimeJSON.lines(data)
            snap.overreach = Array(rows.compactMap(AgentOverreachRecord.init).suffix(Self.overreachLimit))
            if bad > 0 { snap.readProblems.append("越权记录有 \(bad) 行无法解析") }
        }
        let failed = root.appendingPathComponent("events/failed")
        if let names = try? fm.contentsOfDirectory(atPath: failed.path) {
            snap.deadLetters = names.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".failure.json") }.sorted().map { name in
                let failureURL = failed.appendingPathComponent(String(name.dropLast(5)) + ".failure.json")
                let failure = (try? Data(contentsOf: failureURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                return AgentDeadLetter(file: name, failure: failure)
            }
        }
        let events = root.appendingPathComponent("events")
        if let urls = try? fm.contentsOfDirectory(at: events, includingPropertiesForKeys: [.contentModificationDateKey]) {
            snap.pendingEvents = urls.filter { $0.pathExtension == "json" }.compactMap { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return modified.map { AgentRuntimeSnapshot.PendingEvent(file: url.lastPathComponent, modifiedAt: $0) }
            }.sorted { $0.file < $1.file }
        }
        return snap
    }

    /// 死信重新排队：移回 events/（调度器会再处理一次），删掉失败原因文件。只由用户点击触发。
    nonisolated func requeueDeadLetter(_ file: String) throws {
        let fm = FileManager.default
        let src = root.appendingPathComponent("events/failed/\(file)")
        let dest = root.appendingPathComponent("events/\(file)")
        guard fm.fileExists(atPath: src.path) else { throw AgentBridgeError.invalid("死信 \(file) 已不在") }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: src, to: dest)
        try? fm.removeItem(at: root.appendingPathComponent("events/failed/\(file.dropLast(5)).failure.json"))
    }

    /// 收起死信：连同原因文件移入 events/failed/dismissed/（保留可查，不删除）。只由用户点击触发。
    nonisolated func dismissDeadLetter(_ file: String) throws {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("events/failed/dismissed")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in [file, "\(file.dropLast(5)).failure.json"] {
            let src = root.appendingPathComponent("events/failed/\(name)")
            guard fm.fileExists(atPath: src.path) else { continue }
            let dest = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: src, to: dest)
        }
    }
}
