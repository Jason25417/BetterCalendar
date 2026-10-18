//
//  P4OwnershipTests.swift
//  BetterCalendarTests
//
//  W9：P4 按「谁的东西谁做主」实施（SPEC §19.13 Q1–Q4、Q6、Q7/Q8）。
//  两色流水线（橙色退役、一件事只画一次）、日历删除收进待办区、你的日历只关联不复制且作已占用、
//  图钉（自动调整绕开、智能体要动须越级）、章 v2（事件自证 + 版本）与作者宽限。
//  全部用假日历 SimulatedEventKitCalendar × 内存 SwiftData；时钟注入，不用 Date.now。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

private let cal = Calendar.current
/// 固定基准：2026-10-20（周二）。
private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
}

@MainActor private final class Clock { var now: Date; init(_ d: Date) { now = d } }

// MARK: - 纯函数

@MainActor
@Suite struct P4PureRuleTests {
    @Test func stampRoundTripsAndLegacyStillParses() throws {
        let id = UUID()
        let v2 = CalendarStamp(blockID: id, version: 1_760_000_000_123, hash: "abcd1234abcd1234")
        let parsed = try #require(CalendarStamp.parse(v2.url))
        #expect(parsed == v2)
        let legacy = try #require(CalendarStamp.parse(URL(string: "bettercalendar://block/\(id.uuidString)")))
        #expect(legacy.blockID == id && legacy.version == nil && legacy.hash == nil)
        #expect(EventKitCalendarStore.blockID(from: v2.url) == id, "老的解析入口照样认得 v2 章")
        #expect(CalendarStamp.parse(URL(string: "https://example.com/block/\(id.uuidString)")) == nil)
    }

    @Test func untouchedCheckIsSelfEvidentFromContent() {
        var d = CalendarEventDraft(title: "写作", start: at(20, 9), end: at(20, 10), kind: .planned, blockID: UUID())
        d.stampV2(version: 5)
        #expect(d.isUntouchedSinceStamped == true)
        d.start = at(20, 9, 30)
        #expect(d.isUntouchedSinceStamped == false, "你在日历里动过")
        let legacy = CalendarEventDraft(title: "x", start: at(20, 9), end: at(20, 10), kind: .planned, blockID: UUID())
        #expect(legacy.isUntouchedSinceStamped == nil, "旧章判不了，退回本机指纹")
    }

    @Test func plannerRestampsLegacyEventWithoutTouchingContent() {
        let id = UUID()
        let legacy = CalendarEventSnapshot(title: "写作", start: at(20, 9), end: at(20, 10), blockID: id)
        var want = CalendarEventDraft(title: "写作", start: at(20, 9), end: at(20, 10), kind: .planned, blockID: id)
        want.stampV2(version: 7)
        let p = CalendarSyncPlanner.plan(existing: [legacy], drafts: [want], from: at(20, 4), to: at(21, 4))
        #expect(p.updates.count == 1 && p.creates.isEmpty && p.deletes.isEmpty, "补成 v2 章")
        var stamped = legacy; stamped.stampVersion = 7; stamped.stampHash = want.stampHash
        let again = CalendarSyncPlanner.plan(existing: [stamped], drafts: [want], from: at(20, 4), to: at(21, 4))
        #expect(again.updates.isEmpty, "章一致就不再写")
    }

