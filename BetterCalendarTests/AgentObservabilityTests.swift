import Foundation
import Testing
@testable import BetterCalendar

/// SPEC §19 批次 6：转译偏差统计（纯函数，只统计不改行为）。
@MainActor @Suite struct AgentTranslationStatsTests {
    /// 固定「现在」= 本地 2026-10-18 15:00（逻辑日 = 10-18，凌晨 4 点日界线）。
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15))!

    func proposal(_ state: ProposalState, origin: ProposalOrigin = .agent, hoursAgo: Double, expiresIn: Double = 1) -> Proposal {
        let created = Self.now.addingTimeInterval(-hoursAgo * 3600)
        return Proposal(id: UUID(), createdAt: created, expiresAt: Self.now.addingTimeInterval(expiresIn * 3600), origin: origin,
                        originLabel: "BetterCalendar 智能体", originDeviceId: "mac", parentId: nil, targetDeviceId: nil,
                        title: "t", changes: [], reason: "r", action: .experimentNoop(note: "n"), experiment: true, state: state,
                        decidedAt: nil, decidedByDeviceId: nil, appliedAt: nil, resultNote: nil)
    }

    func ledger(_ event: String, _ id: UUID) -> OperationRecord {
        OperationRecord(at: Self.now, actor: .user, actorLabel: "你", deviceId: "mac", event: event, proposalId: id, parentId: nil, detail: "")
    }

    func message(_ delivery: AgentMessage.Delivery, _ reaction: AgentMessage.Reaction?, hoursAgo: Double) -> AgentMessage {
        AgentMessage(id: UUID(), createdAt: Self.now.addingTimeInterval(-hoursAgo * 3600), originLabel: "BetterCalendar 智能体", parentRef: nil,
                     title: "t", body: "b", reason: "r", delivery: delivery, suppressReason: nil, reaction: reaction, reactedAt: nil, reactedByDeviceId: nil)
    }

    @Test func countsAgentProposalsByOutcomeAndIgnoresOtherOrigins() {
        let applied = proposal(.applied, hoursAgo: 1)
        let all = [applied, proposal(.applied, hoursAgo: 2), proposal(.failed, hoursAgo: 1), proposal(.declined, hoursAgo: 1),
                   proposal(.pending, hoursAgo: 1, expiresIn: -0.5),   // 未决定且已过截止 = 过期
                   proposal(.pending, hoursAgo: 1), proposal(.approved, hoursAgo: 1), proposal(.cancelled, hoursAgo: 1),
                   proposal(.applied, origin: .user, hoursAgo: 1)]   // 你自己发起的不算
        let s = AgentTranslationStatsCalculator.compute(proposals: all, messages: [], ledger: [ledger("undone", applied.id)],
                                                        window: .all, now: Self.now)
        #expect(s.proposals == 8 && s.pending == 1)
        #expect(s.approved == 4 && s.applied == 2 && s.failed == 1 && s.declined == 1 && s.expired == 1 && s.cancelled == 1)
        #expect(s.resolved == 7)
        #expect(s.approvalRate == StatRatio(count: 4, of: 7))
        #expect(s.failureRate.text == "1/4（25%）")
        #expect(s.undoRate == StatRatio(count: 1, of: 2) && s.undoRate.percentText == "50%")
        #expect(s.overrideRate.text == "0/2（0%）")
    }

    @Test func undoEventsAreDedupedAndScopedToAgentProposalsInWindow() {
        let a = proposal(.applied, hoursAgo: 1), old = proposal(.applied, hoursAgo: 24 * 10), mine = proposal(.applied, origin: .user, hoursAgo: 1)
        let records = [ledger("undone", a.id), ledger("undone", a.id),          // 两台设备各记一次 → 只算一次
                       ledger("undone", old.id), ledger("undone", mine.id),     // 窗外 / 非智能体 → 不算
                       ledger("undo.failed", a.id), ledger("overridden", a.id)]
        let s = AgentTranslationStatsCalculator.compute(proposals: [a, old, mine], messages: [], ledger: records, window: .week, now: Self.now)
        #expect(s.proposals == 1 && s.undone == 1)
        #expect(s.undoFailed == 0)   // 同一提案最终撤销成功：不再算「没成功」
        #expect(s.overridden == 1)
        #expect(s.applied == 2 && s.undoRate.of == 2)   // 撤销 + 手改不超过分母
    }

    @Test func windowsFilterByCreationTime() {
        let props = [proposal(.applied, hoursAgo: 1), proposal(.declined, hoursAgo: 14),   // 14 小时前 = 01:00，属前一逻辑日
                     proposal(.declined, hoursAgo: 24 * 3), proposal(.expired, hoursAgo: 24 * 30)]
        let calc = { (w: AgentStatsWindow) in AgentTranslationStatsCalculator.compute(proposals: props, messages: [], ledger: [], window: w, now: Self.now) }
        #expect(calc(.today).proposals == 1)
        #expect(calc(.week).proposals == 3)
        #expect(calc(.all).proposals == 4)
        #expect(calc(.today).declineRate.text == "0/1（0%）")
    }

    @Test func messageRatiosUseDeliveredAsReactionDenominator() {
        let msgs = [message(.delivered, .acknowledged, hoursAgo: 1), message(.delivered, .muted, hoursAgo: 1),
                    message(.delivered, nil, hoursAgo: 1), message(.suppressed, nil, hoursAgo: 1), message(.delivered, nil, hoursAgo: 24 * 9)]
        let s = AgentTranslationStatsCalculator.compute(proposals: [], messages: msgs, ledger: [], window: .week, now: Self.now)
        #expect(s.messages == 4 && s.delivered == 3 && s.suppressed == 1)
        #expect(s.deliveredRate.text == "3/4（75%）" && s.suppressedRate.percentText == "25%")
        #expect(s.acknowledgedRate == StatRatio(count: 1, of: 3) && s.mutedRate.percentText == "33%")
    }

    @Test func emptyWindowHasNoRatios() {
        let s = AgentTranslationStatsCalculator.compute(proposals: [], messages: [], ledger: [], window: .today, now: Self.now)
        #expect(s.isEmpty && s.approvalRate.fraction == nil && s.approvalRate.text == "—")
    }
}

