//
//  EventKitYourItemsWriter.swift
//  BetterCalendar
//
//  W32：「你的」日程与提醒的唯一写者（越级审批执行用）。架构约定：
//    · 只注入给 ProposalActionExecutor（架构守卫单测锁住）；每次写都来自你批准的提案或你点的撤销；
//    · BetterCalendar 自家的日历（计划/实际/预览，含另一个通道的）与自家提醒列表一律拒绝——那里的唯一写者是
//      CalendarSyncEngine / ReminderProjector，这个写者绝不越界；
//    · actor（不压主线程，见 [[eventkit-store-actor-not-mainactor]]）；EKEventStore 懒加载（init 零副作用）；
//    · 测试宿主里一律拒写（EventKitWriteGuard，W23b）；不弹权限框：没有完整权限 = 抛错，原因可见。
//  规则（能不能改）在 YourItemRules（纯函数，可单测）；这里只做 EventKit ↔ 快照互转与读写。
//

import Foundation
import EventKit

actor EventKitYourItemsWriter: YourItemsWriting {
    private lazy var store = EKEventStore()
    /// BetterCalendar 两个通道的全部自家日历名（本通道 + 另一个通道）。
    private let ourCalendars: Set<String> = {
        let labels = EventKitCalendarStore.calendarLabels.map(\.1)
        return Set(AppChannel.allCases.flatMap { c in labels.map { c.calendarTitle($0) } })
    }()
    private let ourReminderLists: Set<String> = Set(AppChannel.allCases.map(\.remindersListTitle))

    // MARK: 日程

    func event(_ ref: YourEventRef) async throws -> YourEventSnapshot {
        try snapshot(try find(ref))
    }

    func apply(_ edit: YourEventEdit) async throws -> YourEventSnapshot {
        try await EventKitWriteGuard.refuseIfTestHost("改你的日程「\(edit.ref.externalID.prefix(12))」")
        let ev = try find(edit.ref)
        try guardOurs(ev)
        if let t = edit.title { ev.title = t }
        if let n = edit.notes { ev.notes = n.isEmpty ? nil : n }
        if let s = edit.start { ev.startDate = s }
        if let e = edit.end { ev.endDate = e }
        do {
            try store.save(ev, span: edit.span == .futureEvents ? .futureEvents : .thisEvent, commit: true)
        } catch {
            store.reset()
            throw YourItemsError.failed("日历没写进去：\(error.localizedDescription)")
        }
        return try snapshot(ev)
    }

    func delete(_ ref: YourEventRef, span: YourEventSpan) async throws -> YourEventSnapshot {
        try await EventKitWriteGuard.refuseIfTestHost("删你的日程「\(ref.externalID.prefix(12))」")
        let ev = try find(ref)
        try guardOurs(ev)
        var undo = try snapshot(ev)
        let future = span == .futureEvents && ev.hasRecurrenceRules
        if future {
            // 撤销快照带原重复规则；按次数结束的换算成「原本最后一次」的日期（从这一次起重建的系列在原本会结束的那天结束）
            undo.recurrence = (ev.recurrenceRules ?? []).map { rule in
                var r = YourRecurrenceRule(rule)
                if rule.recurrenceEnd?.occurrenceCount ?? 0 > 0 { r.occurrenceCount = nil; r.endDate = lastOccurrence(of: ev) }
                return r
            }
        }
        do { try store.remove(ev, span: future ? .futureEvents : .thisEvent, commit: true) } catch {
            store.reset()
            throw YourItemsError.failed("日程没删掉：\(error.localizedDescription)")
        }
        return undo
    }

    func recreate(_ s: YourEventSnapshot) async throws -> YourEventSnapshot {
        try await EventKitWriteGuard.refuseIfTestHost("重建你的日程「\(s.title)」")
        try access(.event)
        guard !ourCalendars.contains(s.calendarTitle) else { throw YourItemsError.refused("不往 BetterCalendar 自家日历里重建") }
        let candidates = store.calendars(for: .event).filter { $0.title == s.calendarTitle && $0.allowsContentModifications }
        guard let cal = candidates.first(where: { $0.source.title == s.sourceTitle }) ?? (candidates.count == 1 ? candidates.first : nil) else {
            throw YourItemsError.notFound("找不到原来的日历「\(s.calendarTitle)」（可能被删了或改了名），没有重建")
        }
        let ev = EKEvent(eventStore: store)
        ev.calendar = cal
        ev.title = s.title
        ev.startDate = s.start; ev.endDate = s.end; ev.isAllDay = s.isAllDay
        ev.notes = s.notes; ev.location = s.location
        ev.url = s.url.flatMap(URL.init(string:))
        ev.timeZone = s.timeZone.flatMap(TimeZone.init(identifier:))
        ev.alarms = s.alarmOffsets.map { EKAlarm(relativeOffset: $0) }
        if let rules = s.recurrence, !rules.isEmpty { ev.recurrenceRules = rules.map(\.ekRule) }
        do { try store.save(ev, span: .thisEvent, commit: true) } catch {
            store.reset()
            throw YourItemsError.failed("日程没重建成：\(error.localizedDescription)")
        }
        return try snapshot(ev)
    }

    // MARK: 提醒

    func reminder(_ externalID: String) async throws -> YourReminderSnapshot {
        snapshot(try findReminder(externalID))
    }

    func apply(_ edit: YourReminderEdit) async throws -> YourReminderSnapshot {
        try await EventKitWriteGuard.refuseIfTestHost("改你的提醒「\(edit.externalID.prefix(12))」")
        let r = try findReminder(edit.externalID)
        guard let list = r.calendar, !ourReminderLists.contains(list.title) else {
            throw YourItemsError.refused("不改 BetterCalendar 自己提醒列表里的提醒")
        }
        if let t = edit.title { r.title = t }
        if let d = edit.due {
            let old = Self.dueDate(r)
            let hasTime = r.dueDateComponents?.hour != nil
            let units: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            var comps = Calendar.current.dateComponents(units, from: d)
            comps.timeZone = r.dueDateComponents?.timeZone
            r.dueDateComponents = comps
            // 和原截止同一刻的绝对提醒跟着挪（提醒事项 App 自己就是这么设的）；别的提醒不动
            if let old, let alarms = r.alarms {
                for a in alarms where a.absoluteDate.map({ abs($0.timeIntervalSince(old)) < 1 }) == true { a.absoluteDate = d }
            }
        }
        if let done = edit.done { r.isCompleted = done }
        do { try store.save(r, commit: true) } catch {
            store.reset()
            throw YourItemsError.failed("提醒没写进去：\(error.localizedDescription)")
        }
        return snapshot(r)
    }

    func deleteReminder(_ externalID: String) async throws -> YourReminderSnapshot {
        try await EventKitWriteGuard.refuseIfTestHost("删你的提醒「\(externalID.prefix(12))」")
        let r = try findReminder(externalID)
        guard let list = r.calendar, !ourReminderLists.contains(list.title) else {
            throw YourItemsError.refused("不删 BetterCalendar 自己提醒列表里的提醒")
        }
        let undo = fullSnapshot(r)
        do { try store.remove(r, commit: true) } catch {
            store.reset()
            throw YourItemsError.failed("提醒没删掉：\(error.localizedDescription)")
        }
        return undo
    }

    func recreateReminder(_ s: YourReminderSnapshot) async throws -> YourReminderSnapshot {
        try await EventKitWriteGuard.refuseIfTestHost("重建你的提醒「\(s.title)」")
        try access(.reminder)
        guard !ourReminderLists.contains(s.listTitle) else { throw YourItemsError.refused("不往 BetterCalendar 自家提醒列表里重建") }
        let candidates = store.calendars(for: .reminder).filter { $0.title == s.listTitle && $0.allowsContentModifications }
        guard let list = candidates.first(where: { $0.source.title == s.sourceTitle }) ?? (candidates.count == 1 ? candidates.first : nil) else {
            throw YourItemsError.notFound("找不到原来的提醒列表「\(s.listTitle)」（可能被删了或改了名），没有重建")
        }
        let r = EKReminder(eventStore: store)
        r.calendar = list
        r.title = s.title
        r.notes = s.notes
        r.url = s.url.flatMap(URL.init(string:))
        r.priority = s.priority ?? 0
        let tz = s.dueTimeZone.flatMap(TimeZone.init(identifier:))
        func comps(_ d: Date, time: Bool) -> DateComponents {
            var c = Calendar.current.dateComponents(time ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: d)
            c.timeZone = tz
            return c
        }
        if let due = s.due { r.dueDateComponents = comps(due, time: s.hasTime) }
        if let start = s.startDate { r.startDateComponents = comps(start, time: s.startHasTime ?? s.hasTime) }
        r.alarms = s.absoluteAlarms.map { EKAlarm(absoluteDate: $0) } + (s.relativeAlarms ?? []).map { EKAlarm(relativeOffset: $0) }
        if let rules = s.recurrence, !rules.isEmpty { r.recurrenceRules = rules.map(\.ekRule) }
        do { try store.save(r, commit: true) } catch {
            store.reset()
            throw YourItemsError.failed("提醒没重建成：\(error.localizedDescription)")
        }
        return snapshot(r)
    }

    // MARK: 内部

    /// 这个系列「原本最后一次」的开始（只用于按次数结束的系列；EventKit 查询窗口最长约 4 年，查不到就用这一次）。
    private func lastOccurrence(of ev: EKEvent) -> Date {
        let from: Date = ev.startDate
        let hi = Calendar.current.date(byAdding: .year, value: 4, to: from) ?? from
        let hits = store.events(matching: store.predicateForEvents(withStart: from, end: hi, calendars: ev.calendar.map { [$0] }))
            .filter { $0.calendarItemExternalIdentifier == ev.calendarItemExternalIdentifier }
        return hits.compactMap { $0.startDate as Date? }.max() ?? from
    }

    /// 删提醒前的完整快照（撤销按它重建）。
    private func fullSnapshot(_ r: EKReminder) -> YourReminderSnapshot {
        var s = snapshot(r)
        s.startDate = r.startDateComponents.flatMap { Calendar.current.date(from: $0) }
        s.startHasTime = r.startDateComponents.map { $0.hour != nil }
        s.dueTimeZone = r.dueDateComponents?.timeZone?.identifier
        s.priority = r.priority
        s.url = r.url?.absoluteString
        s.relativeAlarms = (r.alarms ?? []).compactMap { $0.absoluteDate == nil && $0.structuredLocation == nil ? $0.relativeOffset : nil }
        s.recurrence = (r.recurrenceRules ?? []).map(YourRecurrenceRule.init)
        s.sourceTitle = r.calendar?.source?.title
        s.hasLocationAlarm = (r.alarms ?? []).contains { $0.structuredLocation != nil }
        return s
    }

    private func access(_ type: EKEntityType) throws {
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else {
            throw YourItemsError.refused(type == .event ? "没有日历的完整权限（系统设置 → 隐私与安全性 → 日历）" : "没有提醒事项的完整权限（系统设置 → 隐私与安全性 → 提醒事项）")
        }
    }

    /// 外部标识 + 这一次的开始时刻（毫秒内）定位；对不上一条 = 抛错，不猜。
    private func find(_ ref: YourEventRef) throws -> EKEvent {
        try access(.event)
        let lo = ref.occurrenceStart.addingTimeInterval(-86_400), hi = ref.occurrenceStart.addingTimeInterval(86_400)
        let cals = store.calendars(for: .event)
        let hits = store.events(matching: store.predicateForEvents(withStart: lo, end: hi, calendars: cals)).filter {
            $0.calendarItemExternalIdentifier == ref.externalID && abs($0.startDate.timeIntervalSince(ref.occurrenceStart)) < 0.5
        }
        guard hits.count == 1, let ev = hits.first else {
            throw hits.isEmpty ? YourItemsError.notFound("日历里找不到这条日程（可能已被改时间或删除）")
                               : YourItemsError.notFound("日历里有 \(hits.count) 条对得上的日程，没法确定是哪一条，未改动")
        }
        return ev
    }

    private func guardOurs(_ ev: EKEvent) throws {
        if ourCalendars.contains(ev.calendar?.title ?? "") { throw YourItemsError.refused("这条在 BetterCalendar 自家日历里，这个写者不碰") }
    }

    private func findReminder(_ id: String) throws -> EKReminder {
        try access(.reminder)
        let hits = store.calendarItems(withExternalIdentifier: id).compactMap { $0 as? EKReminder }
        guard hits.count == 1, let r = hits.first else {
            throw hits.isEmpty ? YourItemsError.notFound("提醒事项里找不到这条提醒（可能已被删除）")
                               : YourItemsError.notFound("提醒事项里有 \(hits.count) 条对得上的提醒，没法确定是哪一条，未改动")
        }
        return r
    }

    private func snapshot(_ ev: EKEvent) throws -> YourEventSnapshot {
        guard let id = ev.calendarItemExternalIdentifier else { throw YourItemsError.failed("这条日程没有外部标识，没法稳妥定位") }
        return YourEventSnapshot(
            ref: YourEventRef(externalID: id, occurrenceStart: ev.startDate),
            title: ev.title ?? "", start: ev.startDate, end: ev.endDate, isAllDay: ev.isAllDay,
            notes: ev.notes, location: ev.location, url: ev.url?.absoluteString,
            calendarTitle: ev.calendar?.title ?? "", sourceTitle: ev.calendar?.source?.title ?? "",
            timeZone: ev.timeZone?.identifier,
            alarmOffsets: (ev.alarms ?? []).compactMap { $0.absoluteDate == nil ? $0.relativeOffset : nil },
            facts: YourEventFacts(ev, inBetterCalendar: ourCalendars.contains(ev.calendar?.title ?? "")))
    }

    private static func dueDate(_ r: EKReminder) -> Date? { r.dueDateComponents.flatMap { Calendar.current.date(from: $0) } }

    private func snapshot(_ r: EKReminder) -> YourReminderSnapshot {
        YourReminderSnapshot(externalID: r.calendarItemExternalIdentifier ?? "", title: r.title ?? "", notes: r.notes,
                             due: Self.dueDate(r), hasTime: r.dueDateComponents?.hour != nil, isCompleted: r.isCompleted,
                             listTitle: r.calendar?.title ?? "",
                             absoluteAlarms: (r.alarms ?? []).compactMap(\.absoluteDate),
                             facts: YourReminderFacts(r, inBetterCalendarList: ourReminderLists.contains(r.calendar?.title ?? "")))
    }
}