    /// Q2：一件事只画一次——做完的只剩蓝；正在做的只画剩下那段；被动推断的（固定块到点）绿色照留；关联的不画。
    @Test func twoColorRuleDrawsEachThingOnce() {
        let done = ScheduledBlock(title: "做完", start: at(20, 9), end: at(20, 10))
        let live = ScheduledBlock(title: "在做", start: at(20, 10), end: at(20, 12))
        let auto = ScheduledBlock(title: "组会", start: at(20, 8), end: at(20, 9), isFixed: true)
        let plain = ScheduledBlock(title: "之后", start: at(20, 14), end: at(20, 15))
        let linked = ScheduledBlock(title: "上 5529 课", start: at(20, 15), end: at(20, 16))
        let liveAlmostOver = ScheduledBlock(title: "快完", start: at(20, 16), end: at(20, 17))
        let actuals: [UUID: ActualBlock] = [
            done.id: ActualBlock(id: done.id, title: "做完", start: at(20, 9), end: at(20, 9, 40)),
            live.id: ActualBlock(id: live.id, title: "在做", start: at(20, 10, 5), end: at(20, 10, 45), state: .live),
            auto.id: ActualBlock(id: auto.id, title: "组会", start: at(20, 8), end: at(20, 9), state: .auto),
            liveAlmostOver.id: ActualBlock(id: liveAlmostOver.id, title: "快完", start: at(20, 16), end: at(20, 16, 59), state: .live),
        ]
        let r = GreenPresentation.present(blocks: [done, live, auto, plain, linked, liveAlmostOver], actuals: actuals,
                                          linked: [linked.id])
        #expect(r.hidden[done.id] == .done)
        #expect(r.hidden[linked.id] == .linked)
        #expect(r.hidden[liveAlmostOver.id] == .done, "剩不到 1 分钟不画细线")
        let l = r.item(live.id)
        #expect(l?.start == at(20, 10, 45) && l?.end == at(20, 12) && l?.clipped == true)
        #expect(r.item(auto.id)?.start == at(20, 8), "被动推断不画蓝 → 绿色是它唯一的一份")
        #expect(r.item(plain.id)?.clipped == false)
    }

    /// Q4：只关联不复制——课号/标题相同且时间大半重叠才算同一件事；一件事件只配一个块（确定性）。
    @Test func linkerMatchesSameThingOnly() {
        let course = ScheduledBlock(title: "上 5529 课", start: at(20, 14), end: at(20, 16, 30), isFixed: true)
        let gym = ScheduledBlock(title: "健身", start: at(20, 17), end: at(20, 18))
        let other = ScheduledBlock(title: "写论文", start: at(20, 14), end: at(20, 15))
        let events = [
            SystemCalendarEvent(title: "MATH 5529H", start: at(20, 14, 20), end: at(20, 15, 40), isAllDay: false, calendarTitle: "个人", externalID: "m"),
            SystemCalendarEvent(title: "Dentist", start: at(20, 17), end: at(20, 18), isAllDay: false, calendarTitle: "个人", externalID: "d"),
            SystemCalendarEvent(title: "健身", start: at(20, 0), end: at(21, 0), isAllDay: true, calendarTitle: "个人", externalID: "a"),
        ]
        let links = ExternalEventLinker.links(blocks: [course, gym, other], events: events)
        #expect(links[course.id]?.externalID == "m")
        #expect(links[gym.id] == nil, "同一时间但不是同一件事、全天事件不参与")
        #expect(links[other.id] == nil, "一件事件只配一个块")
        #expect(ExternalCalendarSettings.busy(events, excluding: ["个人"]).isEmpty)
        #expect(ExternalCalendarSettings.busy(events, excluding: []).map(\.externalID) == ["m", "d"], "全天不占时段")
    }

    @Test func massDeletionGuardThreshold() {
        #expect(!ReconcileService.isMassDeletion(count: 2, drawn: 2), "少于 3 件不算")
        #expect(ReconcileService.isMassDeletion(count: 3, drawn: 5))
        #expect(!ReconcileService.isMassDeletion(count: 3, drawn: 6))
    }
}

// MARK: - 端到端：投影 × 对账 × 假日历

@MainActor
@Suite struct P4PipelineTests {
    private struct Rig {
        let clock: Clock
        let plan: PlanStore
        let calendar: SimulatedEventKitCalendar
        let projection: ProjectionService
        let reconcile: ReconcileService
        let defaults: UserDefaults
        let container: ModelContainer   // 保活
        @MainActor var today: Date { DayContext.logicalStartOfDay(clock.now) }
    }

