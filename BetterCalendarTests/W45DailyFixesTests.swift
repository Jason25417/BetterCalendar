//
//  W45DailyFixesTests.swift
//  BetterCalendarTests
//
//  0.76（Jason 2026-10-26）：智能体上报 + 时间轴——放不下时给出空档、到点唤醒、数据同步中不排程、
//  过去的计划淡色保留可记做完、拖动撞上后面的块整组顺延。
//

import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

@MainActor @Suite struct W45PlanRulesAndWakeTests {
    let cal = Calendar.current
    func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    @Test func overlapRejectionListsTheFreeGapsThatFit() throws {
        let now = at(26, 8)
        let study = ScheduledBlock(title: "3301 复习", start: at(27, 9), end: at(27, 10, 30))
        var c = PlanEditRules.Context(blocks: [study], now: now, window: PlanEditRules.window(now: now, horizon: 7))
        c.occupied = [.init(title: "STAT 3301", start: at(27, 11, 30), end: at(27, 12, 25)),
                      .init(title: "MATH 5529H 讨论课", start: at(27, 14, 15), end: at(27, 16, 5))]
        do {
            _ = try PlanEditRules.evaluate([.move(ProposalBlockMove(id: study.id, start: at(27, 11, 30), end: at(27, 13), expectedRevision: nil))], in: c)
            Issue.record("应该拒收")
        } catch let e as ProposalExecutionError {
            let why = e.errorDescription ?? ""
            #expect(why.contains("STAT 3301") && why.contains("能放下 90 分钟的空档"))
            #expect(why.contains("08:00–11:30") && why.contains("12:25–14:15") && why.contains("16:05–"))
        }
    }

    @Test func wakesFireOnMacOnTimeAndOnPhoneAfterTheGrace() throws {
        var now = at(26, 12)
        let d = UserDefaults(suiteName: "bc-w45-" + UUID().uuidString)!
        let s = AgentWakeSchedule(defaults: d, now: { now })
        let w = try s.add(at: try AgentWakeSchedule.parseTime("2026-10-26T12:30:00"), note: "回来补复盘、问计时要不要停", by: "内置智能体（iPhone）")
        #expect(s.pending.map(\.id) == [w.id])
        #expect(throws: AgentWakeError.notFuture) { try s.add(at: at(26, 11), note: "x", by: "t") }
        #expect(throws: AgentWakeError.emptyNote) { try s.add(at: at(26, 13), note: " ", by: "t") }
        now = at(26, 12, 31)
        #expect(s.takeDue(isMac: false, by: "iPhone").fire.isEmpty, "iPhone 先让 Mac 叫")
        let mac = s.takeDue(isMac: true, by: "Mac")
        #expect(mac.fire.map(\.id) == [w.id])
        now = at(26, 12, 40)
        #expect(s.takeDue(isMac: false, by: "iPhone").fire.isEmpty, "已经叫过：不再叫")
        // 设备都没开、迟到太久：不叫，标错过
        let late = try s.add(at: at(26, 13), note: "停计时", by: "t")
        now = at(27, 2)
        let r = s.takeDue(isMac: true, by: "Mac")
        #expect(r.fire.isEmpty && r.missed.map(\.id) == [late.id])
        // 取消
        let c = try s.add(at: at(27, 9), note: "早上问一句", by: "t")
        try s.cancel(c.id)
        #expect(s.pending.isEmpty)
        #expect(AgentWakeSchedule.decode(d.string(forKey: AgentWakeSchedule.key)) != nil, "存成带更新时间的整份（同步防旧副本）")
    }

    @Test func pastPlansStayFadedAboveTheGate() {
        let now = at(26, 14)
        let missed = ScheduledBlock(title: "读文献", start: at(26, 9), end: at(26, 10))
        let done = ScheduledBlock(title: "健身", start: at(26, 11), end: at(26, 12))
        let future = ScheduledBlock(title: "写论文", start: at(26, 15), end: at(26, 16))
        let label = DayContext.logicalStartOfDay(now)
        let items = TimelineAxisComposer.compose(AxisInput(labels: [label], now: now, planned: [missed, done, future],
            actuals: [AxisActual(title: "健身", start: at(26, 11), end: at(26, 12), plannedID: done.id)])).flatMap(\.items)
        #expect(items.first { $0.blockID == missed.id }?.kind == .pastPlan)
        #expect(!items.contains { $0.blockID == done.id && $0.kind != .actual }, "记下做成的只画蓝")
        #expect(items.first { $0.blockID == future.id }?.kind == .plan)
    }
}

