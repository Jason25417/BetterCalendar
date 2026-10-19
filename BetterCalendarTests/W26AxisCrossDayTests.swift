//
//  W26AxisCrossDayTests.swift
//  BetterCalendarTests
//
//  W26 时间轴跨天拖动 + 功能探针补登记：
//  - 跨天挪走按 ID 单块写：两天的其它块原样、你拖的块钉到新那天结束、两天都重投影（假日历）、编辑页不把旧版本写回；
//  - 放不下写明原因、什么都不改：拖进过去 / 超出可排范围 / 固定安排本身 / 撞上目标日的固定安排或你的日历 / 正在计时；
//  - 每个登记的功能 id 在 App 源码里都有调用点（没埋点就登记 = 会被误判成「没看见过」）。
//  纪律：内存库显式 cloudKitDatabase: .none；容器随 rig 保活；时间全部从固定时刻派生（注入时钟，不用 Date.now）；
//  不碰真 EventKit（投影写的是 FakeCalendarStore）。
//

import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

@MainActor
@Suite struct W26AxisCrossDayTests {
    private let cal = Calendar.current
    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }
    private func label(_ d: Int) -> Date { cal.startOfDay(for: at(d, 12)) }

    struct Rig {
        let axis: TimelineAxisModel
        let home: HomeViewModel
        let store: PlanStore
        let calendar: W23TimelineAxisTests.StubCalendar
        let projected: FakeCalendarStore
        let live: W23TimelineAxisTests.FakeLive
        let container: ModelContainer   // 保活：容器与 store 同寿命
    }

    private func rig(now: Date) throws -> Rig {
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
        let projected = FakeCalendarStore()
        let live = W23TimelineAxisTests.FakeLive()
        let home = HomeViewModel(
            arrangeDay: ArrangeDayUseCase(parser: FailedScheduleParser(), planner: NaivePlanningEngine()),
            refiner: NoRefine(), calendarStore: projected, reminderStore: FakeReminderStore(),
            exporter: ICSExporter(), planStore: store,
            projection: ProjectionService(planStore: store, calendarStore: projected),
            notifier: NoNotify(), progress: live, now: { now })
        home.autoCommit = true
        home.relayoutLiveDay = false
        home.autosaveDelay = .milliseconds(20)
        let calendar = W23TimelineAxisTests.StubCalendar()
        let axis = TimelineAxisModel(plans: store, actuals: store, calendar: calendar, live: live, home: home, now: { now })
        return Rig(axis: axis, home: home, store: store, calendar: calendar, projected: projected, live: live, container: container)
    }

    private func item(_ r: Rig, _ id: UUID) throws -> AxisItem {
        try #require(r.axis.days().flatMap(\.items).first { $0.blockID == id && $0.kind == .plan })
    }

    // MARK: 跨天挪：其它块原样、钉住、两天重投影

    @Test func crossDayMoveKeepsOtherBlocksOnBothDaysAndPins() async throws {
        let now = at(20, 12)
        let r = try rig(now: now)
        let paper = ScheduledBlock(title: "写论文", start: at(21, 9), end: at(21, 10, 30), priority: .important)
        let gym = ScheduledBlock(title: "健身", start: at(21, 15), end: at(21, 16))
        let meeting = ScheduledBlock(title: "组会", start: at(22, 10), end: at(22, 11), isFixed: true)
        let read = ScheduledBlock(title: "读文献", start: at(22, 16), end: at(22, 17))
        try r.store.replacePlanned([paper, gym], on: label(21))
        try r.store.replacePlanned([meeting, read], on: label(22))
        // 编辑页正好停在源头那一天（之前在那天点过 / 拖过）
        await r.home.focusDay(label(21))
        #expect(r.home.blocks.map(\.id).contains(paper.id))
        await r.axis.reload()

        // 从 21 日 9:00 拖到 22 日 14:02 → 吸附 14:00，保时长（90 分钟）
        let reason = await r.axis.commitDrag(try item(r, paper.id), start: at(22, 14, 2))
        #expect(reason == nil, "\(reason ?? "")")

        let day21 = try r.store.plannedBlocks(on: label(21))
        let day22 = try r.store.plannedBlocks(on: label(22))
        #expect(day21.map(\.id) == [gym.id], "源头那天只剩别的块")
        #expect(day21.first?.start == at(21, 15) && day21.first?.isPinned(at: now) == false)
        #expect(Set(day22.map(\.id)) == [meeting.id, read.id, paper.id], "目标那天原有的块一块不少（没被整页覆盖）")
        let moved = try #require(day22.first { $0.id == paper.id })
        #expect(moved.start == at(22, 14) && moved.end == at(22, 15, 30))
        #expect(moved.priority == .important && moved.title == "写论文", "只改时间，性质原样")
        #expect(moved.pinnedUntil == ScheduledBlock.pinExpiry(forStart: at(22, 14)), "你亲手拖的 = 图钉，钉到它新那天结束")
        #expect(day22.filter { $0.id != paper.id }.allSatisfy { !$0.isPinned(at: now) })
        #expect(day22.first { $0.id == meeting.id }?.start == at(22, 10))
        #expect(day22.first { $0.id == read.id }?.start == at(22, 16))

        // 两天都经 CalendarSyncEngine 重投影（这里是假日历）：块画在新位置、旧位置没了
        let planned = r.projected.captured.filter { $0.kind == .planned && $0.title == "写论文" }
        #expect(planned.count == 1 && planned.first?.start == at(22, 14))

        // 编辑页按库重新加载：旧版本不会在下次自动保存时把它写回 21 日
        #expect(!r.home.blocks.contains { $0.id == paper.id })
        let again = await r.axis.commitDrag(try item(r, gym.id), start: at(21, 17))
        #expect(again == nil, "\(again ?? "")")
        #expect(try r.store.plannedBlocks(on: label(21)).map(\.id) == [gym.id])
        #expect(try r.store.plannedBlocks(on: label(22)).contains { $0.id == paper.id && $0.start == at(22, 14) })
        // 轴上马上看得见
        #expect(try item(r, paper.id).start == at(22, 14))
    }

    @Test func crossDayFromTheLiveDayToTomorrow() async throws {
        let now = at(20, 21)
        let r = try rig(now: now)
        let late = ScheduledBlock(title: "整理笔记", start: at(20, 22), end: at(20, 23))
        let sleepy = ScheduledBlock(title: "看书", start: at(20, 23), end: at(21, 0))
        try r.store.replacePlanned([late, sleepy], on: label(20))
        await r.axis.reload()
        let reason = await r.axis.commitDrag(try item(r, late.id), start: at(21, 8))
        #expect(reason == nil, "\(reason ?? "")")
        #expect(try r.store.plannedBlocks(on: label(20)).map(\.id) == [sleepy.id])
        #expect(try r.store.plannedBlocks(on: label(21)).first?.start == at(21, 8))
        // 凌晨 1 点仍属今天这个逻辑日（4:00 日界线）：拖到那里是同一天，不走跨天
        let reason2 = await r.axis.commitDrag(try item(r, sleepy.id), start: at(21, 1))
        #expect(reason2 == nil, "\(reason2 ?? "")")
        #expect(try r.store.plannedBlocks(on: label(20)).first?.start == at(21, 1))
    }

    // MARK: 放不下：写明原因，什么都不改

    @Test func crossDayRefusalsExplainAndChangeNothing() async throws {
        let now = at(20, 12)
        let r = try rig(now: now)
        let paper = ScheduledBlock(title: "写论文", start: at(21, 9), end: at(21, 10))
        let fixed = ScheduledBlock(title: "例会", start: at(21, 13), end: at(21, 14), isFixed: true)
        let meeting = ScheduledBlock(title: "组会", start: at(22, 10), end: at(22, 11), isFixed: true)
        let running = ScheduledBlock(title: "回邮件", start: at(20, 11, 30), end: at(20, 13))
        try r.store.replacePlanned([running], on: label(20))
        try r.store.replacePlanned([paper, fixed], on: label(21))
        try r.store.replacePlanned([meeting], on: label(22))
        r.calendar.events = [SystemCalendarEvent(title: "看牙", start: at(23, 9), end: at(23, 10), isAllDay: false, calendarTitle: "个人")]
        r.live.axisRunning = [AxisRunning(plannedID: running.id, title: "回邮件", start: at(20, 11, 35))]
        r.live.activePrediction = ActivePrediction(id: running.id, start: at(20, 11, 35), end: at(20, 13))
        await r.axis.reload()
        let paperItem = try item(r, paper.id)

        // 拖进过去（昨天在轴上，但只能往「从现在起」挪）
        let past = await r.axis.commitDrag(paperItem, start: at(19, 15))
        #expect(past?.contains("已经过去") == true, "\(past ?? "")")
        // 超出可排范围（今天到 7 天后）
        let far = await r.axis.commitDrag(paperItem, start: at(28, 9))
        #expect(far?.contains("可排的范围") == true, "\(far ?? "")")
        // 撞上目标那天的固定安排
        let clash = await r.axis.commitDrag(paperItem, start: at(22, 10, 30))
        #expect(clash?.contains("固定安排「组会」") == true, "\(clash ?? "")")
        // 撞上你日历里的事（只读、已占用）
        let mine = await r.axis.commitDrag(paperItem, start: at(23, 9, 30))
        #expect(mine?.contains("你日历里的「看牙」") == true, "\(mine ?? "")")
        // 固定安排本身不挪到别的日子
        let lock = await r.axis.commitDrag(try item(r, fixed.id), start: at(22, 15))
        #expect(lock?.contains("固定安排，按规则不挪") == true, "\(lock ?? "")")
        // 正在计时的那块：轴上根本不让拖；直接调也拒绝
        #expect(try item(r, running.id).isDraggable == false)
        let live = await r.axis.commit(id: running.id, label: label(20), start: at(21, 9), end: at(21, 10, 30),
                                       step: .move(ProposalBlockMove(id: running.id, start: at(21, 9), end: at(21, 10, 30), expectedRevision: nil)))
        #expect(live?.contains("正在计时") == true, "\(live ?? "")")
        #expect(r.axis.notice == live, "原因放在页面上给你看")

        let all = try r.store.plannedBlocks(onLabels: (19...23).map(label))
        #expect(all.first { $0.id == paper.id }?.start == at(21, 9), "放不下 = 什么都不改（绝不悄悄挤）")
        #expect(all.first { $0.id == fixed.id }?.start == at(21, 13))
        #expect(all.first { $0.id == meeting.id }?.start == at(22, 10))
        #expect(all.first { $0.id == running.id }?.start == at(20, 11, 30))
        #expect(!all.contains { $0.isPinned(at: now) }, "没改就不钉")
        #expect(all.count == 4)
    }

    // MARK: 功能探针：每个登记的 id 都有调用点

    @Test func everyRegisteredFeatureHasACallSite() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BetterCalendar")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "FeatureRegistry.swift" }
        let code = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        #expect(code.contains("FeatureID.intent("), "快捷指令 / 控件按映射记（下面据此放行映射里的 id）")
        for f in FeatureID.allCases {
            let name = String(describing: f)
            // 快捷指令 / 控件：经 FeatureID.intent(…) 映射统一记（BetterCalendarApp），不逐个写
            let viaIntent = ["arrangeToday", "openToday", "openJournal", "startFocus", "completeCurrent", "markDone", "review"]
                .contains { FeatureID.intent($0, source: nil) == f } || FeatureID.intent("completeCurrent", source: "control") == f
            if viaIntent { continue }
            let pattern = try Regex("\\.\(name)\\b")
            #expect(code.contains(pattern), "「\(f.label)」(\(f.rawValue)) 登记了却没有调用点")
        }
    }

    @Test func axisFeaturesAreRegisteredWithHonestExposure() {
        // 拖 / 拉边是没有按钮的手势：轴被看见 ≠ 知道能拖 → 只推断「可能不知道」，不推断「不需要」
        #expect(FeatureID.todayAxisDrag.exposure == .gesture(.todayAxis))
        #expect(FeatureID.todayAxisResize.exposure == .gesture(.todayAxis))
        #expect(FeatureID.todayAxis.isSurface)
        #expect(FeatureID.todayExportICS.exposure == .inMenu(.todayPage))
        #expect(FeatureID.todayUpdateDoneFromCalendar.exposure == .inMenu(.todayPage))
        for f in [FeatureID.todaySuggestion, .todayWrapUpCard, .todayMorningBrief, .todayAxisBackToNow] {
            #expect(f.exposure == .direct, "只在条件满足时出现的，出现时自己记 seen")
        }
        // 手势的解读：轴出现过很多天、拖动 0 次 → 「可能不知道」，证据里说它是手势
        let now = at(20, 12)
        var axisStats = FeatureStats(id: .todayAxis); axisStats.seenDays = 10
        let dragStats = FeatureStats(id: .todayAxisDrag)
        let report = FeatureUsageReport(now: now, trackingSince: cal.date(byAdding: .day, value: -20, to: now),
                                        stats: [.todayAxis: axisStats, .todayAxisDrag: dragStats])
        let h = FeatureUsageInterpreter.hypothesis(.todayAxisDrag, dragStats, report: report)
        #expect(h?.kind == .neverSeen)
        #expect(h?.evidence.contains("手势") == true)
    }
}
