//
//  W23TimelineAxisTests.swift
//  BetterCalendarTests
//
//  W23 今天页时间轴：几何（跨 4:00 日界线）、闸门（正在做的块蓝到现在 / 绿是剩下的）、红线（过去只画蓝、
//  没做的计划不留虚影、过去的截止不画）、过去 / 做成的 / 你的日历不能拖、拖动与拉底边写对时间并钉住、
//  放不下写明原因且什么都不改、你的日历只读并当已占用。另：可选的离屏截图（TEST_RUNNER_BC_W23_SHOTS）。
//

import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import BetterCalendar
#if os(macOS)
import AppKit
#endif

@MainActor
@Suite struct W23TimelineAxisTests {
    private let cal = Calendar.current
    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }
    private func label(_ d: Int) -> Date { cal.startOfDay(for: at(d, 12)) }

    // MARK: 几何：时间 ↔ 位置，跨 4:00 日界线连续

    @Test func geometryIsContinuousAcrossTheFourOClockPin() {
        let labels = [label(19), label(20), label(21)]
        let g = AxisGeometry(labels: labels, pointsPerHour: 60)
        #expect(g.start == at(19, 4), "轴顶 = 第一个逻辑日的 4:00")
        #expect(g.end == at(22, 4))
        // 20 日凌晨 3:59（日历 21 日）仍属 20 日这个逻辑日，紧贴在 21 日 4:00 图钉之上
        let lateNight = at(21, 3, 59), pin = at(21, 4)
        #expect(DayContext.logicalStartOfDay(lateNight) == label(20))
        #expect(abs((g.y(pin) - g.y(lateNight)) - 1) < 0.001, "一分钟 = 1pt（60pt/小时），过 4:00 不跳")
        #expect(g.section(label(21)).top == g.y(pin), "21 日那一段从它的 4:00 图钉开始")
        #expect(g.y(lateNight) < g.section(label(21)).top)
        #expect(g.y(lateNight) > g.section(label(20)).top)
        // 位置 → 时间是逆运算
        for t in [at(19, 9, 30), lateNight, pin, at(21, 23, 15)] {
            #expect(abs(g.time(atY: g.y(t)).timeIntervalSince(t)) < 0.01)
        }
        // 一段的高度 = 这一天的真实长度（普通日 24 小时）
        #expect(abs(g.section(label(20)).height - 24 * 60) < 0.001)
    }

    @Test func snapsToFiveMinutes() {
        #expect(AxisGeometry.snap(at(20, 14, 32)) == at(20, 14, 30))
        #expect(AxisGeometry.snap(at(20, 14, 33)) == at(20, 14, 35))
        #expect(AxisGeometry.snap(at(20, 14, 35)) == at(20, 14, 35))
    }

    // MARK: 闸门：正在做的块跨在线上

    @Test func runningBlockSplitsAtTheGate() {
        let now = at(20, 14)
        let b = ScheduledBlock(title: "写论文", start: at(20, 13), end: at(20, 15))
        let days = TimelineAxisComposer.compose(AxisInput(
            labels: [label(20)], now: now, planned: [b], actuals: [],
            running: [AxisRunning(plannedID: b.id, title: "写论文", start: at(20, 13, 10))]))
        let items = days[0].items
        let blue = try? #require(items.first { $0.kind == .actual })
        let green = try? #require(items.first { $0.kind == .plan })
        #expect(blue?.start == at(20, 13, 10) && blue?.end == now, "蓝色从开始长到现在")
        #expect(blue?.isRunning == true)
        #expect(green?.start == now && green?.end == at(20, 15), "绿色只画剩下那段")
        #expect(green?.isRunning == true && green?.isDraggable == false, "正在做的不拖")
        #expect(items.count == 2)
    }

    // MARK: 红线：过去只画蓝，没做的计划不留尸体 / 虚影；过去的截止不画

    @Test func pastSideShowsOnlyWhatWasDone() {
        let now = at(20, 14)
        let missed = ScheduledBlock(title: "读文献", start: at(20, 9), end: at(20, 10), deadline: at(20, 11))
        let done = ScheduledBlock(title: "健身", start: at(20, 11), end: at(20, 12))
        let straddle = ScheduledBlock(title: "回邮件", start: at(20, 13, 30), end: at(20, 14, 30))
        let future = ScheduledBlock(title: "组会", start: at(20, 16), end: at(20, 17), isFixed: true, deadline: at(20, 18))
        let yesterday = ScheduledBlock(title: "昨天的计划", start: at(19, 10), end: at(19, 11))
        let days = TimelineAxisComposer.compose(AxisInput(
            labels: [label(19), label(20)], now: now, planned: [missed, done, straddle, future, yesterday],
            actuals: [AxisActual(title: "健身", start: at(20, 11, 10), end: at(20, 12), plannedID: done.id),
                      AxisActual(title: "散步", start: at(19, 18), end: at(19, 19), plannedID: nil)],
            windDownHour: 23))
        let all = days.flatMap(\.items)
        // 闸门以上没有任何绿色
        #expect(!all.contains { $0.kind == .plan && $0.start < now }, "R1：绿色只活在现在之后")
        #expect(!all.contains { $0.blockID == missed.id }, "没做的计划不留尸体 / 虚影 / 空槽")
        #expect(!all.contains { $0.blockID == yesterday.id })
        #expect(all.filter { $0.kind == .actual }.map(\.title).sorted() == ["健身", "散步"], "过去只有做成的事（含计划外）")
        #expect(!all.contains { $0.kind == .plan && $0.blockID == done.id }, "做完的绿色让位给蓝色")
        // 跨着现在、没开始的：只画从现在起剩下的（不画成「迟到」）
        let s = all.first { $0.blockID == straddle.id }
        #expect(s?.start == now && s?.clippedByGate == true && s?.isDraggable == true)
        // 图钉：过去的截止不画（不读成「没赶上」）；将来的截止、收工线照画；日界线每天一根
        let pins = days.flatMap(\.pins)
        #expect(!pins.contains { $0.id == "ddl-\(missed.id.uuidString)" })
        #expect(pins.contains { $0.id == "ddl-\(future.id.uuidString)" })
        #expect(pins.filter { $0.kind == .dayBoundary }.count == 2)
        #expect(pins.contains { $0.kind == .windDown && $0.at == at(20, 23) })
        #expect(!pins.contains { $0.kind == .windDown && $0.at < now }, "过去的收工线不画")
        // 字面：任何组装出来的字都不带债务措辞
        let words = all.map(\.title) + pins.map(\.label)
        for bad in ["错过", "未完成", "没做", "逾期", "落后", "missed", "overdue"] {
            #expect(!words.contains { $0.contains(bad) }, "出现了「\(bad)」")
        }
    }

    /// 红线的源码守卫：时间轴的呈现代码里不许有红色、不许有「错过 / 未完成」这类债务措辞（注释除外）。
    @Test func axisSourceHasNoDebtStyling() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BetterCalendar/Features/Home/TimelineAxis")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 3)
        for url in files {
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                .joined(separator: "\n")
            for bad in [".red", "Color.red", "错过", "未完成", "逾期", "落后", "迟到", "missed", "overdue", "还剩"] {
                #expect(!code.contains(bad), "\(url.lastPathComponent) 里出现了「\(bad)」")
            }
        }
    }

    // MARK: 不能拖的：过去 / 做成的 / 你的日历

    @Test func onlyFutureGreenIsDraggable() {
        let now = at(20, 14)
        let future = ScheduledBlock(title: "写论文", start: at(20, 15), end: at(20, 16))
        let event = SystemCalendarEvent(title: "量子力学 5529", start: at(20, 17), end: at(20, 18), isAllDay: false, calendarTitle: "课程")
        let days = TimelineAxisComposer.compose(AxisInput(
            labels: [label(19), label(20)], now: now, planned: [future],
            actuals: [AxisActual(title: "健身", start: at(19, 9), end: at(19, 10), plannedID: UUID())],
            occupied: [event]))
        let all = days.flatMap(\.items)
        #expect(all.filter(\.isDraggable).map(\.title) == ["写论文"])
        let occ = all.first { $0.kind == .occupied }
        #expect(occ?.isDraggable == false && occ?.calendarName == "课程", "你的日历：灰色、只读、标出是哪本日历")
        #expect(occ?.title == "量子力学 5529")
    }

    @Test func linkedPlanBlockIsDrawnOnceAsYourEvent() {
        let now = at(20, 9)
        let b = ScheduledBlock(title: "量子力学 5529", start: at(20, 10), end: at(20, 11), isFixed: true)
        let event = SystemCalendarEvent(title: "PHYSICS 5529", start: at(20, 10), end: at(20, 11), isAllDay: false, calendarTitle: "课程")
        let all = TimelineAxisComposer.compose(AxisInput(labels: [label(20)], now: now, planned: [b], actuals: [],
                                                         occupied: [event])).flatMap(\.items)
        #expect(all.count == 1 && all[0].kind == .occupied, "一件事只画一次：你那一份就是它")
    }

    @Test func overlappingItemsShareLanes() {
        let now = at(20, 8)
        let a = ScheduledBlock(title: "A", start: at(20, 9), end: at(20, 11))
        let b = ScheduledBlock(title: "B", start: at(20, 10), end: at(20, 12))
        let c = ScheduledBlock(title: "C", start: at(20, 13), end: at(20, 14))
        let items = TimelineAxisComposer.compose(AxisInput(labels: [label(20)], now: now, planned: [a, b, c], actuals: []))[0].items
        let byTitle = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0) })
        #expect(byTitle["A"]?.lanes == 2 && byTitle["B"]?.lanes == 2)
        #expect(byTitle["A"]?.lane != byTitle["B"]?.lane)
        #expect(byTitle["C"]?.lanes == 1 && byTitle["C"]?.lane == 0)
    }

    // MARK: 直接操作：拖动 / 拉底边 → 写对时间、钉住；放不下 → 写明原因、什么都不改

    final class FakeLive: AxisLiveSource {
        var settledPlannedIDs: Set<UUID> = []
        var activePrediction: ActivePrediction?
        var axisTodayDone: [AxisActual] = []
        var axisRunning: [AxisRunning] = []
    }

    final class StubCalendar: CalendarReading {
        var events: [SystemCalendarEvent] = []
        var fails = false
        func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft] { [] }
        func externalEvents(in window: DateInterval) async throws -> [SystemCalendarEvent] {
            if fails { throw CalendarError(message: "没有日历权限") }
            return events.filter { $0.end > window.start && $0.start < window.end }
        }
    }

    struct Rig {
        let axis: TimelineAxisModel
        let home: HomeViewModel
        let store: PlanStore
        let calendar: StubCalendar
        let live: FakeLive
        let container: ModelContainer   // 保活：容器与 store 同寿命
    }

    func rig(now: Date, startedDays: StartedDayStore? = nil) throws -> Rig {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext, now: { now })
        struct NoRefine: PlanRefining {
            func refine(_ blocks: [ScheduledBlock], command: String,
                        originalRequest: String, now: Date) async throws -> [ScheduledBlock] { blocks }
        }
        struct NoNotify: NotificationScheduling {
            func requestAuthorizationIfNeeded() async {}
            func scheduleDailyReminders(morning: Date?, evening: Date?, summary: String) async {}
        }
        let projectionCalendar = FakeCalendarStore()
        let live = FakeLive()
        let home = HomeViewModel(
            arrangeDay: ArrangeDayUseCase(parser: FailedScheduleParser(), planner: NaivePlanningEngine()),
            refiner: NoRefine(), calendarStore: projectionCalendar, reminderStore: FakeReminderStore(),
            exporter: ICSExporter(), planStore: store,
            projection: ProjectionService(planStore: store, calendarStore: projectionCalendar),
            notifier: NoNotify(), startedDays: startedDays, progress: live, now: { now })
        home.autoCommit = true
        home.relayoutLiveDay = false
        home.autosaveDelay = .milliseconds(20)
        let calendar = StubCalendar()
        let axis = TimelineAxisModel(plans: store, actuals: store, calendar: calendar, live: live, home: home, now: { now })
        return Rig(axis: axis, home: home, store: store, calendar: calendar, live: live, container: container)
    }

    private func item(_ r: Rig, _ id: UUID) throws -> AxisItem {
        try #require(r.axis.days().flatMap(\.items).first { $0.blockID == id && $0.kind == .plan })
    }

    @Test func dragAndResizeWriteSnappedTimesAndPin() async throws {
        let now = at(20, 12)
        let r = try rig(now: now)
        let a = ScheduledBlock(title: "写论文", start: at(21, 9), end: at(21, 10))
        let b = ScheduledBlock(title: "健身", start: at(21, 15), end: at(21, 16))
        try r.store.replacePlanned([a, b], on: label(21))
        await r.axis.reload()

        // 拖到 10:32 → 吸附 10:30，保时长
        let reason = await r.axis.commitDrag(try item(r, a.id), start: at(21, 10, 32))
        #expect(reason == nil)
        var stored = try r.store.plannedBlocks(on: label(21))
        let movedA = try #require(stored.first { $0.id == a.id })
        #expect(movedA.start == at(21, 10, 30) && movedA.end == at(21, 11, 30))
        #expect(movedA.isPinned(at: now), "你拖过的块钉住")
        #expect(stored.first { $0.id == b.id }?.start == at(21, 15), "别的块原样")
        #expect(stored.first { $0.id == b.id }?.isPinned(at: now) == false)

        // 拉底边到 17:03 → 吸附 17:05，开始不动
        let reason2 = await r.axis.commitResize(try item(r, b.id), end: at(21, 17, 3))
        #expect(reason2 == nil)
        stored = try r.store.plannedBlocks(on: label(21))
        let resizedB = try #require(stored.first { $0.id == b.id })
        #expect(resizedB.start == at(21, 15) && resizedB.end == at(21, 17, 5))
        #expect(resizedB.isPinned(at: now))
        // 轴上马上看得见
        #expect(try item(r, b.id).end == at(21, 17, 5))
    }

    @Test func dragOnTheLiveDayChangesOnlyThatBlock() async throws {
        let now = at(20, 13)
        let started = StartedDayStore(persisted: false)
        started.markStarted(label(20))
        let r = try rig(now: now, startedDays: started)
        // 两件撞在同一时段：W19 列表的「从现在起」重铺会把其中一件往后排；时间轴不重铺，拖一件只动那一件
        let a = ScheduledBlock(title: "写论文", start: at(20, 14), end: at(20, 15))
        let b = ScheduledBlock(title: "健身", start: at(20, 14), end: at(20, 15))
        try r.store.replacePlanned([a, b], on: label(20))
        await r.axis.reload()
        let reason = await r.axis.commitDrag(try item(r, a.id), start: at(20, 18))
        #expect(reason == nil)
        let stored = try r.store.plannedBlocks(on: label(20))
        #expect(stored.first { $0.id == a.id }?.start == at(20, 18))
        #expect(stored.first { $0.id == b.id }?.start == at(20, 14), "没被悄悄挪走")
    }

    @Test func conflictsShowAReasonAndChangeNothing() async throws {
        let now = at(20, 12)
        let r = try rig(now: now)
        let meeting = ScheduledBlock(title: "组会", start: at(21, 13), end: at(21, 14), isFixed: true)
        let paper = ScheduledBlock(title: "写论文", start: at(21, 9), end: at(21, 10))
        try r.store.replacePlanned([meeting, paper], on: label(21))
        await r.axis.reload()

        // 撞上固定安排
        let r1 = await r.axis.commitDrag(try item(r, paper.id), start: at(21, 13, 30))
        #expect(r1?.contains("固定安排") == true)
        #expect(r.axis.notice == r1, "原因放在页面上给你看")
        // 固定安排本身不挪、不改时长
        let r2 = await r.axis.commitDrag(try item(r, meeting.id), start: at(21, 15))
        #expect(r2?.contains("固定安排") == true)
        let r3 = await r.axis.commitResize(try item(r, meeting.id), end: at(21, 15))
        #expect(r3?.contains("固定安排") == true)
        // 拖到另一天（W26 起允许，见 W26AxisCrossDayTests）：拖进过去的日子照样拒绝
        let r4 = await r.axis.commitDrag(try item(r, paper.id), start: at(19, 9))
        #expect(r4?.contains("已经过去") == true)
        // 拖进过去
        let today = ScheduledBlock(title: "回邮件", start: at(20, 15), end: at(20, 16))
        try r.store.insertPlanned([today])
        await r.axis.reload()
        let r5 = await r.axis.commitDrag(try item(r, today.id), start: at(20, 10))
        #expect(r5?.contains("已经过去") == true)

        let stored = try r.store.plannedBlocks(onLabels: [label(20), label(21)])
        #expect(stored.first { $0.id == paper.id }?.start == at(21, 9), "放不下 = 什么都不改（绝不悄悄挤）")
        #expect(stored.first { $0.id == meeting.id }?.start == at(21, 13))
        #expect(stored.first { $0.id == today.id }?.start == at(20, 15))
        #expect(!stored.contains { $0.isPinned(at: now) }, "没改就不钉")
    }

    @Test func yourCalendarIsReadOnlyAndCountsAsOccupied() async throws {
        let now = at(20, 12)
        let r = try rig(now: now)
        r.calendar.events = [SystemCalendarEvent(title: "看牙", start: at(21, 10), end: at(21, 11), isAllDay: false, calendarTitle: "个人"),
                             SystemCalendarEvent(title: "国庆", start: at(21, 0), end: at(22, 0), isAllDay: true, calendarTitle: "节假日")]
        let paper = ScheduledBlock(title: "写论文", start: at(21, 8), end: at(21, 9))
        try r.store.replacePlanned([paper], on: label(21))
        await r.axis.reload()
        let occ = r.axis.days().flatMap(\.items).filter { $0.kind == .occupied }
        #expect(occ.map(\.title) == ["看牙"], "全天事件不占时段")
        #expect(occ.allSatisfy { !$0.isDraggable })
        let reason = await r.axis.commitDrag(try item(r, paper.id), start: at(21, 10, 15))
        #expect(reason?.contains("你日历里的「看牙」") == true)
        #expect(try r.store.plannedBlocks(on: label(21)).first?.start == at(21, 8))

        // 读不到你的日历：不假装它是空的——这次不改，写明原因
        r.calendar.fails = true
        await r.axis.reload()
        #expect(r.axis.occupiedError != nil)
        let reason2 = await r.axis.commitDrag(try item(r, paper.id), start: at(21, 15))
        #expect(reason2?.contains("读不到你的日历") == true)
        #expect(try r.store.plannedBlocks(on: label(21)).first?.start == at(21, 8))
    }

    @Test func runningBlockCannotBeDraggedAndBlocksItsSlot() async throws {
        let now = at(20, 13)
        let r = try rig(now: now)
        let running = ScheduledBlock(title: "写论文", start: at(20, 12, 30), end: at(20, 14))
        let next = ScheduledBlock(title: "健身", start: at(20, 15), end: at(20, 16))
        try r.store.replacePlanned([running, next], on: label(20))
        r.live.axisRunning = [AxisRunning(plannedID: running.id, title: "写论文", start: at(20, 12, 35))]
        r.live.settledPlannedIDs = [running.id]
        r.live.activePrediction = ActivePrediction(id: running.id, start: at(20, 12, 35), end: at(20, 14))
        await r.axis.reload()
        #expect(try item(r, running.id).isDraggable == false)
        let reason = await r.axis.commitDrag(try item(r, next.id), start: at(20, 13, 30))
        #expect(reason?.contains("写论文") == true, "正在做那块此刻占着的时间是障碍")
    }
}

