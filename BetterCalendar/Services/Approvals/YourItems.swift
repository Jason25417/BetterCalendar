//
//  YourItems.swift
//  BetterCalendar
//
//  W32（Jason 2026-10-19/20）：越级审批「你的东西」——你自己在苹果日历里的日程、你自己提醒事项里的提醒。
//  原则 8「谁的东西谁做主 + 审慎越级」：智能体可以**提议**改它们，每一份都是越级提案——
//    · 一律要你亲自批准（PreauthPolicy：ownership == .yours 永远不被规则放行）；
//    · 审批卡橙色越级横条点名「改的是你自己设的日程：《标题》」+ 改动前 → 改动后；
//    · 执行前把要动的字段全部拍快照，一键撤销 = 按快照原样改回（删除 = 按快照原样重建）。
//  这里只放纯数据 + 纯规则（可单测）；真写 EventKit 的唯一一处 = EventKitYourItemsWriter（只注入给审批执行器）。
//  解释并拒绝（原因可见）：别人发来的邀请 / 有其他参与者的日程、只读或订阅日历、BetterCalendar 自家日历与提醒列表里的、
//  全天日程改时间。重复日程改动 / 删除必须写明范围（只这一次 / 这一次及以后），默认只这一次。
//  W34（Jason 2026-10-21）：删重复日程（只这一次 → 撤销重建成一条独立日程，不回到系列；这一次及以后 → 撤销按原规则重建剩下的系列）、
//  删你的提醒（含重复提醒 = 整个系列；撤销按完整快照重建）、重复提醒标完成这一次（提醒事项排出下一次；不能一键撤销）。
//

import Foundation

// MARK: - 日历事件

/// 你的一条日程（跨设备定位：外部标识 + 这一次的开始时刻；重复日程的每一次共用外部标识）。
nonisolated struct YourEventRef: Codable, Equatable, Hashable, Sendable {
    var externalID: String
    var occurrenceStart: Date
}

/// 重复日程改动的范围（EventKit span）。
nonisolated enum YourEventSpan: String, Codable, Sendable, CaseIterable {
    /// 只改这一次（默认）
    case thisOccurrence
    /// 这一次及以后的都改
    case futureEvents
    var label: String { self == .thisOccurrence ? "只改这一次" : "这一次及以后的都改" }
    var deleteLabel: String { self == .thisOccurrence ? "只删这一次" : "删这一次及以后的" }
}

/// W34：重复规则的快照（EKRecurrenceRule 的可编码副本；撤销「删这一次及以后」/ 删重复提醒时按它重建）。
/// 结束条件只存日期：按次数结束的系列在删除时换算成「原本最后一次」的日期（见 EventKitYourItemsWriter）。
nonisolated struct YourRecurrenceRule: Codable, Equatable, Sendable {
    /// EKRecurrenceFrequency.rawValue（0 天 / 1 周 / 2 月 / 3 年）
    var frequency: Int
    var interval: Int = 1
    var firstDayOfTheWeek: Int = 0
    /// 星期几（1 = 周日 … 7 = 周六）+ 第几周（0 = 每周）
    var daysOfTheWeek: [Day]? = nil
    var daysOfTheMonth: [Int]? = nil
    var daysOfTheYear: [Int]? = nil
    var weeksOfTheYear: [Int]? = nil
    var monthsOfTheYear: [Int]? = nil
    var setPositions: [Int]? = nil
    var endDate: Date? = nil
    var occurrenceCount: Int? = nil

    nonisolated struct Day: Codable, Equatable, Sendable { var dayOfWeek: Int; var weekNumber: Int = 0 }

    /// 给人看：「每周」「每 2 天」……（只用于卡片，不参与执行）
    var label: String {
        let unit = ["天", "周", "个月", "年"][max(0, min(3, frequency))]
        let every = interval <= 1 ? "每" + (frequency == 2 ? "月" : unit) : "每 \(interval) \(unit)"
        if let endDate {
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"
            return every + "，到 " + f.string(from: endDate)
        }
        if let occurrenceCount { return every + "，共 \(occurrenceCount) 次" }
        return every
    }
}