    private func rig(writer: String = "mac", now: Date = at(20, 13)) throws -> Rig {
        let container = try ModelContainer(for: PlanBlock.self, LongTask.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let clock = Clock(now)
        let plan = PlanStore(context: container.mainContext, writerID: writer, now: { clock.now })
        let defaults = try #require(UserDefaults(suiteName: "bc-p4-own-\(UUID().uuidString)"))
        let calendar = SimulatedEventKitCalendar(now: now)
        let projection = ProjectionService(planStore: plan, calendarStore: calendar, localWriter: writer,
                                           fingerprintDefaults: defaults, now: { clock.now })
        let reconcile = ReconcileService(planReader: plan, planWriter: plan, calendarStore: calendar, projection: projection,
                                         defaults: defaults, now: { clock.now }, calendarAuthorized: { true })
        return Rig(clock: clock, plan: plan, calendar: calendar, projection: projection, reconcile: reconcile,
                   defaults: defaults, container: container)
    }

    private func green(_ r: Rig, _ id: UUID) -> [SimulatedEventKitCalendar.Event] {
        r.calendar.events(.planned).filter { $0.blockID == id }
    }

    /// Q1：启动清扫只删预览日历里带章的旧橙块；你的事件留着、日历不删，App 提示你挪走。
    @Test func previewRetirementSweepsOnlyStampedOrange() async throws {
        let r = try rig()
        r.calendar.seed(.preview, "午饭", at(20, 12), at(20, 13), blockID: UUID())             // 今天的旧橙块
        r.calendar.seed(.preview, "复习整理", at(1, 20), at(1, 21), blockID: UUID())           // 10/1 的僵尸
        r.calendar.seed(.preview, "STAT 4194", at(21, 8), at(21, 9, 15))                       // 你的课
        await r.reconcile.startupSync()
        #expect(r.calendar.events(.preview).map(\.title) == ["STAT 4194"])
        #expect(r.reconcile.calendarNotice?.contains("STAT 4194") == true)
    }

    /// Q2：开工的日子绿色照常投（不再清空），对账也照常认你在日历里的改动。
    @Test func startedDayStillDrawsGreenAndReconciles() async throws {
        let r = try rig()
        let b = ScheduledBlock(title: "写作", start: at(20, 15), end: at(20, 16))
        try r.plan.replacePlanned([b], on: r.today)
        try await r.projection.project(label: r.today)
        #expect(green(r, b.id).count == 1)
        r.calendar.edit(try #require(green(r, b.id).first).externalID, start: at(20, 17), end: at(20, 18))
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: r.today).first?.start == at(20, 17))
        #expect(r.calendar.events(.preview).isEmpty)
    }

