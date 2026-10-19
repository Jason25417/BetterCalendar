//
//  AgentContext.swift
//  BetterCalendar
//
//  SPEC §19 A2：写给 BetterCalendar 智能体的 context.json——让它看到你的一天（只读副本；真相仍在 BetterCalendar）。
//  分三层：
//    - AgentContextInput：从各只读来源收集来的 DTO（与存储实现无关，单测可直接构造）；
//    - AgentContextGatherer：组装点注入的收集器（只读：今天的计划 / 计时 / 待办池与长期事项 / 系统日历 / 蓝色实际 / 可选日记）；
//      计划与实际都读 PlanStore 真相源（PlanReading / ActualReading），日历只用来看「系统日历里别的安排」；
//    - AgentBridgeContext.snapshot：DTO → JSON（各列表设上限，截断显式标 truncated + total；每块都带来源与时间）。
//  全部只读：不写任何库、不改日历、不弹权限。日记默认不给，Jason 在「多端审批」面板打开开关才附最近 3 天摘要。
//

import Foundation

/// 「允许智能体读最近日记」开关（默认关；多端审批面板里切；随设置跨端同步，见 SettingsSync 白名单）。
nonisolated enum AgentContextSettings {
    static let allowJournalKey = "agentContext.allowRecentJournal"
    static var allowRecentJournal: Bool {
        get { UserDefaults.standard.bool(forKey: allowJournalKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowJournalKey) }
    }
}

/// 体积上限（context.json 每 20 秒重写一次，智能体每次唤醒都会读——要小）。
enum AgentContextLimits {
    static let todayBlocks = 40
    static let todos = 30
    static let longterm = 20
    static let calendarEvents = 40
    /// W12：你自己列表里没完成的提醒（只读）。
    static let ownReminders = 30
    /// W12：BetterCalendar 投影账本里「你删掉的 / 你改过时间的」各列几条。
    static let projectionNotes = 20
    static let actuals = 40
    static let journalEntries = 3
    static let journalChars = 500
    static let titleChars = 80
    /// 「最近推进」统计窗口（天）。
    static let progressDays = 7
    /// 「最近实际」与日记回看的逻辑日数（含今天）。
    static let recentDays = 3
    /// 系统日历往后看几天（不含今天）。
    static let calendarAheadDays = 3
    /// W18：未来几天（不含今天）的计划块总数上限；你的日历「已占用」条数上限。
    static let upcomingBlocks = 120
    static let occupied = 80
}

/// 收集好的只读数据（来源 → DTO）。
struct AgentContextInput {
    struct Block { var title: String; var start: Date; var end: Date; var isFixed = false; var important = false
        /// W1：真改动（挪块）要用的身份与版本、截止。
        var id: UUID? = nil; var revision: String? = nil; var deadline: Date? = nil
        /// P4 Q6：图钉（你亲手放的位置，到这一刻前有效）；要动它的提案必须带越级理由。
        var pinnedUntil: Date? = nil }
    struct Run { var title: String; var start: Date; var pausedSeconds: TimeInterval = 0; var timingStyle: String? = nil }
    struct Running { var foreground: Run?; var background: [Run] = []; var onBreak = false }
    struct PoolEntry {
        var title: String
        var deadline: Date?
        var createdAt: Date
        var spilledFromDay: Date?
        var checkpointsDone = 0
        var checkpointsTotal = 0
        var nextCheckpoint: String?
        var lastCheckpointTitle: String?
        var lastCheckpointAt: Date?
        var recentMinutes = 0
        var lastWorkedAt: Date?
    }
    struct CalendarEvent { var title: String; var start: Date; var end: Date; var isAllDay = false; var calendar = "" }
    /// W18：你的日历里一件「已占用」的事（只读；排布规则用的就是这份）。linkedBlockId = 与之是同一件事的计划块。
    struct Occupied { var title: String; var start: Date; var end: Date; var calendar = ""; var linkedBlockId: UUID? = nil }
    /// W12：你自己列表里一条没完成的提醒（只读）。
    struct OwnReminderItem { var title: String; var due: Date?; var hasTime = true; var list = "" }
    struct Actual { var title: String; var start: Date; var end: Date }
    struct JournalDigest { var day: Date; var body: String; var mood: String?; var tags: [String] = []; var modifiedAt: Date }

