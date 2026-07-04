//
//  BetterCalendarTests.swift
//  BetterCalendarTests
//
//  自动化测试：覆盖可单测的逻辑（解析/JSON/日期/回退/路由/映射）。
//  EventKit 真日历需权限+GUI，不在此自动测——见冒烟测试表。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

@MainActor
struct LogicTests {

    // MARK: 工具

    @Test func dateParsingHandlesFormatsAndEmpty() {
        #expect(DateParsing.parse("2026-06-30 09:00") != nil)
        #expect(DateParsing.parse("2026-06-30T09:00:00") != nil)
        #expect(DateParsing.parse("2026-06-30T09:00:00Z") != nil)
        #expect(DateParsing.parse("") == nil)
        #expect(DateParsing.parse(nil) == nil)
        #expect(DateParsing.parse("不是日期") == nil)
    }

    @Test func jsonExtractStripsFenceAndSurroundingText() {
        #expect(JSONText.extractObject("```json\n{\"a\":1}\n```") == "{\"a\":1}")
        #expect(JSONText.extractObject("前缀 {\"a\":1} 后缀") == "{\"a\":1}")
        #expect(JSONText.extractObject("{\"a\":1}") == "{\"a\":1}")
    }

    @Test func appIntentRequestQueuesAndConsumesOnce() {
        _ = AppIntentRequest.consume()
        AppIntentRequest.enqueue(.startToday)
        #expect(AppIntentRequest.consume() == .startToday)
        #expect(AppIntentRequest.consume() == nil)
    }

    @Test func appIntentRequestCarriesOptionalPlanText() {
        _ = AppIntentRequest.consume()
        AppIntentRequest.enqueue(.arrangeToday, payload: "写代码两小时，下午健身")
        #expect(AppIntentRequest.payload() == "写代码两小时，下午健身")
        #expect(AppIntentRequest.consume() == .arrangeToday)
        #expect(AppIntentRequest.payload() == nil)
    }

    @Test func handoffUserInfoRoundTripsRoute() {
        let info = BetterCalendarHandoff.userInfo(tab: .today, activeTitle: "写代码")
        let route = BetterCalendarHandoff.route(from: info)
        #expect(route?.tab == .today)
        #expect(route?.activeTitle == "写代码")
        #expect(BetterCalendarHandoff.route(from: ["tab": "missing"]) == nil)
    }

    // MARK: 本地排程

    @Test func naivePlannerPutsImportantFirst() async throws {
        let planner = NaivePlanningEngine()
        let now = Date()
        let normal = ScheduledBlock(title: "普通", start: now,
                                    end: now.addingTimeInterval(3600), priority: .normal)
        let important = ScheduledBlock(title: "要紧", start: now.addingTimeInterval(7200),
                                       end: now.addingTimeInterval(10800), priority: .important)
        let decision = try await planner.arrange([normal, important], now: now)
        #expect(decision.orderedBlocks.first?.priority == .important)
        #expect(decision.orderedBlocks.count == 2)
    }

    // MARK: 假日历

    @Test func fakeCalendarReplacesSameKind() async throws {
        let store = FakeCalendarStore()
        let now = Date()
        try await store.write([CalendarEventDraft(title: "A", start: now,
                                                  end: now.addingTimeInterval(3600), kind: .planned)])
        try await store.write([CalendarEventDraft(title: "B", start: now,
                                                  end: now.addingTimeInterval(3600), kind: .planned)])
        let planned = try await store.read(kind: .planned)
        #expect(planned.count == 1)              // 同类替换，不累积
        #expect(planned.first?.title == "B")
    }

    // MARK: 云端失败 → 回退本地（用无 key 客户端模拟失败）

    @Test func parserFallsBackToLocalWhenNoKey() async throws {
        let noKey = AnthropicClient(apiKey: { nil }, useCloud: { true })
        let parser = ClaudeScheduleParser(client: noKey, fallback: StubScheduleParser())
        let plan = try await parser.parse("写代码，开会", referenceDate: Date())
        #expect(plan.blocks.count == 2)          // 回退本地桩按逗号切
    }

    @Test func parseContextDefaultIgnoredByStubAndPromptIncludesBusy() async throws {
        // 协议扩展默认：Stub 带上下文调用 = 不带（本地兜底不看上下文）
        let ctx = ParseContext(busy: [BusySlot(title: "牙医", start: at(2026,7,5,10), end: at(2026,7,5,11))],
                               dueReminders: ["交电费"])
        let plan = try await StubScheduleParser().parse("写代码", referenceDate: at(2026,7,5,0), context: ctx)
        #expect(plan.blocks.count == 1)
        // 云端 prompt 注入：已有日程/提醒进 system prompt
        let prompt = ClaudeScheduleParser.systemPrompt(referenceDate: at(2026,7,5,0), context: ctx)
        #expect(prompt.contains("牙医"))
        #expect(prompt.contains("交电费"))
        #expect(prompt.contains("已有的安排"))
    }