    /// Q2 端到端：做完 → 绿让位；正在做 → 只画剩下那段；你在日历里改那段的结束 → 只认结束（开始是实际开始）。
    @Test func liveBlockGreenRemainderFollowsBlueAndEditsKeepActualStart() async throws {
        let r = try rig()
        let live = ScheduledBlock(title: "在做", start: at(20, 12), end: at(20, 15))
        let done = ScheduledBlock(title: "做完", start: at(20, 9), end: at(20, 10))
        try r.plan.replacePlanned([live, done], on: r.today)
        try r.plan.upsertActuals([ActualBlock(id: done.id, title: "做完", start: at(20, 9), end: at(20, 9, 50)),
                                  ActualBlock(id: live.id, title: "在做", start: at(20, 12), end: at(20, 13), state: .live)])
        try await r.projection.project(label: r.today)
        #expect(green(r, done.id).isEmpty, "做完的只剩蓝")
        let rem = try #require(green(r, live.id).first)
        #expect(rem.start == at(20, 13) && rem.end == at(20, 15))
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: r.today).first { $0.id == live.id }?.start == at(20, 12), "回声不回流")

        r.calendar.edit(rem.externalID, start: at(20, 13), end: at(20, 16))   // 你把剩下那段拉长到 16:00
        await r.reconcile.reconcileWindow()
        let row = try #require(try r.plan.plannedBlocks(on: r.today).first { $0.id == live.id })
        #expect(row.start == at(20, 12) && row.end == at(20, 16))
        #expect(row.isPinned(at: r.clock.now))
    }

    /// Q4：你自己日历里的同一节课 → 不画绿（只关联）。
    @Test func linkedBlockIsNotDuplicatedInGreen() async throws {
        let r = try rig()
        r.calendar.userEvents = [SystemCalendarEvent(title: "MATH 5529H", start: at(21, 14, 20), end: at(21, 15, 40),
                                                     isAllDay: false, calendarTitle: "个人", externalID: "m5529")]
        let course = ScheduledBlock(title: "上 5529 课", start: at(21, 14), end: at(21, 16), isFixed: true)
        let other = ScheduledBlock(title: "写作", start: at(21, 9), end: at(21, 10))
        let day = DayContext.logicalDay(offset: 1, from: r.clock.now)
        try r.plan.replacePlanned([course, other], on: day)
        try await r.projection.project(label: day)
        #expect(green(r, course.id).isEmpty)
        #expect(green(r, other.id).count == 1)
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: day).count == 2, "不画 ≠ 被删")
    }

    /// Q3：你在日历里删了一块 → 立即照办：移出时间线、收进待办区、通知桥接；不弹窗。
    @Test func calendarDeletionIsObeyedCollectedAndReported() async throws {
        let r = try rig()
        let pool = LongTaskStore(context: r.container.mainContext)
        var reported: [CalendarUserDeletion] = []
        r.reconcile.collectTodo = { b, _ in _ = pool.addTodo(title: b.title, family: b.family, deadline: b.deadline); return true }
        r.reconcile.onUserDeleted = { reported += $0 }
        let a = ScheduledBlock(title: "读论文", start: at(21, 9), end: at(21, 10))
        let b = ScheduledBlock(title: "跑步", start: at(21, 18), end: at(21, 19))
        let day = DayContext.logicalDay(offset: 1, from: r.clock.now)
        try r.plan.replacePlanned([a, b], on: day)
        try await r.projection.project(label: day)
        r.calendar.delete(try #require(green(r, a.id).first).externalID)
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: day).map(\.id) == [b.id])
        #expect(pool.todoItems().map(\.title) == ["读论文"])
        #expect(reported.map(\.block.title) == ["读论文"] && reported.first?.collectedToTodo == true)
        await r.reconcile.reconcileWindow()
        #expect(reported.count == 1 && pool.todoItems().count == 1, "只照办一次")
        let payload = AgentCalendarEvents.deletionPayload(reported)
        #expect((payload["deletions"] as? [[String: Any]])?.first?["handled"] as? String == "movedToTodo")
    }

    /// Q3 保护：同一天一大半同时不见（像同步错序）→ 先等，2 分钟后仍不见才照办。
    @Test func massDeletionWaitsBeforeObeying() async throws {
        let r = try rig()
        let day = DayContext.logicalDay(offset: 1, from: r.clock.now)
        let blocks = (0..<4).map { ScheduledBlock(title: "块\($0)", start: at(21, 9 + $0), end: at(21, 9 + $0, 50)) }
        try r.plan.replacePlanned(blocks, on: day)
        try await r.projection.project(label: day)
        for b in blocks { r.calendar.delete(try #require(green(r, b.id).first).externalID) }
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: day).count == 4, "先等")
        r.clock.now = r.clock.now.addingTimeInterval(3 * 60)
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: day).isEmpty, "仍不见 → 照办")
    }

    /// 正在做的块：你删的是计划剩下那段 → 计划到此为止（不删这件事、不收待办）。
    @Test func deletingLiveRemainderTrimsPlanInsteadOfDeleting() async throws {
        let r = try rig()
        let live = ScheduledBlock(title: "在做", start: at(20, 12), end: at(20, 15))
        try r.plan.replacePlanned([live], on: r.today)
        try r.plan.upsertActuals([ActualBlock(id: live.id, title: "在做", start: at(20, 12), end: at(20, 13), state: .live)])
        try await r.projection.project(label: r.today)
        var collected = 0
        r.reconcile.collectTodo = { _, _ in collected += 1; return true }
        r.calendar.delete(try #require(green(r, live.id).first).externalID)
        await r.reconcile.reconcileWindow()
        let row = try #require(try r.plan.plannedBlocks(on: r.today).first)
        #expect(row.start == at(20, 12) && row.end == at(20, 13))
        #expect(collected == 0)
        #expect(green(r, live.id).isEmpty)
    }

    /// 回声：我们自己画的旧画面（v2 章写后没动过）→ 重画，绝不当成你的改动采纳（不钉）。
    @Test func untouchedOldDrawingIsRepaintedNotAdopted() async throws {
        let r = try rig()
        let b = ScheduledBlock(title: "写作", start: at(21, 9), end: at(21, 10))
        let day = DayContext.logicalDay(offset: 1, from: r.clock.now)
        try r.plan.replacePlanned([b], on: day)
        try await r.projection.project(label: day)
        r.clock.now = r.clock.now.addingTimeInterval(60)
        try r.plan.updatePlanned(id: b.id, start: at(21, 11), end: at(21, 12), title: "写作", reason: .timelineCoordinator)
        await r.reconcile.reconcileWindow()
        let row = try #require(try r.plan.plannedBlocks(on: day).first)
        #expect(row.start == at(21, 11) && !row.isPinned(at: r.clock.now))
        #expect(green(r, b.id).first?.start == at(21, 11), "画面跟上真相")
    }

    /// 你的操作 ＞ 自动调整：画面画好后协调器挪了它，同时你在日历里也改了 → 你赢，并钉住。
    @Test func calendarEditBeatsAutomaticAdjustment() async throws {
        let r = try rig()
        let b = ScheduledBlock(title: "写作", start: at(21, 9), end: at(21, 10))
        let day = DayContext.logicalDay(offset: 1, from: r.clock.now)
        try r.plan.replacePlanned([b], on: day)
        try await r.projection.project(label: day)
        r.clock.now = r.clock.now.addingTimeInterval(60)
        try r.plan.updatePlanned(id: b.id, start: at(21, 11), end: at(21, 12), title: "写作", reason: .timelineCoordinator)
        r.calendar.edit(try #require(green(r, b.id).first).externalID, start: at(21, 15), end: at(21, 16))
        await r.reconcile.reconcileWindow()
        let row = try #require(try r.plan.plannedBlocks(on: day).first)
        #expect(row.start == at(21, 15) && row.isPinned(at: r.clock.now))
    }

    /// 两边都是你：App 里改过、日历里也改过 → 后改的赢（看事件修改时间）。
    @Test func bothYoursLaterEditWins() async throws {
        let r = try rig()
        let b = ScheduledBlock(title: "写作", start: at(21, 9), end: at(21, 10))
        let day = DayContext.logicalDay(offset: 1, from: r.clock.now)
        try r.plan.replacePlanned([b], on: day)
        try await r.projection.project(label: day)
        r.clock.now = r.clock.now.addingTimeInterval(60)
        try r.plan.updatePlanned(id: b.id, start: at(21, 11), end: at(21, 12), title: "写作", reason: .userEdit)
        let ext = try #require(green(r, b.id).first).externalID
        r.calendar.edit(ext, start: at(21, 15), end: at(21, 16), at: r.clock.now.addingTimeInterval(-30))   // 日历那次更早
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: day).first?.start == at(21, 11), "App 里那次更晚 → 它赢")
        #expect(green(r, b.id).first?.start == at(21, 11))
        r.calendar.edit(ext, start: at(21, 16), end: at(21, 17), at: r.clock.now.addingTimeInterval(30))     // 现在日历这次更晚
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: day).first?.start == at(21, 16))
    }

    /// Q8 另一台设备更新的画面：章的版本比本机真相新（本机数据还在路上）→ 不拿旧真相去盖，也不当成你的改动。
    @Test func newerStampFromAnotherDeviceIsLeftAlone() async throws {
        let r = try rig()
        let b = ScheduledBlock(title: "写作", start: at(21, 9), end: at(21, 10))
        let day = DayContext.logicalDay(offset: 1, from: r.clock.now)
        try r.plan.replacePlanned([b], on: day)
        try await r.projection.project(label: day)
        let truthV = try #require(try r.plan.plannedBlocks(on: day).first).syncVersion
        // iPhone 刚把它挪到 11:00 并重画（新版本、内容指纹一致），本机 CloudKit 还没导入
        var phone = CalendarEventDraft(title: "写作", start: at(21, 11), end: at(21, 12), kind: .planned, blockID: b.id)
        phone.stampV2(version: truthV + 30_000)
        try await r.calendar.apply([phone], kind: .planned, window: DayContext.logicalWindow(forLabel: day))
        #expect(green(r, b.id).count == 1 && green(r, b.id).first?.start == at(21, 11))
        try await r.projection.project(label: day)
        #expect(green(r, b.id).first?.start == at(21, 11), "不盖掉另一台设备的新画面")
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: day).first?.start == at(21, 9), "也不当成你的改动")
        // 超过宽限还对不上 → 真相赢
        r.clock.now = r.clock.now.addingTimeInterval(ProjectionService.authorGrace + 60)
        try await r.projection.project(label: day)
        #expect(green(r, b.id).first?.start == at(21, 9))
    }

    /// Q8 作者宽限：另一台设备刚写的块、日历里还没有 → 本机先不替它画（防两份）；超过宽限再补。日历里没有也不算删除。
    @Test func authorGraceDefersCreationOnOtherDevice() async throws {
        let phone = try rig(writer: "iphone")
        let b = ScheduledBlock(title: "写作", start: at(21, 9), end: at(21, 10))
        let day = DayContext.logicalDay(offset: 1, from: phone.clock.now)
        try phone.plan.replacePlanned([b], on: day)   // iPhone 写的（syncWriter = iphone）
        let mac = ProjectionService(planStore: phone.plan, calendarStore: phone.calendar, localWriter: "mac",
                                    fingerprintDefaults: phone.defaults, now: { phone.clock.now })
        try await mac.project(label: day)
        #expect(green(phone, b.id).isEmpty, "宽限内不替它建")
        phone.clock.now = phone.clock.now.addingTimeInterval(ProjectionService.authorGrace + 60)
        try await mac.project(label: day)
        #expect(green(phone, b.id).count == 1, "过了宽限补画一份")
    }

    /// 收敛：投影 + 对账反复跑，画面稳定后零写入（不来回打转）。
    @Test func pipelineConvergesWithoutFurtherWrites() async throws {
        let r = try rig()
        let blocks = [ScheduledBlock(title: "A", start: at(20, 15), end: at(20, 16)),
                      ScheduledBlock(title: "B", start: at(21, 9), end: at(21, 10))]
        try r.plan.replacePlanned([blocks[0]], on: r.today)
        try r.plan.replacePlanned([blocks[1]], on: DayContext.logicalDay(offset: 1, from: r.clock.now))
        r.calendar.seed(.planned, "A", at(20, 15), at(20, 16), blockID: blocks[0].id)   // 旧章（补成 v2）
        await r.reconcile.reconcileWindow()
        await r.reconcile.reconcileWindow()
        let settled = r.calendar.writes
        for _ in 0..<3 {
            await r.reconcile.reconcileWindow()
            try await r.projection.project(label: r.today)
        }
        #expect(r.calendar.writes == settled)
        #expect(r.calendar.events(.planned).allSatisfy { $0.stampHash != nil }, "旧章都补成 v2")
    }
}