    /// 一个来源的读取结果：条目或错误（失败显式写进上下文，不当成「没有」）。
    struct Read<T> { var items: [T] = []; var error: String? = nil }

    var now: Date
    /// W1：propose_change 真改动要用的目标身份与版本（事项 id/版本、本机计时状态版本）。
    var actionTargets: [String: Any]? = nil
    var today = Read<Block>()
    var running = Running()
    var todos = Read<PoolEntry>()
    var longterm = Read<PoolEntry>()
    var calendar = Read<CalendarEvent>()
    /// W12：系统提醒事项（你自己的列表，只读）。
    var ownReminders = Read<OwnReminderItem>()
    /// W12：BetterCalendar 投进提醒事项的东西里，你删掉 / 改过时间的（账本；nil = 没接或读不出）。
    var reminderLedger: ReminderProjectionLedger? = nil
    var reminderLedgerError: String? = nil
    var actuals = Read<Actual>()
    var journalAllowed = false
    var journal = Read<JournalDigest>()
    /// W13：设备活动摘要（已截断、带来源与时刻；nil = 没接活动记录）。构造见 ActivityContextSummary。
    var activity: [String: Any]? = nil
    /// W18：智能体排时间线（开关开着才附 planning 段）：明天起几天的计划块（带 id / 版本 / 图钉）+ 你的日历「已占用」。
    var planEditing = false
    var upcoming = Read<Block>()
    var occupied = Read<Occupied>()

    init(now: Date) { self.now = now }

    // 时间窗（纯函数，收集器与快照共用）
    var logicalDayStart: Date { DayContext.logicalStartOfDay(now) }
    /// 系统日历：今天（日历日）0 点起 + 未来 3 天。
    var calendarWindow: DateInterval {
        let lo = Calendar.current.startOfDay(for: now)
        let hi = Calendar.current.date(byAdding: .day, value: AgentContextLimits.calendarAheadDays + 1, to: lo) ?? lo
        return DateInterval(start: lo, end: max(lo, hi))
    }
    /// W18：可排范围（今天起 PlanEditRules.horizonDays 个逻辑日）。
    var planningWindow: DateInterval { PlanEditRules.window(now: now, horizon: PlanEditRules.horizonDays) }
    /// W18：明天起的逻辑日标签。
    var upcomingLabels: [Date] {
        (1...PlanEditRules.horizonDays).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: logicalDayStart) }
    }
    /// 最近实际 / 日记：最近 3 个逻辑日（含今天）起点 → 现在。
    var recentWindow: DateInterval {
        let label = Calendar.current.date(byAdding: .day, value: -(AgentContextLimits.recentDays - 1), to: logicalDayStart) ?? logicalDayStart
        let lo = DayContext.logicalWindow(forLabel: label).start   // 逻辑日从日界线（凌晨 4 点）起算
        return DateInterval(start: lo, end: max(lo, now))
    }
}

/// 写给智能体的快照（只读副本；真相仍在 BetterCalendar）。
enum AgentBridgeContext {
    static func snapshot(_ input: AgentContextInput) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current   // 带本地时差，智能体不必再换算
        let t: (Date) -> String = { iso.string(from: $0) }
        let opt: (Date?) -> Any = { $0.map { iso.string(from: $0) } ?? NSNull() }
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        let asOf = t(input.now)
        let window: (DateInterval) -> [String: Any] = { ["start": t($0.start), "end": t($0.end)] }

        var context: [String: Any] = [
            "schemaVersion": 1, "contextRevision": 2, "writtenAt": asOf, "timeZone": TimeZone.current.identifier,
            "synthetic": false, "readOnly": true, "device": ProposalDevice.label, "deviceId": ProposalDevice.id,
        ]

        // 今天的计划块（绿色计划的真相源）。字段 blocks / start / end（HH:mm）保持 v1 兼容。
        let blockJSON: (AgentContextInput.Block) -> [String: Any] = { b in
            var o: [String: Any] = ["title": clip(b.title), "start": hm.string(from: b.start), "end": hm.string(from: b.end),
             "startAt": t(b.start), "endAt": t(b.end), "fixed": b.isFixed, "important": b.important]
            if let id = b.id { o["id"] = id.uuidString }
            if let r = b.revision { o["revision"] = r }
            o["deadline"] = b.deadline.map(t) ?? NSNull()
            if let p = b.pinnedUntil { o["pinnedUntil"] = t(p) }   // P4：有此键 = 图钉，动它须越级
            return o
        }
        var today = section(source: "BetterCalendar 计划（PlanStore，今天这个逻辑日）", asOf: asOf, read: input.today,
                            limit: AgentContextLimits.todayBlocks, key: "blocks", map: blockJSON)
        today["logicalDayStart"] = t(input.logicalDayStart)
        today["day"] = PlanEditRules.dayKey(input.logicalDayStart)   // W18：blockCreate / planDay 的 day 用这个格式
        context["today"] = today
        if let targets = input.actionTargets { context["actionTargets"] = targets }

