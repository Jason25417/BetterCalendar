//
//  SimulatedEventKitCalendar.swift
//  BetterCalendarTests
//
//  P4.0 测试替身：**按 EventKit 语义**模拟系统日历（与 FakeCalendarStore 的「整类替换」不同）——
//  事件有章/无章、创建时间、外部标识；写入/对齐/清空都走生产同一个决定函数 CalendarSyncPlanner，
//  所以「永不删无章事件」「同章确定性去重」这类铁律能在内存里端到端验证（不碰真日历）。
//

import Foundation
@testable import BetterCalendar

final class SimulatedEventKitCalendar: CalendarStore {
    struct Event: Equatable {
        var kind: PlanCalendarKind
        var title: String
        var start: Date
        var end: Date
        var notes: String?
        var alarmLead: Int?
        var blockID: UUID?
        var created: Date
        var externalID: String
    }

    private(set) var events: [Event] = []
    private var serial = 0
    /// 模拟时钟：read(kind:) 的「此刻前后 7 天」与新建事件的创建时间都按它。
    var now: Date

    init(now: Date) { self.now = now }

    /// 直接往日历里放一个事件（模拟用户在日历 App 里新建 / 另一台设备写入）。
    @discardableResult
    func seed(_ kind: PlanCalendarKind, _ title: String, _ start: Date, _ end: Date,
              blockID: UUID? = nil, created: Date? = nil) -> String {
        serial += 1
        let ext = String(format: "ext-%04d", serial)
        events.append(Event(kind: kind, title: title, start: start, end: end, notes: nil, alarmLead: nil,
                            blockID: blockID, created: created ?? now, externalID: ext))
        return ext
    }

    /// 模拟用户在日历 App 里改一个事件（按外部标识）。
    func edit(_ externalID: String, start: Date, end: Date, title: String? = nil) {
        guard let i = events.firstIndex(where: { $0.externalID == externalID }) else { return }
        events[i].start = start; events[i].end = end
        if let title { events[i].title = title }
    }

    func events(_ kind: PlanCalendarKind) -> [Event] { events.filter { $0.kind == kind } }

    // MARK: CalendarStore

    func write(_ drafts: [CalendarEventDraft]) async throws {
        guard !drafts.isEmpty else { return }
        let cal = Calendar.current
        for (kind, group) in Dictionary(grouping: drafts, by: \.kind) {
            let lo = cal.startOfDay(for: group.map(\.start).min()!)
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: group.map(\.end).max()!))!
            sync(group, kind: kind, from: lo, to: hi)
        }
    }

    func apply(_ drafts: [CalendarEventDraft], kind: PlanCalendarKind, window: DateInterval) async throws {
        sync(drafts, kind: kind, from: window.start, to: window.end)
    }

    func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft] {
        try await read(kind: kind, in: DateInterval(start: now.addingTimeInterval(-7 * 86400),
                                                    end: now.addingTimeInterval(7 * 86400)))
    }

    func read(kind: PlanCalendarKind, in window: DateInterval) async throws -> [CalendarEventDraft] {
        inRange(kind, window.start, window.end).map { i in
            let e = events[i]
            return CalendarEventDraft(title: e.title, start: e.start, end: e.end, kind: kind, notes: e.notes,
                                      alarmLeadMinutes: e.alarmLead, blockID: e.blockID,
                                      creationDate: e.created, externalID: e.externalID)
        }
    }

    func clear(kind: PlanCalendarKind) async throws {
        sync([], kind: kind, from: now.addingTimeInterval(-7 * 86400), to: now.addingTimeInterval(7 * 86400))
    }

    // MARK: 执行 CalendarSyncPlanner 的清单（与 EventKitCalendarStore.syncEvents 同构）

    /// EventKit 谓词语义：与 [lo, hi) 相交的事件。
    private func inRange(_ kind: PlanCalendarKind, _ lo: Date, _ hi: Date) -> [Int] {
        events.indices.filter { events[$0].kind == kind && events[$0].start < hi && events[$0].end > lo }
    }

    private func sync(_ drafts: [CalendarEventDraft], kind: PlanCalendarKind, from lo: Date, to hi: Date) {
        let idx = inRange(kind, lo, hi)
        let snaps = idx.map { i -> CalendarEventSnapshot in
            let e = events[i]
            return CalendarEventSnapshot(title: e.title, start: e.start, end: e.end, notes: e.notes,
                                         hasAlarm: e.alarmLead != nil, blockID: e.blockID,
                                         creationDate: e.created, externalID: e.externalID)
        }
        let plan = CalendarSyncPlanner.plan(existing: snaps, drafts: drafts, from: lo, to: hi)
        for u in plan.updates {
            let i = idx[u.index]
            events[i].title = u.draft.title; events[i].start = u.draft.start; events[i].end = u.draft.end
            events[i].notes = u.draft.notes; events[i].alarmLead = u.draft.alarmLeadMinutes
            if let bid = u.draft.blockID { events[i].blockID = bid }
        }
        for d in plan.creates {
            serial += 1
            events.append(Event(kind: kind, title: d.title, start: d.start, end: d.end, notes: d.notes,
                                alarmLead: d.alarmLeadMinutes, blockID: d.blockID, created: now,
                                externalID: String(format: "ext-%04d", serial)))
        }
        let doomed = Set(plan.deletes.map { idx[$0] })
        events = events.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
    }
}