// MARK: - 时间线协调器：图钉 + 你的日历作已占用（只改输入，影子期等价）

@MainActor
@Suite struct P4TimelineInputTests {
    private let base: Date = Calendar.current.startOfDay(for: DayContext.logicalDay(offset: 0))
    private func t(_ h: Int, _ mi: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + mi, to: base)! }

    private func make(_ blocks: [ScheduledBlock]) throws -> (TimelineCoordinator, PlanStore, ModelContainer) {
        let container = try ModelContainer(for: PlanBlock.self, LongTask.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let plan = PlanStore(context: container.mainContext)
        let started = StartedDayStore(persisted: false)
        let now = t(13)
        let traces = ChangeTraceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("p4-trace-\(UUID().uuidString)", isDirectory: true))
        let co = TimelineCoordinator(planStore: plan, startedDays: started, traces: traces,
                                     markerDefaults: UserDefaults(suiteName: "bc-p4-co-\(UUID().uuidString)")!, now: { now })
        started.markStarted(DayContext.logicalStartOfDay(now))
        try plan.replacePlanned(blocks, on: DayContext.logicalStartOfDay(now))
        return (co, plan, container)
    }

    private func rows(_ p: PlanStore) throws -> [UUID: ScheduledBlock] {
        Dictionary(uniqueKeysWithValues: try p.plannedBlocks(on: DayContext.logicalStartOfDay(t(13))).map { ($0.id, $0) })
    }

    /// Q6：图钉不被自动调整挪动（没有图钉时同一块 Δ=3h 本该被拉到现在）。
    @Test func pinnedBlockIsNeverMovedByCoordinator() async throws {
        let stale = ScheduledBlock(title: "过点块", start: t(10), end: t(11))
        let (co, plan, keep) = try make([stale]); _ = keep
        try plan.setPinned(ids: [stale.id], until: ScheduledBlock.pinExpiry(forStart: stale.start))
        #expect(await co.recompute(reason: "测试") == 0)
        #expect(try rows(plan)[stale.id]?.start == t(10))
    }

    /// Q4：你日历里的事件是钉死的障碍——被顺延的块绕开它（不写你的日历、不进结果）。
    @Test func externalEventIsAnObstacle() async throws {
        let stale = ScheduledBlock(title: "过点块", start: t(10), end: t(11))
        let (co, plan, keep) = try make([stale]); _ = keep
        co.externalBusy = { _ in [SystemCalendarEvent(title: "Office hour", start: t(12, 30), end: t(14), isAllDay: false,
                                                      calendarTitle: "个人", externalID: "oh")] }
        #expect(await co.recompute(reason: "测试") == 1)
        let row = try #require(try rows(plan)[stale.id])
        #expect(row.start >= t(14), "从现在起排、绕开你 13:00–14:00 的安排")
        #expect(!co.softSpilledIDs.contains(where: { $0 != stale.id }), "障碍不会出现在软溢出里")
    }

    /// 影子期等价：不接你的日历（nil）与接了但没有事件（[]）结果逐字相同——P4 只改输入、不改引擎。
    @Test func emptyExternalBusyIsEquivalentToNone() async throws {
        let blocks = [ScheduledBlock(title: "过点块", start: t(10), end: t(11)),
                      ScheduledBlock(title: "下午", start: t(15), end: t(16)),
                      ScheduledBlock(title: "会", start: t(16), end: t(17), isFixed: true)]
        let (a, pa, k1) = try make(blocks); _ = k1
        let (b, pb, k2) = try make(blocks); _ = k2
        b.externalBusy = { _ in [] }
        #expect(await a.recompute(reason: "测试") == (await b.recompute(reason: "测试")))
        let ra = try rows(pa), rb = try rows(pb)
        for x in blocks { #expect(ra[x.id]?.start == rb[x.id]?.start && ra[x.id]?.end == rb[x.id]?.end) }
        #expect(a.softSpilledIDs == b.softSpilledIDs)
    }

    /// Q4：关联了你日历事件的块（同一件事）钉在原位，不被当成「被你的事件挡住」而挪走。
    @Test func linkedBlockStaysOnItsOwnEvent() async throws {
        let course = ScheduledBlock(title: "上 5529 课", start: t(14), end: t(15, 30))
        let (co, plan, keep) = try make([course]); _ = keep
        co.externalBusy = { _ in [SystemCalendarEvent(title: "MATH 5529H", start: t(14, 10), end: t(15, 30), isAllDay: false,
                                                      calendarTitle: "个人", externalID: "m")] }
        #expect(await co.recompute(reason: "测试") == 0)
        #expect(try rows(plan)[course.id]?.start == t(14))
    }
}