        // 当前计时（前台）。running 保持 v1 形状：null 或 {title, startedAt}，另补来源与细节。
        let run: (AgentContextInput.Run) -> [String: Any] = { r in
            var o: [String: Any] = ["title": clip(r.title), "startedAt": t(r.start), "pausedSeconds": Int(r.pausedSeconds)]
            if let s = r.timingStyle { o["timingStyle"] = s }
            return o
        }
        if let fg = input.running.foreground {
            var o = run(fg)
            o["source"] = "BetterCalendar 执行陪伴（本机计时）"; o["asOf"] = asOf; o["onBreak"] = input.running.onBreak
            context["running"] = o
        } else {
            context["running"] = NSNull()
        }
        context["parallelRunning"] = ["source": "BetterCalendar 执行陪伴（同时在做的后台计时）", "asOf": asOf,
                                      "onBreak": input.running.onBreak, "items": input.running.background.map(run)] as [String: Any]

        // 待办池 + 长期事项（同一池的两个分区）。
        let pool: (AgentContextInput.PoolEntry) -> [String: Any] = { p in
            var o: [String: Any] = ["title": clip(p.title), "deadline": opt(p.deadline), "createdAt": t(p.createdAt),
                                    "recentMinutes": p.recentMinutes, "lastWorkedAt": opt(p.lastWorkedAt)]
            if p.spilledFromDay != nil { o["spilledFromDay"] = opt(p.spilledFromDay) }
            if p.checkpointsTotal > 0 {
                o["stage"] = ["done": p.checkpointsDone, "total": p.checkpointsTotal,
                              "next": p.nextCheckpoint.map { clip($0) } ?? NSNull(),
                              "lastReached": p.lastCheckpointTitle.map { clip($0) } ?? NSNull(),
                              "lastReachedAt": opt(p.lastCheckpointAt)] as [String: Any]
            }
            return o
        }
        context["pool"] = [
            "source": "BetterCalendar 待办池与长期事项（LongTaskStore，在途条目）", "asOf": asOf,
            "recentWindowDays": AgentContextLimits.progressDays,
            "note": "recentMinutes / lastWorkedAt = 最近 \(AgentContextLimits.progressDays) 天计时投入；stage = 命名阶段（检查点）推进",
            "todo": section(source: "待办区", asOf: asOf, read: input.todos, limit: AgentContextLimits.todos, map: pool),
            "longterm": section(source: "长期区", asOf: asOf, read: input.longterm, limit: AgentContextLimits.longterm, map: pool),
        ] as [String: Any]

        // 系统日历（今天 + 未来 3 天）。
        var calendar = section(source: "系统日历（只读；不含 BetterCalendar 自建的绿/蓝/橙日历）", asOf: asOf, read: input.calendar,
                               limit: AgentContextLimits.calendarEvents, key: "events") { e in
            ["title": clip(e.title), "start": t(e.start), "end": t(e.end), "allDay": e.isAllDay, "calendar": clip(e.calendar)] as [String: Any]
        }
        calendar["window"] = window(input.calendarWindow)
        context["calendar"] = calendar

