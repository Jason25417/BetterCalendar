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
            // 差量 upsert（按 标题+起始 匹配）：已存在且内容没变的**不动**（事件 ID 稳定、不触发索引风暴）；
            // 变了的更新、没有的新建、范围内多余的删除。比"删全部重写"轻得多。
            let cal0 = Calendar.current
            let lo = cal0.startOfDay(for: group.map(\.start).min() ?? Date())
            let hi = cal0.date(byAdding: .day, value: 1,
                               to: cal0.startOfDay(for: group.map(\.end).max() ?? Date())) ?? Date()
            let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: [cal])
            var byKey: [String: EKEvent] = [:]
            for ev in store.events(matching: pred) { byKey[Self.eventKey(ev.title ?? "", ev.startDate)] = ev }

            var keep = Set<String>()
            for d in group {
                let k = Self.eventKey(d.title, d.start)
                keep.insert(k)
                if let ev = byKey[k] {
                    let endChanged = abs(ev.endDate.timeIntervalSince(d.end)) >= 30
                    let notesChanged = (ev.notes ?? "") != (d.notes ?? "")
                    // 普通块从不弹通知（alarm=[]）；仅固定块/会议挂会前提醒（⑤）。按期望态调整。
                    let wantAlarm = d.alarmLeadMinutes != nil
                    let hasAlarm = !(ev.alarms ?? []).isEmpty
                    if endChanged || notesChanged || wantAlarm != hasAlarm {
                        ev.endDate = d.end; ev.notes = d.notes; ev.alarms = Self.alarms(lead: d.alarmLeadMinutes)
                        try store.save(ev, span: .thisEvent, commit: false); changed += 1
                    }
                } else {
                    let ev = EKEvent(eventStore: store)
                    ev.calendar = cal; ev.title = d.title
                    ev.startDate = d.start; ev.endDate = d.end; ev.notes = d.notes
                    ev.alarms = Self.alarms(lead: d.alarmLeadMinutes)   // 普通块 nil→[]（不弹）；固定块→会前提醒
                    try store.save(ev, span: .thisEvent, commit: false); changed += 1
                }
            }
            for (k, ev) in byKey where !keep.contains(k) {
                try? store.remove(ev, span: .thisEvent, commit: false); changed += 1
            }
        }
        if changed > 0 { try store.commit() }
        DevLog.shared.info("日历", "写真日历 \(drafts.count) 项 · 实际变更 \(changed)")
    }

    /// 事件去重键：标题 + 起始分钟（同标题同起始＝同一事件）。
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
                               kind: kind, notes: $0.notes)
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