// MARK: - 智能体要动图钉 = 越级

@MainActor
@Suite struct P4EscalationTests {
    private func rig() throws -> (ProposalCenter, PlanStore, ScheduledBlock, ScheduledBlock, ModelContainer) {
        let container = try ModelContainer(for: DataArchiveStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let now = at(20, 10)
        let plans = PlanStore(context: container.mainContext, now: { now })
        let pinned = ScheduledBlock(title: "整理笔记", start: at(20, 11), end: at(20, 12))
        let free = ScheduledBlock(title: "跑步", start: at(20, 18), end: at(20, 19))
        try plans.replacePlanned([pinned, free], on: cal.startOfDay(for: now))
        try plans.setPinned(ids: [pinned.id], until: ScheduledBlock.pinExpiry(forStart: pinned.start))
        let mover = ApprovedPlanMover(planStore: plans, projection: nil, startedDays: nil, now: { now })
        let executor = ProposalActionExecutor(items: LongTaskStore(context: container.mainContext), mover: mover,
                                              deviceId: "mac", now: { now })
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: executor, notifier: SilentProposalNotifier(),
                                    ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac", now: { now })
        return (center, plans, pinned, free, container)
    }

    private func draft(_ action: ProposalAction, escalation: String? = nil) -> ProposalDraft {
        var d = ProposalDraft(origin: .agent, originLabel: "BetterCalendar 智能体", title: "挪一下", changes: [],
                              reason: "测试", action: action, experiment: false)
        d.escalation = escalation
        return d
    }

    @Test func movingAPinNeedsEscalationAndIsFlagged() async throws {
        let (center, _, pinned, free, keep) = try rig(); _ = keep
        let move = ProposalAction.moveBlock(id: pinned.id, start: at(20, 14), end: nil, expectedRevision: nil)
        #expect(await center.submit(draft(move)) == nil)
        #expect(center.lastError?.contains("亲手放的位置") == true)
        let p = try #require(await center.submit(draft(move, escalation: "他说下午才有空，上午这块得让给面试")))
        #expect(p.escalation != nil)
        #expect(p.changes.first?.field.contains("这会动你亲手放的位置") == true)
        #expect(p.state == .pending, "越级永远先问你")
        // 组里任一块是图钉也一样
        let group = ProposalAction.moveBlocks(moves: [ProposalBlockMove(id: free.id, start: at(20, 20), end: nil, expectedRevision: nil),
                                                      ProposalBlockMove(id: pinned.id, start: at(20, 15), end: nil, expectedRevision: nil)],
                                              isUndo: false)
        #expect(await center.submit(draft(group)) == nil)
        // 不碰图钉的挪动照常（无需越级）
        let plain = try #require(await center.submit(draft(.moveBlock(id: free.id, start: at(20, 20), end: nil, expectedRevision: nil))))
        #expect(plain.escalation == nil)
    }

    /// 你批准的挪动 = 你亲手放的：执行后钉住（当天自动调整绕开）。
    @Test func approvedMovePinsTheBlock() async throws {
        let (center, plans, _, free, keep) = try rig(); _ = keep
        let p = try #require(await center.submit(draft(.moveBlock(id: free.id, start: at(20, 20), end: nil, expectedRevision: nil))))
        await center.decide(p.id, .approve)
        await center.refresh()
        let row = try #require(try plans.plannedBlocks(on: cal.startOfDay(for: at(20, 10))).first { $0.id == free.id })
        #expect(row.start == at(20, 20) && row.isPinned(at: at(20, 10)))
    }
}