        // W12：系统提醒事项（Jason 自己的列表，只读、从不修改；不含 BetterCalendar 自己那本）。
        var reminders = section(source: "系统提醒事项（只读）", asOf: asOf, read: input.ownReminders,
                                limit: AgentContextLimits.ownReminders, key: "items") { r in
            ["title": clip(r.title), "due": opt(r.due), "hasTime": r.hasTime, "list": clip(r.list)] as [String: Any]
        }
        reminders["note"] = "Jason 自己提醒列表里没完成的提醒：当作现实与上下文，只读、从不修改（有截止的在前）"
        context["reminders"] = reminders
        // W12：BetterCalendar 投进提醒事项的东西，Jason 在提醒事项里删掉 / 改过时间的——他的决定。
        var projected: [String: Any] = [
            "source": "BetterCalendar 投进提醒事项的提醒（投影账本）", "asOf": asOf,
            "note": "dismissed = Jason 在提醒事项里删掉了 =「不用提醒我了」：别再提议同一个提醒，除非他开口；retimed = 他改了提醒时间：按他的，不要改回",
        ]
        if let ledger = input.reminderLedger {
            let dismissed = ledger.dismissed, retimed = ledger.retimed
            projected["dismissed"] = dismissed.prefix(AgentContextLimits.projectionNotes).map { e -> [String: Any] in
                ["title": clip(e.title), "kind": e.kind.rawValue, "dismissedAt": opt(e.dismissedAt)]
            }
            projected["retimed"] = retimed.prefix(AgentContextLimits.projectionNotes).map { e -> [String: Any] in
                ["title": clip(e.title), "kind": e.kind.rawValue, "yourTime": opt(e.userDueAt)]
            }
            projected["truncated"] = dismissed.count > AgentContextLimits.projectionNotes || retimed.count > AgentContextLimits.projectionNotes
        }
        if let error = input.reminderLedgerError { projected["error"] = error }
        context["bcReminders"] = projected

        // 最近 3 天实际做了什么（蓝色实际真相源 = 计时完成 + 复盘补记 + 日历对账回流）。截断时保留最近的。
        var actuals = section(source: "BetterCalendar 实际（PlanStore 蓝色实际，最近 3 个逻辑日）", asOf: asOf, read: input.actuals,
                              limit: AgentContextLimits.actuals, keepLast: true) { a in
            ["title": clip(a.title), "start": t(a.start), "end": t(a.end),
             "minutes": max(0, Int(a.end.timeIntervalSince(a.start) / 60))] as [String: Any]
        }
        actuals["window"] = window(input.recentWindow)
        context["recentActuals"] = actuals

        // 日记：默认不给。
        if input.journalAllowed {
            var journal = section(source: "BetterCalendar 日记（Jason 已在多端审批面板允许）", asOf: asOf, read: input.journal,
                                  limit: AgentContextLimits.journalEntries, key: "entries") { j in
                let body = j.body.trimmingCharacters(in: .whitespacesAndNewlines)
                return ["day": t(DayContext.logicalStartOfDay(j.day)), "mood": j.mood ?? NSNull(), "tags": j.tags,
                        "excerpt": String(body.prefix(AgentContextLimits.journalChars)),
                        "excerptTruncated": body.count > AgentContextLimits.journalChars, "bodyChars": body.count,
                        "modifiedAt": t(j.modifiedAt)] as [String: Any]
            }
            journal["included"] = true
            journal["window"] = window(input.recentWindow)
            context["journal"] = journal
        } else {
            context["journal"] = ["included": false, "source": "BetterCalendar 日记", "asOf": asOf,
                                  "note": "Jason 未允许智能体读日记（多端审批面板开关，默认关）"] as [String: Any]
        }
        // W13：最近的设备活动（只用来理解情境与时机；App/网站名永不进复盘、留底、反馈）。全量走 MCP read_activity。
        if let activity = input.activity { context["recentActivity"] = activity }
        // W18：排时间线要看的（开关关着 = 不附，智能体就只能挪今天）。
        if input.planEditing {
            var planning: [String: Any] = [
                "source": "BetterCalendar 计划（PlanStore）+ 你的日历（只读，排布时当作已占用）", "asOf": asOf, "enabled": true,
                "horizonDays": PlanEditRules.horizonDays, "window": window(input.planningWindow),
                "note": "day 用 yyyy-MM-dd（逻辑日，凌晨 0–4 点属于前一天）。今天的块在 today.blocks；明天起的在 days[].blocks（id / revision / pinnedUntil 同 today）。occupied = Jason 自己日历里的安排：只读、当作已占用，App 校验时绝不让块和它重叠（linkedBlockId = 和那一块是同一件事，对那一块不算障碍）。",
            ]
            let kept = Array(input.upcoming.items.prefix(AgentContextLimits.upcomingBlocks))
            planning["days"] = input.upcomingLabels.map { label -> [String: Any] in
                ["day": PlanEditRules.dayKey(label), "name": PlanEditRules.dayName(label), "logicalDayStart": t(label),
                 "blocks": kept.filter { DayContext.logicalStartOfDay($0.start) == label }.map(blockJSON)]
            }
            planning["blocksTotal"] = input.upcoming.items.count
            planning["blocksTruncated"] = input.upcoming.items.count > kept.count
            if let e = input.upcoming.error { planning["blocksError"] = e }
            planning["occupied"] = section(source: "你的日历（只读，已按「排布时当作已占用的日历」设置过滤，不含全天）", asOf: asOf,
                                           read: input.occupied, limit: AgentContextLimits.occupied) { o in
                var row: [String: Any] = ["title": clip(o.title), "start": t(o.start), "end": t(o.end), "calendar": clip(o.calendar)]
                if let id = o.linkedBlockId { row["linkedBlockId"] = id.uuidString }
                return row
            }
            context["planning"] = planning
        } else {
            context["planning"] = ["enabled": false, "source": "BetterCalendar 设置", "asOf": asOf,
                                   "note": "「智能体排时间线」在设置里关着：只能挪今天的块（moveBlock / moveBlocks），不能加 / 改 / 删块，也不能动别的日子"] as [String: Any]
        }
        return context
    }

    /// 列表块：来源 + 时间 + 条目 + total + truncated（截断时附说明）+ 读取错误（显式）。
    private static func section<T>(source: String, asOf: String, read: AgentContextInput.Read<T>, limit: Int,
                                   key: String = "items", keepLast: Bool = false,
                                   map: (T) -> [String: Any]) -> [String: Any] {
        let kept = keepLast ? Array(read.items.suffix(limit)) : Array(read.items.prefix(limit))
        let truncated = read.items.count > kept.count
        var o: [String: Any] = ["source": source, "asOf": asOf, key: kept.map(map), "total": read.items.count, "truncated": truncated]
        if truncated { o["truncatedNote"] = "只列出\(keepLast ? "最近" : "前") \(kept.count) 条（共 \(read.items.count) 条）" }
        if let error = read.error { o["error"] = error }
        return o
    }

    private static func clip(_ s: String) -> String {
        s.count > AgentContextLimits.titleChars ? String(s.prefix(AgentContextLimits.titleChars)) + "…" : s
    }
}