/// 决定「能不能改」的事实（EventKit 读出来，规则只看这些）。
nonisolated struct YourEventFacts: Codable, Equatable, Sendable {
    /// 日历允许改内容（订阅日历 / 节假日 / 别人共享给你只读的 = false）
    var calendarWritable = true
    /// 组织者是别人（= 别人发来的邀请）；名字给人看
    var organizerIsOther = false
    var organizerName: String? = nil
    /// 除你之外还有参与者（改它会给他们发更新）
    var hasOtherAttendees = false
    /// 在 BetterCalendar 自家日历里（不带章 = 误存进来的你的日程；自家日历只由 CalendarSyncEngine 写）
    var inBetterCalendar = false
    var isRecurring = false
}

/// 执行前的快照：撤销按它原样改回（删除的撤销 = 按它原样重建）。只含我们会碰的字段 + 重建要用的字段。
nonisolated struct YourEventSnapshot: Codable, Equatable, Sendable {
    var ref: YourEventRef
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var notes: String?
    var location: String?
    var url: String?
    var calendarTitle: String
    /// 日历所在账户名（重建时在同名日历里挑同一账户的那本）
    var sourceTitle: String
    var timeZone: String?
    /// 相对提醒（秒，相对开始；重建时原样挂回）
    var alarmOffsets: [TimeInterval] = []
    var facts = YourEventFacts()
    /// W34：重建时挂回的重复规则（nil = 重建成一条独立日程）。只在「删这一次及以后」的撤销快照里有值；
    /// 版本串不含它（重复规则不是我们会改的字段）。
    var recurrence: [YourRecurrenceRule]? = nil

    /// 版本：任一会碰的字段变了就变（你在苹果日历里改过 → 执行 / 撤销都拒绝，不覆盖你的改动）。
    var revision: String {
        ProposalRevision.hash(["yourEvent", ref.externalID, title, ProposalRevision.ms(start), ProposalRevision.ms(end),
                               isAllDay ? "allDay" : "timed", notes ?? "", location ?? "", calendarTitle])
    }
}

/// 改你的一条日程（nil = 该项不改；notes 空串 = 清空备注）。时长改法：给 start（end 省略 = 保持原时长）。
nonisolated struct YourEventEdit: Codable, Equatable, Sendable {
    var ref: YourEventRef
    var span: YourEventSpan = .thisOccurrence
    var title: String? = nil
    var start: Date? = nil
    var end: Date? = nil
    var notes: String? = nil
    var expectedRevision: String? = nil

    var isEmpty: Bool { title == nil && start == nil && end == nil && notes == nil }
}

// MARK: - 提醒事项

nonisolated struct YourReminderFacts: Codable, Equatable, Sendable {
    var listWritable = true
    /// 在 BetterCalendar 自己那本提醒列表里（那本只由 ReminderProjector 写）
    var inBetterCalendarList = false
    var isRecurring = false
}

nonisolated struct YourReminderSnapshot: Codable, Equatable, Sendable {
    /// 提醒的外部标识（跨设备）
    var externalID: String
    var title: String
    var notes: String?
    var due: Date?
    /// 截止带具体时刻（只写了日期 = false；改时间保持同一粒度）
    var hasTime: Bool
    var isCompleted: Bool
    var listTitle: String
    /// 绝对时刻的提醒（改截止时，和原截止同一刻的那个跟着挪；撤销原样挪回）
    var absoluteAlarms: [Date] = []
    var facts = YourReminderFacts()
    // —— W34：删提醒的撤销快照（重建要用的全部 EventKit 能写的字段；旧记录没有这些键照常解码）——
    var startDate: Date? = nil
    var startHasTime: Bool? = nil
    /// 截止的时区（nil = 浮动时间）
    var dueTimeZone: String? = nil
    var priority: Int? = nil
    var url: String? = nil
    /// 相对截止的提醒（秒）
    var relativeAlarms: [TimeInterval]? = nil
    var recurrence: [YourRecurrenceRule]? = nil
    /// 列表所在账户名（重建时在同名列表里挑同一账户的那本）
    var sourceTitle: String? = nil
    /// 有位置提醒（EventKit 能读、但重建不挂回 → 卡片写明）
    var hasLocationAlarm: Bool? = nil

    var revision: String {
        ProposalRevision.hash(["yourReminder", externalID, title, notes ?? "", ProposalRevision.ms(due), hasTime ? "t" : "d",
                               isCompleted ? "done" : "open", listTitle])
    }
}

