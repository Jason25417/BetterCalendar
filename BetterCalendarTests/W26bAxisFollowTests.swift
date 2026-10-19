//
//  W26bAxisFollowTests.swift
//  BetterCalendarTests
//
//  W26b 时间轴日用跟进：
//  - 拖动贴边自动滚：边缘带里才滚、越靠边越快、到轴的两端停住；落点 = 手指位移 + 滚过的距离；
//  - iPhone 底边把手触控范围 ≥44pt，只伸进空档（不抢邻居）；
//  - 跨天挪（你拖的 / 批准智能体的）后，早晚通知若属于涉及的那天 → 按新计划重排；不属于 / 已过去 → 不动。
//  纪律：内存库显式 cloudKitDatabase: .none；容器随 rig 保活；固定时刻派生（注入时钟，不用 Date.now）；
//  UserDefaults 用独立 suite；不碰真 EventKit / 真通知（记录型假通知器）。
//

import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

@MainActor
@Suite struct W26bAxisFollowTests {
    private let cal = Calendar.current
    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }
    private func label(_ d: Int) -> Date { cal.startOfDay(for: at(d, 12)) }
    private func suite() -> UserDefaults { UserDefaults(suiteName: "bc.test.w26b.\(UUID().uuidString)")! }

    // MARK: 贴边自动滚

    @Test func autoScrollVelocityOnlyInEdgeBands() {
        let h: CGFloat = 600, e = AxisAutoScroller.edge
        #expect(AxisAutoScroller.velocity(fingerY: 300, viewport: h) == 0, "中间不滚")
        #expect(AxisAutoScroller.velocity(fingerY: e + 1, viewport: h) == 0)
        #expect(AxisAutoScroller.velocity(fingerY: h - e - 1, viewport: h) == 0)
        #expect(AxisAutoScroller.velocity(fingerY: 10, viewport: h) < 0, "贴上边往上滚")
        #expect(AxisAutoScroller.velocity(fingerY: h - 10, viewport: h) > 0, "贴下边往下滚")
        #expect(AxisAutoScroller.velocity(fingerY: h - 5, viewport: h) > AxisAutoScroller.velocity(fingerY: h - 30, viewport: h), "越靠边越快")
        #expect(AxisAutoScroller.velocity(fingerY: h + 80, viewport: h) == AxisAutoScroller.maxSpeed, "拖出视口 = 最快，不再加")
        #expect(AxisAutoScroller.velocity(fingerY: 5, viewport: 100) == 0, "视口太矮（小窗口）不自动滚")
    }

    @Test func autoScrollStopsAtTheAxisEnds() {
        // 内容 3000、视口 600 → 偏移只能在 [0, 2400]
        #expect(AxisAutoScroller.nextOffset(current: 2390, velocity: 900, dt: 0.05, content: 3000, viewport: 600) == 2400)
        #expect(AxisAutoScroller.nextOffset(current: 5, velocity: -900, dt: 0.05, content: 3000, viewport: 600) == 0)
        #expect(AxisAutoScroller.nextOffset(current: 100, velocity: 900, dt: 2, content: 3000, viewport: 600) == 190,
                "一帧卡顿很久也只走 0.1 秒的距离（不突然跳一大截）")
    }

    @Test func autoScrollAccumulatesDistanceAndStopsWhenLeavingTheEdge() async throws {
        let s = AxisAutoScroller()
        s.offsetY = 1000; s.viewportHeight = 600; s.contentHeight = 14_000
        var scrolledTo: [CGFloat] = []
        s.scrollTo = { scrolledTo.append($0) }
        s.begin()
        s.update(fingerY: 300)
        try await Task.sleep(for: .milliseconds(80))
        #expect(scrolledTo.isEmpty && s.delta == 0, "不在边缘带：不滚")
        s.update(fingerY: 595)
        for _ in 0..<100 where s.delta < 40 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(s.delta > 0, "贴下边：往下滚，滚过的距离累计")
        #expect(scrolledTo.last == s.offsetY && s.offsetY == 1000 + s.delta)
        s.update(fingerY: 300)
        try await Task.sleep(for: .milliseconds(80))
        let parked = s.offsetY
        try await Task.sleep(for: .milliseconds(80))
        #expect(s.offsetY == parked, "离开边缘带：停")
        let total = s.end()
        #expect(total == parked - 1000, "松手返回滚过的总距离（加到落点上）")
        #expect(s.delta == 0)
        // 到轴的一端：再贴边也不动
        s.offsetY = 13_400
        s.begin(); s.update(fingerY: 599)
        try await Task.sleep(for: .milliseconds(80))
        #expect(s.end() == 0 && s.offsetY == 13_400)
    }

    // MARK: 底边把手 ≥44pt，只伸进空档

    @Test func resizeHitAreaIsAtLeast44WhenThereIsRoomAndNeverIntoANeighbour() {
        let tall = AxisHitArea.resize(blockHeight: 104, gapBelow: 200, target: 44)
        #expect(tall.inside + tall.outside == 44)
        #expect(tall.inside <= 22, "块里只伸一点，块的大部分仍是「拖动整块」")
        let packed = AxisHitArea.resize(blockHeight: 104, gapBelow: 0, target: 44)
        #expect(packed.outside == 0, "下面紧挨着别的块：不伸过去抢它的点按 / 拖动")
        let tiny = AxisHitArea.resize(blockHeight: 13, gapBelow: 100, target: 44)
        #expect(tiny.inside < 13 && tiny.inside + tiny.outside == 44, "短块：块里少伸，空档里补足")
        let squeezed = AxisHitArea.resize(blockHeight: 4, gapBelow: 10, target: 44)
        #expect(squeezed.inside <= 4 && squeezed.outside == 10)
    }

    // MARK: 跨天挪 → 早晚通知重排

    @MainActor final class RecordingNotifier: NotificationScheduling {
        var calls: [(morning: Date?, evening: Date?, summary: String)] = []
        func requestAuthorizationIfNeeded() async {}
        func scheduleDailyReminders(morning: Date?, evening: Date?, summary: String) async {
            calls.append((morning, evening, summary))
        }
    }

    struct Rig {
        let axis: TimelineAxisModel
        let home: HomeViewModel
        let store: PlanStore
        let notifier: RecordingNotifier
        let defaults: UserDefaults
        let container: ModelContainer
    }

    private func rig(now: Date) throws -> Rig {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext, now: { now })
        struct NoRefine: PlanRefining {
            func refine(_ blocks: [ScheduledBlock], command: String,
                        originalRequest: String, now: Date) async throws -> [ScheduledBlock] { blocks }
        }
        let projected = FakeCalendarStore()
        let notifier = RecordingNotifier()
        let live = W23TimelineAxisTests.FakeLive()
        let home = HomeViewModel(
            arrangeDay: ArrangeDayUseCase(parser: FailedScheduleParser(), planner: NaivePlanningEngine()),
            refiner: NoRefine(), calendarStore: projected, reminderStore: FakeReminderStore(),
            exporter: ICSExporter(), planStore: store,
            projection: ProjectionService(planStore: store, calendarStore: projected),
            notifier: notifier, progress: live, now: { now })
        home.autoCommit = true
        home.relayoutLiveDay = false
        home.autosaveDelay = .milliseconds(20)
        let defaults = suite()
        home.reminderDefaults = defaults
        let axis = TimelineAxisModel(plans: store, actuals: store, calendar: W23TimelineAxisTests.StubCalendar(),
                                     live: live, home: home, now: { now })
        return Rig(axis: axis, home: home, store: store, notifier: notifier, defaults: defaults, container: container)
    }

    private func item(_ r: Rig, _ id: UUID) throws -> AxisItem {
        try #require(r.axis.days().flatMap(\.items).first { $0.blockID == id && $0.kind == .plan })
    }

    @Test func yourCrossDayDragReschedulesTheDayItsRemindersBelongTo() async throws {
        let now = at(20, 21)
        let r = try rig(now: now)
        let early = ScheduledBlock(title: "写论文", start: at(21, 8), end: at(21, 9))
        let later = ScheduledBlock(title: "健身", start: at(21, 10), end: at(21, 11))
        try r.store.replacePlanned([early, later], on: label(21))
        // 今晚在今天页把明天保存了一次 → 早晚通知排给明天（8:00 前 15 分钟）
        await r.home.focusDay(label(21))
        await r.home.confirm(celebrate: false)
        #expect(DailyReminderDay.current(in: r.defaults) == label(21))
        #expect(r.notifier.calls.last?.morning == at(21, 7, 45))
        let before = r.notifier.calls.count

        // 把明天的第一件拖到后天：明早的通知改到新的第一件（10:00）前 15 分钟、正文点名新的第一件
        await r.axis.reload()
        let reason = await r.axis.commitDrag(try item(r, early.id), start: at(22, 9))
        #expect(reason == nil, "\(reason ?? "")")
        #expect(r.notifier.calls.count == before + 1)
        let last = try #require(r.notifier.calls.last)
        #expect(last.morning == at(21, 9, 45) && last.evening == at(21, 11, 30))
        #expect(last.summary.contains("「健身」") && !last.summary.contains("写论文"))

        // 涉及的两天都不是已排通知的那天 → 不动（不把明天的通知换成别的日子的）
        let mid = r.notifier.calls.count
        let other = ScheduledBlock(title: "读文献", start: at(23, 9), end: at(23, 10))
        try r.store.insertPlanned([other])
        await r.axis.reload()
        let reason2 = await r.axis.commitDrag(try item(r, other.id), start: at(24, 9))
        #expect(reason2 == nil, "\(reason2 ?? "")")
        #expect(r.notifier.calls.count == mid)
    }

    @Test func approvedAgentCrossDayMoveReschedulesToo() async throws {
        let now = at(20, 21)
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext, now: { now })
        let notes = ScheduledBlock(title: "整理笔记", start: at(21, 14), end: at(21, 15))
        let gym = ScheduledBlock(title: "健身", start: at(21, 9), end: at(21, 10))
        try store.replacePlanned([gym, notes], on: label(21))
        let notifier = RecordingNotifier()
        let defaults = suite()
        DailyReminderDay.record(label(21), in: defaults)
        let mover = ApprovedPlanMover(planStore: store, projection: nil, startedDays: nil, now: { now })
        mover.enabledFlag = { true }
        mover.reminderRefresher = DailyReminderRefresher(plans: store, notifier: notifier, note: { _ in "慢慢来" },
                                                         defaults: defaults, now: { now })
        // 批准：把明天最后一件挪到后天 → 明晚的通知改到新的最后一件（10:00 结束）后 30 分钟
        let step = ProposalPlanStep.move(ProposalBlockMove(id: notes.id, start: at(22, 14), end: nil,
                                                           expectedRevision: ProposalRevision.block(notes)))
        _ = try await mover.apply([step], restoring: false, planDay: nil)
        let last = try #require(notifier.calls.last)
        #expect(last.morning == at(21, 8, 45) && last.evening == at(21, 10, 30))
        #expect(last.summary.contains("昨晚的你说：慢慢来"), "重排不冲掉「给明天的一句话」")
        #expect(try store.plannedBlocks(on: label(22)).first?.pinnedUntil == nil, "批准的挪动照旧不钉")
        _ = container
    }

    @Test func refresherLeavesPastDaysAloneAndSilencesLooseDays() async throws {
        let now = at(20, 21)
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext, now: { now })
        try store.replacePlanned([ScheduledBlock(title: "A", start: at(21, 9), end: at(21, 10))], on: label(21))
        let notifier = RecordingNotifier()
        let defaults = suite()
        // 已排的是昨天的：过去了，不动
        DailyReminderDay.record(label(19), in: defaults)
        let r1 = DailyReminderRefresher(plans: store, notifier: notifier, defaults: defaults, now: { now })
        #expect(await r1.refresh(affecting: [label(19), label(21)]) == false && notifier.calls.isEmpty)
        // 从没排过：不动
        let fresh = suite()
        #expect(await DailyReminderRefresher(plans: store, notifier: notifier, defaults: fresh, now: { now })
            .refresh(affecting: [label(21)]) == false)
        // 松散日：静音（与保存时同口径）
        DailyReminderDay.record(label(21), in: defaults)
        let loose = DailyReminderRefresher(plans: store, notifier: notifier, isLoose: { $0 == label(21) },
                                           defaults: defaults, now: { now })
        #expect(await loose.refresh(affecting: [label(21)]))
        #expect(notifier.calls.last?.morning == nil && notifier.calls.last?.evening == nil)
        // 今天：早上那条已经过去 → 只排晚上那条（不为过去的时刻报警告）
        try store.replacePlanned([ScheduledBlock(title: "B", start: at(20, 9), end: at(20, 22))], on: label(20))
        DailyReminderDay.record(label(20), in: defaults)
        let today = DailyReminderDay.current(in: defaults)
        #expect(today == label(20))
        #expect(await r1.refresh(affecting: [label(20)]))
        #expect(notifier.calls.last?.morning == nil && notifier.calls.last?.evening == at(20, 22, 30))
        _ = container
    }
}