/// 收集器（Mac 组装点注入；全部只读）。EventKit 读走 actor store 的 async 协议方法，不压主线程。
@MainActor final class AgentContextGatherer {
    private let planStore: (any PlanReading)?
    private let actualStore: (any ActualReading)?
    private let longTasks: LongTaskStore?
    private let calendarStore: (any CalendarReading)?
    private let journalStore: JournalStore?
    /// W12：系统提醒事项（只读：你自己的列表）+ BetterCalendar 投影账本（你删掉 / 改过时间的）。
    private let reminderStore: (any ReminderStore)?
    private let reminderLedger: () throws -> ReminderProjectionLedger?
    private let running: () -> AgentContextInput.Running
    private let journalAllowed: () -> Bool
    private let actionTargets: () -> [String: Any]?
    /// W18：智能体排时间线开关。
    private let planEditing: () -> Bool
    /// 同一来源同一错误只记一次日志（每 20 秒刷新，别刷屏）；错误本身每次都写进上下文。
    private var loggedErrors: [String: String] = [:]
    /// W13：设备活动摘要（组装点设置；nil = 不附）。
    var activitySummary: ((Date) async -> [String: Any]?)?

    init(planStore: (any PlanReading)?, actualStore: (any ActualReading)?, longTasks: LongTaskStore?, calendarStore: (any CalendarReading)?,
         journalStore: JournalStore?, reminderStore: (any ReminderStore)? = nil,
         reminderLedger: @escaping () throws -> ReminderProjectionLedger? = { try ReminderProjectionLedgerStore().load() },
         running: @escaping () -> AgentContextInput.Running,
         journalAllowed: @escaping () -> Bool = { AgentContextSettings.allowRecentJournal },
         actionTargets: @escaping () -> [String: Any]? = { nil },
         planEditing: @escaping () -> Bool = { PlanEditingSettings.enabled }) {
        self.actionTargets = actionTargets
        self.planEditing = planEditing
        self.planStore = planStore; self.actualStore = actualStore; self.longTasks = longTasks; self.calendarStore = calendarStore
        self.journalStore = journalStore; self.running = running; self.journalAllowed = journalAllowed
        self.reminderStore = reminderStore; self.reminderLedger = reminderLedger
    }