/// 改你的一条提醒：改名 / 改截止（只挪已有的截止，粒度不变）/ 标完成（done=false 只作撤销或你明说的「取消完成」）。
nonisolated struct YourReminderEdit: Codable, Equatable, Sendable {
    var externalID: String
    var title: String? = nil
    var due: Date? = nil
    var done: Bool? = nil
    var expectedRevision: String? = nil

    var isEmpty: Bool { title == nil && due == nil && done == nil }
}

// MARK: - 唯一写者（只注入给审批执行器）

nonisolated enum YourItemsError: Error, LocalizedError, Equatable {
    case notFound(String)
    case refused(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case let .notFound(s), let .refused(s), let .failed(s): s
        }
    }
}

/// 读写「你的」日程与提醒的窄缝：生产唯一实现 = EventKitYourItemsWriter（actor，不压主线程）；
/// **只有 ProposalActionExecutor 持有**（架构守卫单测 `yourItemsWriterStaysInApprovalExecutor` 锁住）。
/// 每次写都来自一份你批准过的提案（或你点的撤销）。BetterCalendar 自家日历 / 提醒列表永远拒绝（那里的唯一写者是投影）。
nonisolated protocol YourItemsWriting: AnyObject, Sendable {
    /// 读一条你的日程（找不到 / 不止一条对得上 → 抛错，不猜）。
    func event(_ ref: YourEventRef) async throws -> YourEventSnapshot
    /// 改：返回改完后的快照（ref 用改完后的外部标识与开始时刻）。
    func apply(_ edit: YourEventEdit) async throws -> YourEventSnapshot
    /// 删（W34：重复日程按 span：只这一次 / 这一次及以后）。返回撤销用的快照：只这一次 → 不带重复规则（重建成独立日程）；
    /// 这一次及以后 → 带原重复规则（按次数结束的换算成原本最后一次的日期）。不重复的日程 span 无意义。
    func delete(_ ref: YourEventRef, span: YourEventSpan) async throws -> YourEventSnapshot
    /// 撤销删除：按快照原样重建（同名日历、同一账户；快照带重复规则就重建成系列），返回新建后的快照。
    func recreate(_ snapshot: YourEventSnapshot) async throws -> YourEventSnapshot
    func reminder(_ externalID: String) async throws -> YourReminderSnapshot
    func apply(_ edit: YourReminderEdit) async throws -> YourReminderSnapshot
    /// W34：删你的一条提醒（重复提醒 = 整个系列）。返回删之前的完整快照（撤销按它重建）。
    func deleteReminder(_ externalID: String) async throws -> YourReminderSnapshot
    /// W34：撤销删提醒：按快照重建（同名列表、同一账户），返回新建后的快照（新标识）。
    func recreateReminder(_ snapshot: YourReminderSnapshot) async throws -> YourReminderSnapshot
}

// MARK: - 纯规则