/// SPEC §19 批次 11：调度器写进桥接目录的运行记录 / 状态 / 死信 / 越权镜像的解析与健康判断。
@MainActor @Suite struct AgentRuntimeStatusTests {
    /// 样例 = 调度器 v2 自测（dispatch/test）真实写出的格式。
    static let runsJSONL = #"""
{"schemaVersion":1,"runId":"r1","at":"2026-10-18T18:00:05.123Z","eventId":"block_finished-1","kind":"block_finished","attempt":1,"latencyMs":25014,"sessionId":"S1","resumed":true,"isError":false,"timedOut":false,"error":null,"willRetry":false,"deadLettered":false,"costUsd":0.83,"numTurns":7,"contextTokens":21000,"summary":"什么都不做：深夜不打扰"}
{"schemaVersion":1,"runId":"r2","at":"2026-10-18T18:10:00.000Z","eventId":"user_message-2","kind":"user_message","attempt":1,"latencyMs":3000,"sessionId":"S1","resumed":true,"isError":true,"timedOut":false,"error":"Claude Code 没有返回 JSON（退出码 1）：网络抖动","willRetry":true,"deadLettered":false,"costUsd":null,"numTurns":null,"contextTokens":null,"summary":""}
这一行坏了
{"schemaVersion":1,"runId":"r3","at":"2026-10-18T18:10:10.000Z","eventId":null,"kind":"rotation_handoff","attempt":1,"latencyMs":9000,"sessionId":"S1","resumed":true,"isError":true,"timedOut":false,"error":"智能体返回错误（error_during_execution）","rotationReason":"累计成本 $5.10 ≥ $5"}
"""#
    static let statusJSON = #"""
{"schemaVersion":1,"dispatcherVersion":2,"updatedAt":"2026-10-18T18:10:11.000Z","state":"idle","currentEvent":null,"pid":42,
 "session":{"id":"S1","events":12,"costUsd":4.2,"turns":80,"contextTokens":64000,"startedAt":"2026-10-18T10:00:00.000Z"},
 "thresholds":{"costUsd":5,"turns":150,"contextTokens":120000,"events":50},
 "lastFatal":{"at":"2026-10-18T17:00:00.000Z","message":"找不到 Claude Code 命令行（可设 BC_CLAUDE_BIN）"},
 "lastRotation":{"at":"2026-10-18T09:59:00.000Z","reason":"已处理 50 个事件 ≥ 50","fromSessionId":"S0","handoffOk":true},
 "lastLockRecovery":null,"configWarnings":["配置 rotateTurns 非法（-1），已用默认值"]}
"""#

    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("events/failed"), withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, _ relative: String, in root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(relative))
    }

    @Test func parsesRunsStatusOverreachAndDeadLetters() throws {
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        try write(Self.runsJSONL, "runtime/runs.jsonl", in: root)
        try write(Self.statusJSON, "runtime/status.json", in: root)
        try write(#"{"at":"2026-10-18T17:30:00.000Z","what":"重写了损坏的结果文件","why":"文件锁冲突","result":"成功","eventId":"e1"}"# + "\n", "runtime/overreach-log.jsonl", in: root)
        try write(#"{"schemaVersion":1,"id":"x","kind":"block_finished"}"#, "events/failed/20261018-block_finished-x.json", in: root)
        try write(#"{"schemaVersion":1,"file":"20261018-block_finished-x.json","failedAt":"2026-10-18T18:00:00.000Z","eventId":"x","kind":"block_finished","attempts":3,"reason":"智能体返回错误（error_max_turns）","lastRunId":"r9"}"#,
                  "events/failed/20261018-block_finished-x.failure.json", in: root)
        let snap = io.readRuntime()
        #expect(snap.runs.map(\.id) == ["r1", "r2", "r3"])
        let r1 = snap.runs[0]
        #expect(r1.latencySeconds == 25.014 && r1.costUsd == 0.83 && r1.numTurns == 7 && r1.resumed == true && !r1.isError)
        #expect(snap.runs[1].isError && snap.runs[1].willRetry && snap.runs[1].error?.contains("网络抖动") == true)
        #expect(snap.runs[2].kindLabel == "会话轮换交接" && snap.runs[2].rotationReason?.contains("累计成本") == true)
        #expect(snap.readProblems == ["运行记录有 1 行无法解析"])
        let st = try #require(snap.status)
        #expect(st.dispatcherVersion == 2 && st.state == "idle")
        #expect(st.session == .init(id: "S1", events: 12, costUsd: 4.2, turns: 80, contextTokens: 64000))
        #expect(st.thresholds.costUsd == 5 && st.thresholds.events == 50)
        #expect(st.lastFatal?.message.contains("找不到 Claude Code") == true && st.lastRotation?.handoffOk == true)
        #expect(snap.overreach.count == 1 && snap.overreach[0].why == "文件锁冲突" && snap.overreach[0].at != nil)
        #expect(snap.deadLetters.count == 1)
        #expect(snap.deadLetters[0].attempts == 3 && snap.deadLetters[0].reason.contains("error_max_turns"))
    }

    @Test func healthAlertsMakeDispatchFailuresVisible() throws {
        let now = try #require(AgentRuntimeJSON.date("2026-10-18T18:30:00.000Z"))
        var snap = AgentRuntimeSnapshot()
        #expect(AgentRuntimeHealth.alerts(snap, now: now).isEmpty)   // 什么都没有 ≠ 失败
        snap.deadLetters = [AgentDeadLetter(file: "a.json", failure: ["kind": "block_finished", "reason": "超时（超过 6 分钟）"])]
        snap.pendingEvents = [.init(file: "old.json", modifiedAt: now.addingTimeInterval(-15 * 60)),
                              .init(file: "new.json", modifiedAt: now.addingTimeInterval(-60))]
        let root = try tempRoot()
        try write(Self.statusJSON, "runtime/status.json", in: root)
        try write(Self.runsJSONL, "runtime/runs.jsonl", in: root)
        let read = AgentBridgeIO(root: root).readRuntime()
        snap.status = read.status; snap.runs = read.runs
        let alerts = AgentRuntimeHealth.alerts(snap, now: now)
        let errors = alerts.filter { $0.severity == .error }.map(\.message)
        #expect(errors.count == 3)
        #expect(errors.contains { $0.contains("1 个智能体事件处理失败") && $0.contains("超时") })
        #expect(errors.contains { $0.contains("调度器出错") && $0.contains("找不到 Claude Code") })
        #expect(errors.contains { $0.contains("1 个事件等了 15 分钟") })
        let warnings = alerts.filter { $0.severity == .warning }.map(\.message)
        #expect(warnings.contains { $0.contains("会话轮换交接") })        // 最近一次运行出错且不会重试
        #expect(warnings.contains { $0.contains("rotateTurns") })        // 配置警告
        #expect(Set(alerts.map(\.key)).count == alerts.count)
    }

    @Test func runningButStaleStatusIsFlagged() throws {
        let now = try #require(AgentRuntimeJSON.date("2026-10-18T19:00:00.000Z"))
        let st = AgentDispatcherStatus(["state": "running", "dispatcherVersion": 2, "updatedAt": "2026-10-18T18:00:00.000Z"])
        let alerts = AgentRuntimeHealth.alerts(AgentRuntimeSnapshot(status: st), now: now)
        #expect(alerts.count == 1 && alerts[0].message.contains("60 分钟没有更新"))
        // 调度器在跑、状态新鲜：排队 15 分钟的事件不报「没在运行」
        let busy = AgentDispatcherStatus(["state": "running", "dispatcherVersion": 2, "updatedAt": "2026-10-18T18:55:00.000Z"])
        let queued = AgentRuntimeSnapshot(status: busy, pendingEvents: [.init(file: "q.json", modifiedAt: now.addingTimeInterval(-15 * 60))])
        #expect(AgentRuntimeHealth.alerts(queued, now: now).isEmpty)
        // 停了（空闲）却还有久等的事件：报错
        let idle = AgentDispatcherStatus(["state": "idle", "dispatcherVersion": 2, "updatedAt": "2026-10-18T18:55:00.000Z"])
        #expect(AgentRuntimeHealth.alerts(AgentRuntimeSnapshot(status: idle, pendingEvents: queued.pendingEvents), now: now).first?.severity == .error)
    }

    @Test func requeueAndDismissDeadLetters() throws {
        let root = try tempRoot(), io = AgentBridgeIO(root: root), fm = FileManager.default
        for name in ["a", "b"] {
            try write("{}", "events/failed/\(name).json", in: root)
            try write(#"{"reason":"r"}"#, "events/failed/\(name).failure.json", in: root)
        }
        try io.requeueDeadLetter("a.json")
        #expect(fm.fileExists(atPath: root.appendingPathComponent("events/a.json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("events/failed/a.failure.json").path))
        try io.dismissDeadLetter("b.json")
        #expect(fm.fileExists(atPath: root.appendingPathComponent("events/failed/dismissed/b.json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("events/failed/dismissed/b.failure.json").path))
        #expect(io.readRuntime().deadLetters.isEmpty)
        #expect(throws: AgentBridgeError.self) { try io.requeueDeadLetter("a.json") }
    }

    @Test func bridgeSyncReadsRuntimeAndLogsEachAlertOnce() async throws {
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        let marker = "模拟致命错误 " + UUID().uuidString   // 唯一文本：DevLog 是全局共享的
        try write(Self.statusJSON.replacingOccurrences(of: "找不到 Claude Code 命令行（可设 BC_CLAUDE_BIN）", with: marker), "runtime/status.json", in: root)
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(),
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac")
        let bridge = AgentBridge(center: center, defaults: UserDefaults(suiteName: "bc-bridge-" + UUID().uuidString)!) { [:] }
        bridge.eventsEnabled = { false }
        let fixed = try #require(AgentRuntimeJSON.date("2026-10-18T18:30:00.000Z"))
        bridge.runtimeNow = { fixed }
        await bridge.sync(io: io)
        await bridge.sync(io: io)
        #expect(bridge.runtime?.status?.session?.events == 12)
        #expect(bridge.runtimeAlerts.contains { $0.severity == .error && $0.message.contains("调度器出错") })
        let logged = DevLog.shared.entries.filter { $0.source == "智能体运行" && $0.message.contains(marker) }
        #expect(logged.count == 1 && logged[0].level == .error)   // 两轮同步，同一告警只写一次日志
    }
}