    func snapshot(now: Date = .now) async -> [String: Any] {
        AgentBridgeContext.snapshot(await gather(now: now))
    }

    func gather(now: Date) async -> AgentContextInput {
        var input = AgentContextInput(now: now)
        input.actionTargets = actionTargets()
        // 今天的计划
        if let planStore {
            do {
                input.today.items = try planStore.plannedBlocks(on: input.logicalDayStart).sorted { $0.start < $1.start }.map {
                    .init(title: $0.title, start: $0.start, end: $0.end, isFixed: $0.isFixed, important: $0.priority == .important,
                          id: $0.id, revision: ProposalRevision.block($0), deadline: $0.deadline,
                          pinnedUntil: $0.isPinned(at: input.now) ? $0.pinnedUntil : nil)
                }
            } catch { input.today.error = fail("今天的计划", error) }
        }
        input.running = running()
        // W18：明天起几天的计划 + 你的日历「已占用」（与排布规则用的是同一份：同样按设置过滤、同样的关联）
        input.planEditing = planEditing()
        if input.planEditing {
            var windowBlocks: [ScheduledBlock] = []
            if let planStore {
                do {
                    windowBlocks = try planStore.plannedBlocks(onLabels: [input.logicalDayStart] + input.upcomingLabels)
                    input.upcoming.items = windowBlocks.filter { DayContext.logicalStartOfDay($0.start) != input.logicalDayStart }.map {
                        .init(title: $0.title, start: $0.start, end: $0.end, isFixed: $0.isFixed, important: $0.priority == .important,
                              id: $0.id, revision: ProposalRevision.block($0), deadline: $0.deadline,
                              pinnedUntil: $0.isPinned(at: input.now) ? $0.pinnedUntil : nil)
                    }
                } catch { input.upcoming.error = fail("未来几天的计划", error) }
            }
            if let calendarStore {
                do {
                    let busy = ExternalCalendarSettings.busy(try await calendarStore.externalEvents(in: input.planningWindow),
                                                             excluding: ExternalCalendarSettings.excludedTitles)
                        .filter { $0.end > $0.start }
                    let links = ExternalEventLinker.links(blocks: windowBlocks, events: busy)
                    input.occupied.items = busy.sorted { $0.start < $1.start }.map { e in
                        .init(title: e.title, start: e.start, end: e.end, calendar: e.calendarTitle, linkedBlockId: links.first { $0.value == e }?.key)
                    }
                } catch { input.occupied.error = fail("你的日历（已占用）", error) }
            }
        }
        // 待办池 / 长期事项（缓存列表 + 一次批量算最近推进）
        if let longTasks {
            let todos = longTasks.todoItems(), longterm = longTasks.active()
            var progress: [UUID: LongTaskStore.RecentProgress] = [:]
            do {
                let since = Calendar.current.date(byAdding: .day, value: -AgentContextLimits.progressDays, to: now) ?? now
                progress = try longTasks.recentProgress(for: todos + longterm, since: since)
            } catch {
                let e = fail("最近推进", error)
                input.todos.error = e; input.longterm.error = e
            }
            let entry: (LongTask) -> AgentContextInput.PoolEntry = { task in
                let cps = task.sortedCheckpoints
                let reached = cps.filter { $0.doneAt != nil }
                let last = reached.max { ($0.doneAt ?? .distantPast) < ($1.doneAt ?? .distantPast) }
                let p = progress[task.id]
                return .init(title: task.title, deadline: task.deadline, createdAt: task.createdAt, spilledFromDay: task.spilledFromDay,
                             checkpointsDone: reached.count, checkpointsTotal: cps.count, nextCheckpoint: task.nextCheckpoint?.title,
                             lastCheckpointTitle: last?.title, lastCheckpointAt: last?.doneAt,
                             recentMinutes: p?.minutes ?? 0, lastWorkedAt: p?.lastWorkedAt)
            }
            input.todos.items = todos.map(entry)
            input.longterm.items = longterm.map(entry)
        }
        // 最近 3 个逻辑日的实际（蓝色实际真相源；一天一次批量读）
        if let actualStore {
            do {
                var items: [AgentContextInput.Actual] = []
                for offset in stride(from: AgentContextLimits.recentDays - 1, through: 0, by: -1) {
                    let label = Calendar.current.date(byAdding: .day, value: -offset, to: input.logicalDayStart) ?? input.logicalDayStart
                    items += try actualStore.actualBlocks(on: label).map { .init(title: $0.title, start: $0.start, end: $0.end) }
                }
                input.actuals.items = items.filter { $0.start <= now }.sorted { $0.start < $1.start }
            } catch { input.actuals.error = fail("最近实际", error) }
        }
        // 系统日历（EventKit actor，async，不压主线程）
        if let calendarStore {
            do { input.calendar.items = try await calendarStore.systemEvents(in: input.calendarWindow).map {
                    .init(title: $0.title, start: $0.start, end: $0.end, isAllDay: $0.isAllDay, calendar: $0.calendarTitle)
                }
            } catch { input.calendar.error = fail("系统日历", error) }
        }
        // W12：系统提醒事项（你自己的列表；不弹权限框，没授权 = 显式错误）+ BetterCalendar 投影账本
        if let reminderStore {
            do { input.ownReminders.items = try await reminderStore.ownOpenReminders().map {
                    .init(title: $0.title, due: $0.due, hasTime: $0.hasTime, list: $0.list)
                }
            } catch { input.ownReminders.error = fail("系统提醒事项", error) }
            do { input.reminderLedger = try reminderLedger() } catch { input.reminderLedgerError = fail("提醒投影账本", error) }
        }
        // 日记：只有 Jason 允许时才读（关着时连读都不读）
        input.journalAllowed = journalAllowed()
        if input.journalAllowed, let journalStore {
            do {
                input.journal.items = try journalStore.entries(since: input.recentWindow.start).map {
                    .init(day: $0.date, body: $0.body, mood: $0.mood, tags: $0.tags, modifiedAt: $0.modifiedAt)
                }
            } catch { input.journal.error = fail("日记", error) }
        }
        if let activitySummary { input.activity = await activitySummary(now) }
        clearRecovered(input)
        return input
    }