nonisolated enum YourItemRules {
    static let titleLimit = 200
    static let notesLimit = 2000

    /// 这条日程根本不能由提案改（有值 = 给人看的原因）。删除与修改共用。
    static func eventBlocked(_ f: YourEventFacts, title: String, calendar: String) -> String? {
        if f.inBetterCalendar {
            return "「\(title)」在 BetterCalendar 自己的日历「\(calendar)」里——那本日历只由 BetterCalendar 的投影写；要让智能体改它，请先把它挪到你自己的日历"
        }
        if !f.calendarWritable { return "「\(title)」在只读日历「\(calendar)」里（订阅 / 节假日 / 别人只读共享），改不了" }
        if f.organizerIsOther {
            return "「\(title)」是\(f.organizerName.map { "「\($0)」" } ?? "别人")发来的邀请，只有组织者能改；要改请在日历里回复组织者"
        }
        if f.hasOtherAttendees { return "「\(title)」还有其他参与者，改它会给他们发更新；这种请你自己在日历里改" }
        return nil
    }

    /// 校验并规范化一次修改（返回规范化后的修改；抛错 = 拒收，原因可见）。
    static func checkEdit(_ s: YourEventSnapshot, _ edit: YourEventEdit) throws -> YourEventEdit {
        if let why = eventBlocked(s.facts, title: s.title, calendar: s.calendarTitle) { throw ProposalExecutionError.invalid(why) }
        var e = edit
        if let t = e.title {
            let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count <= titleLimit else { throw ProposalExecutionError.invalid("日程标题不能为空，且不超过 \(titleLimit) 字") }
            e.title = t == s.title ? nil : t
        }
        if let n = e.notes {
            guard n.count <= notesLimit else { throw ProposalExecutionError.invalid("备注不超过 \(notesLimit) 字") }
            e.notes = n == (s.notes ?? "") ? nil : n
        }
        if e.start != nil || e.end != nil {
            guard !s.isAllDay else { throw ProposalExecutionError.invalid("「\(s.title)」是全天日程：不改它的时间（只能改标题 / 备注）") }
            let start = e.start ?? s.start
            let end = e.end ?? start.addingTimeInterval(s.end.timeIntervalSince(s.start))
            guard end > start else { throw ProposalExecutionError.invalid("结束时间必须晚于开始时间") }
            if start == s.start && end == s.end { e.start = nil; e.end = nil } else { e.start = start; e.end = end }
        }
        if !s.facts.isRecurring { e.span = .thisOccurrence }   // 不重复的日程没有「以后」
        guard !e.isEmpty else { throw ProposalExecutionError.invalid("「\(s.title)」没有任何变化") }
        return e
    }

    /// W34：重复日程也能删（范围写明；撤销按范围重建，限制写在卡上）。快照放不下的超长备注拒收（撤销要按快照原样重建）。
    static func checkDelete(_ s: YourEventSnapshot) throws {
        if let why = eventBlocked(s.facts, title: s.title, calendar: s.calendarTitle) { throw ProposalExecutionError.invalid(why) }
        if (s.notes?.count ?? 0) > snapshotNotesLimit {
            throw ProposalExecutionError.invalid("「\(s.title)」的备注太长（超过 \(snapshotNotesLimit) 字），撤销快照放不下，请你自己在日历里删")
        }
    }

    /// 撤销快照里备注的上限（快照随提案存进 iCloud 的 JSON 载荷；防一条提案记录过大）。
    static let snapshotNotesLimit = 20_000

    /// W34：删你的一条提醒（重复提醒 = 整个系列）。
    static func checkReminderDelete(_ s: YourReminderSnapshot) throws {
        if let why = reminderBlocked(s) { throw ProposalExecutionError.invalid(why) }
        if (s.notes?.count ?? 0) > snapshotNotesLimit {
            throw ProposalExecutionError.invalid("「\(s.title)」的备注太长（超过 \(snapshotNotesLimit) 字），撤销快照放不下，请你自己在提醒事项里删")
        }
    }

    static func reminderBlocked(_ s: YourReminderSnapshot) -> String? {
        if s.facts.inBetterCalendarList {
            return "「\(s.title)」在 BetterCalendar 自己的提醒列表里（由 BetterCalendar 投影维护），不按「你的提醒」改"
        }
        if !s.facts.listWritable { return "「\(s.title)」所在的列表「\(s.listTitle)」是只读的，改不了" }
        return nil
    }

    static func checkEdit(_ s: YourReminderSnapshot, _ edit: YourReminderEdit) throws -> YourReminderEdit {
        if let why = reminderBlocked(s) { throw ProposalExecutionError.invalid(why) }
        var e = edit
        if let t = e.title {
            let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count <= titleLimit else { throw ProposalExecutionError.invalid("提醒标题不能为空，且不超过 \(titleLimit) 字") }
            e.title = t == s.title ? nil : t
        }
        if let d = e.due {
            guard let old = s.due else {
                throw ProposalExecutionError.invalid("「\(s.title)」没有截止时间：只能挪已有的截止，不新加（要提醒请用 reminder）")
            }
            let normalized = s.hasTime ? d : Calendar.current.startOfDay(for: d)
            e.due = normalized == (s.hasTime ? old : Calendar.current.startOfDay(for: old)) ? nil : normalized
        }
        // W34：重复提醒也能标完成——完成的是这一次，提醒事项排出下一次（不能一键撤销，卡上写明）。
        if let done = e.done, done == s.isCompleted { e.done = nil }
        if s.isCompleted, e.title != nil || e.due != nil {
            throw ProposalExecutionError.invalid("「\(s.title)」已经完成了：不改已完成提醒的标题 / 时间")
        }
        guard !e.isEmpty else { throw ProposalExecutionError.invalid("「\(s.title)」没有任何变化") }
        return e
    }

    // MARK: 给人看

    static func when(_ s: Date, _ e: Date, allDay: Bool) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        if allDay { f.dateFormat = "M月d日"; return f.string(from: s) + "（全天）" }
        f.dateFormat = "M月d日 HH:mm"
        let g = DateFormatter(); g.dateFormat = Calendar.current.isDate(s, inSameDayAs: e) ? "HH:mm" : "M月d日 HH:mm"
        g.locale = f.locale
        return f.string(from: s) + "–" + g.string(from: e)
    }

    static func due(_ d: Date?, hasTime: Bool) -> String {
        guard let d else { return "（没有截止）" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = hasTime ? "M月d日 HH:mm" : "M月d日"
        return f.string(from: d)
    }

    // MARK: 卡片：一句「做什么」+ 改动 + 一行后果（W34：每条信息只出现一次）

    static func eventEditHeadline(_ s: YourEventSnapshot, _ e: YourEventEdit) -> String {
        "改你的日程「\(s.title)」" + (s.facts.isRecurring ? "（重复日程，\(e.span.label)）" : "")
    }

    static func eventChanges(_ s: YourEventSnapshot, _ e: YourEventEdit) -> [ProposalChange] {
        var out = [ProposalChange.escalationSubject("改的是你自己设的日程：《\(s.title)》（日历「\(s.calendarTitle)」）")]
        if let t = e.title { out.append(ProposalChange(field: "标题", before: s.title, after: t)) }
        if let start = e.start, let end = e.end {
            out.append(ProposalChange(field: "时间", before: when(s.start, s.end, allDay: false), after: when(start, end, allDay: false)))
        }
        if let n = e.notes {
            out.append(ProposalChange(field: "备注", before: (s.notes ?? "").isEmpty ? "（空）" : s.notes, after: n.isEmpty ? "（空）" : n))
        }
        let split = s.facts.isRecurring && e.span == .futureEvents ? "苹果日历会从这一次起把系列分成两段 · " : ""
        out.append(.consequence(split + "可一键撤销：原样改回（你之后在日历里又改过就不撤）"))
        return out
    }

    static func deleteHeadline(_ s: YourEventSnapshot, span: YourEventSpan) -> String {
        let at = when(s.start, s.end, allDay: s.isAllDay)
        guard s.facts.isRecurring else { return "删除你的日程「\(s.title)」（\(at)）" }
        return span == .thisOccurrence ? "删除重复日程「\(s.title)」的这一次（\(at)）"
                                       : "删除重复日程「\(s.title)」这一次及以后（从 \(at) 起）"
    }

    static func deleteChanges(_ s: YourEventSnapshot, span: YourEventSpan) -> [ProposalChange] {
        let undo: String
        if !s.facts.isRecurring { undo = "可一键撤销：按原样重建（苹果日历里是一条新建的同内容日程）" }
        else if span == .thisOccurrence { undo = "可一键撤销：重建成一条独立日程，不会回到重复系列里" }
        else { undo = "可一键撤销：按原来的重复规则重建剩下的系列（之后单独改过的那几次按系列原样回来）" }
        return [ProposalChange.escalationSubject("删的是你自己设的日程：《\(s.title)》（日历「\(s.calendarTitle)」）"),
                .consequence("删掉后这段时间不再算已占用 · " + undo)]
    }

    /// 只标完成 / 取消完成（没改名、没改截止）——标题就说清了，不再列「未完成 → 已完成」。
    static func reminderHeadline(_ s: YourReminderSnapshot, _ e: YourReminderEdit) -> String {
        if let done = e.done, e.title == nil, e.due == nil {
            if done { return s.facts.isRecurring ? "标完成你的重复提醒「\(s.title)」这一次" : "标完成你的提醒「\(s.title)」" }
            return "取消完成你的提醒「\(s.title)」"
        }
        return "改你的提醒「\(s.title)」"
    }

    /// 重复提醒标完成：完成这一次、提醒事项排出下一次——这一项没法一键撤销。
    static func isRecurringCompletion(_ s: YourReminderSnapshot, _ e: YourReminderEdit) -> Bool { e.done == true && s.facts.isRecurring }

    static let recurringCompletionUndoReason = "重复提醒标完成后，提醒事项已经排出下一次，没法原样撤销；要撤请你在提醒事项「已完成」里取消勾选这一次"

    static func reminderChanges(_ s: YourReminderSnapshot, _ e: YourReminderEdit) -> [ProposalChange] {
        var out = [ProposalChange.escalationSubject("改的是你自己的提醒：《\(s.title)》（列表「\(s.listTitle)」）")]
        if let t = e.title { out.append(ProposalChange(field: "标题", before: s.title, after: t)) }
        if let d = e.due { out.append(ProposalChange(field: "截止", before: due(s.due, hasTime: s.hasTime), after: due(d, hasTime: s.hasTime))) }
        let doneOnly = e.title == nil && e.due == nil
        if let done = e.done, !doneOnly { out.append(ProposalChange(field: "完成", before: s.isCompleted ? "已完成" : "未完成", after: done ? "已完成" : "未完成")) }
        if isRecurringCompletion(s, e) {
            out.append(.consequence("完成的是这一次，下一次照常出现 · 不能一键撤销（要撤请你在提醒事项里取消勾选）"))
        } else {
            out.append(.consequence("可一键撤销：原样改回（你之后在提醒事项里又改过就不撤）"))
        }
        return out
    }

    static func reminderDeleteHeadline(_ s: YourReminderSnapshot) -> String {
        "删除你的提醒「\(s.title)」" + (s.facts.isRecurring ? "（重复提醒，整个系列）" : "")
    }

    /// 撤销限制如实写（EventKit 写不了子任务 / 标签 / 旗标 / 附件；位置提醒不挂回；重复提醒的完成记录不恢复）。
    static func reminderDeleteChanges(_ s: YourReminderSnapshot) -> [ProposalChange] {
        var lost = ["子任务", "标签", "旗标", "附件"]
        if s.hasLocationAlarm == true { lost.append("位置提醒") }
        if s.facts.isRecurring { lost.append("以前各次的完成记录") }
        return [ProposalChange.escalationSubject("删的是你自己的提醒：《\(s.title)》（列表「\(s.listTitle)」）"),
                .consequence("可一键撤销：按原样重建成新的一条（\(lost.joined(separator: "、"))不会恢复）")]
    }
}

extension ProposalChange {
    /// 越级点名行的前缀（图钉 / 固定安排 / 你的东西共用一个越级概念）：审批卡把这些行放进橙色越级横条。
    nonisolated static let escalationMarker = "⚠️ "
    nonisolated static func escalationSubject(_ text: String) -> ProposalChange {
        ProposalChange(field: escalationMarker + text, before: nil, after: nil)
    }
    nonisolated var isEscalationSubject: Bool { field.hasPrefix(Self.escalationMarker) && before == nil && after == nil }
    /// W34：后果行（「进回收站 30 天可恢复 · 可一键撤销」这类）——没有前后值、也不是越级点名。卡片上把它们合成一行。
    nonisolated static func consequence(_ text: String) -> ProposalChange { ProposalChange(field: text, before: nil, after: nil) }
    nonisolated var isConsequence: Bool { before == nil && after == nil && !isEscalationSubject }
}