    @Test func decodePlanIsLenientToDirtyLLMOutput() {
        // 单块损坏（缺 end）跳过不废全包；cadence 数字/字符串都认；多余字段无害
        let dirty = """
        {"blocks":[
          {"title":"写代码","start":"2026-07-05 09:00","end":"2026-07-05 11:00","priority":"important","extra":1},
          {"title":"坏块","start":"2026-07-05 12:00"}
        ],
        "longTasks":[
          {"title":"通识课作业","deadline":null,"cadenceMinutesPerWeek":"540"},
          {"title":"量化学习","cadenceMinutesPerWeek":360}
        ]}
        """
        let d = ClaudeScheduleParser.decodePlan(dirty)
        #expect(d != nil)
        #expect(d?.blocks.count == 1)
        #expect(d?.blocks.first?.priority == .important)
        #expect(d?.dropped == 1)
        #expect(d?.longTasks.count == 2)
        #expect(d?.longTasks.first?.cadenceMinutesPerWeek == 540)   // 字符串数字也认
        // 截断的 JSON（模拟 max_tokens 拦腰）→ 整体解不开 → nil（上层回退+记原文）
        #expect(ClaudeScheduleParser.decodePlan("{\"blocks\":[{\"title\":\"半截") == nil)
    }

    @Test func plannerFallsBackToLocalWhenNoKey() async throws {
        let noKey = AnthropicClient(apiKey: { nil }, useCloud: { true })
        let planner = LLMPlanningEngine(client: noKey, fallback: NaivePlanningEngine())
        let now = Date()
        let block = ScheduledBlock(title: "x", start: now, end: now.addingTimeInterval(3600))
        let decision = try await planner.arrange([block], now: now)
        #expect(decision.orderedBlocks.count == 1)
    }

    @Test func refinerKeepsDraftOnFailureOrEmptyCommand() async throws {
        let noKey = AnthropicClient(apiKey: { nil }, useCloud: { true })
        let refiner = ClaudePlanRefiner(client: noKey)
        let now = Date()
        let block = ScheduledBlock(title: "x", start: now, end: now.addingTimeInterval(3600))
        let onFailure = try await refiner.refine([block], command: "把x挪到下午", originalRequest: "写一天代码", now: now)
        #expect(onFailure.count == 1)            // 云端失败 → 原样
        let onEmpty = try await refiner.refine([block], command: "  ", originalRequest: "", now: now)
        #expect(onEmpty.count == 1)              // 空指令 → 原样
    }

    // MARK: 草稿映射

    @Test func editableBlockRoundTrips() {
        let now = Date()
        let sb = ScheduledBlock(title: "读书", start: now, end: now.addingTimeInterval(1800),
                                isFixed: true, priority: .important)
        let eb = EditableBlock(from: sb)
        #expect(eb.title == "读书")
        #expect(eb.isFixed)
        #expect(eb.priority == .important)
        let back = eb.scheduled
        #expect(back.id == sb.id)
        #expect(back.priority == .important)
        #expect(back.isFixed)
    }

    // MARK: 日历后端路由

    @Test func routingWritesToFakeWhenBackendFake() async throws {
        CalendarSettings.backend = .fake
        let fake = FakeCalendarStore()
        let routing = RoutingCalendarStore(fake: fake, eventKit: EventKitCalendarStore())
        let now = Date()
        try await routing.write([CalendarEventDraft(title: "T", start: now,
                                                    end: now.addingTimeInterval(3600), kind: .planned)])
        #expect(fake.captured.count == 1)        // 路由到假日历
    }

    // MARK: 标题匹配

    @Test func titleSimilarityBasics() {
        #expect(TitleMatch.similarity("写代码", "写代码") == 1)         // 完全相同
        #expect(TitleMatch.similarity("写代码", "写代码 (上午)") == 0.9) // 子串
        #expect(TitleMatch.similarity("健身", "跑步") < 0.5)            // 不相关
        #expect(TitleMatch.similarity("", "x") == 0)
    }

    // MARK: 计划 × 实际 对比

    private func planned(_ title: String, _ h: Int, _ durMin: Int) -> CalendarEventDraft {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
        return CalendarEventDraft(title: title, start: start,
                                  end: start.addingTimeInterval(Double(durMin) * 60), kind: .planned)
    }
    private func actual(_ title: String, _ h: Int, _ durMin: Int) -> CalendarEventDraft {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
        return CalendarEventDraft(title: title, start: start,
                                  end: start.addingTimeInterval(Double(durMin) * 60), kind: .actual)
    }

    @Test func comparerMarksDoneWhenMatchedSameLength() {
        let c = OverlapTitleComparer().compare(
            planned: [planned("写代码", 9, 120)],
            actual:  [actual("写代码", 9, 120)])
        #expect(c.items.count == 1)
        #expect(c.items.first?.status == .done)
        #expect(c.accomplishedCount == 1)
        #expect(c.effectiveMinutes == 120)
        #expect(c.missedCount == 0)
    }

    @Test func comparerMarksMissedAndExtra() {
        let c = OverlapTitleComparer().compare(
            planned: [planned("读书", 20, 60)],          // 计划了没做
            actual:  [actual("读论文", 14, 60)])          // 计划外做了别的
        #expect(c.missedCount == 1)
        #expect(c.bonusCount == 1)
        #expect(c.accomplishedCount == 1)              // 只有 bonus 进「做成了」
        #expect(c.missed.first?.plannedTitle == "读书")
        #expect(c.bonus.first?.actualTitle == "读论文")
    }

