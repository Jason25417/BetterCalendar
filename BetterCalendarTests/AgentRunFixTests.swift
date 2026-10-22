//
//  AgentRunFixTests.swift
//  BetterCalendarTests
//
//  2026-10-22 内置智能体（DeepSeek）两天日志复盘：一轮常被「放不下 → 一块一块重试」耗光 8 步。
//  拒收原因附 App 算好的整组顺延；一组里顺手列了不变的块不再整组拒收；标题过长截断、askFirst 放错位置挪回提案级。
//

import Foundation
import Testing
@testable import BetterCalendar

extension ProposalActionTests {
    @Test func overlapRejectionCarriesACopyableCascadeThatThenPasses() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        r.mac.clearError()
        _ = await r.mac.submit(draft(.moveBlock(id: ids.flex, start: at(17, 30, c), end: nil, expectedRevision: nil)))
        let why = try #require(r.mac.lastError)
        #expect(why.contains("要连带挪「跑步」") && why.contains("App 算好的连带顺延") && why.contains("「跑步」18:00–19:00 → 18:30–19:30"))
        // 照抄建议里的 moves，和原来那块一起提 → 一次通过
        let json = try #require(why.range(of: "moves 追加：").map { String(why[$0.upperBound...]) })
        let extra = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]])
        var moves = [ProposalBlockMove(id: ids.flex, start: at(17, 30, c), end: nil, expectedRevision: nil)]
        let iso = ISO8601DateFormatter()
        for m in extra {
            moves.append(ProposalBlockMove(id: try #require(UUID(uuidString: m["blockId"] ?? "")), start: try #require(iso.date(from: m["start"] ?? "")),
                                           end: iso.date(from: m["end"] ?? ""), expectedRevision: nil))
        }
        let p = try await approve(r, .moveBlocks(moves: moves, isUndo: false))
        #expect(p.state == .applied)
    }

    @Test func noCascadeHintWhenItWouldBreakADeadlineOrHitsAFixedBlock() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        r.mac.clearError()
        // 「交作业」顺延到 16:30–17:30 会越过 17:00 截止 → 不给建议，照常拒收
        _ = await r.mac.submit(draft(.moveBlock(id: ids.flex, start: at(15, 30, c), end: nil, expectedRevision: nil)))
        #expect(r.mac.lastError?.contains("要连带挪「交作业」") == true && r.mac.lastError?.contains("App 算好") == false)
        r.mac.clearError()
        _ = await r.mac.submit(draft(.moveBlock(id: ids.flex, start: at(13, 30, c), end: nil, expectedRevision: nil)))
        #expect(r.mac.lastError?.contains("与固定安排「组会」") == true && r.mac.lastError?.contains("App 算好") == false)
    }

    @Test func unchangedBlocksListedInAGroupAreSkippedNotRejected() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        let p = try await approve(r, group([(ids.flex, at(20, 0, c), nil), (ids.other, at(18, 0, c), nil)]))
        #expect(p.state == .applied)
        #expect(!p.changes.contains { $0.field.contains("跑步") })   // 没变的那块不出现在卡上
    }

    @Test func longTitleIsClippedAndMisplacedAskFirstIsHoisted() throws {
        let file: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString, "title": String(repeating: "长", count: 120), "reason": "测试",
                                   "action": ["kind": "experimentNoop", "note": "x"], "changes": [["field": "f", "before": "a", "after": "b"]]]
        let d = try AgentBridgeIO.draft(from: try JSONSerialization.data(withJSONObject: file))
        #expect(d.title.count == 80 && d.title.hasSuffix("…"))
        let built = try BuiltinAgentToolbox.proposalFile(["title": "t", "reason": "r",
                                                          "action": ["kind": "itemCreate", "title": "买菜", "askFirst": true]], id: UUID(), eventId: nil)
        #expect((built["action"] as? [String: Any])?["askFirst"] == nil && built["askFirst"] as? Bool == true)
    }
}