#if os(macOS)
/// 时间轴截图（只在显式要求时跑：`TEST_RUNNER_BC_W23_SHOTS=<输出目录>`；门控全量测试里不跑）。
/// ⚠️ 不用 AppContainer：它在测试宿主里接的是**真 EventKit**（日用版的「BetterCalendar · 计划 / 实际 (Dev)」日历），
/// 一保存 / 一计时就会写进 Jason 的真日历（W23 开发时踩过）。这里只用内存 PlanStore + 假日历 + 假执行陪伴，渲染时间轴本身。
@MainActor
@Suite struct W23AxisShots {
    static let outDir = ProcessInfo.processInfo.environment["BC_W23_SHOTS"]

    @Test(.enabled(if: W23AxisShots.outDir != nil)) func renderTodayAxis() async throws {
        let dir = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cal = Calendar.current
        let today = cal.startOfDay(for: cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!)
        func t(_ h: Int, _ m: Int = 0, day: Int = 0) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: day, to: today)!)!
        }
        let now = t(14, 5)
        let r = try W23TimelineAxisTests().rig(now: now)
        let doneA = ScheduledBlock(title: "写论文第二章", start: t(9), end: t(11))
        let doneB = ScheduledBlock(title: "健身", start: t(11, 30), end: t(12, 15))
        let running = ScheduledBlock(title: "整理笔记", start: t(13, 30), end: t(15))
        let missed = ScheduledBlock(title: "没做的计划（不该出现）", start: t(12, 30), end: t(13, 15))
        let next = ScheduledBlock(title: "读文献", start: t(15, 30), end: t(16, 30))
        let meeting = ScheduledBlock(title: "组会", start: t(17), end: t(18), isFixed: true)
        let ddl = ScheduledBlock(title: "交作业", start: t(19), end: t(20), priority: .important, deadline: t(21))
        try r.store.replacePlanned([doneA, doneB, running, missed, next, meeting, ddl], on: today)
        try r.store.setPinned(ids: [next.id], until: ScheduledBlock.pinExpiry(forStart: next.start))
        try r.store.replacePlanned([ScheduledBlock(title: "写论文第三章", start: t(9, day: 1), end: t(11, day: 1)),
                                    ScheduledBlock(title: "跑步", start: t(17, day: 1), end: t(18, day: 1))],
                                   on: cal.date(byAdding: .day, value: 1, to: today)!)
        try r.store.upsertActuals([ActualBlock(id: UUID(), title: "读书", start: t(20, day: -1), end: t(21, 30, day: -1))])
        r.live.axisTodayDone = [AxisActual(title: doneA.title, start: t(9, 10), end: t(10, 50), plannedID: doneA.id),
                                AxisActual(title: doneB.title, start: t(11, 30), end: t(12, 15), plannedID: doneB.id),
                                AxisActual(title: "顺手修了自行车", start: t(12, 30), end: t(13), plannedID: nil)]
        r.live.axisRunning = [AxisRunning(plannedID: running.id, title: running.title, start: t(13, 35))]
        r.live.settledPlannedIDs = [doneA.id, doneB.id, running.id]
        r.calendar.events = [SystemCalendarEvent(title: "量子力学 5529", start: t(16, 30), end: t(17), isAllDay: false, calendarTitle: "课程")]
        await r.axis.reload()

        let theme = ThemeSettings.current
        for (sizeName, size) in [("normal", CGSize(width: 1000, height: 760)), ("small", CGSize(width: 520, height: 460)),
                                 ("tall", CGSize(width: 640, height: 1700))] {
            let rect = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let page = VStack(alignment: .leading, spacing: 8) {
                Text("（顶上是「现在 / 下一件」执行面板，截图里省略）").font(.caption).foregroundStyle(.secondary)
                TimelineAxisView(axis: r.axis, onEdit: { _ in }, dayMenu: { _ in Image(systemName: "ellipsis.circle") })
            }
            .padding(16)
            let host = NSHostingView(rootView: page.frame(width: size.width, height: size.height)
                .environment(\.appTheme, theme).tint(theme.accent)
                .environment(\.colorScheme, .light).background(theme.bg))
            host.frame = rect; host.appearance = NSAppearance(named: .aqua); window.contentView = host
            host.layoutSubtreeIfNeeded()
            for _ in 0..<60 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(800))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: dir.appendingPathComponent("w23-today-axis-\(sizeName).png"), options: .atomic)
            window.close()
        }
    }
}
#endif