    @Test func comparerMatchesContentChangeBySameTime() {
        // 健身 → 跑步：标题不同但时间重叠 → 匹配上（内容变更），不算 missed
        let c = OverlapTitleComparer().compare(
            planned: [planned("健身", 17, 60)],
            actual:  [actual("跑步", 17, 60)])
        #expect(c.missedCount == 0)
        #expect(c.bonusCount == 0)
        #expect(c.items.first?.isContentChange == true)
    }

    @Test func comparerMarksPartialWhenShorter() {
        let c = OverlapTitleComparer().compare(
            planned: [planned("写代码", 9, 120)],
            actual:  [actual("写代码", 9, 40)])           // 只做了 1/3
        #expect(c.items.first?.status == .partial)
    }

    @Test func reviewShareSummaryLeadsWithAccomplishments() {
        let c = OverlapTitleComparer().compare(
            planned: [
                planned("写代码", 9, 120),
                planned("读书", 20, 60),
            ],
            actual: [
                actual("写代码", 9, 90),
                actual("读论文", 14, 60),
            ])
        let text = ReviewSummaryText.make(comparison: c,
                                          activeDayCount: 5,
                                          mvpTitle: "写代码",
                                          mvpNote: "今天最稳的一件")
        #expect(text.contains("今天做成 2 件"))
        #expect(text.contains("计划外"))
        #expect(text.contains("有效投入 2 小时 30 分"))
        #expect(text.contains("今日最有价值：写代码"))
        #expect(text.contains("- 读论文"))
        #expect(!text.contains("读书"))
        #expect(!text.contains("未做"))
    }

    // MARK: 跨天 / 逻辑日（M5 地基）—— 冒烟测难覆盖，靠注入时间的集成测试

