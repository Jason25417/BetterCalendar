//
//  W48ReportFixesTests.swift
//  BetterCalendarTests
//
//  0.78.1（Jason 2026-10-26）：收发文字上限放宽、回复里的思考过程不给人看、长期事项能直接建、提案结论事件带标题。
//

import Foundation
import Testing
@testable import BetterCalendar

@Suite struct W48ReportFixesTests {
    @Test func thinkingIsStrippedAndThinkingOnlyRepliesAreRefused() throws {
        #expect(AgentChatText.strippingThinking("<analysis>按时间梳理…</analysis>\n好，下午 3 点开始。") == "好，下午 3 点开始。")
        #expect(AgentChatText.strippingThinking("先说结论。<think>半截思考没闭合") == "先说结论。")
        func reply(_ text: String) -> Data {
            try! SafeJSON.data(withJSONObject: ["schemaVersion": 1, "id": UUID().uuidString, "text": text])
        }
        #expect(throws: AgentBridgeError.self) { _ = try AgentBridgeIO.chatReplyDraft(from: reply("<analysis>让我按时间顺序梳理这次对话")) }
        let long = String(repeating: "字", count: 5000)
        #expect(try AgentBridgeIO.chatReplyDraft(from: reply(long)).text.count == 5000, "原来 1000 字就拒收")
        #expect(throws: AgentBridgeError.self) { _ = try AgentBridgeIO.chatReplyDraft(from: reply(String(repeating: "字", count: AgentChatMessage.maxText + 1))) }
    }

    @Test func itemCreateCanTargetTheLongTermZone() throws {
        let file: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString, "originLabel": "x", "title": "建长期事项", "reason": "他说分阶段的进长期区",
                                   "action": ["kind": "itemCreate", "title": "FSCJ Canvas 模块", "zone": "longterm"]]
        guard case let .itemCreate(_, _, _, longTerm) = try AgentBridgeIO.draft(from: SafeJSON.data(withJSONObject: file)).action else {
            Issue.record("种类不对"); return
        }
        #expect(longTerm == true)
        var bad = file; bad["action"] = ["kind": "itemCreate", "title": "x", "zone": "someday"]
        #expect(throws: AgentBridgeError.self) { _ = try AgentBridgeIO.draft(from: SafeJSON.data(withJSONObject: bad)) }
        // 旧数据（没有 longTerm）照常解码
        let old = #"{"itemCreate":{"id":"\#(UUID().uuidString)","title":"旧的","note":null}}"#
        guard case let .itemCreate(_, title, _, lt) = try JSONDecoder().decode(ProposalAction.self, from: Data(old.utf8)) else { Issue.record("解不出"); return }
        #expect(title == "旧的" && lt == nil)
    }

    @Test func todayIsListedInPlanningDays() {
        var input = AgentContextInput(now: Date())
        input.planEditing = true
        input.today.items = [.init(title: "写论文", start: Date(), end: Date().addingTimeInterval(3600), id: UUID())]
        let days = (AgentBridgeContext.snapshot(input)["planning"] as? [String: Any])?["days"] as? [[String: Any]]
        #expect(days?.first?["name"] as? String == "今天")
        #expect((days?.first?["blocks"] as? [[String: Any]])?.count == 1)
        #expect(days?.count == PlanEditRules.horizonDays + 1)
    }
}

extension ProposalActionTests {
    @Test func longTermItemIsCreatedInTheLongTermZone() async throws {
        let r = try rig()
        let id = UUID()
        let p = try await approve(r, .itemCreate(id: id, title: "BYU 入门模块", note: nil, longTerm: true))
        #expect(p.state == .applied && p.changes.first?.field == "长期事项")
        #expect(try r.items.task(id: id)?.zoneRaw == PoolZone.longterm.rawValue)
    }
}
