//
//  W41CascadeTests.swift
//  BetterCalendarTests
//
//  W41（Jason 2026-10-22）：日程排得紧时挪一块会牵动后面几块——智能体带 cascade: true，放不下时 App 把算好的连带顺延
//  直接并进同一份提案（一步提交、卡上逐块列出、可整组挪回），不再「提一块 → 被拒 → 照抄重提」。
//  固定安排、图钉、截止、你的日历照样不被连带挪；算不出来就照常拒收、原因不变。
//

import Foundation
import Testing
@testable import BetterCalendar

extension ProposalActionTests {
    func cascadeDraft(_ action: ProposalAction) -> ProposalDraft {
        var d = draft(action, target: "mac")
        d.cascade = true
        return d
    }

    @Test func cascadeFoldsTheShiftIntoOneProposalAndUndoesAsAGroup() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        let p = try #require(await r.mac.submit(cascadeDraft(.moveBlock(id: ids.flex, start: at(17, 30, c), end: nil, expectedRevision: nil))))
        guard case let .moveBlocks(moves, false) = p.action else { Issue.record("应变成整组挪：\(p.action)"); return }
        #expect(Set(moves.map(\.id)) == [ids.flex, ids.other])
        #expect(p.changes.contains { $0.field == "「跑步」时间" && $0.before == "18:00–19:00" && $0.after == "18:30–19:30" })
        await r.phone.decide(p.id, .approve)
        await r.mac.refresh(); await r.phone.refresh()
        #expect(r.mac.proposals.first { $0.id == p.id }?.state == .applied)
        let label = Calendar.current.startOfDay(for: c.now)
        let run = try #require(try r.plans.plannedBlocks(on: label).first { $0.id == ids.other })
        #expect(run.start == at(18, 30, c) && run.end == at(19, 30, c))
        #expect(await r.phone.undo(p.id))
        let back = try #require(try r.plans.plannedBlocks(on: label).first { $0.id == ids.other })
        #expect(back.start == at(18, 0, c))
    }

    @Test func cascadeWithoutACollisionStaysASingleMove() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let p = try #require(await r.mac.submit(cascadeDraft(.moveBlock(id: ids.flex, start: at(16, 0, r.clock), end: nil, expectedRevision: nil))))
        guard case .moveBlock = p.action else { Issue.record("没撞上就不该变成整组：\(p.action)"); return }
    }

    @Test func cascadeStillRejectsWhatCannotBeShifted() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        // 「交作业」顺延会越过 17:00 截止；撞固定安排「组会」→ 照常拒收、原因不变
        #expect(await r.mac.submit(cascadeDraft(.moveBlock(id: ids.flex, start: at(15, 30, c), end: nil, expectedRevision: nil))) == nil)
        #expect(r.mac.lastError?.contains("要连带挪「交作业」") == true)
        r.mac.clearError()
        #expect(await r.mac.submit(cascadeDraft(.moveBlock(id: ids.flex, start: at(13, 30, c), end: nil, expectedRevision: nil))) == nil)
        #expect(r.mac.lastError?.contains("与固定安排「组会」") == true)
    }

    @Test func cascadeOnlyAppliesToMoves() async throws {
        let r = try rig()
        _ = try seedDay(r)
        #expect(await r.mac.submit(cascadeDraft(.itemCreate(id: UUID(), title: "买牛奶", note: ""))) == nil)
        #expect(r.mac.lastError?.contains("只用于挪块") == true)
    }

    @Test func pinnedBlocksAreObstaclesNotCascaded() throws {
        let now = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        func t(_ h: Int, _ m: Int = 0) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: now)! }
        let a = ScheduledBlock(title: "整理笔记", start: t(11), end: t(12))
        var pinned = ScheduledBlock(title: "跑步", start: t(18), end: t(19))
        pinned.pinnedUntil = t(23)
        let c = PlanEditRules.Context(blocks: [a, pinned], now: now, window: PlanEditRules.window(now: now, horizon: 0))
        let step = ProposalPlanStep.move(ProposalBlockMove(id: a.id, start: t(17, 30), end: nil, expectedRevision: nil))
        #expect(throws: ProposalExecutionError.self) { try PlanEditRules.withCascade([step], in: c) }
        // 没钉住时就会连带顺延
        pinned.pinnedUntil = nil
        let free = PlanEditRules.Context(blocks: [a, pinned], now: now, window: PlanEditRules.window(now: now, horizon: 0))
        #expect(try PlanEditRules.withCascade([step], in: free).count == 2)
    }

    @Test func bridgeReadsCascadeOnlyWhereItBelongs() throws {
        func file(_ action: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": UUID().uuidString, "title": "挪", "reason": "测试", "action": action])
        }
        let id = UUID().uuidString, iso = "2030-01-01T10:00:00Z"
        #expect(try AgentBridgeIO.draft(from: file(["kind": "moveBlock", "blockId": id, "start": iso, "cascade": true])).cascade)
        #expect(try AgentBridgeIO.draft(from: file(["kind": "moveBlocks", "moves": [["blockId": id, "start": iso]], "cascade": true])).cascade)
        #expect(try !AgentBridgeIO.draft(from: file(["kind": "moveBlock", "blockId": id, "start": iso])).cascade)
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.draft(from: file(["kind": "moveBlocks", "moves": [["blockId": id, "start": iso, "cascade": true]]])) }
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.draft(from: file(["kind": "itemCreate", "title": "x", "cascade": true])) }
    }
}