    /// 构造「某年月日某点」的本地时刻。
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Calendar.current.date(from: c)!
    }
    private func startOfDay(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        Calendar.current.startOfDay(for: at(y, mo, d, 12))
    }

    @Test func dayContextLogicalBoundaryAt4am() {
        // 凌晨 4 点是日界线：之前算前一天，之后算当天
        #expect(DayContext.logicalStartOfDay(at(2026, 6, 30, 2, 0)) == startOfDay(2026, 6, 29))
        #expect(DayContext.logicalStartOfDay(at(2026, 6, 30, 3, 59)) == startOfDay(2026, 6, 29))
        #expect(DayContext.logicalStartOfDay(at(2026, 6, 30, 4, 0)) == startOfDay(2026, 6, 30))
        #expect(DayContext.logicalStartOfDay(at(2026, 6, 30, 15, 0)) == startOfDay(2026, 6, 30))
        #expect(DayContext.logicalStartOfDay(at(2026, 6, 30, 23, 0)) == startOfDay(2026, 6, 30))
    }

    @Test func dayContextDefaultTargetDay() {
        // 目标日用日历日（与可点标签一致）：晚上 → 明天，白天/凌晨 → 日历今天
        #expect(DayContext.defaultTargetDay(at(2026, 6, 30, 22, 0)) == startOfDay(2026, 7, 1))
        #expect(DayContext.defaultTargetDay(at(2026, 6, 30, 15, 0)) == startOfDay(2026, 6, 30))
        #expect(DayContext.defaultTargetDay(at(2026, 6, 30, 1, 0)) == startOfDay(2026, 6, 30))
    }

    @Test func dayContextSameLogicalDayAcrossMidnight() {
        // 6/29 晚 23 点 与 6/30 凌晨 1 点 属同一逻辑日
        #expect(DayContext.isSameLogicalDay(at(2026, 6, 29, 23, 0), at(2026, 6, 30, 1, 0)))
        // 6/30 凌晨 2 点 与 6/30 早 5 点 跨了日界线，不同逻辑日
        #expect(!DayContext.isSameLogicalDay(at(2026, 6, 30, 2, 0), at(2026, 6, 30, 5, 0)))
    }

    @Test func streakAccumulatesByLogicalDayWithDedup() {
        var days = Set<String>()
        days.insert(DayContext.dayKey(at(2026, 6, 28, 10, 0)))   // 6/28
        days.insert(DayContext.dayKey(at(2026, 6, 29, 10, 0)))   // 6/29
        days.insert(DayContext.dayKey(at(2026, 6, 29, 20, 0)))   // 6/29 再次 → 去重
        #expect(days.count == 2)
        // 6/30 凌晨 2 点 → 归到逻辑日 6/29 → 不增（验证凌晨归并）
        days.insert(DayContext.dayKey(at(2026, 6, 30, 2, 0)))
        #expect(days.count == 2)
        // 6/30 上午 → 真正的新逻辑日
        days.insert(DayContext.dayKey(at(2026, 6, 30, 10, 0)))
        #expect(days.count == 3)
    }

    // MARK: M5 reflow（晨间平移 / 撞固定块顺延 / 真相源往返）

    @Test func naiveReflowAnchorsFixedAndShiftsFlexible() async throws {
        let planner = NaivePlanningEngine()
        let code = ScheduledBlock(title: "写代码", start: at(2026,6,30,9), end: at(2026,6,30,10))
        let meeting = ScheduledBlock(title: "开会", start: at(2026,6,30,11),
                                     end: at(2026,6,30,12), isFixed: true)
        let read = ScheduledBlock(title: "读书", start: at(2026,6,30,13), end: at(2026,6,30,14))
        let now = at(2026,6,30,9,40)                       // 9:40 才开工
        let blocks = try await planner.reflow([code, meeting, read], from: now, now: now).orderedBlocks
        #expect(blocks.first { $0.title == "开会" }?.start == at(2026,6,30,11))   // 固定锚住
        #expect(blocks.first { $0.title == "写代码" }?.start == now)              // 从开工点起
        // 读书本应接在 10:40，但会撞 11:00 会议 → 顺延到会议后 12:00
        #expect(blocks.first { $0.title == "读书" }?.start == at(2026,6,30,12))
    }

    @Test func reflowLayoutDefersFlexibleHittingFixed() {
        let long = ScheduledBlock(title: "长任务", start: at(2026,6,30,10), end: at(2026,6,30,11,30)) // 90min
        let fixed = ScheduledBlock(title: "会议", start: at(2026,6,30,11),
                                   end: at(2026,6,30,12), isFixed: true)
        let laid = ReflowLayout.layOut(flexible: [long], fixed: [fixed], from: at(2026,6,30,10,30))
        #expect(laid.first { $0.title == "长任务" }?.start == at(2026,6,30,12))   // 撞会议→顺延到其后
        #expect(laid.first { $0.title == "会议" }?.start == at(2026,6,30,11))     // 固定不动
    }

    // MARK: 跨端日志（DeviceLog：追加/保留7天）

    @Test func logSyncFlushAppendsAndPrunesOldDays() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: DeviceLog.self, configurations: config)
        let sync = LogSyncService(context: container.mainContext)
        sync.dumpEnabled = false
        // 旧记录（10 天前）应被清
        container.mainContext.insert(DeviceLog(deviceID: "x", deviceName: "old", dayKey: "2026-06-20"))
        try container.mainContext.save()

        sync.start()
        DevLog.shared.info("测试", "第一条")
        DevLog.shared.warn("测试", "第二条")
        sync.flush(now: at(2026,7,5,12))
        DevLog.shared.onAppend = nil   // 摘钩，别影响其它测试

        let logs = try container.mainContext.fetch(FetchDescriptor<DeviceLog>())
        #expect(logs.count == 1)                          // 旧的清了、今天的建了
        let today = logs.first { $0.dayKey == "2026-07-05" }
        #expect(today != nil)
        #expect(today?.text.contains("第一条") == true)
        #expect(today?.text.contains("[WARNING] 测试: 第二条") == true)
    }

    // MARK: 草稿快照（崩溃/重启还原）

    @Test func draftSnapshotPersistsAndRestoresUnconfirmedDraft() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bc-draft-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let store = DraftSnapshotStore(directory: tmp)

        // 第一个 VM：造未确认草稿 → persistDraft
        let vm1 = Self.makeHomeVM(planStore: planStore, draftStore: store)
        vm1.inputText = "写代码两小时，下午健身"
        vm1.blocks = [EditableBlock(title: "写代码", start: at(2026,7,5,9), end: at(2026,7,5,11),
                                    priority: .important)]
        vm1.draftSource = .arranged
        vm1.pendingLongTasks = [ParsedLongTask(title: "交论文", deadline: at(2026,7,11,22),
                                               cadenceMinutesPerWeek: nil)]
        vm1.persistDraft()

        // 第二个 VM（模拟崩溃后重启）：整份还原
        let vm2 = Self.makeHomeVM(planStore: planStore, draftStore: store)
        #expect(vm2.inputText == "写代码两小时，下午健身")
        #expect(vm2.draftSource == .arranged)
        #expect(vm2.blocks.count == 1)
        #expect(vm2.blocks.first?.title == "写代码")
        #expect(vm2.blocks.first?.priority == .important)
        #expect(vm2.pendingLongTasks.first?.title == "交论文")

        // 已确认（loaded）状态的快照 → 重启只还原输入文本，块交给真相源自动加载
        vm2.draftSource = .loaded
        vm2.persistDraft()
        let vm3 = Self.makeHomeVM(planStore: planStore, draftStore: store)
        #expect(vm3.inputText == "写代码两小时，下午健身")
        #expect(vm3.blocks.isEmpty)
        #expect(vm3.draftSource == .empty)
    }

    // MARK: 排X天按钮文案（目标日口语词）

    @Test func relativeDayWordFollowsTargetDay() {
        let cal = Calendar.current
        let now = Date.now
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: now)! }
        #expect(HomeView.relativeDayWord(day(0), from: now) == "今天")
        #expect(HomeView.relativeDayWord(day(1), from: now) == "明天")
        #expect(HomeView.relativeDayWord(day(2), from: now) == "后天")
        #expect(HomeView.relativeDayWord(day(-1), from: now) == "昨天")
        #expect(HomeView.relativeDayWord(day(5), from: now) != "今天")   // 远日显日期
    }

    // MARK: 「在途」池（M10：LongTask 跨日任务/长线作业）

    @Test func planningEnginePoolDefaultIgnoresPool() async throws {
        // 协议扩展默认实现：本地引擎带池调用 = 不带池（建议是 LLM 的活，Naive 不产建议块）
        let planner = NaivePlanningEngine()
        let b = ScheduledBlock(title: "写代码", start: at(2026,7,4,9), end: at(2026,7,4,10))
        let pool = [LongTaskBrief(title: "论文", deadline: at(2026,7,11,22), cadenceMinutesPerWeek: nil)]
        let d = try await planner.arrange([b], pool: pool, now: at(2026,7,4,8))
        #expect(d.orderedBlocks.count == 1)
        #expect(d.poolSuggestedTitles.isEmpty)
    }

    @Test func longTaskStoreAddsDedupsAndLifecycles() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LongTask.self, configurations: config)
        let store = LongTaskStore(context: container.mainContext)
        let ddl = at(2026,7,11,22)
        store.add(title: "交论文", deadline: ddl)
        store.add(title: "学 Swift", cadenceMinutesPerWeek: 300)
        #expect(store.active().count == 2)
        #expect(store.active().first?.title == "交论文")          // 有 DDL 的排前
        // 幂等：同名再确认一次 → 不重复、只更新 DDL
        store.add(title: "交论文", deadline: at(2026,7,12,22))
        #expect(store.active().count == 2)
        #expect(store.active().first?.deadline == at(2026,7,12,22))
        // 生命周期：完成/放下出池；改期顺延
        let swift = store.active().first { $0.title == "学 Swift" }!
        store.pushDeadline(swift, days: 7)
        #expect(swift.deadline != nil)
        store.complete(store.active().first!)
        #expect(store.active().count == 1)
        store.shelve(store.active().first!)
        #expect(store.active().isEmpty)
    }

    @Test func longTaskInvestedMinutesAggregatesSessionsByTitle() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LongTask.self, ExecutionSession.self,
                                           configurations: config)
        let store = LongTaskStore(context: container.mainContext)
        let sessions = ExecutionSessionStore(context: container.mainContext)
        let paper = store.add(title: "写论文", deadline: at(2026,7,11,22))
        sessions.record(blockID: nil, title: "写论文", start: at(2026,7,3,9), end: at(2026,7,3,10,30),
                        timingStyle: .light, pomodoroWorkSegments: nil, interruptions: 0)   // 昨天 90m
        sessions.record(blockID: nil, title: "论文", start: at(2026,7,4,9), end: at(2026,7,4,10),
                        timingStyle: .light, pomodoroWorkSegments: nil, interruptions: 0)   // 今天 60m（相似标题）
        sessions.record(blockID: nil, title: "健身", start: at(2026,7,4,16), end: at(2026,7,4,17),
                        timingStyle: .light, pomodoroWorkSegments: nil, interruptions: 0)   // 无关
        #expect(store.investedMinutes(for: paper) == 150)                       // 累计
        #expect(store.investedMinutes(for: paper, on: at(2026,7,4,12)) == 60)   // 只今天
        let line = store.progressLine(now: at(2026,7,4,12))
        #expect(line?.contains("写论文") == true)
        #expect(line?.contains("累计") == true)
        #expect(store.progressLine(now: at(2026,7,6,12)) == nil)                // 没动的日子不上榜
    }

    @Test func longTaskOverdueQuery() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LongTask.self, configurations: config)
        let store = LongTaskStore(context: container.mainContext)
        store.add(title: "早该交的", deadline: at(2026,7,1,22))
        store.add(title: "还早", deadline: at(2026,12,1,22))
        store.add(title: "无 DDL")
        let od = store.overdue(now: at(2026,7,4,12))
        #expect(od.count == 1)
        #expect(od.first?.title == "早该交的")
    }

    // MARK: 标记完成（MarkDone Intent → ExecutionViewModel.markDone）

    @Test func markDoneRecordsActualForMatchingPlannedBlock() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        try planStore.replacePlanned([
            ScheduledBlock(title: "写代码", start: s, end: s.addingTimeInterval(3600)),
            ScheduledBlock(title: "读书", start: s.addingTimeInterval(3600), end: s.addingTimeInterval(7200)),
        ], on: day)
        let vm = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: FakeReminderStore(),
            liveActivity: NoLiveActivity())
        await vm.loadToday()
        #expect(vm.doneCount == 0)
        let hit = await vm.markDone(titleLike: "写代码")
        #expect(hit == "写代码")
        #expect(vm.doneCount == 1)
        let miss = await vm.markDone(titleLike: "完全无关的事")
        #expect(miss == nil)
        #expect(vm.doneCount == 1)
    }

    @Test func appIntentMarkDoneCarriesTitlePayload() {
        _ = AppIntentRequest.consume()
        AppIntentRequest.enqueue(.markDone, payload: "写代码")
        #expect(AppIntentRequest.payload() == "写代码")
        #expect(AppIntentRequest.consume() == .markDone)
    }

    // MARK: 日记照片跨端（JournalPhoto：DB 真相源 + 本地缓存 + 旧文件迁移）

    @Test func photoStoreRoundTripsViaDBAndMigratesLocalFiles() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bc-photo-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: JournalPhoto.self, configurations: config)

        // 预置一张「旧版本只存了本地文件」的照片 → init 时应迁入 DB
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let legacy = "legacy.jpg"
        try Data([0xFF, 0xD8, 0xFF]).write(to: tmp.appendingPathComponent(legacy))

        let store = PhotoStore(context: container.mainContext, directory: tmp)
        let inDB = try container.mainContext.fetch(FetchDescriptor<JournalPhoto>())
        #expect(inDB.contains { $0.ref == legacy })          // 旧文件迁入

        // save → DB + 缓存；删缓存文件后 data(for:) 仍能从 DB 取回（模拟另一端同步到的照片）
        let ref = store.save(Data([0x01, 0x02, 0x03]))
        #expect(ref != nil)
        try FileManager.default.removeItem(at: store.url(for: ref!))
        #expect(store.data(for: ref!) == Data([0x01, 0x02, 0x03]))

        store.delete(ref!)
        #expect(store.data(for: ref!) == nil)
    }

    // MARK: 日记 R5：导出 markdown + 往年今天

    @Test func journalExportMarkdownOrdersAndFormats() {
        let old = JournalEntry(date: at(2025,7,4,21), body: "去年今天", mood: "😌", tags: ["回顾"])
        let new = JournalEntry(date: at(2026,7,3,22), body: "昨天", mood: nil, tags: [])
        let md = JournalExport.markdown([new, old])
        #expect(md.hasPrefix("# BetterCalendar 日记"))
        #expect(md.contains("😌"))
        #expect(md.contains("#回顾"))
        // 按时间正序：去年的在前
        #expect(md.range(of: "去年今天")!.lowerBound < md.range(of: "昨天")!.lowerBound)
    }

    @Test func journalOnThisDayFindsSameMonthDayInPastYears() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: JournalEntry.self, configurations: config)
        let store = JournalStore(context: container.mainContext)
        let vm = JournalViewModel(store: store)
        _ = store  // silence unused warning path
        container.mainContext.insert(JournalEntry(date: at(2025,7,4,20), body: "去年今天"))
        container.mainContext.insert(JournalEntry(date: at(2025,7,1,20), body: "去年七月一"))
        try container.mainContext.save()
        vm.reload()
        #expect(vm.onThisDay(at(2026,7,4,12))?.body == "去年今天")   // 同月同日命中
        #expect(vm.onThisDay(at(2026,7,2,12)) == nil)                // 无同月同日 → nil
    }

    // MARK: 执行会话落库（ExecutionSession，趋势统计数据源）

    @Test func executionSessionStoreRecordsAndQueriesByLogicalDay() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ExecutionSession.self, configurations: config)
        let store = ExecutionSessionStore(context: container.mainContext)
        store.record(blockID: UUID(), title: "写代码", start: at(2026,7,4,9), end: at(2026,7,4,10,30),
                     timingStyle: .pomodoro, pomodoroWorkSegments: 3, interruptions: 1)
        store.record(blockID: nil, title: "凌晨收尾", start: at(2026,7,5,1), end: at(2026,7,5,2),
                     timingStyle: .light, pomodoroWorkSegments: nil, interruptions: 0)
        let day = store.sessions(onLogicalDay: at(2026,7,4,12))
        #expect(day.count == 2)                             // 凌晨 1 点 = 同一逻辑日
        #expect(day.first?.completedCount == 3)             // 番茄段数保住
        #expect(day.first?.interruptions == 1)
        #expect(store.sessions(onLogicalDay: at(2026,7,6,12)).isEmpty)
    }

    // MARK: deadline（硬 DDL）贯通：解析 → 草稿 → 真相源/提醒

    @Test func editableBlockCarriesDeadlineThrough() {
        let ddl = at(2026,7,4,22)
        let b = ScheduledBlock(title: "交作业", start: at(2026,7,4,19), end: at(2026,7,4,21),
                               priority: .normal, deadline: ddl)
        let editable = EditableBlock(from: b)
        #expect(editable.deadline == ddl)              // 草稿携带（之前在这里丢）
        #expect(editable.scheduled.deadline == ddl)    // 回转不丢 → 真相源/提醒都拿得到
    }

    // MARK: 实际写入「合并不覆盖」（工程债修复：menu bar × 回填 × 双端并发）

    @Test func calendarMergeUnionKeepsExistingAndOverridesSameKey() {
        let e1 = CalendarEventDraft(title: "回填的事", start: at(2026,7,4,14), end: at(2026,7,4,15), kind: .actual)
        let e2 = CalendarEventDraft(title: "写代码", start: at(2026,7,4,9), end: at(2026,7,4,10), kind: .actual)
        // done 里同键（写代码@9点）但时长更新到 10:30；新增一件
        let a1 = CalendarEventDraft(title: "写代码", start: at(2026,7,4,9), end: at(2026,7,4,10,30), kind: .actual)
        let a2 = CalendarEventDraft(title: "健身", start: at(2026,7,4,16), end: at(2026,7,4,17), kind: .actual)
        let merged = CalendarMerge.union(existing: [e1, e2], additions: [a1, a2], kind: .actual)
        #expect(merged.count == 3)                                    // 回填的保住、同键不重复
        #expect(merged.first { $0.title == "写代码" }?.end == at(2026,7,4,10,30))   // additions 覆盖同键
        #expect(merged.contains { $0.title == "回填的事" })            // 别处写的不被删
    }

    // MARK: 活跃天数 / 今日 MVP（DayRecord，跨端同步的复盘小数据）

    @Test func dayRecordStoreCountsDistinctActiveDaysAndIsIdempotent() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: DayRecord.self, configurations: config)
        let store = ReviewLocalStore(context: container.mainContext)
        #expect(store.activeDayCount == 0)
        store.markActive(on: at(2026,6,30,12))
        store.markActive(on: at(2026,6,30,20))   // 同一逻辑日重复标 → 不重复计
        store.markActive(on: at(2026,7,1,1))     // 凌晨 1 点 = 逻辑日 6/30 → 也不重复计
        #expect(store.activeDayCount == 1)
        store.markActive(on: at(2026,7,1,9))     // 新的一天
        #expect(store.activeDayCount == 2)
    }

    @Test func dayRecordStoreMVPRoundTripsAndDedupsByLatest() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: DayRecord.self, configurations: config)
        let store = ReviewLocalStore(context: container.mainContext)
        store.todayMVP = "写代码"
        store.todayMVPNote = "最稳的一件"
        #expect(store.todayMVP == "写代码")
        #expect(store.todayMVPNote == "最稳的一件")
        // 模拟两端并发写出的重复 dayKey 记录：新 modifiedAt 优先
        let key = DayContext.dayKey(.now)
        container.mainContext.insert(
            DayRecord(dayKey: key, isActive: true, mvpTitle: "健身",
                      modifiedAt: .now.addingTimeInterval(60)))
        #expect(store.todayMVP == "健身")
        #expect(store.activeDayCount == 1)   // 重复 dayKey 只算一天
    }

    @Test func planStoreRoundTripsMetadataAndReplaces() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let day = at(2026,6,30,12)
        try store.replacePlanned([
            ScheduledBlock(title: "开会", start: at(2026,6,30,9), end: at(2026,6,30,10),
                           isFixed: true, priority: .important)
        ], on: day)
        let read = try store.plannedBlocks(on: day)
        #expect(read.count == 1)
        #expect(read.first?.isFixed == true)            // 固定信息保住（reflow 命门）
        #expect(read.first?.priority == .important)
        // 覆盖写：替换不累积
        try store.replacePlanned([
            ScheduledBlock(title: "换了", start: at(2026,6,30,9), end: at(2026,6,30,10))
        ], on: day)
        #expect(try store.plannedBlocks(on: day).count == 1)
        #expect(try store.plannedBlocks(on: day).first?.title == "换了")
    }

    /// 排日程页自动加载目标日已确认计划（2026-07-01 Jason 定）：
    /// 进页/切目标日加载真相源；未确认的新草稿不被覆盖；切到空的一天清掉加载视图。
    @Test func homeAutoLoadsConfirmedPlanForTargetDay() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let vm = Self.makeHomeVM(planStore: store)
        let day = at(2026, 7, 2, 12)
        try store.replacePlanned([
            ScheduledBlock(title: "写代码", start: at(2026, 7, 2, 9), end: at(2026, 7, 2, 11)),
            ScheduledBlock(title: "健身", start: at(2026, 7, 2, 15), end: at(2026, 7, 2, 16)),
        ], on: day)

        vm.targetDay = day
        vm.autoLoadOnAppear()
        #expect(vm.blocks.count == 2)
        #expect(vm.draftSource == .loaded)

        // 未确认的新草稿（arranged）不被自动加载覆盖
        vm.blocks = [EditableBlock(title: "新草稿", start: day, end: day.addingTimeInterval(3600))]
        vm.draftSource = .arranged
        vm.autoLoadOnAppear()
        #expect(vm.blocks.count == 1)
        #expect(vm.blocks.first?.title == "新草稿")

        // 已确认视图下切到没计划的一天 → 清空、回 empty
        vm.draftSource = .loaded
        vm.targetDay = at(2026, 7, 3, 12)
        vm.loadConfirmedPlan()
        #expect(vm.blocks.isEmpty)
        #expect(vm.draftSource == .empty)
    }

    /// 修复回归：编辑「已加载的确认计划」后未点确认 → 切 tab / 再次进页不能静默丢弃编辑。
    @Test func homeAutoSavesEditsToLoadedPlan() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let vm = Self.makeHomeVM(planStore: store)
        let day = at(2026, 7, 2, 12)
        try store.replacePlanned([
            ScheduledBlock(title: "写代码", start: at(2026, 7, 2, 9), end: at(2026, 7, 2, 11)),
            ScheduledBlock(title: "健身", start: at(2026, 7, 2, 15), end: at(2026, 7, 2, 16)),
        ], on: day)
        vm.targetDay = day
        vm.autoLoadOnAppear()
        #expect(vm.draftSource == .loaded)
        #expect(vm.blocks.count == 2)

        // 0.15：编辑已加载计划（删一项）→ **保持已确认视图**，自动回写真相源
        vm.delete(id: vm.blocks[0].id)
        #expect(vm.draftSource == .loaded)
        await vm.autoCommitNow()   // 冲掉防抖直接落盘（也取消挂起任务，防游离 Task）
        #expect(try store.plannedBlocks(on: day).count == 1)   // 真相源已更新
        #expect(try store.plannedBlocks(on: day).first?.title == "健身")

        // 再次进页 → 重载出的就是保存后的 1 项（编辑即真相，不存在"被覆盖"）
        vm.autoLoadOnAppear()
        #expect(vm.blocks.count == 1)
    }

    private static func makeHomeVM(planStore: PlanStore,
                                   draftStore: DraftSnapshotStore? = nil) -> HomeViewModel {
        struct NoRefine: PlanRefining {
            func refine(_ blocks: [ScheduledBlock], command: String,
                        originalRequest: String, now: Date) async throws -> [ScheduledBlock] { blocks }
        }
        struct NoNotify: NotificationScheduling {
            func requestAuthorizationIfNeeded() async {}
            func scheduleDailyReminders(morning: Date?, evening: Date?, summary: String) async {}
        }
        return HomeViewModel(
            arrangeDay: ArrangeDayUseCase(parser: StubScheduleParser(), planner: NaivePlanningEngine()),
            refiner: NoRefine(),
            calendarStore: FakeCalendarStore(),
            reminderStore: FakeReminderStore(),
            exporter: ICSExporter(),
            planStore: planStore,
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            notifier: NoNotify(),
            draftStore: draftStore)
    }

    // MARK: M5 尾巴（排不下冲突 / 解法 / 通知时间）

    @Test func reflowConflictWhenOverflowsDayEnd() {
        let now = at(2026,6,30,10)
        let huge = ScheduledBlock(title: "超长", start: at(2026,6,30,10), end: at(2026,7,1,16)) // ~30h
        let laid = ReflowLayout.layOut(flexible: [huge], fixed: [], from: now)
        let conflict = ReflowLayout.conflict(in: laid, now: now)
        #expect(conflict?.blockTitle == "超长")   // 超过次日 4 点日界线 → 冲突
    }

    @Test func reflowResolutionSkipRemovesBlock() {
        let blocks = [
            ScheduledBlock(title: "A", start: at(2026,6,30,9), end: at(2026,6,30,10)),
            ScheduledBlock(title: "B", start: at(2026,6,30,10), end: at(2026,6,30,11)),
        ]
        let result = RescheduleService.apply(.skip("B"), to: blocks, from: at(2026,6,30,9))
        #expect(result.map(\.title) == ["A"])
    }

    @Test func reflowResolutionSplitMakesTwoHalves() {
        let blocks = [ScheduledBlock(title: "长", start: at(2026,6,30,9), end: at(2026,6,30,11))] // 2h
        let result = RescheduleService.apply(.split("长"), to: blocks, from: at(2026,6,30,9))
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })   // 各 1h
    }

    @Test func reminderTimesFromFirstAndLastBlock() {
        let blocks = [
            ScheduledBlock(title: "早", start: at(2026,6,30,9), end: at(2026,6,30,10)),
            ScheduledBlock(title: "晚", start: at(2026,6,30,20), end: at(2026,6,30,21)),
        ]
        let t = RescheduleService.reminderTimes(for: blocks)
        #expect(t.morning == at(2026,6,30,8,45))    // 首块前 15 分钟
        #expect(t.evening == at(2026,6,30,21,30))   // 末块后 30 分钟
    }

    // MARK: M6 番茄钟分段

    @Test func pomodoroPhaseWorkRestCycle() {
        let w = PomodoroTimer.phase(elapsed: 10 * 60)       // 10 分钟 → 工作段
        #expect(w.kind == .work)
        #expect(w.remaining == 15 * 60)
        let r = PomodoroTimer.phase(elapsed: 27 * 60)       // 27 分钟 → 休息段
        #expect(r.kind == .rest)
        #expect(r.elapsedInPhase == 2 * 60)
        #expect(r.remaining == 3 * 60)
        let w2 = PomodoroTimer.phase(elapsed: 31 * 60)      // 31 分钟 → 第二轮工作
        #expect(w2.kind == .work)
        #expect(w2.elapsedInPhase == 1 * 60)
    }

    // MARK: M9/R1 日记

    @Test func journalStoreTodayIsSingletonAndSearchable() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: JournalEntry.self, configurations: config)
        let store = JournalStore(context: container.mainContext)
        let e1 = store.entryForToday()
        e1.body = "今天写代码很顺"; store.save()
        let e2 = store.entryForToday()
        #expect(e1.id == e2.id)                       // 一天最多一条
        #expect(store.allEntries().count == 1)
        #expect(store.search("写代码").count == 1)    // 全文搜
        #expect(store.search("钓鱼").count == 0)
        store.delete(e1)
        #expect(store.allEntries().isEmpty)
    }
}
