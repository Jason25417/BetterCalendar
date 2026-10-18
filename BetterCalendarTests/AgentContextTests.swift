import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

/// SPEC §19 A2：写给智能体的 context.json——字段、来源/时间、截断标记、日记开关。
@MainActor @Suite struct AgentContextTests {
    /// 固定时钟：2026-10-18 15:00（本地时区）。
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15))!
    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func json(_ o: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }

    private func richInput() -> AgentContextInput {
        var input = AgentContextInput(now: now)
        input.today.items = [.init(title: "组会", start: at(60), end: at(120), isFixed: true),
                             .init(title: "写论文", start: at(-60), end: at(0), important: true)]
        input.running = .init(foreground: .init(title: "写论文", start: at(-20), pausedSeconds: 90, timingStyle: "light"),
                              background: [.init(title: "洗衣服", start: at(-10))])
        input.todos.items = [.init(title: "买牛奶", deadline: nil, createdAt: at(-600), spilledFromDay: at(-1440))]
        input.longterm.items = [.init(title: "N1 准备", deadline: at(10_000), createdAt: at(-20_000), checkpointsDone: 1, checkpointsTotal: 3,
                                      nextCheckpoint: "语法", lastCheckpointTitle: "词汇", lastCheckpointAt: at(-120),
                                      recentMinutes: 45, lastWorkedAt: at(-100))]
        input.calendar.items = [.init(title: "牙医", start: at(1440), end: at(1500), calendar: "家庭")]
        input.actuals.items = [.init(title: "跑步", start: at(-1500), end: at(-1470))]
        return input
    }

    @Test func snapshotCarriesEverySectionWithSourceAndTime() throws {
        let c = AgentBridgeContext.snapshot(richInput())
        #expect(JSONSerialization.isValidJSONObject(c))
        #expect(c["schemaVersion"] as? Int == 1 && c["readOnly"] as? Bool == true && c["writtenAt"] is String)
        // v1 兼容：today.blocks[].title/start(HH:mm) 与 running.title/startedAt 仍在
        let today = try #require(c["today"] as? [String: Any])
        let blocks = try #require(today["blocks"] as? [[String: Any]])
        #expect(blocks.count == 2 && blocks[0]["title"] as? String == "组会" && blocks[0]["start"] as? String == "16:00")
        #expect(blocks[0]["fixed"] as? Bool == true && blocks[1]["important"] as? Bool == true)
        let running = try #require(c["running"] as? [String: Any])
        #expect(running["title"] as? String == "写论文" && running["startedAt"] is String && running["pausedSeconds"] as? Int == 90)
        let parallel = try #require(c["parallelRunning"] as? [String: Any])
        #expect((parallel["items"] as? [[String: Any]])?.first?["title"] as? String == "洗衣服")
        // 待办池 / 长期事项：阶段与最近推进
        let pool = try #require(c["pool"] as? [String: Any])
        let longterm = try #require(pool["longterm"] as? [String: Any])
        let n1 = try #require((longterm["items"] as? [[String: Any]])?.first)
        let stage = try #require(n1["stage"] as? [String: Any])
        #expect(stage["done"] as? Int == 1 && stage["total"] as? Int == 3 && stage["next"] as? String == "语法" && stage["lastReached"] as? String == "词汇")
        #expect(n1["recentMinutes"] as? Int == 45 && n1["lastWorkedAt"] is String)
        let todo = try #require((pool["todo"] as? [String: Any])?["items"] as? [[String: Any]])
        #expect(todo.first?["spilledFromDay"] is String && todo.first?["stage"] == nil)
        // 系统日历标注来源；最近实际带时长
        let cal = try #require(c["calendar"] as? [String: Any])
        #expect((cal["source"] as? String)?.contains("系统日历") == true && cal["window"] is [String: Any])
        #expect((cal["events"] as? [[String: Any]])?.first?["calendar"] as? String == "家庭")
        let actuals = try #require(c["recentActuals"] as? [String: Any])
        #expect((actuals["items"] as? [[String: Any]])?.first?["minutes"] as? Int == 30)
        // 每个块都带来源与时间
        for key in ["today", "running", "parallelRunning", "pool", "calendar", "recentActuals", "journal"] {
            let section = try #require(c[key] as? [String: Any], "缺 \(key)")
            #expect(section["source"] is String && section["asOf"] as? String == c["writtenAt"] as? String, "\(key) 缺来源/时间")
        }
        for key in ["today", "calendar", "recentActuals"] {
            #expect((c[key] as? [String: Any])?["truncated"] as? Bool == false)
        }
    }

    @Test func listsAreCappedAndTruncationIsExplicit() throws {
        var input = AgentContextInput(now: now)
        input.todos.items = (0..<50).map { .init(title: "待办\($0)", deadline: nil, createdAt: at(Double(-$0))) }
        input.actuals.items = (0..<60).map { .init(title: "实际\($0)", start: at(Double($0 - 3000)), end: at(Double($0 - 2990))) }
        input.calendar.items = (0..<5).map { .init(title: "事件\($0)", start: at(Double($0 * 60)), end: at(Double($0 * 60 + 30))) }
        input.longterm.items = [.init(title: String(repeating: "长", count: 200), deadline: nil, createdAt: now)]
        let c = AgentBridgeContext.snapshot(input)
        let todo = try #require((c["pool"] as? [String: Any])?["todo"] as? [String: Any])
        #expect((todo["items"] as? [Any])?.count == AgentContextLimits.todos)
        #expect(todo["total"] as? Int == 50 && todo["truncated"] as? Bool == true && (todo["truncatedNote"] as? String)?.contains("50") == true)
        // 实际：截断时保留最近的
        let actuals = try #require(c["recentActuals"] as? [String: Any])
        let kept = try #require(actuals["items"] as? [[String: Any]])
        #expect(kept.count == AgentContextLimits.actuals && actuals["total"] as? Int == 60 && actuals["truncated"] as? Bool == true)
        #expect(kept.last?["title"] as? String == "实际59" && kept.first?["title"] as? String == "实际20")
        let cal = try #require(c["calendar"] as? [String: Any])
        #expect(cal["truncated"] as? Bool == false && cal["total"] as? Int == 5 && cal["truncatedNote"] == nil)
        // 超长标题被截短
        let long = try #require(((c["pool"] as? [String: Any])?["longterm"] as? [String: Any])?["items"] as? [[String: Any]])
        #expect((long.first?["title"] as? String)?.count == AgentContextLimits.titleChars + 1)
    }

    @Test func journalIsAbsentUnlessAllowed() throws {
        var input = richInput()
        input.journal.items = [.init(day: at(-60), body: "今天心里有点乱的秘密", mood: "😐", modifiedAt: at(-30))]
        input.journalAllowed = false
        let off = AgentBridgeContext.snapshot(input)
        let journal = try #require(off["journal"] as? [String: Any])
        #expect(journal["included"] as? Bool == false && journal["entries"] == nil)
        #expect(try !json(off).contains("秘密"))

        input.journalAllowed = true
        input.journal.items = [.init(day: at(-60), body: String(repeating: "字", count: 800), mood: nil, modifiedAt: at(-30))]
        let on = AgentBridgeContext.snapshot(input)
        let j = try #require(on["journal"] as? [String: Any])
        let entry = try #require((j["entries"] as? [[String: Any]])?.first)
        #expect(j["included"] as? Bool == true && (entry["excerpt"] as? String)?.count == AgentContextLimits.journalChars)
        #expect(entry["excerptTruncated"] as? Bool == true && entry["bodyChars"] as? Int == 800)
    }

    @Test func readErrorsAreVisibleNotSilentlyEmpty() throws {
        var input = AgentContextInput(now: now)
        input.calendar.error = "读取系统日历失败：无日历 full access"
        let c = AgentBridgeContext.snapshot(input)
        let cal = try #require(c["calendar"] as? [String: Any])
        #expect((cal["error"] as? String)?.contains("full access") == true && cal["total"] as? Int == 0)
        #expect((c["recentActuals"] as? [String: Any])?["error"] == nil)
    }

    // MARK: 收集器（内存 SwiftData，只读）

    private func container() throws -> ModelContainer {
        try ModelContainer(for: DataArchiveStore.schema,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private final class FailingActuals: ActualReading {
        func actualBlocks(on day: Date) throws -> [ActualBlock] { throw CalendarError(message: "读蓝色失败") }
        func clearedPlannedIDs(on day: Date) throws -> Set<UUID> { [] }
    }

    private final class SystemCalendarStub: CalendarStore {
        var events: [SystemCalendarEvent] = []
        var failure: String?
        func write(_ drafts: [CalendarEventDraft]) async throws {}
        func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft] { [] }
        func clear(kind: PlanCalendarKind) async throws {}
        func apply(_ drafts: [CalendarEventDraft], kind: PlanCalendarKind, window: DateInterval) async throws {}
        func systemEvents(in window: DateInterval) async throws -> [SystemCalendarEvent] {
            if let failure { throw CalendarError(message: failure) }
            return events.filter { $0.start < window.end && $0.end > window.start }
        }
    }

    @Test func gathererReadsPoolProgressActualsAndHonorsJournalSwitch() async throws {
        let c = try container(); let ctx = c.mainContext
        let task = LongTask(title: "N1 准备", createdAt: at(-20_000))
        ctx.insert(task)
        let cp = LongTaskCheckpoint(title: "词汇", doneAt: at(-120), order: 0); ctx.insert(cp); cp.task = task
        let cp2 = LongTaskCheckpoint(title: "语法", order: 1); ctx.insert(cp2); cp2.task = task
        ctx.insert(LongTask(title: "买牛奶", createdAt: at(-60), zone: .todo))
        let s = ExecutionSession(start: at(-90), end: at(-60)); s.title = "N1 准备"; ctx.insert(s)
        let old = ExecutionSession(start: at(-20 * 1440), end: at(-20 * 1440 + 60)); old.title = "N1 准备"; ctx.insert(old)   // 窗口外
        ctx.insert(PlanBlock(title: "组会", start: at(60), end: at(120), isFixed: true, kind: .planned))
        ctx.insert(PlanBlock(title: "跑步", start: at(-1620), end: at(-1590), kind: .actual))           // 昨天
        ctx.insert(PlanBlock(title: "上周的事", start: at(-6 * 1440), end: at(-6 * 1440 + 30), kind: .actual))   // 窗口外
        ctx.insert(JournalEntry(date: at(-60), body: "不该给智能体看的日记"))
        try ctx.save()

        let calendar = SystemCalendarStub()
        calendar.events = [SystemCalendarEvent(title: "牙医", start: at(1440), end: at(1500), isAllDay: false, calendarTitle: "家庭"),
                           SystemCalendarEvent(title: "下周旅行", start: at(8 * 1440), end: at(9 * 1440), isAllDay: true, calendarTitle: "家庭")]
        var allowJournal = false
        let plans = PlanStore(context: ctx)
        let gatherer = AgentContextGatherer(planStore: plans, actualStore: plans, longTasks: LongTaskStore(context: ctx),
                                            calendarStore: calendar, journalStore: JournalStore(context: ctx),
                                            running: { .init(foreground: .init(title: "组会准备", start: self.at(-5))) },
                                            journalAllowed: { allowJournal })
        let input = await gatherer.gather(now: now)
        #expect(input.today.items.map(\.title) == ["组会"])
        #expect(input.running.foreground?.title == "组会准备")
        #expect(input.todos.items.map(\.title) == ["买牛奶"])
        let n1 = try #require(input.longterm.items.first)
        #expect(n1.checkpointsDone == 1 && n1.checkpointsTotal == 2 && n1.nextCheckpoint == "语法" && n1.lastCheckpointTitle == "词汇")
        #expect(n1.recentMinutes == 30 && n1.lastWorkedAt == at(-60))
        #expect(input.actuals.items.map(\.title) == ["跑步"])          // 只要最近 3 个逻辑日
        #expect(input.calendar.error == nil && input.calendar.items.map(\.title) == ["牙医"])   // 只要今天 + 未来 3 天
        #expect(!input.journalAllowed && input.journal.items.isEmpty)   // 开关关：连读都不读
        #expect(try !json(AgentBridgeContext.snapshot(input)).contains("不该给智能体看"))

        allowJournal = true
        let withJournal = await gatherer.gather(now: now)
        #expect(withJournal.journal.items.map(\.body) == ["不该给智能体看的日记"])

        // 日历读失败：显式写进上下文，不当成「没有」
        let stub = SystemCalendarStub(); stub.failure = "无权限"
        let failing = AgentContextGatherer(planStore: nil, actualStore: FailingActuals(), longTasks: nil, calendarStore: stub, journalStore: nil,
                                           running: { .init() }, journalAllowed: { false })
        let broken = await failing.gather(now: now)
        #expect(broken.calendar.error?.contains("无权限") == true && broken.actuals.error?.contains("读蓝色失败") == true)
        _ = c   // 容器与 store 同寿命
    }

    @Test func bridgeWritesGatheredContextFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bc-ctx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(),
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac")
        let input = richInput()
        let bridge = AgentBridge(center: center, defaults: UserDefaults(suiteName: "bc-ctx-" + UUID().uuidString)!) {
            AgentBridgeContext.snapshot(input)
        }
        bridge.eventsEnabled = { false }
        await bridge.sync(io: AgentBridgeIO(root: root))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("context.json"))) as! [String: Any]
        #expect(written["recentActuals"] is [String: Any] && (written["journal"] as? [String: Any])?["included"] as? Bool == false)
        try? FileManager.default.removeItem(at: root)
    }
}
