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
        AppIntentRequest.enqueue(.openToday)
        #expect(AppIntentRequest.consume() == .openToday)
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

    @Test func parserThrowsCleanlyWhenNoKeyAndNoFallback() async throws {
        // 0.26 删 Stub：无 key 且终端兜底=FailedScheduleParser → 干净抛错（HomeViewModel.arrange 转成失败态，不产垃圾）
        let noKey = AnthropicClient(apiKey: { nil }, useCloud: { true })
        let parser = ClaudeScheduleParser(client: noKey, fallback: FailedScheduleParser())
        await #expect(throws: (any Error).self) {
            _ = try await parser.parse("写代码，开会", referenceDate: Date())
        }
    }

    @Test func parsePromptIncludesBusyAndDueContext() async throws {
        let ctx = ParseContext(busy: [BusySlot(title: "牙医", start: at(2026,7,5,10), end: at(2026,7,5,11))],
                               dueReminders: ["交电费"])
        // 云端 prompt 注入：已占用时段/提醒进 system prompt。
        // L1 脱敏（0.28）：busy 只传时段**不传标题**——避开时段不需要云端知道是什么事。
        let prompt = ClaudeScheduleParser.systemPrompt(referenceDate: at(2026,7,5,0), context: ctx)
        #expect(!prompt.contains("牙医"))                 // 标题绝不出云
        #expect(prompt.contains("10:00–11:00（已占用）"))  // 时段仍在（避让能力不丢）
        #expect(prompt.contains("交电费"))                 // 提醒标题保留（本就是要排的候选任务）
        #expect(prompt.contains("已被占用的时段"))
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

    // W31 自测：「加一项」寻空档要避开你自己日历里的课，凌晨加到今天不落进过去
    @Test func plainSlotStartAvoidsUserCalendarAndPast() {
        let day = at(2026,10,20,0)
        let cls = [(start: at(2026,10,20,8), end: at(2026,10,20,9,20))]
        // 未来日：9 点起，但 8:00–9:20 有课 → 9:20
        #expect(HomeViewModel.plainSlotStart(targetDay: day, now: at(2026,10,19,23,44), duration: 3600,
                                             planned: [], busy: cls, windDownHour: 23) == at(2026,10,20,9,20))
        // 凌晨 1 点（逻辑上仍是 19 日）加到今天：从现在起，不回到 19 日 9 点
        let lateNow = at(2026,10,20,1)
        let got = HomeViewModel.plainSlotStart(targetDay: at(2026,10,19,0), now: lateNow, duration: 3600,
                                               planned: [], busy: [], windDownHour: 23)
        #expect(got >= lateNow)
    }

    // W31 自测：大字号下「现在」卡把时间轴挤没——卡最多占页面一半
    @Test func nowCardNeverTakesMoreThanFortyPercentOfThePage() {
        #expect(HomeView.nowCardFrameHeight(natural: 300, page: 800) == 300)
        #expect(HomeView.nowCardFrameHeight(natural: 1200, page: 800) == 320, "W31b：最多四成")
        #expect(HomeView.nowCardFrameHeight(natural: 0, page: 800) == 320, "没量到时先给上限，不塌成 0")
        #expect(HomeView.nowCardFrameHeight(natural: 500, page: 100) == 120, "极矮也留得下一行")
    }

    // MARK: 本地兜底解析抽时长（0.18.23：云端失败时也给可用草稿）

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
        let now = Date()
        let block = ScheduledBlock(title: "x", start: now, end: now.addingTimeInterval(3600))
        // 0.29.0 链语义：ClaudePlanRefiner=云端车道，失败**抛错**（「保持原样」的决定上收到 FM 链，
        // 否则云端失败没机会给端侧 FM 兜底）
        let cloudLane = ClaudePlanRefiner(client: noKey)
        await #expect(throws: (any Error).self) {
            _ = try await cloudLane.refine([block], command: "把x挪到下午", originalRequest: "写一天代码", now: now)
        }
        // 组装链（FM 包装器）：云端失败 → FM 兜底（测试机不可用 → nil）→ 保持原样；空指令 → 原样
        let chain = FoundationModelsPlanRefiner(fallback: cloudLane)
        let onFailure = try await chain.refine([block], command: "把x挪到下午", originalRequest: "写一天代码", now: now)
        #expect(onFailure.count == 1)
        let onEmpty = try await chain.refine([block], command: "  ", originalRequest: "", now: now)
        #expect(onEmpty.count == 1)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

    /// 按日草稿本（0.23 C）：每天一页互不串页；旧单页格式自动迁移；过去页自动清理。
    @Test func draftStoreKeepsPagesPerDayAndMigratesLegacy() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bc-draftday-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = DraftSnapshotStore(directory: tmp)
        let today = DayContext.logicalDay(offset: 0)
        let tomorrow = DayContext.logicalDay(offset: 1)

        store.save(DraftSnapshot(inputText: "今页", targetDay: today, dirty: true), day: today)
        store.save(DraftSnapshot(inputText: "明页", targetDay: tomorrow, dirty: true), day: tomorrow)
        #expect(store.load(day: today)?.inputText == "今页")
        #expect(store.load(day: tomorrow)?.inputText == "明页")     // 互不串页

        // 过去页保存时被清理（草稿只对今天及以后有意义）
        let yesterday = DayContext.logicalDay(offset: -1)
        store.save(DraftSnapshot(inputText: "昨页", targetDay: yesterday, dirty: true), day: yesterday)
        store.save(DraftSnapshot(inputText: "今页2", targetDay: today, dirty: true), day: today)
        #expect(store.load(day: yesterday) == nil)
        #expect(store.load(day: today)?.inputText == "今页2")

        // 旧格式（单份 DraftSnapshot JSON）→ 读时迁移到它的 targetDay 页
        let legacyDir = tmp.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacy = DraftSnapshot(inputText: "旧格式", targetDay: tomorrow, dirty: true)
        try JSONEncoder().encode(legacy).write(to: legacyDir.appendingPathComponent("draft-snapshot.json"))
        let migrated = DraftSnapshotStore(directory: legacyDir)
        #expect(migrated.load(day: tomorrow)?.inputText == "旧格式")
    }

    /// 切目标日=换页（0.23 C）：那天有脏草稿→静默还原那页；干净日→加载已确认计划；切回来草稿还在。
    @Test func switchingTargetDaySwapsDraftPages() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bc-draftswitch-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let store = DraftSnapshotStore(directory: tmp)
        let vm = Self.makeHomeVM(planStore: planStore, draftStore: store)
        let today = DayContext.logicalDay(offset: 0)
        let tomorrow = DayContext.logicalDay(offset: 1)

        // 明天页已确认过一份计划（真相源）
        let t9 = Calendar.current.date(byAdding: .hour, value: 9, to: tomorrow)!
        try planStore.replacePlanned([ScheduledBlock(title: "晨会", start: t9,
                                                     end: t9.addingTimeInterval(1800))], on: tomorrow)

        // 今天页写一份脏草稿
        vm.targetDay = today
        vm.targetDayDidChange()
        vm.inputText = "今天想干的事"
        vm.blocks = [EditableBlock(title: "写代码", start: t9, end: t9.addingTimeInterval(3600))]
        vm.delete(id: UUID())   // 只置未保存标记
        vm.persistDraft()

        // 切到明天：干净页 → 已确认计划；草稿不跟车
        vm.targetDay = tomorrow
        vm.targetDayDidChange()
        #expect(vm.hasUnsavedChanges == false)
        #expect(vm.blocks.first?.title == "晨会")

        // 切回今天：脏草稿页原样还原
        vm.targetDay = today
        vm.targetDayDidChange()
        #expect(vm.hasUnsavedChanges == true)
        #expect(vm.blocks.first?.title == "写代码")
        #expect(vm.inputText == "今天想干的事")
    }

    /// 精修台（0.24 C2「过去只读、未来可编」）：实时日只加载未尘埃落定的块，从现在起铺排。
    @Test func liveDayLoadsOnlyRemainingAsBase() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let started = StartedDayStore(persisted: false)
        // 时钟注入（2026-07-14 根治深夜炸弹）：固定时刻跑，任何真实时间（含凌晨 3 点半）结果一致
        let fixedNow = at(2026, 7, 10, 10, 0)
        let today = DayContext.logicalDay(offset: 0, from: fixedNow)
        let doneBlock = ScheduledBlock(title: "已完成的事", start: today.addingTimeInterval(9 * 3600),
                                       end: today.addingTimeInterval(10 * 3600))
        let futureBlock = ScheduledBlock(title: "还没做的事", start: fixedNow.addingTimeInterval(3600),
                                         end: fixedNow.addingTimeInterval(2 * 3600))
        try planStore.replacePlanned([doneBlock, futureBlock], on: today)
        started.markStarted(today)
        let vm = Self.makeHomeVM(planStore: planStore, startedDays: started,
                                 progress: ProgressStub([doneBlock.id]), now: { fixedNow })
        vm.targetDay = today
        vm.loadConfirmedPlan()
        #expect(vm.isLiveTargetDay)
        #expect(vm.blocks.map(\.title) == ["还没做的事"])   // 已完成不进精修台
        #expect(vm.hasUnsavedChanges == false)
    }

    /// 精修台确认只替换未来：已完成/进行中/已流逝的块原样保留（复盘基线不被中途改写）。
    @Test func liveDayConfirmPreservesSettledAndPast() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let started = StartedDayStore(persisted: false)
        // 时钟注入：同 liveDayLoadsOnlyRemainingAsBase（固定时刻，深夜跑也稳定）
        let fixedNow = at(2026, 7, 10, 10, 0)
        let today = DayContext.logicalDay(offset: 0, from: fixedNow)
        let doneBlock = ScheduledBlock(title: "已完成的事", start: today.addingTimeInterval(9 * 3600),
                                       end: today.addingTimeInterval(9 * 3600 + 1800))
        let editable = ScheduledBlock(title: "待精修的事", start: fixedNow.addingTimeInterval(3600),
                                      end: fixedNow.addingTimeInterval(2 * 3600))
        try planStore.replacePlanned([doneBlock, editable], on: today)
        started.markStarted(today)
        let vm = Self.makeHomeVM(planStore: planStore, startedDays: started,
                                 progress: ProgressStub([doneBlock.id]), now: { fixedNow })
        vm.targetDay = today
        vm.loadConfirmedPlan()
        // 精修：把剩余那件改名 + 挪时间，确认
        vm.blocks = [EditableBlock(title: "精修后的事", start: fixedNow.addingTimeInterval(1800),
                                   end: fixedNow.addingTimeInterval(5400))]
        await vm.confirm()
        let stored = try planStore.plannedBlocks(on: today)
        #expect(stored.count == 2)
        let kept = stored.first { $0.id == doneBlock.id }
        #expect(kept?.title == "已完成的事")                 // 过去只读：原样保留
        #expect(kept?.start == doneBlock.start)
        #expect(stored.contains { $0.title == "精修后的事" })  // 未来可编：草稿覆盖
    }

    /// 新鲜度徽标：编辑中底层变了 → 亮标不打扰；载入最新 → 清标回到干净底；确认 → 清标（最后动作赢）。
    @Test func freshnessBadgeLifecycle() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let started = StartedDayStore(persisted: false)
        // 时钟注入：固定时刻（根治 2026-07-14 03:20 实爆的深夜炸弹——真实时钟下 23:00–04:00
        // 窗口内「未来块」跨出逻辑日 → blocks 空 → 下标越界崩整个 test host、连锁全红）。
        let fixedNow = at(2026, 7, 10, 10, 0)
        let today = DayContext.logicalDay(offset: 0, from: fixedNow)
        let b = ScheduledBlock(title: "一件事", start: fixedNow.addingTimeInterval(3600),
                               end: fixedNow.addingTimeInterval(2 * 3600))
        try planStore.replacePlanned([b], on: today)
        started.markStarted(today)
        let vm = Self.makeHomeVM(planStore: planStore, startedDays: started, progress: ProgressStub(),
                                 now: { fixedNow })
        vm.targetDay = today
        vm.loadConfirmedPlan()
        // 防崩闸保留（防未来同类）：红一个测试可以，绝不允许下标越界崩 host
        try #require(!vm.blocks.isEmpty)
        // 干净时进展变化 → 直接刷新、不亮标
        vm.noteExecutionProgress()
        #expect(vm.freshness == false)
        // 编辑中进展变化 → 亮标（不打扰、不覆盖）
        vm.blocks[0].title = "改了名"
        vm.delete(id: UUID())   // 只置未保存标记
        vm.noteExecutionProgress()
        #expect(vm.freshness == true)
        #expect(vm.blocks[0].title == "改了名")   // 本页没被动
        // 载入最新 → 清标、放弃本页
        vm.reloadFreshBase()
        #expect(vm.freshness == false)
        #expect(vm.hasUnsavedChanges == false)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
            liveActivity: NoLiveActivity(), persistsRunState: false)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

    // #40 批1：检查点（有限一层）+ 三量编辑 + 捞回
    @Test func longTaskCheckpointsAndTriadEditing() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: LongTask.self, configurations: config)
        let store = LongTaskStore(context: container.mainContext)
        let t = store.add(title: "量化学习")
        // 检查点：追加保序、next=第一个未勾、toggle 可反悔
        store.addCheckpoint(to: t, title: "第 1 章")
        store.addCheckpoint(to: t, title: "第 2 章")
        store.addCheckpoint(to: t, title: "第 3 章")
        #expect(t.sortedCheckpoints.map(\.title) == ["第 1 章", "第 2 章", "第 3 章"])
        #expect(t.nextCheckpoint?.title == "第 1 章")
        store.toggleCheckpoint(t.sortedCheckpoints[0])
        #expect(t.nextCheckpoint?.title == "第 2 章")
        // 清单型进度口径：已推进 m/n + 下一个（计数不百分比）
        let progress = store.progressText(for: t)
        #expect(progress.contains("已推进 1/3"))
        #expect(progress.contains("下一个：第 2 章"))
        store.toggleCheckpoint(t.sortedCheckpoints[0])   // 反悔零惩罚
        #expect(t.nextCheckpoint?.title == "第 1 章")
        // 重排 + 删除
        store.reorderCheckpoints(t, ordered: [t.sortedCheckpoints[2], t.sortedCheckpoints[0], t.sortedCheckpoints[1]])
        #expect(t.sortedCheckpoints.first?.title == "第 3 章")
        store.deleteCheckpoint(t.sortedCheckpoints[0])
        #expect(t.sortedCheckpoints.count == 2)
        // 三量编辑：设值与显式清空（double-optional 表单语义）
        store.update(t, deadline: at(2026,8,1,0), cadenceMinutesPerWeek: 300, totalMinutes: 600, unitMinutes: nil)
        #expect(t.deadline == at(2026,8,1,0))
        #expect(t.cadenceMinutesPerWeek == 300)
        store.update(t, deadline: .some(nil), cadenceMinutesPerWeek: .some(nil), totalMinutes: .some(nil), unitMinutes: .some(nil))
        #expect(t.deadline == nil && t.cadenceMinutesPerWeek == nil && t.totalMinutes == nil)
        // 先放下 → 捞回
        store.shelve(t)
        #expect(store.active().isEmpty && store.shelved().count == 1)
        store.unshelve(t)
        #expect(store.active().count == 1 && store.shelved().isEmpty)
        // 做成 → 存档分组
        store.complete(t)
        #expect(store.doneItems().count == 1)
        // D2-C（2026-07-20 Jason 裁）：做成了可逆——拿回在途、doneAt 清掉、投入记录不动
        store.reopen(t)
        #expect(store.active().count == 1 && store.doneItems().isEmpty)
        #expect(t.doneAt == nil)
    }

    // #40 批2：复盘「长线推进」带阶段名（勾了检查点即使没记投入也上榜）
    @Test func longTaskProgressLineIncludesCheckpointAdvance() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: LongTask.self, ExecutionSession.self, configurations: config)
        let store = LongTaskStore(context: container.mainContext)
        let t = store.add(title: "量化学习")
        store.addCheckpoint(to: t, title: "第 1 章")
        // 没有任何投入记录时：无推进=不上榜（不无中生有）
        #expect(store.progressLine(now: .now) == nil)
        // 勾上检查点（doneAt=现在）→ 上榜且带阶段名
        store.toggleCheckpoint(t.sortedCheckpoints[0])
        let line = store.progressLine(now: .now)
        #expect(line?.contains("推进到「第 1 章」") == true)
    }

    // 长期任务「说一句」的改现有链（2026-07-20）：解码层——双 optional 语义 + 幻觉防御
    @Test func longTaskRefinerDecodesCreatesAndUpdates() throws {
        let existing = [LongTaskContext(title: "准备 GRE", deadline: nil,
                                        cadenceMinutesPerWeek: 300, totalMinutes: nil,
                                        checkpoints: ["背单词"])]
        let json = """
        {"creates":[{"title":"学 Rust","deadline":null,"cadenceMinutesPerWeek":120,
          "totalMinutes":null,"unitMinutes":null,"checkpoints":["所有权","并发"]}],
         "updates":[
          {"targetTitle":"准备 GRE","newTitle":null,"deadline":"2026-11-08 09:00",
           "cadenceMinutesPerWeek":"clear","totalMinutes":null,"addCheckpoints":["做填空"," "]},
          {"targetTitle":"根本不存在的任务","newTitle":"哈","deadline":null,
           "cadenceMinutesPerWeek":null,"totalMinutes":null,"addCheckpoints":[]}]}
        """
        let edit = ClaudeLongTaskRefiner.decode(json, existing: existing)
        // 新增照常
        #expect(edit.creates.count == 1)
        #expect(edit.creates[0].checkpoints == ["所有权", "并发"])
        // 幻觉防御：不存在的目标被丢弃 → 只剩一条有效修改
        #expect(edit.updates.count == 1)
        let u = try #require(edit.updates.first)
        #expect(u.targetTitle == "准备 GRE")
        #expect(u.deadline ?? nil != nil)                    // 有值=改截止
        #expect(u.cadenceMinutesPerWeek == .some(nil))       // "clear"=显式清空
        #expect(u.totalMinutes == nil)                       // null=不改
        #expect(u.addCheckpoints == ["做填空"])               // 空白项被剔除
    }

    // 跑分 L1 实锤 bug（2026-07-20）：模型对「11 月 8 号考」给纯日期 "2026-11-08"，
    // 原 DateParsing 解不出 → 整条修改被当空值丢弃 → App 里静默无反应。
    @Test func deadlineAcceptsDateOnlyAndLandsAtDayEnd() throws {
        // 纯日期 → 当天 23:59（DDL 语义：那天结束前，不提前一天判过期）
        let d = try #require(DateParsing.parseDeadline("2026-11-08"))
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        #expect(c.year == 2026 && c.month == 11 && c.day == 8)
        #expect(c.hour == 23 && c.minute == 59)
        // 带时分的照字面来，不改
        let exact = try #require(DateParsing.parseDeadline("2026-11-08 09:30"))
        let c2 = Calendar.current.dateComponents([.hour, .minute], from: exact)
        #expect(c2.hour == 9 && c2.minute == 30)

        // 端到端：L1 那句话的模型输出现在能解出修改（此前 updates 为空）
        let existing = [LongTaskContext(title: "准备 GRE", deadline: nil,
                                        cadenceMinutesPerWeek: 300, totalMinutes: nil)]
        let edit = ClaudeLongTaskRefiner.decode(
            #"{"creates":[],"updates":[{"targetTitle":"准备 GRE","newTitle":null,"deadline":"2026-11-08","cadenceMinutesPerWeek":null,"totalMinutes":null,"addCheckpoints":[]}]}"#,
            existing: existing)
        #expect(edit.updates.count == 1)
        #expect((edit.updates.first?.deadline ?? nil) != nil)
    }

    @Test func longTaskRefinerRejectsEmptyAndGarbage() throws {
        let existing = [LongTaskContext(title: "写论文", deadline: nil, cadenceMinutesPerWeek: nil,
                                        totalMinutes: nil)]
        // 空修改（什么都没改）不进草稿——免得用户点了个寂寞
        let empty = ClaudeLongTaskRefiner.decode(
            #"{"creates":[],"updates":[{"targetTitle":"写论文","newTitle":null,"deadline":null,"cadenceMinutesPerWeek":null,"totalMinutes":null,"addCheckpoints":[]}]}"#,
            existing: existing)
        #expect(empty.isEmpty)
        // 垃圾输入不崩、不产脏数据
        #expect(ClaudeLongTaskRefiner.decode("这不是 JSON", existing: existing).isEmpty)
    }

    // #41③：分步排序的**本地布局层**（纯函数、确定性——LLM 只给标签，排布结果必须可复现）
    @Test func hybridArrangerLayoutRespectsHardRulesThenSemantics() throws {
        let base = at(2026, 7, 20, 9)
        func blk(_ t: String, _ h: Int, important: Bool = false, anchor: Bool = false,
                 ddl: Date? = nil) -> ScheduledBlock {
            ScheduledBlock(title: t, start: at(2026, 7, 20, h), end: at(2026, 7, 20, h + 1),
                           isFixed: false, isAnchor: anchor, timingStyle: .light,
                           priority: important ? .important : .normal, deadline: ddl)
        }
        // 硬规则优先：★ > DDL > 其余 > 锚点垫底——语义标签不得越权
        let blocks = [blk("杂务", 9), blk("要紧事", 14, important: true),
                      blk("午饭", 12, anchor: true), blk("有DDL", 15, ddl: at(2026, 7, 21, 9))]
        let labels = [HybridArranger.Label(index: 0, cognitiveLoad: 3, preferEarly: true, dependsOnIndex: nil)]
        let out = HybridArranger.layOut(blocks, labels: labels)
        #expect(out.map(\.title) == ["要紧事", "有DDL", "杂务", "午饭"])

        // 同档内：语义标签说话——宜趁早的在前
        let same = [blk("轻杂务", 9), blk("深度活", 10)]
        let l2 = [HybridArranger.Label(index: 1, cognitiveLoad: 3, preferEarly: true, dependsOnIndex: nil)]
        #expect(HybridArranger.layOut(same, labels: l2).map(\.title) == ["深度活", "轻杂务"])

        // 依赖修正：做饭依赖买菜 → 买菜必须在前（哪怕原时间在后）
        let dep = [blk("做饭", 17), blk("买菜", 18)]
        let l3 = [HybridArranger.Label(index: 0, cognitiveLoad: 1, preferEarly: false, dependsOnIndex: 1)]
        #expect(HybridArranger.layOut(dep, labels: l3).map(\.title) == ["买菜", "做饭"])

        // 跨档依赖**不得越权**（2026-07-20 跑分实锤修复）：模型说「写周报(★)依赖组会(普通)」，
        // 但 ★ 是用户显式标记、依赖是模型推断——★ 必须仍在最前（代理而不代权）。
        let cross = [blk("写周报", 13, important: true), blk("组会", 10)]
        let l4 = [HybridArranger.Label(index: 0, cognitiveLoad: 2, preferEarly: false, dependsOnIndex: 1)]
        #expect(HybridArranger.layOut(cross, labels: l4).map(\.title) == ["写周报", "组会"])
        _ = base
    }

    // M10-2 池建议在分步排序里必须保住（2026-07-20 切生产前发现的静默倒退风险）
    @Test func hybridArrangerKeepsPoolSuggestions() throws {
        let existing = [ScheduledBlock(title: "写论文", start: at(2026,7,20,9), end: at(2026,7,20,11),
                                       isFixed: false, isAnchor: false, timingStyle: .light,
                                       priority: .normal, deadline: nil)]
        let pool = [LongTaskBrief(title: "量化学习", deadline: nil, cadenceMinutesPerWeek: 300,
                                  nextCheckpoint: "第 3 章"),
                    LongTaskBrief(title: "写论文", deadline: nil, cadenceMinutesPerWeek: nil,
                                  nextCheckpoint: nil)]
        let raw = [HybridArranger.PoolSuggestion(poolIndex: 0, start: at(2026,7,20,14), end: at(2026,7,20,15)),
                   HybridArranger.PoolSuggestion(poolIndex: 1, start: at(2026,7,20,16), end: at(2026,7,20,17)),
                   HybridArranger.PoolSuggestion(poolIndex: 9, start: at(2026,7,20,18), end: at(2026,7,20,19))]
        let out = HybridArranger.suggestionBlocks(raw, pool: pool, existing: existing)
        // 只留第一条：第二条与今日已有「写论文」同名（不重复建议）、第三条索引越界
        #expect(out.count == 1)
        #expect(out[0].title == "量化学习 · 第 3 章")   // 有下一阶段则块名带上
    }

    // #41②：脱敏排序的索引解码（补齐遗漏/去重/越界丢弃——LLM 抽风也不丢块）
    @Test func maskedArrangerDecodeOrderIsTotalAndSafe() throws {
        // 越界 9 丢弃、重复 1 去重、遗漏 3 自动补齐在末尾
        let order = try MaskedArranger.decodeOrder(#"{"orderedIndexes":[2,1,9,1,0]}"#, count: 4)
        #expect(order == [2, 1, 0, 3])
        #expect(Set(order) == Set(0..<4))   // 全覆盖=一块都不丢
        // 空/垃圾输入 → 退化成原顺序（不崩、不丢块）
        #expect(try MaskedArranger.decodeOrder(#"{"orderedIndexes":[]}"#, count: 3) == [0, 1, 2])
    }

    // #40 批3：解析器产阶段（JSON 解码 + 脏数据防御）
    @Test func parserDecodesLongTaskCheckpoints() throws {
        let json = """
        {"loose":false,"blocks":[],"longTasks":[
          {"title":"准备 GRE","deadline":"2026-10-08 09:00","cadenceMinutesPerWeek":300,
           "totalMinutes":null,"unitMinutes":null,"checkpoints":["背单词"," 做填空 ","","练写作"]},
          {"title":"读测度论","deadline":null,"cadenceMinutesPerWeek":180,
           "totalMinutes":null,"unitMinutes":null,"checkpoints":[]}]}
        """
        let d = try #require(ClaudeScheduleParser.decodePlan(json))
        #expect(d.longTasks.count == 2)
        // 去空、去首尾空白、保序
        #expect(d.longTasks[0].checkpoints == ["背单词", "做填空", "练写作"])
        #expect(d.longTasks[0].cadenceMinutesPerWeek == 300)
        // 没提阶段 → 空（不自创）
        #expect(d.longTasks[1].checkpoints.isEmpty)
    }

    @Test func parserIgnoresMalformedCheckpoints() throws {
        // 模型抽风给了对象数组 → 整体忽略（宁缺勿脏），不崩、不产垃圾阶段
        let json = """
        {"loose":false,"blocks":[],"longTasks":[
          {"title":"写论文","deadline":null,"cadenceMinutesPerWeek":null,
           "totalMinutes":null,"unitMinutes":null,"checkpoints":[{"name":"第一章"},123]}]}
        """
        let d = try #require(ClaudeScheduleParser.decodePlan(json))
        #expect(d.longTasks.count == 1)
        #expect(d.longTasks[0].checkpoints.isEmpty)
    }

    @Test func longTaskProgressUnitsAndFraction() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
            liveActivity: NoLiveActivity(), persistsRunState: false)
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

    /// 蓝对账 A2：完成的实际落 PlanStore 真相源；换一个「日历全空」的新 VM 仍能从真相源读回 done。
    /// 证明蓝色实际真相已从日历迁到 PlanStore（这是后续「删日历事件也 stick」的前置：真相不再只在日历）。
    @Test func actualPersistsToPlanStoreTruthAndReloadsWithoutCalendar() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let coding = ScheduledBlock(title: "写代码", start: s, end: s.addingTimeInterval(3600))
        try planStore.replacePlanned([coding], on: day)

        let vm1 = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: FakeReminderStore(),
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm1.loadToday()
        _ = await vm1.markDone(titleLike: "写代码")
        await vm1.waitForPreview()
        #expect(vm1.doneCount == 1)
        // 真相源里应有这条实际（id = 计划块 id，同 UUID 换幕布）
        #expect(try planStore.actualBlocks(on: day).contains { $0.id == coding.id })

        // 换一个「全新空日历」的 VM：done 仍能从 PlanStore 真相读回（不靠日历）
        let vm2 = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: FakeReminderStore(),
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm2.loadToday()
        #expect(vm2.doneCount == 1)
    }

    /// 蓝对账 Stage B：自动完成（这里走提醒打勾）→ 用户在 Apple 日历删掉蓝块 → 手动对账 →
    /// 真相源移除+盖 tombstone → 再 loadToday **不再重建**（删了 stick，根治 §3；即使提醒仍打着勾也不复活）。
    @Test func reconcileDeletionTombstonesAndStaysDeleted() async throws {
        final class StubReminders: ReminderStore {
            let completed: Set<UUID>
            init(_ c: Set<UUID>) { completed = c }
            func write(_ drafts: [ReminderDraft]) async throws {}
            func completedBlockIDs() async -> Set<UUID> { completed }
        }
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let task = ScheduledBlock(title: "写报告", start: s, end: s.addingTimeInterval(3600), priority: .important)
        try planStore.replacePlanned([task], on: day)
        let cal = FakeCalendarStore()
        let vm = ExecutionViewModel(
            calendarStore: cal,
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: StubReminders([task.id]),
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm.loadToday()
        #expect(vm.doneCount == 1)                                        // 提醒打勾 → 自动完成、落真相源
        #expect(try planStore.actualBlocks(on: day).contains { $0.id == task.id })

        try await cal.clear(kind: .actual)                               // 用户在 Apple 日历删掉蓝块
        await vm.reconcileCalendarActuals()                             // 手动对账
        #expect(try planStore.actualBlocks(on: day).isEmpty)            // 真相源已同步移除
        #expect(vm.doneCount == 0)                                      // 对账后立即反映

        await vm.loadToday()
        #expect(vm.doneCount == 0)                                      // 删了 stick：即使提醒仍打勾也不重建
    }

    /// 蓝对账 B：在 Apple 日历里改了带章蓝块的时间/标题 → 手动对账 → 真相源回填新时间/标题。
    @Test func reconcileBackfillsEditedActualTimeAndTitle() async throws {
        final class StubReminders: ReminderStore {
            let completed: Set<UUID>
            init(_ c: Set<UUID>) { completed = c }
            func write(_ drafts: [ReminderDraft]) async throws {}
            func completedBlockIDs() async -> Set<UUID> { completed }
        }
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let task = ScheduledBlock(title: "写报告", start: s, end: s.addingTimeInterval(3600), priority: .important)
        try planStore.replacePlanned([task], on: day)
        let cal = FakeCalendarStore()
        let vm = ExecutionViewModel(
            calendarStore: cal,
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: StubReminders([task.id]),
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm.loadToday()
        #expect(try planStore.actualBlocks(on: day).first { $0.id == task.id }?.start == s)

        // 用户在 Apple 日历里把这件实际改到 10:00 起、并改了标题
        let newStart = s.addingTimeInterval(3600)
        try await cal.write([CalendarEventDraft(title: "写报告(改)", start: newStart,
                                                end: newStart.addingTimeInterval(5400), kind: .actual, blockID: task.id)])
        await vm.reconcileCalendarActuals()
        let a = try planStore.actualBlocks(on: day).first { $0.id == task.id }
        #expect(a?.start == newStart)              // 时间回填
        #expect(a?.title == "写报告(改)")           // 标题回填
    }

    // MARK: 日记照片跨端（JournalPhoto：DB 真相源 + 本地缓存 + 旧文件迁移）

    @Test func photoStoreRoundTripsViaDBAndMigratesLocalFiles() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bc-photo-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: JournalPhoto.self, configurations: config)

        // 旧文件不在 init 时自动迁入：需显式导入，避免复活云端已删除的缓存照片。
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let legacy = "legacy.jpg"
        try Data([0xFF, 0xD8, 0xFF]).write(to: tmp.appendingPathComponent(legacy))

        let store = PhotoStore(context: container.mainContext, directory: tmp)
        #expect(try container.mainContext.fetch(FetchDescriptor<JournalPhoto>()).isEmpty)
        store.importLegacyFiles()
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
            ParsedLongTask(title: "期末论文", deadline: ddl, totalMinutes: 120),  // 有 DDL+估算 → 出提醒
            ParsedLongTask(title: "学 Swift"),                          // 无 DDL → 不出
            ParsedLongTask(title: "读论文", deadline: at(2026,7,8,20)),  // 有 DDL 但已排成今天块 → 去重跳过
        ]
        let drafts = HomeViewModel.poolReminderDrafts(pending: pending,
                                                      blockTitles: ["读论文"], leadMinutes: 30)
        #expect(drafts.count == 1)
        #expect(drafts.first?.title == "期末论文")
        #expect(drafts.first?.due == ddl)
        #expect(drafts.first?.priority == 5)          // 中优先级，同带 DDL 块口径
        #expect(drafts.first?.leadMinutes == 150)     // p−m−N：估算 120 + 提前 30 → 响在「最迟该开始」而非刚好截止
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

    @MainActor final class ProgressStub: ExecutionProgressReading {
        var settledPlannedIDs: Set<UUID> = []
        init(_ ids: Set<UUID> = []) { settledPlannedIDs = ids }
    }

    private static func makeHomeVM(planStore: PlanStore,
                                   draftStore: DraftSnapshotStore? = nil,
                                   startedDays: StartedDayStore? = nil,
                                   calendar: FakeCalendarStore = FakeCalendarStore(),
                                   progress: ExecutionProgressReading? = nil,
                                   now: @escaping () -> Date = { .now }) -> HomeViewModel {
        struct NoRefine: PlanRefining {
            func refine(_ blocks: [ScheduledBlock], command: String,
                        originalRequest: String, now: Date) async throws -> [ScheduledBlock] { blocks }
        }
        struct NoNotify: NotificationScheduling {
            func requestAuthorizationIfNeeded() async {}
            func scheduleDailyReminders(morning: Date?, evening: Date?, summary: String) async {}
        }
        return HomeViewModel(
            arrangeDay: ArrangeDayUseCase(parser: FailedScheduleParser(), planner: NaivePlanningEngine()),
            refiner: NoRefine(),
            calendarStore: calendar,
            reminderStore: FakeReminderStore(),
            exporter: ICSExporter(),
            planStore: planStore,
            projection: ProjectionService(planStore: planStore, calendarStore: calendar),
            notifier: NoNotify(),
            draftStore: draftStore,
            startedDays: startedDays,
            progress: progress,
            now: now)
    }

    // MARK: 收工线 / 候补（0.23 B：溢出冲突弹窗退役，语义=候补）

    /// 生效收工线：线前开工用收工线；**过线仍开工=用户自选的加班** → 退回逻辑日尾 4 点（原则7 不夺权）。
    @Test func effectiveWindDownFallsBackAfterLine() {
        WorkHoursSettings.windDownHour = 23
        let before = at(2026,6,30,20)
        #expect(WorkHoursSettings.effectiveWindDown(from: before) == at(2026,6,30,23))
        let overtime = at(2026,6,30,23,30)   // 已过线
        #expect(WorkHoursSettings.effectiveWindDown(from: overtime) == at(2026,7,1,4))   // 逻辑日尾
        let smallHours = at(2026,7,1,0,30)   // 凌晨加班（逻辑 6/30）
        #expect(WorkHoursSettings.effectiveWindDown(from: smallHours) == at(2026,7,1,4))
    }

    /// 引擎级候补：本地 reflow 放不进收工线的块进 deferred（不再铺到深夜、不再产冲突弹窗）。
    @Test func naiveReflowDefersOverflowToStandby() async throws {
        WorkHoursSettings.windDownHour = 23
        let from = at(2026,6,30,21)
        let vip = ScheduledBlock(title: "要紧收尾", start: at(2026,6,30,21), end: at(2026,6,30,23),
                                 priority: .important)
        let chores = ScheduledBlock(title: "整理桌面", start: at(2026,6,30,21,30), end: at(2026,6,30,23,0))
        let decision = try await NaivePlanningEngine().reflow([vip, chores], from: from, now: from)
        #expect(decision.orderedBlocks.map(\.title) == ["要紧收尾"])   // ★ 照排
        #expect(decision.deferred.map(\.title) == ["整理桌面"])        // 放不下 → 候补
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

    /// 投影：绿色带章；P4 Q1/Q2：开工后**不再清空绿色、也不写橙色**（1b 实时态与橙色预览日历退役）。
    @Test func projectionKeepsGreenAfterStartAndNeverWritesOrange() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let fake = FakeCalendarStore()
        let started = StartedDayStore(persisted: false)
        let projection = ProjectionService(planStore: store, calendarStore: fake)
        let label = at(2026, 7, 7, 0)
        let block = ScheduledBlock(title: "写代码", start: at(2026, 7, 7, 9), end: at(2026, 7, 7, 11))
        try store.replacePlanned([block], on: label)

        try await projection.project(label: label)
        let green = try await fake.read(kind: .planned)
        #expect(green.count == 1)
        #expect(green.first?.blockID == block.id)          // 盖了章

        started.markStarted(label)
        try await projection.project(label: label)
        #expect(try await fake.read(kind: .planned).map(\.blockID) == [block.id])   // 开工后绿色照在
        #expect(try await fake.read(kind: .preview).isEmpty)                        // 不再写橙色
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

    /// 显式挪日（0.23 C，取代自动平移）：凌晨块（0–4 点）落到新逻辑日的**次日日历日**，归属跟着逻辑日走。
    @Test func homeMoveDraftKeepsCrossMidnightAttribution() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let vm = Self.makeHomeVM(planStore: PlanStore(context: container.mainContext))
        vm.blocks = [
            EditableBlock(title: "写代码", start: at(2026, 7, 7, 21), end: at(2026, 7, 7, 22)),
            EditableBlock(title: "睡前看书", start: at(2026, 7, 8, 0, 30), end: at(2026, 7, 8, 1)),
        ]
        vm.moveDraft(to: at(2026, 7, 9, 0))
        #expect(Calendar.current.startOfDay(for: vm.targetDay) == at(2026, 7, 9, 0))   // 挪日=切到那页
        #expect(vm.blocks[0].start == at(2026, 7, 9, 21))          // 白天块落目标日
        #expect(vm.blocks[1].start == at(2026, 7, 10, 0, 30))      // 凌晨块落目标日次日（同一逻辑日）
        #expect(DayContext.logicalStartOfDay(vm.blocks[1].start) == at(2026, 7, 9, 0))
    }

    /// 完成判定按 ID：同名两块做完一件，另一件不被连坐标完成、仍在「换一件」列表（menu bar 误标完成的根治）。
    @Test func executionSameTitleBlocksDoNotCrossContaminate() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm.loadToday()
        _ = await vm.markDone(titleLike: "写代码")   // 完成其中一件（记录带该块 plannedID）
        #expect(vm.doneCount == 1)                   // 旧标题匹配会把两件都标完成
        #expect(vm.remaining.count == 1)             // 另一件仍在「换一件/同时做」列表
    }

    /// 提醒 ID 盖章根治（0.25.4）：被动完成只认 blockID 精确匹配——同名两块，只有"被打勾的那个 id"标完成，
    /// 另一个同名块不被连坐（旧 bug：往日打勾的同名旧提醒会误标今天的同名任务）。
    @Test func passiveCompletionMatchesByBlockIDNotTitle() async throws {
        final class StubReminders: ReminderStore {
            let completed: Set<UUID>
            init(_ c: Set<UUID>) { completed = c }
            func write(_ drafts: [ReminderDraft]) async throws {}
            func completedBlockIDs() async -> Set<UUID> { completed }
        }
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let a = ScheduledBlock(title: "开发", start: s, end: s.addingTimeInterval(3600), priority: .important)
        let b = ScheduledBlock(title: "开发", start: s.addingTimeInterval(7200), end: s.addingTimeInterval(10800), priority: .important)
        try planStore.replacePlanned([a, b], on: day)
        let vm = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: StubReminders([a.id]),   // 只勾了 a
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm.loadToday()
        await vm.waitForPreview()
        #expect(vm.doneCount == 1)                                      // 只有 a 完成，同名 b 不连坐
        #expect(vm.remaining.contains { $0.id == b.id })               // b 仍在待做
    }

    /// 计划外「+ 新事项…」（0.25，点子 #1）：临时事项直接开始 = bonus——不进 planned、
    /// 完成即记蓝色实际、复盘里无匹配计划（extra）；同时做的进后台。
    @Test func adHocBonusStartsWithoutTouchingPlan() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        try planStore.replacePlanned([ScheduledBlock(title: "写代码", start: s, end: s.addingTimeInterval(3600))], on: day)
        let vm = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: FakeReminderStore(),
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm.loadToday()
        #expect(vm.planned.count == 1)

        // 前台开始一件计划外的事（每次动作后 await 预览 Task 落地——游离 Task 会崩宿主）
        await vm.startAdHoc(title: "突然要回封邮件", timingStyle: .light)
        await vm.waitForPreview()
        #expect(vm.active?.title == "突然要回封邮件")
        #expect(vm.planned.count == 1)                                   // 没写进计划
        #expect(try planStore.plannedBlocks(on: day).count == 1)         // 真相源没多块
        await vm.completeCurrent()
        await vm.waitForPreview()
        #expect(vm.done.contains { $0.title == "突然要回封邮件" })         // 完成记蓝色实际（bonus）

        // 同时做一件计划外的事 → 进后台
        vm.startAlsoAdHoc(title: "顺手洗个衣服")
        await vm.waitForPreview()
        #expect(vm.background.contains { $0.title == "顺手洗个衣服" })
        #expect(try planStore.plannedBlocks(on: day).count == 1)         // 仍不写计划
    }

    /// 实时模式合并（0.23 A）：某逻辑日**第一次真正开始一件事**即进实时模式（markStarted，同日幂等）。
    /// P4 Q1/Q2：开工不再清空绿色、不写橙色；做完后这件只剩蓝色（绿色让位）——一件事只画一次。
    @Test func firstStartOfDayMarksStartedKeepsGreenAndDoneLeavesOnlyBlue() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let started = StartedDayStore(persisted: false)
        let cal = FakeCalendarStore()
        let projection = ProjectionService(planStore: store, calendarStore: cal)
        let label = DayContext.logicalDay(offset: 0)
        let s = Calendar.current.date(byAdding: .hour, value: 10, to: label)!
        try store.replacePlanned([ScheduledBlock(title: "写代码", start: s,
                                                 end: s.addingTimeInterval(3600))], on: label)
        try await projection.project(label: label)
        #expect(try await cal.read(kind: .planned).count == 1)   // 未开始：绿在

        let vm = ExecutionViewModel(calendarStore: cal,
                                    reschedule: RescheduleService(planStore: store,
                                                                  planner: NaivePlanningEngine()),
                                    planStore: store, reminderStore: FakeReminderStore(),
                                    liveActivity: NoLiveActivity(), persistsRunState: false,
                                    startedDays: started, projection: projection)
        await vm.loadToday()
        #expect(!started.isStarted(label))

        // 第一次开始 → 进实时模式：标记；绿色照在、没有橙色
        guard let first = vm.planned.first else { Issue.record("没有今日计划块"); return }
        await vm.startBlock(first)
        await vm.waitForPreview()
        #expect(started.isStarted(label))
        #expect(try await cal.read(kind: .planned).count == 1)   // 绿照在
        #expect(try await cal.read(kind: .preview).isEmpty)      // 橙色预览已退役

        // 完成 → 只剩蓝色（绿色让位）；幂等：不重复标记、不出错
        await vm.completeCurrent()
        await vm.waitForPreview()
        #expect(started.isStarted(label))
        #expect(try await cal.read(kind: .planned).isEmpty, "做完的只画蓝")
        #expect(try await cal.read(kind: .actual).map(\.blockID) == [first.id])
    }

    /// 微调防呆之二（0.23.1 #9）：模型只返回改动块 → 并回原清单（没回=未改；id 继承；新增保留）。
    @Test func mergePartialRefineRestoresOmittedBlocks() {
        let a = ScheduledBlock(title: "写作", start: at(2026,7,9,9), end: at(2026,7,9,11))
        let b = ScheduledBlock(title: "会议", start: at(2026,7,9,11,30), end: at(2026,7,9,12,30), isFixed: true)
        let c = ScheduledBlock(title: "阅读", start: at(2026,7,9,14), end: at(2026,7,9,15))
        // 模型抽风：让挪阅读，却只回了阅读一块（R1 实锤形态）
        let onlyRead = ScheduledBlock(title: "阅读", start: at(2026,7,9,16), end: at(2026,7,9,17))
        let merged = RefineGuards.mergePartialRefine(original: [a, b, c], refined: [onlyRead],
                                                      command: "把阅读挪到16点")
        #expect(merged.count == 3)
        #expect(merged.first { $0.title == "阅读" }?.start == at(2026,7,9,16))   // 改动生效
        #expect(merged.first { $0.title == "阅读" }?.id == c.id)                 // 身份保持
        #expect(merged.first { $0.title == "写作" }?.start == a.start)           // 没回=未改
        #expect(merged.first { $0.title == "会议" }?.start == b.start)

        // 模型新增块保留（"加一件"场景）
        let added = ScheduledBlock(title: "散步", start: at(2026,7,9,18), end: at(2026,7,9,18,30))
        let withNew = RefineGuards.mergePartialRefine(original: [a], refined: [a, added], command: "加个散步")
        #expect(withNew.count == 2)
    }

    /// 命令含删除词 → 信任模型的省略（删除功能不被"恢复"破坏）。
    @Test func mergePartialRefineRespectsDeleteIntent() {
        let a = ScheduledBlock(title: "写作", start: at(2026,7,9,9), end: at(2026,7,9,11))
        let c = ScheduledBlock(title: "阅读", start: at(2026,7,9,14), end: at(2026,7,9,15))
        let merged = RefineGuards.mergePartialRefine(original: [a, c], refined: [a], command: "删掉阅读")
        #expect(merged.count == 1)
        #expect(merged.first?.title == "写作")
    }

    /// 微调防呆之三（0.23.1 #9）：命令没点名的固定块，起止时间也还原（R3 实锤：整体挪一小时把会议也挪了）。
    @Test func guardRestoresFixedBlockTimeWhenUnmentioned() {
        let meeting = ScheduledBlock(title: "会议", start: at(2026,7,9,11,30), end: at(2026,7,9,12,30), isFixed: true)
        var moved = meeting; moved.start = at(2026,7,9,12,30); moved.end = at(2026,7,9,13,30)
        // 没点名 → 时间还原
        let guarded = RefineGuards.guardRefineFlags(original: [meeting], refined: [moved],
                                                     command: "整体往后挪一小时")
        #expect(guarded.first?.start == at(2026,7,9,11,30))
        // 点名了 → 尊重用户（模型改动保留）
        let named = RefineGuards.guardRefineFlags(original: [meeting], refined: [moved],
                                                   command: "把会议挪到12点半")
        #expect(named.first?.start == at(2026,7,9,12,30))
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
        let guarded = RefineGuards.guardRefineFlags(original: [a, b], refined: [ra, rb],
                                                     command: "把写代码挪到10点")
        #expect(guarded.first?.start == at(2026,7,8,10))          // 让改的（时间）保留
        #expect(guarded.allSatisfy { !$0.isFixed })               // 没让改的全部还原
        #expect(guarded.allSatisfy { $0.priority == .normal })
        #expect(guarded.allSatisfy { $0.timingStyle == .light })
        // 明说了「番茄」→ timingStyle 允许改，固定/★ 仍还原
        let allowed = RefineGuards.guardRefineFlags(original: [a], refined: [ra], command: "写代码改成番茄钟")
        #expect(allowed.first?.timingStyle == .pomodoro)
        #expect(allowed.first?.isFixed == false)
    }

    /// 微调防呆（bug 修复 2026-07-09）：模型重吐块漏了 isAnchor → 还原（午饭/晚饭绝不被悄悄变成"能干的事项"）。
    @Test func refineGuardPreservesAnchor() {
        let lunch = ScheduledBlock(title: "午饭", start: at(2026,7,8,12), end: at(2026,7,8,13),
                                   isAnchor: true, timingStyle: .light, priority: .normal)
        var rLunch = lunch; rLunch.isAnchor = false     // 模型抽风：把午饭的锚点标志丢了
        let guarded = RefineGuards.guardRefineFlags(original: [lunch], refined: [rLunch],
                                                     command: "把健身挪到下午")   // 命令根本没提午饭
        #expect(guarded.first?.isAnchor == true)         // 还原：午饭仍是锚点、不进执行列表
        // 模型新加的午饭（原来没有）→ 标题兜底也锚
        let newDinner = ScheduledBlock(title: "晚饭", start: at(2026,7,8,18), end: at(2026,7,8,19), isAnchor: false)
        let guarded2 = RefineGuards.guardRefineFlags(original: [], refined: [newDinner], command: "加个晚饭")
        #expect(guarded2.first?.isAnchor == true)
    }

    /// 计时显示格式（2026-07-09 敲定）：到分、XhYm、无秒（去滴答）。
    @Test func timerHmFormatsMinuteGranularityNoSeconds() {
        #expect(ExecutionViewModel.hm(0) == "0m")
        #expect(ExecutionViewModel.hm(59) == "0m")          // <1 分 → 0m（到分、不显秒）
        #expect(ExecutionViewModel.hm(60) == "1m")
        #expect(ExecutionViewModel.hm(45 * 60) == "45m")
        #expect(ExecutionViewModel.hm(60 * 60) == "1h")     // 整点不显 0m
        #expect(ExecutionViewModel.hm(75 * 60) == "1h15m")
        #expect(ExecutionViewModel.hm(120 * 60) == "2h")
    }

    /// 时间重锚：编辑器把时间改到 0–3:59 → 自动落目标日的次日日历日（同一逻辑日，不窜到列表顶）。
    @Test func anchoredMovesWeeHoursToNextCalendarDay() {
        let label = at(2026, 7, 8, 0)
        #expect(HomeViewModel.anchored(at(2026, 7, 1, 0, 30), toLogicalDayOf: label) == at(2026, 7, 9, 0, 30))
        #expect(HomeViewModel.anchored(at(2026, 7, 1, 21, 0), toLogicalDayOf: label) == at(2026, 7, 8, 21, 0))
        #expect(HomeViewModel.anchored(at(2026, 7, 8, 5, 0), toLogicalDayOf: label) == at(2026, 7, 8, 5, 0))
    }

    // MARK: 0.20 双向同步（ReconcileService.diff 纯函数）

    /// 对账 diff：手改回流 / 自写跳过 / 删除识别 / 缺投影补画 各走各路。
    @Test func reconcileDiffSeparatesUserEditsFromSelfWrites() {
        let idA = UUID(), idB = UUID(), idC = UUID(), idD = UUID()
        let truth = [
            ScheduledBlock(id: idA, title: "写代码", start: at(2026,7,9,9), end: at(2026,7,9,11)),
            ScheduledBlock(id: idB, title: "健身", start: at(2026,7,9,15), end: at(2026,7,9,16)),
            ScheduledBlock(id: idC, title: "读书", start: at(2026,7,9,21), end: at(2026,7,9,22)),
            ScheduledBlock(id: idD, title: "新块没投影过", start: at(2026,7,9,19), end: at(2026,7,9,20)),
        ]
        func tup(_ b: ScheduledBlock) -> String {
            ProjectionFingerprints.tuple(start: b.start, end: b.end, title: b.title)
        }
        // 指纹 = 上次投影写下的样子（A/B/C 都投影过；D 没有）
        let fp = [idA.uuidString: tup(truth[0]), idB.uuidString: tup(truth[1]), idC.uuidString: tup(truth[2])]
        // 日历现状：A 被用户挪到 10 点（≠指纹=手改）；B 原样（=指纹）；C 消失（被删）；D 本来就没有
        let events = [
            CalendarEventDraft(title: "写代码", start: at(2026,7,9,10), end: at(2026,7,9,12),
                               kind: .planned, blockID: idA),
            CalendarEventDraft(title: "健身", start: at(2026,7,9,15), end: at(2026,7,9,16),
                               kind: .planned, blockID: idB),
        ]
        let plan = ReconcileService.diff(truth: truth, events: events, fingerprint: fp)
        #expect(plan.updates == [ReconcileService.Update(id: idA, start: at(2026,7,9,10),
                                                         end: at(2026,7,9,12), title: "写代码")])
        #expect(plan.deletions == [ReconcileService.Deletion(id: idC, title: "读书")])   // 只有 C 是删除
        #expect(plan.needsRepaint)   // D 缺投影 → 补画，而不是当删除
        #expect(plan.foreign.isEmpty)

        // 日历里你新建的无章事件 → foreign（P4 Q4：你的事件，只读，不复制不删），不再直接当垃圾清掉
        let withNew = events + [CalendarEventDraft(title: "临时冒出来的事", start: at(2026,7,9,18),
                                                   end: at(2026,7,9,19), kind: .planned)]
        let plan2 = ReconcileService.diff(truth: truth, events: withNew, fingerprint: fp)
        #expect(plan2.foreign.count == 1)
        #expect(plan2.foreign.first?.title == "临时冒出来的事")
    }

    /// 复盘对比按 ID 精确配对：同名两块只有被执行的那块算 done，另一块如实 missed（不再连坐）。
    @Test func comparerMatchesByBlockIDFirst() {
        let idA = UUID(), idB = UUID()
        let planned = [
            CalendarEventDraft(title: "写代码", start: at(2026,7,9,9), end: at(2026,7,9,10),
                               kind: .planned, blockID: idA),
            CalendarEventDraft(title: "写代码", start: at(2026,7,9,14), end: at(2026,7,9,15),
                               kind: .planned, blockID: idB),
        ]
        // 只做了下午那段（实际块带 B 的章）；旧启发式会把它配给上午那块（先到先得）
        let actual = [CalendarEventDraft(title: "写代码", start: at(2026,7,9,14), end: at(2026,7,9,15),
                                         kind: .actual, blockID: idB)]
        let c = OverlapTitleComparer().compare(planned: planned, actual: actual)
        let morning = c.items.first { $0.anchor == at(2026,7,9,9) }
        let afternoon = c.items.first { $0.anchor == at(2026,7,9,14) }
        #expect(morning?.status == .missed)
        #expect(afternoon?.status == .done)
    }

    /// 重做=延长完成时间（Jason 定 2026-07-08）：同一块的多段实际聚合成一条，不显示"又完成一件"。
    @Test func comparerAggregatesRedoSegmentsIntoOneItem() {
        let id = UUID()
        let planned = [CalendarEventDraft(title: "写代码", start: at(2026,7,9,9), end: at(2026,7,9,10),
                                          kind: .planned, blockID: id)]
        // 做了 30 分钟 → 切走 → 傍晚重做 35 分钟：两段实际、同一个章
        let actual = [
            CalendarEventDraft(title: "写代码", start: at(2026,7,9,9), end: at(2026,7,9,9,30),
                               kind: .actual, blockID: id),
            CalendarEventDraft(title: "写代码", start: at(2026,7,9,18), end: at(2026,7,9,18,35),
                               kind: .actual, blockID: id),
        ]
        let c = OverlapTitleComparer().compare(planned: planned, actual: actual)
        #expect(c.items.count == 1)                      // 聚合成一条，不出现 extra/bonus
        #expect(c.items.first?.status == .done)          // 30+35=65 分钟 / 计划 60 → done
        #expect(c.items.first?.actualMinutes == 65)      // 完成时间=各段之和
    }

    /// 投影失败后的旧日历不倒灌：日历与指纹一致（没人手改）而真相更新了 → 重画，不回流。
    @Test func reconcileDiffRepaintsWhenCalendarUntouched() {
        let id = UUID()
        let old = ScheduledBlock(id: id, title: "写代码", start: at(2026,7,9,9), end: at(2026,7,9,10))
        var updated = old; updated.start = at(2026,7,9,14); updated.end = at(2026,7,9,15)
        let fp = [id.uuidString: ProjectionFingerprints.tuple(start: old.start, end: old.end, title: old.title)]
        let events = [CalendarEventDraft(title: old.title, start: old.start, end: old.end,
                                         kind: .planned, blockID: id)]
        let plan = ReconcileService.diff(truth: [updated], events: events, fingerprint: fp)
        #expect(plan.updates.isEmpty)      // 绝不把旧日历倒灌回真相
        #expect(plan.deletions.isEmpty)
        #expect(plan.needsRepaint)         // 真相赢 → 重画
    }

    // MARK: 0.20.1 云端流式（部分 JSON 抽完整块）

    /// 部分 JSON 抽块：只取完整闭合的对象；标题里的引号/花括号不骗过扫描；截半的对象不取。
    @Test func streamingPartialJSONExtractsOnlyCompleteBlocks() {
        // 生成中途：第 1 块完整（标题含转义引号和花括号）、第 2 块被截半
        let partial = #"{"blocks":[{"title":"写\"接口{v2}\"文档","start":"2026-07-09 09:00","end":"2026-07-09 10:00"},{"title":"健身","start":"2026-07-0"#
        let objs = JSONText.completeArrayObjects(in: partial)
        #expect(objs.count == 1)
        let live = ClaudeScheduleParser.liveBlocks(fromPartial: partial)
        #expect(live.count == 1)
        #expect(live.first?.title == #"写"接口{v2}"文档"#)
        // 数组闭合后继续出现别的字段 → 不再误取
        let done = #"{"blocks":[{"title":"A","start":"2026-07-09 09:00","end":"2026-07-09 10:00"}],"longTasks":[{"title":"X"}]}"#
        #expect(JSONText.completeArrayObjects(in: done).count == 1)
        // 还没出现 blocks 数组 → 空
        #expect(JSONText.completeArrayObjects(in: #"{"loo"#).isEmpty)
    }

    // MARK: 0.22 并行标签（同组=同时段，reflow 绑定）

    /// reflow 布局同组绑定：同 parallel 组的块同一起点、各自时长；槽长=组内最长；后续块接在槽后。
    @Test func reflowLayoutBindsParallelGroup() {
        let g = ScheduledBlock.parallelPrefix + "P1"
        let a = ScheduledBlock(title: "A", start: at(2026,7,10,9), end: at(2026,7,10,12), labels: [g])   // 3h
        let b = ScheduledBlock(title: "B", start: at(2026,7,10,9), end: at(2026,7,10,10), labels: [g])   // 1h
        let c = ScheduledBlock(title: "C", start: at(2026,7,10,13), end: at(2026,7,10,14))               // 无组 1h
        let laid = ReflowLayout.layOut(flexible: [a, b, c], fixed: [], from: at(2026,7,10,10))
        let la = laid.first { $0.title == "A" }!, lb = laid.first { $0.title == "B" }!, lc = laid.first { $0.title == "C" }!
        #expect(la.start == at(2026,7,10,10) && lb.start == at(2026,7,10,10))   // 同组同起点
        #expect(la.end == at(2026,7,10,13) && lb.end == at(2026,7,10,11))       // 各自保时长
        #expect(lc.start == at(2026,7,10,13))                                    // 下一块接在槽（3h）后
    }

    /// 防线：确认过的并行计划经全天连续 reflow（PlanStore→continuousReflow→layOut）绑定不散、标签不丢。
    /// （0.23 A：morningReflow 已退役，这条防线改守连续 reflow——它现在是唯一重排路径。）
    @Test func continuousReflowPreservesParallelBinding() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let g = ScheduledBlock.parallelPrefix + "P1"
        let label = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(byAdding: .hour, value: 9, to: label)!
        try store.replacePlanned([
            ScheduledBlock(title: "A", start: s, end: s.addingTimeInterval(3 * 3600), labels: [g]),
            ScheduledBlock(title: "B", start: s, end: s.addingTimeInterval(3600), labels: [g]),
            ScheduledBlock(title: "C", start: s.addingTimeInterval(4 * 3600), end: s.addingTimeInterval(5 * 3600)),
        ], on: label)
        let svc = RescheduleService(planStore: store, planner: NaivePlanningEngine())
        let laid = try await svc.continuousReflow(now: s)
        let a = laid.first { $0.title == "A" }
        let b = laid.first { $0.title == "B" }
        #expect(a?.start == b?.start)                       // 同组同起点（绑定没散）
        #expect(a?.parallelGroup == g && b?.parallelGroup == g)   // 标签存活
    }

    /// labels 全链路存活：PlanStore 往返 + 解析 parallel 字段 → parallel: 标签。
    @Test func parallelLabelsSurviveStoreAndParse() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let g = ScheduledBlock.parallelPrefix + "洗衣组"
        let label = at(2026, 7, 10, 0)
        try store.replacePlanned([ScheduledBlock(title: "洗衣服", start: at(2026,7,10,9),
                                                 end: at(2026,7,10,10), labels: [g])], on: label)
        #expect(try store.plannedBlocks(on: label).first?.parallelGroup == g)   // 落库往返不丢

        let json = #"{"loose":false,"longTasks":[],"blocks":[{"title":"A","start":"2026-07-10 09:00","end":"2026-07-10 10:00","parallel":"P1"},{"title":"B","start":"2026-07-10 09:00","end":"2026-07-10 11:00","parallel":"P1"},{"title":"C","start":"2026-07-10 11:00","end":"2026-07-10 12:00","parallel":null}]}"#
        let decoded = ClaudeScheduleParser.decodePlan(json)
        #expect(decoded?.blocks.count == 3)
        #expect(decoded?.blocks[0].labels == [ScheduledBlock.parallelPrefix + "P1"])
        #expect(decoded?.blocks[1].labels == [ScheduledBlock.parallelPrefix + "P1"])
        #expect(decoded?.blocks[2].labels == [])
    }

    /// 计时方式实时改（0.21）：番茄工作段中锁定；转番茄带目标段数、做满自动转轻计时续走。
    @Test func executionTimingChangeRespectsPomodoroLockAndTarget() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(byAdding: .hour, value: 10, to: day)!
        try planStore.replacePlanned([ScheduledBlock(title: "写代码", start: s,
                                                     end: s.addingTimeInterval(3600))], on: day)
        let vm = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: FakeReminderStore(),
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm.loadToday()
        await vm.startBlock(vm.planned[0])           // 轻计时开始
        await vm.waitForPreview()                    // 等游离预览 Task 落地（防撞已析构内存库）
        #expect(vm.canChangeTimingNow)               // 非番茄：随时可改
        vm.changeTiming(to: .pomodoro, pomodoroSegments: 1)   // 转番茄，目标 1 段
        #expect(vm.activeStyle == .pomodoro)
        #expect(!vm.canChangeTimingNow)              // 工作段进行中：锁定
        vm.changeTiming(to: TimingStyle.none)        // 锁定期改动无效
        #expect(vm.activeStyle == .pomodoro)
        vm.confirmPomodoroNext()                     // 完成第 1 段 = 做满目标 → 自动转轻计时续走
        #expect(vm.activeStyle == .light)
        #expect(vm.pomodoroPhase == nil)             // 已退出段循环
    }

    /// 番茄提前休息的周键：ISO 周、周一零点起新周（定死不设置，Jason 2026-07-08）。
    @Test func pomodoroWeekKeyResetsMondayMidnight() {
        // 2026-07-12 是周日、07-13 是周一
        #expect(PomodoroDiscipline.weekKey(at(2026, 7, 12, 23, 59)) != PomodoroDiscipline.weekKey(at(2026, 7, 13, 0, 0)))
        #expect(PomodoroDiscipline.weekKey(at(2026, 7, 13, 0, 0)) == PomodoroDiscipline.weekKey(at(2026, 7, 19, 23, 59)))
        #expect(PomodoroDiscipline.weekKey(at(2026, 7, 7, 10, 0)) == PomodoroDiscipline.weekKey(at(2026, 7, 12, 10, 0)))
    }

    // MARK: 0.20 执行运行态快照（重启/清后台恢复）

    /// 同逻辑日可恢复、跨逻辑日不恢复；Codable 往返不丢字段。
    @Test func executionRunStateRestorableOnlySameLogicalDay() throws {
        var snap = ExecutionViewModel.RunStateSnapshot()
        snap.active = .init(plannedID: UUID(), title: "写代码", start: at(2026,7,9,9),
                            pausedTotal: 120, timingStyleRaw: "pomodoro")
        snap.pomoWorkSegmentsDone = 3
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ExecutionViewModel.RunStateSnapshot.self, from: data)
        #expect(back.active?.title == "写代码")
        #expect(back.active?.pausedTotal == 120)
        #expect(back.pomoWorkSegmentsDone == 3)
        // 同逻辑日（当晚 23 点 / 次日凌晨 1 点）可恢复；次日白天不可
        #expect(ExecutionViewModel.RunStateSnapshot.isRestorable(back, now: at(2026,7,9,23)))
        #expect(ExecutionViewModel.RunStateSnapshot.isRestorable(back, now: at(2026,7,10,1)))
        #expect(!ExecutionViewModel.RunStateSnapshot.isRestorable(back, now: at(2026,7,10,9)))
        // 空快照（没有进行中的事）不恢复
        #expect(!ExecutionViewModel.RunStateSnapshot.isRestorable(.init(), now: at(2026,7,9,23)))
    }

    // MARK: 并行接替（0.26.15 点子 #20）：前台完成 → 同时做队首顶上；被换走 → 回同时做不误结束

    @Test func parallelTakeoverPromotesFirstBackgroundOnComplete() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        // B 计划风格是番茄：接替时必须降轻计时（绝不自动进番茄——锁必须用户自己上）
        try planStore.replacePlanned([
            ScheduledBlock(title: "写代码", start: s, end: s.addingTimeInterval(3600)),
            ScheduledBlock(title: "洗衣服", start: s.addingTimeInterval(3600), end: s.addingTimeInterval(5400),
                           timingStyle: .pomodoro),
            ScheduledBlock(title: "跑数据", start: s.addingTimeInterval(5400), end: s.addingTimeInterval(7200)),
        ], on: day)
        let vm = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: FakeReminderStore(),
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm.loadToday()
        let itemA = vm.planned.first { $0.title == "写代码" }!
        let itemB = vm.planned.first { $0.title == "洗衣服" }!
        let itemC = vm.planned.first { $0.title == "跑数据" }!
        await vm.startBlock(itemA)
        vm.startAlso(itemB)
        vm.startAlso(itemC)
        let bStart = vm.background.first!.start
        await vm.completeCurrent()          // A 完成 → B 顶上、C 前移
        await vm.waitForPreview()
        #expect(vm.isDone(itemA))
        #expect(vm.active?.plannedID == itemB.id)
        #expect(vm.active?.start == bStart)                    // 计时无缝：沿用后台起点
        #expect(vm.activeStyle == .light)                      // 番茄降轻计时
        #expect(vm.background.count == 1)
        #expect(vm.background.first?.plannedID == itemC.id)    // C 成同时做第一位
        await vm.completeCurrent()          // 链式：B 完成 → C 顶上
        await vm.waitForPreview()
        #expect(vm.isDone(itemB))
        #expect(vm.active?.plannedID == itemC.id)
        #expect(vm.background.isEmpty)
    }

    @Test func parallelTakeoverDemotesBackOnSwitchInsteadOfEnding() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        try planStore.replacePlanned([
            ScheduledBlock(title: "写代码", start: s, end: s.addingTimeInterval(3600)),
            ScheduledBlock(title: "洗衣服", start: s.addingTimeInterval(3600), end: s.addingTimeInterval(5400)),
            ScheduledBlock(title: "读书", start: s.addingTimeInterval(5400), end: s.addingTimeInterval(7200)),
        ], on: day)
        let vm = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: FakeReminderStore(),
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm.loadToday()
        let itemA = vm.planned.first { $0.title == "写代码" }!
        let itemB = vm.planned.first { $0.title == "洗衣服" }!
        let itemD = vm.planned.first { $0.title == "读书" }!
        await vm.startBlock(itemA)
        vm.startAlso(itemB)
        await vm.completeCurrent()                    // B 自动接替上前台
        #expect(vm.active?.plannedID == itemB.id)
        await vm.startBlock(itemD)                    // 开始别件：接替块回同时做，不是被结束
        await vm.waitForPreview()
        #expect(vm.active?.plannedID == itemD.id)
        #expect(!vm.isDone(itemB))                                 // B 没被误记完成
        #expect(vm.background.first?.plannedID == itemB.id)        // 回到同时做队首（计时保留）
        await vm.completeCurrent()                    // D 完成 → B 再接替
        #expect(vm.active?.plannedID == itemB.id)
        await vm.completeCurrent()                    // 明确点完成才落实际
        await vm.waitForPreview()
        #expect(vm.isDone(itemB))
        #expect(vm.active == nil)                     // 没有并行块了 → 回空档
    }

    // MARK: 日记第一方情境读真相源（0.26.15 补迁移：实时模式绿色淡出，从日历读会全算计划外）

    @Test func reflectionPromptReadsTruthStoreNotCalendarProjection() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let coding = ScheduledBlock(title: "写代码", start: s, end: s.addingTimeInterval(3600))
        let lunch = ScheduledBlock(title: "午饭", start: s.addingTimeInterval(3600),
                                   end: s.addingTimeInterval(5400), isAnchor: true)
        try planStore.replacePlanned([coding, lunch], on: day)
        try planStore.upsertActuals([ActualBlock(id: coding.id, title: "写代码",
                                                 start: s, end: s.addingTimeInterval(3000))])
        // 不给日历（日历全空 = 实时模式绿色已淡出的极端情形）——引子仍从真相源算出正确口径
        let provider = ReflectionContextProvider(planStore: planStore, comparer: OverlapTitleComparer())
        let prompt = await provider.todayPrompt()
        #expect(prompt?.contains("做成 1 件") == true)
        #expect(prompt?.contains("计划外") != true)   // 计划内做成，不再被算成 bonus
    }

    // MARK: 真相源边界守卫（2026-07-10：复盘/日记两次漏迁移的复盘产物）

    /// 日历 = 投影不是真相源：读它当数据源只允许白名单文件（∪带章合并 / 手动对账 / 绿对账回流）。
    /// 新代码要读计划/实际 → 从 PlanStore 读；确要读日历，先想清楚语义再把文件加进白名单。
    @Test func calendarReadsStayWithinSanctionedFiles() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BetterCalendarTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("BetterCalendar")
        let allowed: Set<String> = ["ExecutionViewModel.swift", "ReviewViewModel.swift",
                                    "ReconcileService.swift",
                                    // 0.35.0：投影对齐前查画面上的外来带章事件（多设备 pass-through），
                                    // 不是把日历当数据源——语义见 ProjectionService.project（P4.0 起还用于原样保留待核对的块）
                                    "CalendarSyncEngine.swift"]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            guard !allowed.contains(url.lastPathComponent) else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("calendarStore.read(") { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "白名单外从日历读数据：\(offenders)——计划/实际请读 PlanStore 真相源")
    }

    // MARK: 聪音待办投影 + 回流（SPEC §11 过审，0.26.16）

    @Test func chiyneCompleteByPlanIDMarksDoneIdempotently() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let day = DayContext.logicalStartOfDay(.now)
        let s = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let coding = ScheduledBlock(title: "写代码", start: s, end: s.addingTimeInterval(3600))
        let reading = ScheduledBlock(title: "读书", start: s.addingTimeInterval(3600), end: s.addingTimeInterval(7200))
        try planStore.replacePlanned([coding, reading], on: day)
        let vm = ExecutionViewModel(
            calendarStore: FakeCalendarStore(),
            reschedule: RescheduleService(planStore: planStore, planner: NaivePlanningEngine()),
            planStore: planStore, reminderStore: FakeReminderStore(),
            liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm.loadToday()
        await vm.complete(planID: coding.id)      // 计划块 → 按计划时段记实际
        await vm.waitForPreview()
        #expect(vm.doneCount == 1)
        #expect(try planStore.actualBlocks(on: day).contains { $0.id == coding.id })
        await vm.complete(planID: coding.id)      // 幂等：重复回流不翻倍
        await vm.complete(planID: UUID())         // 不认识的 id 忽略
        #expect(vm.doneCount == 1)
        // 后台并行块回流 → completeBackground 路径（净时长口径）
        let item = vm.planned.first { $0.id == reading.id }!
        vm.startAlso(item)
        await vm.complete(planID: reading.id)
        await vm.waitForPreview()
        #expect(vm.doneCount == 2)
        #expect(vm.background.isEmpty)
    }

    @Test func chiyneTodoProjectionItemsCarryIDTitleDone() {
        let a = ExecutionViewModel.PlannedItem(title: "写代码", start: .now, end: .now.addingTimeInterval(3600))
        let b = ExecutionViewModel.PlannedItem(title: "读书", start: .now, end: .now.addingTimeInterval(7200))
        let items = ExecutionViewModel.todoProjectionItems(planned: [a, b]) { $0.id == a.id }
        #expect(items.count == 2)
        #expect(items[0].id == a.id.uuidString)
        #expect(items[0].done == true)
        #expect(items[1].title == "读书")
        #expect(items[1].done == false)
    }

    // MARK: 聪音日历日档 + 终点对齐协议（0.26.17）

    @Test func chiyneDailySummaryOnlyCelebratesAccomplished() {
        // 空天/没做成 → 空串（mod 不写、不打扰）
        #expect(ReviewViewModel.chiyneDailySummary(comparison: nil, mitDone: [], mvpTitle: nil) == "")
        var c = DayComparison()
        c.items = [
            ComparedItem(status: .done, plannedTitle: "写代码", actualTitle: "写代码",
                         plannedMinutes: 120, actualMinutes: 130, anchor: .now),
            ComparedItem(status: .extra, plannedTitle: nil, actualTitle: "买菜",
                         plannedMinutes: nil, actualMinutes: 20, anchor: .now),
            ComparedItem(status: .missed, plannedTitle: "背单词", actualTitle: nil,
                         plannedMinutes: 30, actualMinutes: nil, anchor: .now),
        ]
        let s = ReviewViewModel.chiyneDailySummary(comparison: c, mitDone: ["写代码"], mvpTitle: "写代码")
        #expect(s.contains("做成 2 件"))
        #expect(s.contains("买菜（计划外）"))
        #expect(s.contains("🎯 想尽早的「写代码」做成了"))
        #expect(s.contains("⭐ 今日最有价值：写代码"))
        #expect(s.contains("有效投入 2 小时 30 分"))
        #expect(!s.contains("背单词"))       // 羞辱铁律：没做成的绝不出现
        #expect(!s.contains("完成率"))
    }

    @Test func pomodoroAutoSegmentsCeil() {
        // 0.34（Jason 定向上取整）：2h ÷ (25+5) = 4 段整；110min → 4（向上）；25min → 1；无计划/非正 → nil
        #expect(ExecutionViewModel.pomodoroAutoSegments(plannedSec: 2 * 3600) == 4)
        #expect(ExecutionViewModel.pomodoroAutoSegments(plannedSec: 110 * 60) == 4)
        #expect(ExecutionViewModel.pomodoroAutoSegments(plannedSec: 25 * 60) == 1)
        #expect(ExecutionViewModel.pomodoroAutoSegments(plannedSec: 5 * 60) == 1)     // 极短也给足 1 段
        #expect(ExecutionViewModel.pomodoroAutoSegments(plannedSec: nil) == nil)      // 计划外 bonus=不限段
        #expect(ExecutionViewModel.pomodoroAutoSegments(plannedSec: 0) == nil)
    }

    @Test func pomodoroSegmentsRemainingMath() {
        #expect(ExecutionViewModel.pomodoroSegmentsRemaining(target: nil, done: 0, inWork: true) == -1)   // 不限段
        #expect(ExecutionViewModel.pomodoroSegmentsRemaining(target: 3, done: 0, inWork: true) == 2)      // 第一段进行中
        #expect(ExecutionViewModel.pomodoroSegmentsRemaining(target: 3, done: 1, inWork: false) == 2)     // 休息段中
        #expect(ExecutionViewModel.pomodoroSegmentsRemaining(target: 2, done: 2, inWork: false) == 0)     // 做满
    }

    // MARK: 解析链 v2（「只使用端侧」0.29.0，race 退役）+ 回填跨午夜整形 + 徽标 v2（0.26.19）

    /// 线程安全的一次性标志（chain 测试用：验证某条车道没被调过）。
    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    @Test func parserChainRespectsOnDeviceOnly() async throws {
        func plan(_ tag: String) -> ParsedPlan {
            ParsedPlan(blocks: [], longTasks: [ParsedLongTask(title: tag, deadline: nil,
                       cadenceMinutesPerWeek: nil, totalMinutes: nil, unitMinutes: nil)], isLoose: false)
        }
        // Build fixtures before the race: actor-bound construction must not
        // consume the simulated network response window under parallel load.
        let devicePlan = plan("端侧"), cloudPlan = plan("云端")
        // v3 默认：并行热备——云端优先窗内出结果=用云端，端侧先出也押着等（不再是先到先得）
        var r = try await FoundationModelsScheduleParser.chain(
            onDeviceOnly: false, cloudPriorityWindow: 0.5, totalDeadline: 2,
            onDevice: { devicePlan },   // 立即出
            cloud: { try? await Task.sleep(nanoseconds: 100_000_000); return cloudPlan })
        #expect(r.longTasks.first?.title == "云端")
        // v3：云端超优先窗没出、端侧有货 → 端侧接管
        r = try await FoundationModelsScheduleParser.chain(
            onDeviceOnly: false, cloudPriorityWindow: 0.05, totalDeadline: 2,
            onDevice: { devicePlan },
            cloud: { try? await Task.sleep(nanoseconds: 1_000_000_000); return cloudPlan })
        #expect(r.longTasks.first?.title == "端侧")
        // v3：云端失败 → 端侧热备接管（不等窗）
        r = try await FoundationModelsScheduleParser.chain(
            onDeviceOnly: false,
            onDevice: { devicePlan },
            cloud: { throw AnthropicError(message: "云端挂了") })
        #expect(r.longTasks.first?.title == "端侧")
        // v3：端云双失 → 干净抛错
        await #expect(throws: (any Error).self) {
            _ = try await FoundationModelsScheduleParser.chain(
                onDeviceOnly: false, onDevice: { nil },
                cloud: { throw AnthropicError(message: "云端挂了") })
        }
        // v3：总限到点两边都没出 → 干净报错（不挂死）
        await #expect(throws: (any Error).self) {
            _ = try await FoundationModelsScheduleParser.chain(
                onDeviceOnly: false, cloudPriorityWindow: 0.05, totalDeadline: 0.15,
                onDevice: { try? await Task.sleep(nanoseconds: 2_000_000_000); return nil },
                cloud: { try? await Task.sleep(nanoseconds: 2_000_000_000); return cloudPlan })
        }
        // 只使用端侧：端侧胜出，云端**绝不被调**（绝对隐私承诺）
        let cloudTouched = LockedFlag()
        r = try await FoundationModelsScheduleParser.chain(
            onDeviceOnly: true,
            onDevice: { devicePlan },
            cloud: { cloudTouched.set(); return cloudPlan })
        #expect(r.longTasks.first?.title == "端侧")
        #expect(!cloudTouched.value)
        // 只使用端侧：端侧失手 → 干净抛错，云端仍不被调（不静默回云）
        await #expect(throws: (any Error).self) {
            _ = try await FoundationModelsScheduleParser.chain(
                onDeviceOnly: true, onDevice: { nil },
                cloud: { cloudTouched.set(); return cloudPlan })
        }
        #expect(!cloudTouched.value)
    }

    @Test func anchorBlocksAlwaysDecodeAsUntimed() {
        // 锚点不计时（2026-07-11）：模型就算给午饭配番茄，解码也拉回 none（prompt+解码双保险）
        let json = """
        {"loose":false,"blocks":[
          {"title":"午饭","start":"2026-07-11 12:00","end":"2026-07-11 12:30","isFixed":false,"isAnchor":true,"category":"","timingStyle":"pomodoro","priority":"normal","deadline":null},
          {"title":"写代码","start":"2026-07-11 13:00","end":"2026-07-11 15:00","isFixed":false,"isAnchor":false,"category":"","timingStyle":"pomodoro","priority":"normal","deadline":null}
        ],"longTasks":[]}
        """
        let decoded = ClaudeScheduleParser.decodePlan(json)
        #expect(decoded != nil)
        let anchor = decoded!.blocks.first { $0.title == "午饭" }
        let task = decoded!.blocks.first { $0.title == "写代码" }
        #expect(anchor?.timingStyle == TimingStyle.none)      // 锚点：番茄被拉回不计时
        #expect(task?.timingStyle == TimingStyle.pomodoro)    // 普通任务：不受影响
    }

    @Test func refineChangeCountDiffsBySignature() {
        let base = at(2026, 7, 11, 9, 0)
        func blk(_ t: String, h: Int, fixed: Bool = false) -> ScheduledBlock {
            ScheduledBlock(title: t, start: base.addingTimeInterval(TimeInterval(h * 3600)),
                           end: base.addingTimeInterval(TimeInterval(h * 3600 + 1800)), isFixed: fixed)
        }
        let before = [blk("写代码", h: 0), blk("健身", h: 2), blk("读书", h: 4)]
        // 没改 → 0 处
        #expect(HomeViewModel.countRefineChanges(before: before, after: before) == 0)
        // 挪一个块的时间 → 1 处
        #expect(HomeViewModel.countRefineChanges(before: before,
                                                 after: [blk("写代码", h: 1), blk("健身", h: 2), blk("读书", h: 4)]) == 1)
        // 删一个块 → 1 处；加一个块 → 1 处
        #expect(HomeViewModel.countRefineChanges(before: before,
                                                 after: [blk("写代码", h: 0), blk("健身", h: 2)]) == 1)
        #expect(HomeViewModel.countRefineChanges(before: before,
                                                 after: before + [blk("散步", h: 6)]) == 1)
        // 改属性（标固定）→ 1 处
        #expect(HomeViewModel.countRefineChanges(before: before,
                                                 after: [blk("写代码", h: 0, fixed: true), blk("健身", h: 2), blk("读书", h: 4)]) == 1)
    }

    @Test func backfillSpanNormalizationKeepsMidnightWhole() {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 23, minute: 30, second: 0, of: .now)!
        // 模型把「23:30–0:30」的结束写成当天 0:30（end < start）→ 顺延次日、时长 1h
        let sameDayEnd = cal.date(bySettingHour: 0, minute: 30, second: 0, of: start)!
        var out = ReviewViewModel.normalizedSpans(
            [EditableBlock(title: "看书", start: start, end: sameDayEnd)])[0]
        #expect(out.end > out.start)
        #expect(abs(out.end.timeIntervalSince(out.start) - 3600) < 61)
        // 用户把结束时分改回同一天、日期挂在次日（10:00→次日18:00=32h）→ 收回一天（8h）
        let s10 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: .now)!
        let nextDay18 = cal.date(byAdding: .day, value: 1,
                                 to: cal.date(bySettingHour: 18, minute: 0, second: 0, of: .now)!)!
        out = ReviewViewModel.normalizedSpans(
            [EditableBlock(title: "写作", start: s10, end: nextDay18)])[0]
        #expect(abs(out.end.timeIntervalSince(out.start) - 8 * 3600) < 61)
        // 真跨午夜块（23:30–次日 01:00）原样保留
        let nextDay1 = cal.date(byAdding: .day, value: 1,
                                to: cal.date(bySettingHour: 1, minute: 0, second: 0, of: start)!)!
        out = ReviewViewModel.normalizedSpans(
            [EditableBlock(title: "夜聊", start: start, end: nextDay1)])[0]
        #expect(abs(out.end.timeIntervalSince(out.start) - 5400) < 61)
    }

    /// 徽标 v2：亮标时算最新底但不套用（freshBase 快照）；保留我的编辑 → 熄标、本页不动。
    @Test func freshnessCompareSnapshotAndChoices() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let planStore = PlanStore(context: container.mainContext)
        let started = StartedDayStore(persisted: false)
        // 时钟注入：固定时刻（同 freshnessBadgeLifecycle——本测试就是 2026-07-14 03:20 崩 host 的第一现场）
        let fixedNow = at(2026, 7, 10, 10, 0)
        let today = DayContext.logicalDay(offset: 0, from: fixedNow)
        let b = ScheduledBlock(title: "一件事", start: fixedNow.addingTimeInterval(3600),
                               end: fixedNow.addingTimeInterval(2 * 3600))
        try planStore.replacePlanned([b], on: today)
        started.markStarted(today)
        let vm = Self.makeHomeVM(planStore: planStore, startedDays: started, progress: ProgressStub(),
                                 now: { fixedNow })
        vm.targetDay = today
        vm.loadConfirmedPlan()
        try #require(!vm.blocks.isEmpty)   // 防崩闸保留（防未来同类）：红可以，崩 host 不行
        vm.blocks[0].title = "改了名"
        vm.delete(id: UUID())   // 只置未保存标记
        vm.noteExecutionProgress()
        #expect(vm.freshness == true)
        #expect(vm.freshBase != nil)                 // 算了最新底、没套用
        #expect(vm.freshBase?.first?.title == "一件事")
        #expect(vm.blocks[0].title == "改了名")       // 本页原样
        vm.keepMyDraft()                             // 保留我的编辑
        #expect(vm.freshness == false)
        #expect(vm.freshBase == nil)
        #expect(vm.blocks[0].title == "改了名")
        #expect(vm.hasUnsavedChanges == true)
    }

    // MARK: 锚点软固定 ±20 分钟（0.27.0，Jason 拍板定死）

    @Test func reflowAnchorSoftFixedWithin20MinuteTolerance() {
        let windDown = at(2026, 7, 10, 22, 0)
        let anchor = ScheduledBlock(title: "午饭", start: at(2026, 7, 10, 13, 0),
                                    end: at(2026, 7, 10, 13, 30), isAnchor: true)
        // 70 分钟任务从 12:00 铺 → 12:00–13:10 撞午饭 10 分钟（≤20）→ 午饭顺延到 13:10、任务不断
        var r = ReflowLayoutV2.layOut(
            flexible: [ScheduledBlock(title: "写代码", start: at(2026, 7, 10, 9, 0),
                                      end: at(2026, 7, 10, 10, 10)), anchor],
            fixed: [], from: at(2026, 7, 10, 12, 0), windDown: windDown, graceMinutes: 10)
        #expect(r.scheduled.first { $0.title == "写代码" }?.end == at(2026, 7, 10, 13, 10))
        #expect(r.scheduled.first { $0.title == "午饭" }?.start == at(2026, 7, 10, 13, 10))
        // 100 分钟任务需要让 40 分钟（>20）→ 午饭不动、任务绕到 13:30 之后
        r = ReflowLayoutV2.layOut(
            flexible: [ScheduledBlock(title: "长任务", start: at(2026, 7, 10, 9, 0),
                                      end: at(2026, 7, 10, 10, 40)), anchor],
            fixed: [], from: at(2026, 7, 10, 12, 0), windDown: windDown, graceMinutes: 10)
        #expect(r.scheduled.first { $0.title == "午饭" }?.start == at(2026, 7, 10, 13, 0))
        #expect(r.scheduled.first { $0.title == "长任务" }?.start == at(2026, 7, 10, 13, 30))
        #expect(r.deferred.isEmpty)   // 锚点绝不进候补
    }

    // MARK: 自动日记（0.28：15–30 秒最低闭环，本地模板、零出云）

    @Test func autoJournalComposeOnlyCelebrates() {
        // 空天 → nil（绝不生成「今天 0 件」）
        #expect(AutoJournal.compose(comparison: nil) == nil)
        var empty = DayComparison()
        empty.items = [ComparedItem(status: .missed, plannedTitle: "背单词", actualTitle: nil,
                                    plannedMinutes: 30, actualMinutes: nil, anchor: .now)]
        #expect(AutoJournal.compose(comparison: empty) == nil)
        // 有做成 → 首行 🤖 标记 + 做成清单 + 投入 + 鼓励语；没做成的绝不出现
        var c = DayComparison()
        c.items = [
            ComparedItem(status: .done, plannedTitle: "写代码", actualTitle: "写代码",
                         plannedMinutes: 60, actualMinutes: 70, anchor: .now),
            ComparedItem(status: .extra, plannedTitle: nil, actualTitle: "买菜",
                         plannedMinutes: nil, actualMinutes: 20, anchor: .now),
            ComparedItem(status: .missed, plannedTitle: "背单词", actualTitle: nil,
                         plannedMinutes: 30, actualMinutes: nil, anchor: .now),
        ]
        let text = AutoJournal.compose(comparison: c, pick: 0)
        #expect(text?.hasPrefix("🤖 自动日记") == true)       // 与手写明显区分
        #expect(text?.contains("做成 2 件") == true)
        #expect(text?.contains("买菜（计划外）") == true)
        #expect(text?.contains("1 小时 30 分") == true)
        #expect(text?.contains(AutoJournal.encouragements[0]) == true)
        #expect(text?.contains("背单词") != true)              // 羞辱铁律
    }

    // MARK: arrange 排序固化（0.28.1 候选，试验台对照中）+ 早通知小总结

    @Test func ruleBasedArrangerOrdersMITThenDDLThenTime() async throws {
        let anytime = ScheduledBlock(title: "杂务", start: at(2026, 7, 10, 9, 0), end: at(2026, 7, 10, 9, 30))
        let ddlLate = ScheduledBlock(title: "交报销", start: at(2026, 7, 10, 15, 0),
                                     end: at(2026, 7, 10, 15, 30), deadline: at(2026, 7, 10, 18, 0))
        let ddlSoon = ScheduledBlock(title: "改简历", start: at(2026, 7, 10, 11, 0),
                                     end: at(2026, 7, 10, 12, 0), deadline: at(2026, 7, 10, 14, 0))
        let mit = ScheduledBlock(title: "写论文", start: at(2026, 7, 10, 10, 0),
                                 end: at(2026, 7, 10, 12, 0), priority: .important)
        let lunch = ScheduledBlock(title: "午饭", start: at(2026, 7, 10, 12, 30),
                                   end: at(2026, 7, 10, 13, 0), isAnchor: true)
        let d = try await RuleBasedArranger().arrange([anytime, ddlLate, ddlSoon, mit, lunch],
                                                      now: at(2026, 7, 10, 8, 30))
        #expect(d.orderedBlocks.map(\.title) == ["写论文", "改简历", "交报销", "杂务", "午饭"])
        #expect(d.orderedBlocks.first { $0.title == "写论文" }?.start == mit.start)   // 时间绝不动
        #expect(d.note?.contains("写论文") == true)                                    // note 点名 ★
        // 无 ★ 有 DDL → note 点名最近截止；单件 → 专属句
        let d2 = try await RuleBasedArranger().arrange([anytime, ddlSoon], now: at(2026, 7, 10, 8, 30))
        #expect(d2.note?.contains("改简历") == true)
        let d3 = try await RuleBasedArranger().arrange([anytime], now: at(2026, 7, 10, 8, 30))
        #expect(d3.note == "今天就这一件，做完就赢。")
    }

    @Test func morningSummaryCountsTasksAndNamesFirst() {
        let blocks = [
            EditableBlock(title: "早饭", start: at(2026, 7, 10, 8, 0), end: at(2026, 7, 10, 8, 30), isAnchor: true),
            EditableBlock(title: "写代码", start: at(2026, 7, 10, 9, 0), end: at(2026, 7, 10, 11, 0)),
            EditableBlock(title: "健身", start: at(2026, 7, 10, 16, 0), end: at(2026, 7, 10, 17, 0),
                          priority: .important),
        ]
        let s = HomeViewModel.morningSummary(for: blocks)
        #expect(s.contains("今天 2 件"))                     // 锚点不计数
        #expect(s.contains("尽早：健身"))
        #expect(s.contains("第一件：「写代码」"))
    }

    // MARK: 「给明天的一句话」提取（0.28.2：写在日记里、本地规则解析——宁可漏不误提）

    @Test func tomorrowNoteExtractionIsConservative() {
        // 行首前缀才算；取最后一条（改主意以最后为准）；标点剥离
        let body = """
        今天把论文写完了，挺累的。
        给明天：先把数据跑上再吃早饭。
        中间还和导师聊了聊给明天的规划（这句不该被提取）。
        致明天——轻松点，别慌。
        """
        #expect(TomorrowNote.extract(from: body) == "轻松点，别慌。")
        // 没有寄语 → nil；前缀后为空 → nil
        #expect(TomorrowNote.extract(from: "普通的一天，没什么想说的。") == nil)
        #expect(TomorrowNote.extract(from: "给明天：") == nil)
        // 行中出现「给明天」不算（宁可漏不误提）
        #expect(TomorrowNote.extract(from: "我想给明天留点余地这样说说而已") == nil)
    }

    // MARK: M9/R1 日记

    @Test func journalStoreTodayIsSingletonAndSearchable() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

    /// W28b：只打开日记页不落空条目、空条目不算「写下 1 篇」（P4 不虚报）。
    @Test func journalOpeningPageDoesNotCreateOrCountEmptyEntry() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: JournalEntry.self, configurations: config)
        let store = JournalStore(context: container.mainContext)
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 17))!
        // 打开页面：拿到的是草稿，库里没有任何条目
        let draft = store.todayEntryOrDraft(now)
        #expect(draft.modelContext == nil)
        store.commit(draft)                                   // 什么都没写就「保存」：仍不落库
        #expect(try container.mainContext.fetchCount(FetchDescriptor<JournalEntry>()) == 0)
        #expect(JournalEntry.writtenCount(store.allEntries()) == 0)
        #expect(store.hasContentToday(now) == false)
        // 只打标签：落库（是输入），但不算写下一篇
        draft.tags = ["随手"]; store.commit(draft)
        #expect(store.allEntries().count == 1 && JournalEntry.writtenCount(store.allEntries()) == 0)
        // 写了正文才算；再次打开拿到的是同一条
        draft.body = "  今天顺  "; store.commit(draft)
        #expect(JournalEntry.writtenCount(store.allEntries()) == 1 && store.hasContentToday(now))
        #expect(store.todayEntryOrDraft(now).id == draft.id && store.allEntries().count == 1)
        // 历史里的老空条目（以前打开页面留下的）不计数；只放照片 / 只选心情的算
        let oldEmpty = JournalEntry(date: now.addingTimeInterval(-86_400 * 3))
        let photoOnly = JournalEntry(date: now.addingTimeInterval(-86_400 * 2), photoRefs: ["p.jpg"])
        let moodOnly = JournalEntry(date: now.addingTimeInterval(-86_400), mood: "🙂")
        for e in [oldEmpty, photoOnly, moodOnly] { container.mainContext.insert(e) }
        try container.mainContext.save()
        #expect(JournalEntry.writtenCount(store.allEntries()) == 3)
        #expect(!oldEmpty.hasRealContent && !oldEmpty.hasAnyInput && photoOnly.hasRealContent && moodOnly.hasRealContent)
    }
}