    private func fail(_ what: String, _ error: Error) -> String {
        let message = "读取\(what)失败：\(error.localizedDescription)"
        if loggedErrors[what] != message {
            loggedErrors[what] = message
            DevLog.shared.warn("智能体上下文", message)
        }
        return message
    }

    /// 恢复后清掉记录，下次再失败会重新记一条。
    private func clearRecovered(_ input: AgentContextInput) {
        let failing: [String: String?] = ["今天的计划": input.today.error, "最近推进": input.todos.error,
                                          "系统日历": input.calendar.error, "最近实际": input.actuals.error, "日记": input.journal.error,
                                          "系统提醒事项": input.ownReminders.error, "提醒投影账本": input.reminderLedgerError,
                                          "未来几天的计划": input.upcoming.error, "你的日历（已占用）": input.occupied.error]
        for (what, error) in failing where error == nil { loggedErrors[what] = nil }
    }
}

extension AgentBridgeContext {
    /// propose_change 真改动要用的目标身份与版本（W1）：事项 id/版本、本机计时状态版本。
    /// 计划块的 id/版本在 today.blocks 里。只读副本；版本过时的提案会被 App 拒绝。
    static func actionTargets(longTasks: LongTaskStore?, timer: ProposalTimerState?) -> [String: Any] {
        let items = (longTasks.map { $0.todoItems() + $0.active() + $0.doneItems().prefix(20) } ?? []).map { t -> [String: Any] in
            ["id": t.id.uuidString, "revision": ProposalRevision.item(t), "title": t.title,
             "zone": t.poolZone.rawValue, "status": t.status.rawValue, "hasNote": !t.note.isEmpty]
        }
        var targets: [String: Any] = ["items": items, "deviceId": ProposalDevice.id]
        // W8 D3：最近见过的设备（提醒/闹钟的 targetDevice 从这里取；闹钟只能设在 platform=iOS 的设备上）。
        let iso = ISO8601DateFormatter()
        targets["devices"] = KnownDevices.all().map { d -> [String: Any] in
            ["id": d.id, "label": d.label, "platform": d.platform, "lastSeenAt": iso.string(from: d.seenAt), "isThisDevice": d.id == ProposalDevice.id]
        }
        targets["timer"] = timer.map { t -> [String: Any] in
            ["phase": t.phase.rawValue, "title": t.title ?? NSNull(), "blockId": t.blockId?.uuidString ?? NSNull(), "revision": t.revision]
        } ?? NSNull()
        return targets
    }
}
