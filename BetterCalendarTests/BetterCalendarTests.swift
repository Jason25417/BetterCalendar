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

    // MARK: 日期钉到目标日（0.18.20：杀"明天"漂移/年份幻觉 → 修 menu bar/开始今天"无计划")
    @Test func clampToDayPinsBlocksToTargetDay() {
        let ref = at(2026,7,6,0)
        // LLM 把块错排到 7/7 上午9点 → 钉回 7/6 上午9点、时长保留
        let (s, e) = ArrangeDayUseCase.clampToDay(start: at(2026,7,7,9), end: at(2026,7,7,11), referenceDate: ref)
        #expect(Calendar.current.isDate(s, inSameDayAs: at(2026,7,6,0)))
        #expect(Calendar.current.component(.hour, from: s) == 9)
        #expect(e.timeIntervalSince(s) == 7200)
        // 凌晨(<6点)块=睡前跨午夜 → 落次日 7/7
        let (s2, _) = ArrangeDayUseCase.clampToDay(start: at(2026,7,6,1), end: at(2026,7,6,2), referenceDate: ref)
        #expect(Calendar.current.isDate(s2, inSameDayAs: at(2026,7,7,0)))
    }

    // MARK: 最晚工作时间（0.18.12：收工软限制文案 + 夹取）
    @Test func workHoursWindDownTextAndClamp() {
        let saved = WorkHoursSettings.windDownHour
        WorkHoursSettings.windDownHour = 22
        #expect(WorkHoursSettings.windDownText == "22:00")
        WorkHoursSettings.windDownHour = 99          // 越界 → 夹到 24
        #expect(WorkHoursSettings.windDownHour == 24)
        WorkHoursSettings.windDownHour = saved       // 恢复，避免污染其它测试
    }

    // MARK: L2「帮我排进今天」空档查找（0.18.13）
    @Test func firstFreeStartFindsGapBeforeWindDown() {
        let nine = at(2026,7,6,9), windDown = at(2026,7,6,23)
        let existing = [(start: at(2026,7,6,9), end: at(2026,7,6,10)),
                        (start: at(2026,7,6,14), end: at(2026,7,6,15))]
        // 9–10 后有大空档 → 60min 插到 10:00
        #expect(HomeViewModel.firstFreeStart(existing: existing, duration: 3600,
                                             notBefore: nine, windDown: windDown) == at(2026,7,6,10))
        // 收工前被占满 → 排不下 → nil
        let packed = [(start: at(2026,7,6,9), end: at(2026,7,6,23))]
        #expect(HomeViewModel.firstFreeStart(existing: packed, duration: 3600,
                                             notBefore: nine, windDown: windDown) == nil)
    }

    // MARK: 本地兜底解析抽时长（0.18.23：云端失败时也给可用草稿）
    @Test func stubExtractsDurations() {
        #expect(StubScheduleParser.extractMinutes("写两个小时的论文") == 120)
        #expect(StubScheduleParser.extractMinutes("花半个小时整理房间") == 30)
        #expect(StubScheduleParser.extractMinutes("1。5个小时的数据库学习") == 90)   // 中文句号当小数
        #expect(StubScheduleParser.extractMinutes("3个小时的开发") == 180)
        #expect(StubScheduleParser.extractMinutes("锻炼一个半小时") == 90)
        #expect(StubScheduleParser.extractMinutes("发呆 20 分钟") == 20)
        #expect(StubScheduleParser.extractMinutes("没提时长的事") == nil)
    }

    // MARK: JSON 尾逗号修复（0.18.22：治「JSON 解码失败」）
    @Test func extractObjectRepairsTrailingCommas() {
        let out = JSONText.extractObject("```json\n{\"a\":[1,2,],\"b\":3,}\n```")
        #expect((try? JSONSerialization.jsonObject(with: Data(out.utf8))) != nil)   // 围栏去掉+尾逗号修掉→可解析
    }

    // MARK: 松散意图识别（0.18.9：LLM 从输入识别"想松散"→标目标日松散）
    @Test func decodePlanReadsLooseIntent() {
        let d = ClaudeScheduleParser.decodePlan("{\"loose\":true,\"blocks\":[],\"longTasks\":[]}")
        #expect(d?.loose == true)                 // 明说想松散 → true（无块也带得上来）
        let d2 = ClaudeScheduleParser.decodePlan(
            "{\"blocks\":[{\"title\":\"写代码\",\"start\":\"2026-07-06 09:00\",\"end\":\"2026-07-06 10:00\"}]}")
        #expect(d2?.loose == false)               // 普通排程、没提松散 → false
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
        #expect(!text.contains("计划外"))   // 去对比化：分享面不单标计划外（那件仍在下方清单里被庆祝）
        #expect(text.contains("有效投入 2 小时 30 分"))
        #expect(text.contains("今日最有价值：写代码"))
        #expect(text.contains("- 读论文"))   // 计划外那件仍进"做成了什么"清单、平权庆祝
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
        // 目标日按逻辑日（重构 2026-07-07）：晚上 → 明天，白天 → 今天，凌晨(0–4) → 逻辑今天=日历昨天
        #expect(DayContext.defaultTargetDay(at(2026, 6, 30, 22, 0)) == startOfDay(2026, 7, 1))
        #expect(DayContext.defaultTargetDay(at(2026, 6, 30, 15, 0)) == startOfDay(2026, 6, 30))
        #expect(DayContext.defaultTargetDay(at(2026, 6, 30, 1, 0)) == startOfDay(2026, 6, 29))
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
        vm1.delete(id: UUID())   // 触发 markDirty（不删任何块，仅置未保存标记）
        vm1.persistDraft()

        // 第二个 VM（模拟重启，0.16 文件模型）：**不自动还原**，只给恢复入口
        let vm2 = Self.makeHomeVM(planStore: planStore, draftStore: store)
        #expect(vm2.inputText == "写代码两小时，下午健身")
        #expect(vm2.blocks.isEmpty)                 // 默认显示已保存态
        #expect(vm2.pendingRestore != nil)          // 小字入口在
        vm2.applyPendingRestore()                   // 点「恢复」
        #expect(vm2.hasUnsavedChanges == true)
        #expect(vm2.blocks.count == 1)
        #expect(vm2.blocks.first?.title == "写代码")
        #expect(vm2.pendingLongTasks.first?.title == "交论文")

        // 干净（已保存）状态的快照 → 重启无恢复入口
        vm2.discardDraft()
        let vm3 = Self.makeHomeVM(planStore: planStore, draftStore: store)
        #expect(vm3.inputText == "写代码两小时，下午健身")
        #expect(vm3.blocks.isEmpty)
        #expect(vm3.pendingRestore == nil)
    }

    // MARK: 排X天按钮文案（目标日口语词）

    @Test func relativeDayWordFollowsTargetDay() {
        let cal = Calendar.current
        // 钉死白天时刻（原来用 Date.now：凌晨跑测试会因逻辑日基准挂掉）
        let now = at(2026, 7, 8, 15, 0)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: now)! }
        #expect(HomeView.relativeDayWord(day(0), from: now) == "今天")
        #expect(HomeView.relativeDayWord(day(1), from: now) == "明天")
        #expect(HomeView.relativeDayWord(day(2), from: now) == "后天")
        #expect(HomeView.relativeDayWord(day(-1), from: now) == "昨天")
        #expect(HomeView.relativeDayWord(day(5), from: now) != "今天")   // 远日显日期
        // 凌晨 0–4 点：逻辑今天 = 日历昨天（凌晨 1 点看 7/7 = "今天"、7/8 = "明天"）
        let lateNight = at(2026, 7, 8, 1, 0)
        #expect(HomeView.relativeDayWord(at(2026, 7, 7, 0), from: lateNight) == "今天")
        #expect(HomeView.relativeDayWord(at(2026, 7, 8, 0), from: lateNight) == "明天")
    }

    // MARK: 锚点块（午饭/通勤：占日程但不计完成度、不进执行列表）

    @Test func anchorBlockExcludedFromExecutionPlanned() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        try planStore.replacePlanned([
            ScheduledBlock(title: "写代码", start: s, end: s.addingTimeInterval(3600)),
            ScheduledBlock(title: "午饭", start: s.addingTimeInterval(3600), end: s.addingTimeInterval(5400),
                           isAnchor: true),
        ], on: day)
        // 锚点属性往返存活
        #expect(try planStore.plannedBlocks(on: day).first { $0.title == "午饭" }?.isAnchor == true)
        let vm = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: FakeReminderStore(),
            liveActivity: NoLiveActivity())
        await vm.loadToday()
        #expect(vm.planned.count == 1)                       // 午饭不进执行列表
        #expect(vm.planned.first?.title == "写代码")
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

    @Test func longTaskProgressUnitsAndFraction() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LongTask.self, ExecutionSession.self, configurations: config)
        let store = LongTaskStore(context: container.mainContext)
        let sessions = ExecutionSessionStore(context: container.mainContext)
        // 量化学习：9 单元 × 40min = 360，已做 120min（=3 单元）
        let t = store.add(title: "量化学习", totalMinutes: 360, unitMinutes: 40)
        sessions.record(blockID: nil, title: "量化学习", start: at(2026,7,5,9), end: at(2026,7,5,11),
                        timingStyle: .light, pomodoroWorkSegments: nil, interruptions: 0)
        #expect(store.progressText(for: t).contains("已推进 3/9 单元"))
        #expect(abs((store.progressFraction(for: t) ?? 0) - (120.0/360.0)) < 0.001)
        // 无总量的任务：只显已投入、无条
        let t2 = store.add(title: "数据库学习")
        sessions.record(blockID: nil, title: "数据库学习", start: at(2026,7,5,14), end: at(2026,7,5,15),
                        timingStyle: .light, pomodoroWorkSegments: nil, interruptions: 0)
        #expect(store.progressText(for: t2) == "已投入 1 小时")
        #expect(store.progressFraction(for: t2) == nil)
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

    // MARK: 0.18.2 精确归属：会话所属块显式归属 → 不靠标题、不串味
    @Test func investedMinutesPrefersLinkedTaskOverTitle() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LongTask.self, ExecutionSession.self, PlanBlock.self,
                                           configurations: config)
        let ctx = container.mainContext
        let store = LongTaskStore(context: ctx)
        let sessions = ExecutionSessionStore(context: ctx)
        let paper = store.add(title: "论文")
        let db = store.add(title: "数据库")                 // 与"论文"不相似 → 两件并存（不触发入池去重）
        // 块显式归属到「论文」，但块/会话标题写成「数据库」——用来证明"归属优先于标题"
        let bid = UUID()
        ctx.insert(PlanBlock(id: bid, title: "数据库", start: at(2026,7,5,9), end: at(2026,7,5,10),
                             kind: .planned, linkedTaskID: paper.id))
        try ctx.save()
        sessions.record(blockID: bid, title: "数据库", start: at(2026,7,5,9), end: at(2026,7,5,10),
                        timingStyle: .light, pomodoroWorkSegments: nil, interruptions: 0)   // 60m
        #expect(store.investedMinutes(for: paper) == 60)    // 归属优先：虽标题=数据库，仍精确记给「论文」
        #expect(store.investedMinutes(for: db) == 0)        // 标题匹配也不串味（块显式属于「论文」）
    }

    // MARK: 0.18.2 超估算 → 淡掉 N/M 单元、只显已投入 + looksComplete 出邀请
    @Test func progressDropsFractionWhenOverEstimate() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LongTask.self, ExecutionSession.self, configurations: config)
        let store = LongTaskStore(context: container.mainContext)
        let sessions = ExecutionSessionStore(context: container.mainContext)
        let t = store.add(title: "通识作业", totalMinutes: 120, unitMinutes: 60)   // 估 2 单元
        sessions.record(blockID: nil, title: "通识作业", start: at(2026,7,5,9), end: at(2026,7,5,12),
                        timingStyle: .light, pomodoroWorkSegments: nil, interruptions: 0)   // 180m > 120
        #expect(store.looksComplete(for: t) == true)                 // 达/超估算 → 出"看起来做完了？"
        #expect(store.progressText(for: t) == "已投入 3 小时")        // 淡掉 N/M 单元、只显已投入
        #expect(store.progressFraction(for: t) == 1.0)               // 条封顶、不越界
    }

    // MARK: L3 主动建议引擎（0.18.14）：触发 + 休息日静音 + 强度 + 静音集
    @Test func l3SuggestsDeadlineAndRespectsLooseIntensityMute() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LongTask.self, ExecutionSession.self, PlanBlock.self,
                                           configurations: config)
        let store = LongTaskStore(context: container.mainContext)
        let paper = store.add(title: "论文", deadline: at(2026,7,7,22))   // 1 天后 DDL
        let now = at(2026,7,6,10)
        let s = store.l3Suggestions(now: now, loose: false, intensity: 1, muted: [])
        #expect(s.count == 1)
        #expect(s.first?.kind == .deadline)
        #expect(s.first?.text.contains("论文") == true)
        #expect(store.l3Suggestions(now: now, loose: true, intensity: 1, muted: []).isEmpty)      // 休息日全静音
        #expect(store.l3Suggestions(now: now, loose: false, intensity: 0, muted: []).isEmpty)     // 关闭
        #expect(store.l3Suggestions(now: now, loose: false, intensity: 1, muted: [paper.id]).isEmpty) // 别再提
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

    // MARK: 带 DDL 的未来任务入池 → 系统提醒（0.18.1，去重不重复）

    @Test func poolDeadlineTaskWritesReminderUnlessAlreadyScheduledAsBlock() {
        let ddl = at(2026,7,10,23)
        let pending = [
            ParsedLongTask(title: "期末论文", deadline: ddl),            // 有 DDL、没排块 → 出提醒
            ParsedLongTask(title: "学 Swift"),                          // 无 DDL → 不出
            ParsedLongTask(title: "读论文", deadline: at(2026,7,8,20)),  // 有 DDL 但已排成今天块 → 去重跳过
        ]
        let drafts = HomeViewModel.poolReminderDrafts(pending: pending,
                                                      blockTitles: ["读论文"], leadMinutes: 30)
        #expect(drafts.count == 1)
        #expect(drafts.first?.title == "期末论文")
        #expect(drafts.first?.due == ddl)
        #expect(drafts.first?.priority == 5)          // 中优先级，同带 DDL 块口径
        #expect(drafts.first?.leadMinutes == 30)
    }

    // MARK: 复盘对比跳过锚点（0.18.1，午饭这类不算 missed）

    @Test func reviewStripsAnchorsFromComparison() {
        let planned = [
            CalendarEventDraft(title: "写代码", start: at(2026,7,5,9), end: at(2026,7,5,11), kind: .planned),
            CalendarEventDraft(title: "午饭", start: at(2026,7,5,12), end: at(2026,7,5,13), kind: .planned),
        ]
        let stripped = ReviewViewModel.stripAnchors(planned, anchorTitles: ["午饭"])
        #expect(stripped.count == 1)
        #expect(stripped.first?.title == "写代码")                       // 锚点被剔、任务保留
        #expect(ReviewViewModel.stripAnchors(planned, anchorTitles: []).count == 2)   // 无锚点 → 原样
    }

    // MARK: 要紧事兑现红利（0.18.3）——只庆祝做成的，没做成的不罚、不留校
    // MARK: 按日清日历（0.18.6：删光当天最后一件也能确认写入=清空那天，不误删别天）
    @Test func fakeCalendarClearsSingleDayOnly() async throws {
        let store = FakeCalendarStore()
        try await store.write([
            CalendarEventDraft(title: "今天A", start: at(2026,7,6,9), end: at(2026,7,6,10), kind: .planned),
            CalendarEventDraft(title: "明天B", start: at(2026,7,7,9), end: at(2026,7,7,10), kind: .planned),
        ])
        try await store.clear(kind: .planned, on: at(2026,7,6,0))
        let left = try await store.read(kind: .planned)
        #expect(left.count == 1)
        #expect(left.first?.title == "明天B")   // 只清了 7/6，7/7 保留
    }

    @Test func reviewMITCashInOnlyCelebratesDone() {
        let done = ReviewViewModel.mitDone(importantTitles: ["写论文", "复习考试"],
                                           accomplishedTitles: ["写论文", "健身"])
        #expect(done == ["写论文"])          // 论文做成→兑现；复习没做成→不进(不罚)
        #expect(ReviewViewModel.mitDone(importantTitles: [], accomplishedTitles: ["写论文"]).isEmpty)
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

        // 未保存的修改（0.16 文件模型：脏标）不被自动加载覆盖
        vm.blocks = [EditableBlock(title: "新草稿", start: day, end: day.addingTimeInterval(3600))]
        vm.draftSource = .arranged
        vm.delete(id: UUID())   // 走编辑入口置脏（不删任何块）
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
    @Test func homeFileModelKeepsEditsUnsavedUntilConfirm() async throws {
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
        #expect(vm.hasUnsavedChanges == false)   // 打开 = 已保存态
        #expect(vm.blocks.count == 2)

        // 0.16 文件模型：编辑 → 未保存修改；真相源**不动**
        vm.delete(id: vm.blocks[0].id)
        #expect(vm.hasUnsavedChanges == true)
        #expect(try store.plannedBlocks(on: day).count == 2)   // 库仍是保存前的 2 项

        // 有未保存修改时，重进页不被已保存态覆盖
        vm.autoLoadOnAppear()
        #expect(vm.blocks.count == 1)

        // 确认写入 = 保存 → 库更新、dirty 清零
        await vm.confirm()
        #expect(vm.hasUnsavedChanges == false)
        #expect(try store.plannedBlocks(on: day).count == 1)
        #expect(try store.plannedBlocks(on: day).first?.title == "健身")

        // 放弃修改 = 回到已保存态
        vm.delete(id: vm.blocks[0].id)
        #expect(vm.hasUnsavedChanges == true)
        vm.discardDraft()
        #expect(vm.hasUnsavedChanges == false)
        #expect(vm.blocks.count == 1)
    }

    private static func makeHomeVM(planStore: PlanStore,
                                   draftStore: DraftSnapshotStore? = nil,
                                   startedDays: StartedDayStore? = nil,
                                   calendar: FakeCalendarStore = FakeCalendarStore()) -> HomeViewModel {
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
            calendarStore: calendar,
            reminderStore: FakeReminderStore(),
            exporter: ICSExporter(),
            planStore: planStore,
            projection: ProjectionService(planStore: planStore, calendarStore: calendar,
                                          startedDays: startedDays),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            notifier: NoNotify(),
            draftStore: draftStore,
            startedDays: startedDays)
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

    // MARK: PlanStore 单一真相源重构（2026-07-07：逻辑日归桶 / 盖章 / 单向投影）

    /// 逻辑日归桶：凌晨 0:30 的「睡前看书」归前一逻辑日——当天读回包含它、次日不含（根治"少几项"）。
    @Test func planStoreBucketsByLogicalDay() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let label = at(2026, 7, 7, 0)   // 逻辑日标签 7/7 = [7/7 4:00, 7/8 4:00)
        try store.replacePlanned([
            ScheduledBlock(title: "写代码", start: at(2026, 7, 7, 21), end: at(2026, 7, 7, 23)),
            ScheduledBlock(title: "睡前看书", start: at(2026, 7, 8, 0, 30), end: at(2026, 7, 8, 1)),
        ], on: label)
        let day = try store.plannedBlocks(on: label)
        #expect(day.count == 2)
        #expect(day.map(\.title).contains("睡前看书"))     // 跨午夜块在当天桶里
        #expect(try store.plannedBlocks(on: at(2026, 7, 8, 0)).isEmpty)   // 次日桶不含它

        // 覆盖写清空当天（含跨午夜块）、不碰别天
        try store.replacePlanned([ScheduledBlock(title: "明天的事", start: at(2026, 7, 8, 9),
                                                 end: at(2026, 7, 8, 10))], on: at(2026, 7, 8, 0))
        try store.replacePlanned([], on: label)
        #expect(try store.plannedBlocks(on: label).isEmpty)
        #expect(try store.plannedBlocks(on: at(2026, 7, 8, 0)).count == 1)
    }

    /// 投影：常规日 → 绿色带章；实时模式（开始今天）→ 绿清空、整日转橙。
    @Test func projectionPaintsGreenThenFadesToOrangeWhenStarted() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let fake = FakeCalendarStore()
        let started = StartedDayStore(persisted: false)
        let projection = ProjectionService(planStore: store, calendarStore: fake, startedDays: started)
        let label = at(2026, 7, 7, 0)
        let block = ScheduledBlock(title: "写代码", start: at(2026, 7, 7, 9), end: at(2026, 7, 7, 11))
        try store.replacePlanned([block], on: label)

        try await projection.project(label: label)
        let green = try await fake.read(kind: .planned)
        #expect(green.count == 1)
        #expect(green.first?.blockID == block.id)          // 盖了章

        started.markStarted(label)
        try await projection.project(label: label)
        #expect(try await fake.read(kind: .planned).isEmpty)          // 绿淡出
        let orange = try await fake.read(kind: .preview)
        #expect(orange.count == 1)                                    // 整日转橙
        #expect(orange.first?.blockID == block.id)                    // 同一章「换幕布」
    }

    /// apply 权威对齐按半开窗口归属：只动窗口内该 kind，邻日/别色不受伤。
    @Test func fakeCalendarApplyRespectsWindowAndKind() async throws {
        let fake = FakeCalendarStore()
        try await fake.write([
            CalendarEventDraft(title: "今天绿", start: at(2026, 7, 7, 9), end: at(2026, 7, 7, 10), kind: .planned),
            CalendarEventDraft(title: "明天绿", start: at(2026, 7, 8, 9), end: at(2026, 7, 8, 10), kind: .planned),
        ])
        try await fake.apply([], kind: .planned, window: DayContext.logicalWindow(forLabel: at(2026, 7, 7, 0)))
        let left = try await fake.read(kind: .planned)
        #expect(left.count == 1)
        #expect(left.first?.title == "明天绿")   // 7/7 窗口清了，7/8 保留
    }

    /// 事件 URL 章：写入/解析往返一致；外部 URL 不误认。
    @Test func eventStampURLRoundTrips() {
        let id = UUID()
        let url = EventKitCalendarStore.stampURL(id)
        #expect(EventKitCalendarStore.blockID(from: url) == id)
        #expect(EventKitCalendarStore.blockID(from: URL(string: "https://example.com/block/\(id.uuidString)")) == nil)
        #expect(EventKitCalendarStore.blockID(from: nil) == nil)
    }

    /// union 合并不丢章：addition 无章时保留 existing 的章。
    @Test func calendarMergeUnionKeepsBlockID() {
        let id = UUID()
        let e = CalendarEventDraft(title: "写代码", start: at(2026, 7, 4, 9), end: at(2026, 7, 4, 10),
                                   kind: .actual, blockID: id)
        let a = CalendarEventDraft(title: "写代码", start: at(2026, 7, 4, 9), end: at(2026, 7, 4, 10, 30),
                                   kind: .actual)
        let merged = CalendarMerge.union(existing: [e], additions: [a], kind: .actual)
        #expect(merged.count == 1)
        #expect(merged.first?.blockID == id)               // 章保住
        #expect(merged.first?.end == at(2026, 7, 4, 10, 30))   // 内容用 addition 的
    }

    /// 切目标日平移草稿：凌晨块（0–4 点）落到新逻辑日的**次日日历日**，归属跟着逻辑日走。
    @Test func homeShiftDraftsKeepsCrossMidnightAttribution() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let vm = Self.makeHomeVM(planStore: PlanStore(context: container.mainContext))
        vm.blocks = [
            EditableBlock(title: "写代码", start: at(2026, 7, 7, 21), end: at(2026, 7, 7, 22)),
            EditableBlock(title: "睡前看书", start: at(2026, 7, 8, 0, 30), end: at(2026, 7, 8, 1)),
        ]
        vm.shiftDraftsToDay(at(2026, 7, 9, 0))
        #expect(vm.blocks[0].start == at(2026, 7, 9, 21))          // 白天块落目标日
        #expect(vm.blocks[1].start == at(2026, 7, 10, 0, 30))      // 凌晨块落目标日次日（同一逻辑日）
        #expect(DayContext.logicalStartOfDay(vm.blocks[1].start) == at(2026, 7, 9, 0))
    }

    /// 完成判定按 ID：同名两块做完一件，另一件不被连坐标完成、仍在「换一件」列表（menu bar 误标完成的根治）。
    @Test func executionSameTitleBlocksDoNotCrossContaminate() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        try planStore.replacePlanned([
            ScheduledBlock(title: "写代码", start: s, end: s.addingTimeInterval(3600)),
            ScheduledBlock(title: "写代码", start: s.addingTimeInterval(7200), end: s.addingTimeInterval(10800)),
        ], on: day)
        let vm = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: FakeReminderStore(),
            liveActivity: NoLiveActivity())
        await vm.loadToday()
        _ = await vm.markDone(titleLike: "写代码")   // 完成其中一件（记录带该块 plannedID）
        #expect(vm.doneCount == 1)                   // 旧标题匹配会把两件都标完成
        #expect(vm.remaining.count == 1)             // 另一件仍在「换一件/同时做」列表
    }

    /// 「开始今天」只出草稿（日历不动、未进实时模式）；「确认写入」才 markStarted + 绿淡出转橙（Jason 定 2026-07-07）。
    /// 放弃修改则取消进入实时模式。
    @Test func startTodayDraftOnlyConfirmEntersRealtime() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let started = StartedDayStore(persisted: false)
        let cal = FakeCalendarStore()
        let vm = Self.makeHomeVM(planStore: store, startedDays: started, calendar: cal)
        let label = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(byAdding: .hour, value: 10, to: label)!
        try store.replacePlanned([ScheduledBlock(title: "写代码", start: s,
                                                 end: s.addingTimeInterval(3600))], on: label)
        vm.targetDay = label

        await vm.startToday()
        #expect(!vm.blocks.isEmpty)               // 出了 reflow 草稿
        #expect(!started.isStarted(label))        // 但还没进实时模式（日历不动）

        // 放弃修改 → 取消开始（绿色保持）
        vm.discardDraft()
        await vm.confirm()
        #expect(!started.isStarted(label))

        // 再来一次：开始今天 → 确认写入 = 正式进实时模式，绿淡出、整日转橙
        await vm.startToday()
        await vm.confirm()
        #expect(started.isStarted(label))
        #expect(try await cal.read(kind: .planned).isEmpty)     // 绿已淡出
        #expect(try await cal.read(kind: .preview).count == 1)  // 整日转橙
    }

    /// 微调防呆：命令没提到 固定/星/计时 时，模型批量翻转这些属性会被恢复原值（端侧全番茄钟抽风的根治）。
    @Test func refineGuardBlocksUnaskedFlagFlips() {
        let a = ScheduledBlock(title: "写代码", start: at(2026,7,8,9), end: at(2026,7,8,11),
                               isFixed: false, timingStyle: .light, priority: .normal)
        let b = ScheduledBlock(title: "健身", start: at(2026,7,8,15), end: at(2026,7,8,16),
                               isFixed: false, timingStyle: .light, priority: .normal)
        // 模型抽风：只让挪时间，却把两块全改成 固定+★+番茄钟
        var ra = a; ra.start = at(2026,7,8,10); ra.end = at(2026,7,8,12)
        ra.isFixed = true; ra.priority = .important; ra.timingStyle = .pomodoro
        var rb = b; rb.isFixed = true; rb.priority = .important; rb.timingStyle = .pomodoro
        let guarded = HomeViewModel.guardRefineFlags(original: [a, b], refined: [ra, rb],
                                                     command: "把写代码挪到10点")
        #expect(guarded.first?.start == at(2026,7,8,10))          // 让改的（时间）保留
        #expect(guarded.allSatisfy { !$0.isFixed })               // 没让改的全部还原
        #expect(guarded.allSatisfy { $0.priority == .normal })
        #expect(guarded.allSatisfy { $0.timingStyle == .light })
        // 明说了「番茄」→ timingStyle 允许改，固定/★ 仍还原
        let allowed = HomeViewModel.guardRefineFlags(original: [a], refined: [ra], command: "写代码改成番茄钟")
        #expect(allowed.first?.timingStyle == .pomodoro)
        #expect(allowed.first?.isFixed == false)
    }

    /// 时间重锚：编辑器把时间改到 0–3:59 → 自动落目标日的次日日历日（同一逻辑日，不窜到列表顶）。
    @Test func anchoredMovesWeeHoursToNextCalendarDay() {
        let label = at(2026, 7, 8, 0)
        #expect(HomeViewModel.anchored(at(2026, 7, 1, 0, 30), toLogicalDayOf: label) == at(2026, 7, 9, 0, 30))
        #expect(HomeViewModel.anchored(at(2026, 7, 1, 21, 0), toLogicalDayOf: label) == at(2026, 7, 8, 21, 0))
        #expect(HomeViewModel.anchored(at(2026, 7, 8, 5, 0), toLogicalDayOf: label) == at(2026, 7, 8, 5, 0))
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