// 规则要的事实（写者与只读上下文共用同一份口径：智能体在 context 里看到的「能不能改」= 执行时判的）。
extension YourEventFacts {
    nonisolated init(_ ev: EKEvent, inBetterCalendar: Bool) {
        let organizerOther = ev.organizer.map { !$0.isCurrentUser } ?? false
        self.init(calendarWritable: ev.calendar?.allowsContentModifications ?? false,
                  organizerIsOther: organizerOther, organizerName: organizerOther ? ev.organizer?.name : nil,
                  hasOtherAttendees: (ev.attendees ?? []).contains { !$0.isCurrentUser },
                  inBetterCalendar: inBetterCalendar,
                  isRecurring: ev.hasRecurrenceRules || ev.isDetached)
    }
}

extension YourReminderFacts {
    nonisolated init(_ r: EKReminder, inBetterCalendarList: Bool) {
        self.init(listWritable: r.calendar?.allowsContentModifications ?? false, inBetterCalendarList: inBetterCalendarList,
                  isRecurring: r.hasRecurrenceRules)
    }
}

// W34：重复规则 ↔ 可编码快照。
extension YourRecurrenceRule {
    nonisolated init(_ r: EKRecurrenceRule) {
        self.init(frequency: r.frequency.rawValue, interval: r.interval, firstDayOfTheWeek: r.firstDayOfTheWeek,
                  daysOfTheWeek: r.daysOfTheWeek?.map { Day(dayOfWeek: $0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber) },
                  daysOfTheMonth: r.daysOfTheMonth?.map(\.intValue), daysOfTheYear: r.daysOfTheYear?.map(\.intValue),
                  weeksOfTheYear: r.weeksOfTheYear?.map(\.intValue), monthsOfTheYear: r.monthsOfTheYear?.map(\.intValue),
                  setPositions: r.setPositions?.map(\.intValue),
                  endDate: r.recurrenceEnd?.endDate,
                  occurrenceCount: (r.recurrenceEnd?.occurrenceCount ?? 0) > 0 ? r.recurrenceEnd?.occurrenceCount : nil)
    }