extension W23TimelineAxisTests {
    @Test func draggingIntoTheNextBlockPushesItAlongUnpinned() async throws {
        let now = at(20, 12)
        let r = try rig(now: now)
        let a = ScheduledBlock(title: "写论文", start: at(21, 9), end: at(21, 10))
        let b = ScheduledBlock(title: "健身", start: at(21, 10), end: at(21, 11))
        try r.store.replacePlanned([a, b], on: label(21))
        await r.axis.reload()
        let reason = await r.axis.commitDrag(try #require(r.axis.days().flatMap(\.items).first { $0.blockID == a.id && $0.kind == .plan }),
                                             start: at(21, 9, 30))
        #expect(reason == nil)
        let stored = try r.store.plannedBlocks(on: label(21))
        #expect(stored.first { $0.id == a.id }?.start == at(21, 9, 30))
        let pushed = try #require(stored.first { $0.id == b.id })
        #expect(pushed.start == at(21, 10, 30) && pushed.end == at(21, 11, 30), "后面的块顺延、时长不变")
        #expect(pushed.isPinned(at: now) == false, "顺延的不钉，只钉你亲手拖的")
        #expect(r.axis.notice?.contains("顺延") == true)
    }

    @Test func tappingAPastPlanRecordsItAsDone() async throws {
        let now = at(20, 14)
        let r = try rig(now: now)
        let past = ScheduledBlock(title: "读文献", start: at(19, 9), end: at(19, 10))
        try r.store.replacePlanned([past], on: label(19))
        final class MarkingLive: AxisLiveSource {
            var settledPlannedIDs: Set<UUID> = []
            var axisTodayDone: [AxisActual] = []
            var axisRunning: [AxisRunning] = []
            var store: PlanStore?
            func axisMarkDone(_ block: ScheduledBlock) async -> String? {
                try? store?.upsertActuals([ActualBlock(id: block.id, title: block.title, start: block.start, end: block.end)])
                return nil
            }
        }
        let live = MarkingLive(); live.store = r.store
        let axis = TimelineAxisModel(plans: r.store, actuals: r.store, calendar: r.calendar, live: live, home: r.home, now: { now })
        await axis.reload()
        let item = try #require(axis.days().flatMap(\.items).first { $0.blockID == past.id })
        #expect(item.kind == .pastPlan)
        await axis.markPastDone(item)
        #expect(axis.days().flatMap(\.items).first { $0.blockID == past.id }?.kind == .actual)
    }
}

extension W20BuiltinAgentTests {
    @Test func scheduleWakeToolAndFiring() async throws {
        let e = env()
        e.selection.select(.builtin)
        #expect(BuiltinAgentToolbox.toolNames.contains("schedule_wake"))
        // 测试环境的工具箱没接定时唤醒：直说
        let none = object(await e.tools.call("schedule_wake", arguments: #"{"at":"2026-10-26T12:30:00-04:00","note":"x"}"#, eventId: nil, ledger: BuiltinAgentRunLedger()))
        #expect(none["ok"] as? Bool == false)
    }

    @Test func proposalResultsCarryAPlainStateLabel() {
        let at = Date()
        let p = Proposal(id: UUID(), createdAt: at, expiresAt: at.addingTimeInterval(3600), origin: .agent, originLabel: "BetterCalendar 智能体",
                         originDeviceId: "mac", parentId: nil, targetDeviceId: nil, title: "挪一下",
                         changes: [], reason: "", action: .experimentNoop(note: "a"), experiment: true, state: .replied)
        let o = AgentBridgeIO.resultObject(p, at: Date())
        #expect(o["stateLabel"] as? String == "你回了一句，等智能体重新提")
    }
}

@MainActor @Suite struct W45ContextTests {
    @Test func dataSyncCautionReachesTheAgentContext() {
        var input = AgentContextInput(now: Date())
        #expect(AgentBridgeContext.snapshot(input)["dataSync"] == nil)
        input.dataSyncCaution = "App 刚启动 1 分钟，还没收到第一次 iCloud 同步：本机计划可能还不全"
        let o = AgentBridgeContext.snapshot(input)["dataSync"] as? [String: Any]
        #expect((o?["caution"] as? String)?.contains("还没收到第一次") == true && (o?["rule"] as? String)?.contains("别据此重排") == true)
    }
}
