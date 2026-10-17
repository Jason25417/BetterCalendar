import Foundation
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
}