    nonisolated var ekRule: EKRecurrenceRule {
        let end: EKRecurrenceEnd? = endDate.map { EKRecurrenceEnd(end: $0) } ?? occurrenceCount.map { EKRecurrenceEnd(occurrenceCount: $0) }
        let days = daysOfTheWeek?.compactMap { d in
            EKWeekday(rawValue: d.dayOfWeek).map { d.weekNumber == 0 ? EKRecurrenceDayOfWeek($0) : EKRecurrenceDayOfWeek($0, weekNumber: d.weekNumber) }
        }
        let nums: ([Int]?) -> [NSNumber]? = { $0?.map { NSNumber(value: $0) } }
        let rule = EKRecurrenceRule(recurrenceWith: EKRecurrenceFrequency(rawValue: frequency) ?? .daily, interval: max(1, interval),
                                    daysOfTheWeek: days, daysOfTheMonth: nums(daysOfTheMonth), monthsOfTheYear: nums(monthsOfTheYear),
                                    weeksOfTheYear: nums(weeksOfTheYear), daysOfTheYear: nums(daysOfTheYear),
                                    setPositions: nums(setPositions), end: end)
        return rule   // firstDayOfTheWeek 在 EventKit 里只读：重建用系统默认（只影响「每 N 周」跨周起算，快照留底备查）
    }
}
