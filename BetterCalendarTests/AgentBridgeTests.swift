import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

/// SPEC §19 P2：App ⇄ 智能体桥接目录的契约与同步。样例 = 智能体 2026-10-17 真实产出的提案文件（模拟数据场景）。
@MainActor @Suite struct AgentBridgeTests {
    static let realAgentProposal = #"""
{"schemaVersion": 1, "id": "5FCC2D9D-62D6-4C96-8A18-1B7A0FA02336", "createdAt": "2026-10-17T15:39:12.136Z", "origin": "agent", "originLabel": "BetterCalendar 智能体", "parentEventId": "test-event-1", "targetDevice": null, "title": "「整理 5529 笔记」挪到 15:00–16:00", "changes": [{"field": "整理 5529 笔记.start", "before": "14:00", "after": "15:00"}, {"field": "整理 5529 笔记.end", "before": "15:00", "after": "16:00"}], "reason": "Jason 说午饭吃晚了，想把整理笔记往后挪一小时；挪过去后刚好在 16:00 组会（固定）之前结束，不冲突。（测试改动，批准后不碰真实数据）", "action": {"kind": "experimentNoop", "note": "智能体测试提案"}, "experiment": true, "lifetimeSeconds": 10800}
"""#

    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func parsesRealAgentProposalFile() throws {
        let draft = try AgentBridgeIO.draft(from: Data(Self.realAgentProposal.utf8))
        #expect(draft.origin == .agent && draft.experiment && draft.parentRef == "test-event-1")
        #expect(draft.id?.uuidString == "5FCC2D9D-62D6-4C96-8A18-1B7A0FA02336")
        #expect(draft.changes.count == 2 && draft.changes[0].before == "14:00" && draft.changes[0].after == "15:00")
        #expect(draft.lifetime == 10800)
    }

    @Test func rejectsUnknownActionAndMissingReason() throws {
        var o = try JSONSerialization.jsonObject(with: Data(Self.realAgentProposal.utf8)) as! [String: Any]
        o["action"] = ["kind": "itemDelete"]
        #expect(throws: AgentBridgeError.self) { _ = try AgentBridgeIO.draft(from: JSONSerialization.data(withJSONObject: o)) }
        o["action"] = ["kind": "experimentNoop"]; o["reason"] = "  "
        #expect(throws: AgentBridgeError.self) { _ = try AgentBridgeIO.draft(from: JSONSerialization.data(withJSONObject: o)) }
    }

    @Test func syncImportsOnceWritesResultsAndContextAndRejectsBadFiles() async throws {
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        try io.prepare()
        try io.writeAtomic(Data(Self.realAgentProposal.utf8), to: "proposals/good.json")
        try io.writeAtomic(Data(#"{"schemaVersion":1,"id":"nope"}"#.utf8), to: "proposals/bad.json")
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(),
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(),
                                    deviceId: "mac", deviceLabel: "Mac")
        let bridge = AgentBridge(center: center, defaults: UserDefaults(suiteName: "bc-bridge-" + UUID().uuidString)!) {
            ["schemaVersion": 1, "synthetic": true]
        }
        await bridge.sync(io: io)
        let fm = FileManager.default
        #expect(center.proposals.count == 1 && center.proposals[0].origin == .agent && center.proposals[0].parentRef == "test-event-1")
        #expect(fm.fileExists(atPath: root.appendingPathComponent("proposals/imported/good.json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("proposals/rejected/bad.json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("proposals/rejected/bad.reason.txt").path))
        #expect(bridge.lastError?.contains("bad.json") == true)
        let id = center.proposals[0].id.uuidString
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results/\(id).json"))) as! [String: Any]
        #expect(result["state"] as? String == "pending")
        #expect(fm.fileExists(atPath: root.appendingPathComponent("context.json").path))
        // 同一文件再次出现（例如上次崩在移动前）：不重复提交。
        try io.writeAtomic(Data(Self.realAgentProposal.utf8), to: "proposals/good.json")
        await bridge.sync(io: io)
        #expect(center.proposals.count == 1 && bridge.importedCount == 1)
        // 批准后结果文件更新。
        await center.decide(center.proposals[0].id, .approve)
        await bridge.sync(io: io)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results/\(id).json"))) as! [String: Any]
        #expect(after["state"] as? String == "applied")
    }

    @Test func importsAgentMessagesThroughAttentionGateAndWritesResults() async throws {
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        try io.prepare()
        let id = UUID().uuidString
        let msg = #"{"schemaVersion":1,"id":"\#(id)","title":"下一步","body":"要不要先看一眼 N1 表格要填什么？","reason":"空档 + 他说过想做","parentEventId":"evt-1"}"#
        try io.writeAtomic(Data(msg.utf8), to: "messages/\(id).json")
        try io.writeAtomic(Data(#"{"schemaVersion":1,"id":"\#(UUID().uuidString)","title":"t","body":"b"}"#.utf8), to: "messages/noreason.json")
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(),
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac")
        let messages = AgentMessageCenter(transport: InMemoryAgentMessageTransport(), notifier: SilentAgentMessageNotifier(),
                                          ledger: MemoryOperationLedger(), deviceId: "mac",
                                          defaults: UserDefaults(suiteName: "bc-msg-" + UUID().uuidString)!)
        let bridge = AgentBridge(center: center, messages: messages, defaults: UserDefaults(suiteName: "bc-bridge-" + UUID().uuidString)!) { [:] }
        bridge.eventsEnabled = { false }
        await bridge.sync(io: io)
        #expect(messages.messages.count == 1 && messages.messages[0].parentRef == "evt-1")
        #expect(messages.messages[0].delivery == .suppressed)   // 总开关默认关：拦下但保存
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results/messages/\(id).json"))) as! [String: Any]
        #expect(result["delivery"] as? String == "suppressed" && (result["suppressReason"] as? String)?.contains("未开启") == true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("messages/rejected/noreason.json").path))
    }

    @Test func resolvedAgentProposalEmitsOneEventOnlyWhenEnabled() async throws {
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        try io.prepare()
        try io.writeAtomic(Data(Self.realAgentProposal.utf8), to: "proposals/good.json")
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(),
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac")
        let bridge = AgentBridge(center: center, defaults: UserDefaults(suiteName: "bc-bridge-" + UUID().uuidString)!) { [:] }
        var on = false
        bridge.eventsEnabled = { on }
        await bridge.sync(io: io)
        await center.decide(center.proposals[0].id, .decline)
        await bridge.sync(io: io)
        let events = { try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("events").path).filter { $0.hasSuffix(".json") } }
        #expect(try events().isEmpty)                         // 关着：不写事件、不耗额度
        on = true
        await bridge.sync(io: io); await bridge.sync(io: io)
        let written = try events()
        #expect(written.count == 1 && written[0].contains("proposal_resolved"))   // 只写一次
    }

    // MARK: W1 真改动种类的桥接契约

    func file(_ action: [String: Any], changes: Any? = nil, id: String = UUID().uuidString) throws -> Data {
        var o: [String: Any] = ["schemaVersion": 1, "id": id, "title": "测试", "reason": "Jason 说的", "action": action]
        if let changes { o["changes"] = changes }
        return try JSONSerialization.data(withJSONObject: o)
    }

    @Test func parsesEveryRealKindStrictly() throws {
        let item = UUID(), block = UUID(), pid = UUID()
        let create = try AgentBridgeIO.draft(from: file(["kind": "itemCreate", "title": "买牛奶", "note": "低脂"], id: pid.uuidString))
        #expect(create.action == .itemCreate(id: pid, title: "买牛奶", note: "低脂") && !create.experiment && create.changes.isEmpty)
        let edit = try AgentBridgeIO.draft(from: file(["kind": "itemEdit", "itemId": item.uuidString, "title": "新标题", "expectedRevision": "r1"]))
        #expect(edit.action == .itemEdit(id: item, title: "新标题", note: nil, expectedRevision: "r1"))
        let done = try AgentBridgeIO.draft(from: file(["kind": "itemSetDone", "itemId": item.uuidString, "done": true]))
        #expect(done.action == .itemSetDone(id: item, done: true, expectedRevision: nil))
        let start = try AgentBridgeIO.draft(from: file(["kind": "timer", "command": "start", "blockId": block.uuidString]))
        #expect(start.action == .timer(command: .start, blockId: block, title: nil, expectedRevision: nil))
        let stop = try AgentBridgeIO.draft(from: file(["kind": "timer", "command": "stop", "blockId": NSNull()]))
        #expect(stop.action == .timer(command: .stop, blockId: nil, title: nil, expectedRevision: nil))
        let move = try AgentBridgeIO.draft(from: file(["kind": "moveBlock", "blockId": block.uuidString, "start": "2026-10-18T15:00:00+08:00"]))
        guard case let .moveBlock(id, s, e, rev) = move.action else { Issue.record("应解析为 moveBlock"); return }
        #expect(id == block && s == Date(timeIntervalSince1970: 1792306800) && e == nil && rev == nil)
        let frac = try AgentBridgeIO.draft(from: file(["kind": "moveBlock", "blockId": block.uuidString, "start": "2026-10-18T07:00:00.000Z", "end": "2026-10-18T08:00:00Z"]))
        guard case let .moveBlock(_, s2, e2?, _) = frac.action else { Issue.record("应带结束时间"); return }
        #expect(s2 == s && e2.timeIntervalSince(s2) == 3600)
    }

    @Test func rejectsMalformedRealKinds() throws {
        let item = UUID().uuidString, block = UUID().uuidString
        let bad: [[String: Any]] = [
            ["kind": "itemDiscard", "itemId": item],                                   // 只用于撤销
            ["kind": "itemDelete", "itemId": item],                                    // 不认识的种类
            ["kind": "itemCreate"],                                                    // 缺标题
            ["kind": "itemCreate", "title": "x", "deadline": "明天"],                  // 不认识的字段
            ["kind": "itemEdit", "itemId": item],                                      // 什么都不改
            ["kind": "itemEdit", "itemId": "not-a-uuid", "title": "x"],
            ["kind": "itemSetDone", "itemId": item, "done": 1],                        // 不是布尔
            ["kind": "timer", "command": "start"],                                     // 二选一缺失
            ["kind": "timer", "command": "start", "blockId": block, "title": "x"],     // 二选一都给
            ["kind": "timer", "command": "pause", "title": "x"],
            ["kind": "timer", "command": "skip"],
            ["kind": "moveBlock", "blockId": block, "start": "15:00"],                 // 没有时区的时间
            ["kind": "moveBlock", "start": "2026-10-18T15:00:00Z"],                    // 缺 blockId
        ]
        for action in bad {
            #expect(throws: AgentBridgeError.self, "应拒绝：\(action)") { _ = try AgentBridgeIO.draft(from: file(action)) }
        }
        // 测试改动仍要求 changes
        #expect(throws: AgentBridgeError.self) { _ = try AgentBridgeIO.draft(from: file(["kind": "experimentNoop"])) }
    }

    @Test func syncPreparesRealProposalAndRejectsStaleOneWithReason() async throws {
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        try io.prepare()
        let container = try ModelContainer(for: DataArchiveStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let items = LongTaskStore(context: container.mainContext)
        let itemId = UUID()
        try items.createTodo(id: itemId, title: "读论文", note: "", at: Date(timeIntervalSince1970: 1_792_000_000))
        let center = ProposalCenter(transport: InMemoryProposalTransport(),
                                    executor: ProposalActionExecutor(items: items, deviceId: "mac"),
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac")
        let bridge = AgentBridge(center: center, defaults: UserDefaults(suiteName: "bc-bridge-" + UUID().uuidString)!) {
            AgentBridgeContext.snapshot(planStore: nil, active: nil, longTasks: items, timer: .idle)
        }
        bridge.eventsEnabled = { false }
        try io.writeAtomic(file(["kind": "itemSetDone", "itemId": itemId.uuidString, "done": true]), to: "proposals/good.json")
        try io.writeAtomic(file(["kind": "itemEdit", "itemId": itemId.uuidString, "title": "x", "expectedRevision": "stale"]), to: "proposals/stale.json")
        await bridge.sync(io: io)
        #expect(center.proposals.count == 1)
        #expect(center.proposals[0].changes == [ProposalChange(field: "「读论文」", before: "在途", after: "做成了")])
        let reason = try String(contentsOf: root.appendingPathComponent("proposals/rejected/stale.reason.txt"), encoding: .utf8)
        #expect(reason.contains("版本不一致"))
        // context.json 里给出事项 id 与版本，智能体据此提案
        let context = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("context.json"))) as! [String: Any]
        let targets = try #require(context["actionTargets"] as? [String: Any])
        let listed = try #require((targets["items"] as? [[String: Any]])?.first)
        let task = try #require(try items.task(id: itemId))
        #expect(listed["id"] as? String == itemId.uuidString && listed["revision"] as? String == ProposalRevision.item(task))
        // 批准 → 执行 → 结果文件带种类与撤销信息
        await center.decide(center.proposals[0].id, .approve)
        await bridge.sync(io: io)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results/\(center.proposals[0].id.uuidString).json"))) as! [String: Any]
        #expect(result["state"] as? String == "applied" && result["kind"] as? String == "itemSetDone" && result["undoAvailable"] as? Bool == true)
        #expect(await center.undo(center.proposals[0].id))
        await bridge.sync(io: io)
        let undone = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results/\(center.proposals[0].id.uuidString).json"))) as! [String: Any]
        #expect(undone["undoneAt"] is String && undone["undoAvailable"] as? Bool == false)
    }
}
