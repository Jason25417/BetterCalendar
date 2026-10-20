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
//  重复日程的删除、重复提醒的完成、全天日程改时间。重复日程改动必须写明范围（只这一次 / 这一次及以后），默认只这一次。
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
    /// 删（只这一次；重复日程的删除规则里已拒）。
    func delete(_ ref: YourEventRef) async throws
    /// 撤销删除：按快照原样重建（同名日历、同一账户），返回新建后的快照。
    func recreate(_ snapshot: YourEventSnapshot) async throws -> YourEventSnapshot
    func reminder(_ externalID: String) async throws -> YourReminderSnapshot
    func apply(_ edit: YourReminderEdit) async throws -> YourReminderSnapshot
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

    static func checkDelete(_ s: YourEventSnapshot) throws {
        if let why = eventBlocked(s.facts, title: s.title, calendar: s.calendarTitle) { throw ProposalExecutionError.invalid(why) }
        if s.facts.isRecurring {
            throw ProposalExecutionError.invalid("「\(s.title)」是重复日程：删除请你自己在日历里做（撤销没法把这一次或整个系列原样恢复）")
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
        if let done = e.done {
            if done == s.isCompleted { e.done = nil }
            else if done, s.facts.isRecurring {
                throw ProposalExecutionError.invalid("「\(s.title)」是重复提醒：标完成会生成下一次，撤销没法原样恢复，请你自己在提醒事项里勾")
            }
        }
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

    static func eventChanges(_ s: YourEventSnapshot, _ e: YourEventEdit) -> [ProposalChange] {
        var out = [ProposalChange.escalationSubject("改的是你自己设的日程：《\(s.title)》（日历「\(s.calendarTitle)」）")]
        if s.facts.isRecurring { out.append(ProposalChange(field: "重复日程：\(e.span.label)", before: nil, after: nil)) }
        if let t = e.title { out.append(ProposalChange(field: "日程标题", before: s.title, after: t)) }
        if let start = e.start, let end = e.end {
            out.append(ProposalChange(field: "「\(e.title ?? s.title)」时间", before: when(s.start, s.end, allDay: false), after: when(start, end, allDay: false)))
        }
        if let n = e.notes {
            out.append(ProposalChange(field: "「\(e.title ?? s.title)」备注", before: (s.notes ?? "").isEmpty ? "（空）" : s.notes, after: n.isEmpty ? "（空）" : n))
        }
        out.append(ProposalChange(field: "批准后可一键撤销：按改之前的样子原样改回（你之后在日历里又改过就不撤）", before: nil, after: nil))
        return out
    }

    static func deleteChanges(_ s: YourEventSnapshot) -> [ProposalChange] {
        [ProposalChange.escalationSubject("删的是你自己设的日程：《\(s.title)》（日历「\(s.calendarTitle)」）"),
         ProposalChange(field: "日程", before: "\(s.title)（\(when(s.start, s.end, allDay: s.isAllDay))）", after: nil),
         ProposalChange(field: "批准后可一键撤销：按删之前的样子原样重建（同一本日历；苹果日历里会是一条新建的同内容日程）", before: nil, after: nil)]
    }

    static func reminderChanges(_ s: YourReminderSnapshot, _ e: YourReminderEdit) -> [ProposalChange] {
        var out = [ProposalChange.escalationSubject("改的是你自己的提醒：《\(s.title)》（列表「\(s.listTitle)」）")]
        if let t = e.title { out.append(ProposalChange(field: "提醒标题", before: s.title, after: t)) }
        if let d = e.due { out.append(ProposalChange(field: "「\(e.title ?? s.title)」截止", before: due(s.due, hasTime: s.hasTime), after: due(d, hasTime: s.hasTime))) }
        if let done = e.done { out.append(ProposalChange(field: "「\(e.title ?? s.title)」", before: s.isCompleted ? "已完成" : "未完成", after: done ? "已完成" : "未完成")) }
        out.append(ProposalChange(field: "批准后可一键撤销：原样改回（你之后在提醒事项里又改过就不撤）", before: nil, after: nil))
        return out
    }
}

extension ProposalChange {
    /// 越级点名行的前缀（图钉 / 固定安排 / 你的东西共用一个越级概念）：审批卡把这些行放进橙色越级横条。
    nonisolated static let escalationMarker = "⚠️ "
    nonisolated static func escalationSubject(_ text: String) -> ProposalChange {
        ProposalChange(field: escalationMarker + text, before: nil, after: nil)
    }
    nonisolated var isEscalationSubject: Bool { field.hasPrefix(Self.escalationMarker) && before == nil && after == nil }
}
