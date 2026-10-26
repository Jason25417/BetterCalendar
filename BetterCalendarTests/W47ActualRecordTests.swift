//
//  W47ActualRecordTests.swift
//  BetterCalendarTests
//
//  0.78（Jason 2026-10-26）：智能体补记「实际花了多久」——actualRecord 走提案、低风险自动通过、可撤销。
//

import Foundation
import Testing
@testable import BetterCalendar

extension ProposalActionTests {
    func execution(_ r: Rig) -> ExecutionViewModel {
        let e = ExecutionViewModel(calendarStore: FakeCalendarStore(),
                                   reschedule: RescheduleService(planStore: r.plans, planner: NaivePlanningEngine()),
                                   planStore: r.plans, reminderStore: FakeReminderStore(),
                                   liveActivity: NoLiveActivity(), persistsRunState: false)
        e.clock = { r.clock.now }
        r.executor.timer = e
        return e
    }

    @Test func recordingWhatWasDoneOnAPlanBlockMarksItDoneAndUndoes() async throws {
        let r = try rig()
        let e = execution(r)
        let label = DayContext.logicalStartOfDay(r.clock.now)
        let block = ScheduledBlock(title: "写论文", start: at(8, 0, r.clock), end: at(9, 0, r.clock))
        try r.plans.replacePlanned([block], on: label)
        let p = try await approve(r, .actualRecord(recordId: UUID(), blockId: block.id, title: "", start: at(8, 10, r.clock), end: at(9, 50, r.clock)))
        #expect(p.state == .applied)
        #expect(p.changes.first?.field.contains("补记 100 分钟") == true && p.changes.first?.after?.contains("写论文") == true)
        #expect(e.done.contains { $0.plannedID == block.id && $0.end == at(9, 50, r.clock) })
        #expect(try r.plans.actualBlocks(on: label).contains { $0.id == block.id })
        await r.mac.undo(p.id)
        #expect(!e.done.contains { $0.plannedID == block.id })
        #expect(try !r.plans.actualBlocks(on: label).contains { $0.id == block.id })
    }

    @Test func recordingAnUnplannedThingOnAnEarlierDay() async throws {
        let r = try rig()
        let e = execution(r)   // 执行器只弱引用计时组件：留住它
        defer { withExtendedLifetime(e) {} }
        let yesterday = r.clock.now.addingTimeInterval(-86400)
        let start = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: yesterday)!
        let sub = await r.mac.submit(draft(.actualRecord(recordId: UUID(), blockId: nil, title: "复习 3301", start: start, end: start.addingTimeInterval(3600))))
        #expect(sub != nil, "\(r.mac.lastError ?? "")")
        let p = try await approve(r, .actualRecord(recordId: UUID(), blockId: nil, title: "复习 3301", start: start, end: start.addingTimeInterval(3600)))
        #expect(p.state == .applied)
        let label = DayContext.logicalStartOfDay(start)
        #expect(try r.plans.actualBlocks(on: label).contains { $0.title == "复习 3301" })
    }

    @Test func onlyThePastAndNotTooLongAgo() async throws {
        let r = try rig()
        let e = execution(r)   // 执行器只弱引用计时组件：留住它
        defer { withExtendedLifetime(e) {} }
        #expect(await r.mac.submit(draft(.actualRecord(recordId: UUID(), blockId: nil, title: "x",
                                                       start: r.clock.now, end: r.clock.now.addingTimeInterval(3600)))) == nil)
        #expect(r.mac.lastError?.contains("已经过去") == true, "\(r.mac.lastError ?? "")")
        let old = r.clock.now.addingTimeInterval(-6 * 86400)
        #expect(await r.mac.submit(draft(.actualRecord(recordId: UUID(), blockId: nil, title: "x", start: old, end: old.addingTimeInterval(600)))) == nil)
        #expect(r.mac.lastError?.contains("3 天") == true)
    }

    @Test func actualRecordParsesFromTheBridgeAndIsLowRisk() throws {
        let file: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString, "originLabel": "x", "title": "补记", "reason": "他说的",
                                   "action": ["kind": "actualRecord", "title": "跑步", "start": "2026-10-26T07:00:00-04:00", "end": "2026-10-26T07:40:00-04:00"]]
        let d = try AgentBridgeIO.draft(from: SafeJSON.data(withJSONObject: file))
        guard case let .actualRecord(_, block, title, _, _) = d.action else { Issue.record("种类不对"); return }
        #expect(block == nil && title == "跑步")
        #expect(PreauthPolicy.lowRiskReason(Proposal(id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(60), origin: .agent,
            originLabel: "x", originDeviceId: "mac", parentId: nil, targetDeviceId: nil, title: "t", changes: [], reason: "r",
            action: d.action, experiment: false, state: .pending)) == nil)
    }
}
