//
//  EventKitCalendarStore.swift
//  BetterCalendar
//
//  真 Apple 日历后端（M2）：把计划写进专用「计划」日历（绿）、读回。
//  专用日历名带 (Dev) 与「计划/实际」标识，可整本删、不污染你别的日历。
//  需日历 full access（首次写会弹权限）。
//

import Foundation
import EventKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct CalendarError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class EventKitCalendarStore: CalendarStore {
    private let store = EKEventStore()
    private let titles: [PlanCalendarKind: String] = [
        .planned: "BetterCalendar · 计划 (Dev)",
        .actual: "BetterCalendar · 实际 (Dev)",
        .preview: "BetterCalendar · 预览 (Dev)",
    ]

    func write(_ drafts: [CalendarEventDraft]) async throws {
        try await ensureAccess()
        guard !drafts.isEmpty else { return }
        var changed = 0
        for (kind, group) in Dictionary(grouping: drafts, by: \.kind) {
            let cal = try calendar(for: kind)
            let cal0 = Calendar.current
            let lo = cal0.startOfDay(for: group.map(\.start).min() ?? Date())
            let hi = cal0.date(byAdding: .day, value: 1,
                               to: cal0.startOfDay(for: group.map(\.end).max() ?? Date())) ?? Date()
            changed += try syncEvents(group, calendar: cal, from: lo, to: hi)
        }
        if changed > 0 { try store.commit() }
        DevLog.shared.info("日历", "写真日历 \(drafts.count) 项 · 实际变更 \(changed)")
    }

    func apply(_ drafts: [CalendarEventDraft], kind: PlanCalendarKind, window: DateInterval) async throws {
        try await ensureAccess()
        // 空草稿 + 日历本就不存在 → 无事可清，别为了清空去创建日历
        if drafts.isEmpty, existingCalendar(for: kind) == nil { return }
        let cal = try calendar(for: kind)
        let changed = try syncEvents(drafts, calendar: cal, from: window.start, to: window.end)
        if changed > 0 { try store.commit() }
        DevLog.shared.info("投影", "对齐「\(titles[kind] ?? "?")」\(drafts.count) 项 · 实际变更 \(changed)")
    }

    /// 差量对齐核心（write / apply 共用）：范围内该日历的事件与 drafts 对齐。
    /// 匹配优先级：① blockID 盖章（跨设备稳定，改标题/挪时间不删重建）
    /// ② 无章旧事件按 标题+起始 认领并**补章**（存量数据自迁移，不删不重建）
    /// ③ 都对不上且 start ∈ [lo, hi) → 删（范围外的跨界重叠事件不动，防误删邻日）。
    private func syncEvents(_ drafts: [CalendarEventDraft], calendar cal: EKCalendar,
                            from lo: Date, to hi: Date) throws -> Int {
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: [cal])
        let existing = store.events(matching: pred)
        var byID: [UUID: EKEvent] = [:]
        var unstamped: [String: EKEvent] = [:]
        for ev in existing {
            if let bid = Self.blockID(from: ev.url) { byID[bid] = ev }
            else { unstamped[Self.eventKey(ev.title ?? "", ev.startDate)] = ev }
        }
        var changed = 0
        var keep = Set<ObjectIdentifier>()
        for d in drafts {
            var target: EKEvent?
            if let bid = d.blockID { target = byID[bid] }
            if target == nil { target = unstamped.removeValue(forKey: Self.eventKey(d.title, d.start)) }
            let wantURL = d.blockID.flatMap(Self.stampURL)
            if let ev = target {
                keep.insert(ObjectIdentifier(ev))
                let titleChanged = (ev.title ?? "") != d.title
                let startChanged = abs(ev.startDate.timeIntervalSince(d.start)) >= 30
                let endChanged = abs(ev.endDate.timeIntervalSince(d.end)) >= 30
                let notesChanged = (ev.notes ?? "") != (d.notes ?? "")
                // 普通块从不弹通知（alarm=[]）；仅固定块/会议挂会前提醒（⑤）。按期望态调整。
                let wantAlarm = d.alarmLeadMinutes != nil
                let hasAlarm = !(ev.alarms ?? []).isEmpty
                // 只在有章可盖时改 URL（认领补章/换章）；draft 无章不抹既有 URL
                let urlChanged = wantURL != nil && ev.url != wantURL
                if titleChanged || startChanged || endChanged || notesChanged || wantAlarm != hasAlarm || urlChanged {
                    ev.title = d.title; ev.startDate = d.start; ev.endDate = d.end
                    ev.notes = d.notes; ev.alarms = Self.alarms(lead: d.alarmLeadMinutes)
                    if let wantURL { ev.url = wantURL }
                    try store.save(ev, span: .thisEvent, commit: false); changed += 1
                }
            } else {
                let ev = EKEvent(eventStore: store)
                ev.calendar = cal; ev.title = d.title
                ev.startDate = d.start; ev.endDate = d.end; ev.notes = d.notes
                ev.alarms = Self.alarms(lead: d.alarmLeadMinutes)   // 普通块 nil→[]（不弹）；固定块→会前提醒
                ev.url = wantURL
                try store.save(ev, span: .thisEvent, commit: false); changed += 1
            }
        }
        // 删除只针对**归属本范围**（start ∈ [lo, hi)）的未匹配事件；同 ID 重复事件也在此收敛
        for ev in existing where !keep.contains(ObjectIdentifier(ev))
            && ev.startDate >= lo && ev.startDate < hi {
            try? store.remove(ev, span: .thisEvent, commit: false); changed += 1
        }
        return changed
    }

    // MARK: - 盖章（重构 P1「稳定身份」）

    /// blockID → 事件 URL 章（bettercalendar://block/UUID）：随 iCloud 日历同步到所有设备，
    /// 任何设备匹配都按它；日后可注册 URL scheme 做 deep link（点事件跳回 App 对应块）。
    static func stampURL(_ id: UUID) -> URL? {
        URL(string: "bettercalendar://block/\(id.uuidString)")
    }

    /// 事件 URL → blockID（非本 App 的章 → nil）。
    static func blockID(from url: URL?) -> UUID? {
        guard let url, url.scheme == "bettercalendar", url.host == "block" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// 事件去重键：标题 + 起始分钟（无章旧事件的认领键）。
    private static func eventKey(_ title: String, _ start: Date) -> String {
        "\(title)#\(Int(start.timeIntervalSinceReferenceDate / 60))"
    }

    /// 会前提醒（⑤会议自动化）：lead 分钟前响一次；nil/负 → 无提醒（普通块）。
    private static func alarms(lead: Int?) -> [EKAlarm] {
        guard let lead, lead >= 0 else { return [] }
        return [EKAlarm(relativeOffset: TimeInterval(-lead * 60))]
    }

    func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft] {
        try await ensureAccess()
        guard let title = titles[kind],
              let cal = store.calendars(for: .event).first(where: { $0.title == title }) else { return [] }
        let cal0 = Calendar.current
        let lo = cal0.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let hi = cal0.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: [cal])
        return store.events(matching: pred).map {
            CalendarEventDraft(title: $0.title ?? "", start: $0.startDate, end: $0.endDate,
                               kind: kind, notes: $0.notes, blockID: Self.blockID(from: $0.url))
        }
    }

    func clear(kind: PlanCalendarKind) async throws {
        try await ensureAccess()
        guard let title = titles[kind],
              let cal = store.calendars(for: .event).first(where: { $0.title == title }) else { return }
        let cal0 = Calendar.current
        let lo = cal0.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let hi = cal0.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: [cal])
        for ev in store.events(matching: pred) { try? store.remove(ev, span: .thisEvent, commit: false) }
        try store.commit()
    }

    /// 清空某一天某一类（删光当天所有块后确认写入 → 清该日绿色事件；不碰别天）。
    func clear(kind: PlanCalendarKind, on day: Date) async throws {
        try await ensureAccess()
        guard let title = titles[kind],
              let cal = store.calendars(for: .event).first(where: { $0.title == title }) else { return }
        let cal0 = Calendar.current
        let lo = cal0.startOfDay(for: day)
        guard let hi = cal0.date(byAdding: .day, value: 1, to: lo) else { return }
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: [cal])
        var removed = 0
        for ev in store.events(matching: pred) { try? store.remove(ev, span: .thisEvent, commit: false); removed += 1 }
        if removed > 0 { try store.commit() }
    }

    /// 目标日系统里已有的安排（所有事件日历，排除本 App 的三本 Dev 日历）。
    /// 权限没给/读失败 → 空（上下文缺失不挡排程）。
    func existingEvents(on day: Date) async -> [BusySlot] {
        do { try await ensureAccess() } catch { return [] }
        let cal0 = Calendar.current
        let lo = cal0.startOfDay(for: day)
        guard let hi = cal0.date(byAdding: .day, value: 1, to: lo) else { return [] }
        let ours = Set(titles.values)
        let others = store.calendars(for: .event).filter { !ours.contains($0.title) }
        guard !others.isEmpty else { return [] }
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: others)
        return store.events(matching: pred)
            .filter { !$0.isAllDay }   // 全天事件不占时段
            .map { BusySlot(title: $0.title ?? "（无标题）", start: $0.startDate, end: $0.endDate) }
    }

    // MARK: - 权限 / 日历

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await store.requestFullAccessToEvents()
            if !granted { throw CalendarError(message: "日历权限被拒绝") }
        default:
            throw CalendarError(message: "无日历 full access（系统设置 → 隐私与安全性 → 日历 开启）")
        }
    }

    /// 该 kind 的专用日历（已存在才返回，不创建）。
    private func existingCalendar(for kind: PlanCalendarKind) -> EKCalendar? {
        guard let title = titles[kind] else { return nil }
        return store.calendars(for: .event).first { $0.title == title }
    }

    private func calendar(for kind: PlanCalendarKind) throws -> EKCalendar {
        let title = titles[kind] ?? "BetterCalendar (Dev)"
        if let existing = store.calendars(for: .event).first(where: { $0.title == title }) {
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = title
        cal.cgColor = Self.color(kind)
        guard let source = writableSource() else { throw CalendarError(message: "找不到可写日历源") }
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        return cal
    }

    private func writableSource() -> EKSource? {
        if let icloud = store.sources.first(where: {
            $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud")
        }) { return icloud }
        if let calDAV = store.sources.first(where: { $0.sourceType == .calDAV }) { return calDAV }
        if let local = store.sources.first(where: { $0.sourceType == .local }) { return local }
        return store.defaultCalendarForNewEvents?.source
    }

    private static func color(_ kind: PlanCalendarKind) -> CGColor {
        #if canImport(AppKit)
        switch kind {
        case .planned: return NSColor.systemGreen.cgColor
        case .actual:  return NSColor.systemBlue.cgColor
        case .preview: return NSColor.systemOrange.cgColor
        }
        #elseif canImport(UIKit)
        switch kind {
        case .planned: return UIColor.systemGreen.cgColor
        case .actual:  return UIColor.systemBlue.cgColor
        case .preview: return UIColor.systemOrange.cgColor
        }
        #else
        return CGColor(red: 0, green: 0.7, blue: 0.3, alpha: 1)
        #endif
    }
}
