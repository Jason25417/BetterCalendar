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
    ]

    func write(_ drafts: [CalendarEventDraft]) async throws {
        try await ensureAccess()
        guard !drafts.isEmpty else { return }
        for (kind, group) in Dictionary(grouping: drafts, by: \.kind) {
            let cal = try calendar(for: kind)
            // 覆盖：先删该日历在覆盖日范围内的事件，再写新事件（确认即替换）
            let cal0 = Calendar.current
            let lo = cal0.startOfDay(for: group.map(\.start).min() ?? Date())
            let hi = cal0.date(byAdding: .day, value: 1,
                               to: cal0.startOfDay(for: group.map(\.end).max() ?? Date())) ?? Date()
            let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: [cal])
            for ev in store.events(matching: pred) { try? store.remove(ev, span: .thisEvent, commit: false) }
            for d in group {
                let ev = EKEvent(eventStore: store)
                ev.calendar = cal
                ev.title = d.title
                ev.startDate = d.start
                ev.endDate = d.end
                ev.notes = d.notes
                try store.save(ev, span: .thisEvent, commit: false)
            }
        }
        try store.commit()
        DevLog.shared.info("日历", "写入真日历 \(drafts.count) 项")
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
        return (kind == .planned ? NSColor.systemGreen : NSColor.systemBlue).cgColor
        #elseif canImport(UIKit)
        return (kind == .planned ? UIColor.systemGreen : UIColor.systemBlue).cgColor
        #else
        return CGColor(red: 0, green: 0.7, blue: 0.3, alpha: 1)
        #endif
    }
}
