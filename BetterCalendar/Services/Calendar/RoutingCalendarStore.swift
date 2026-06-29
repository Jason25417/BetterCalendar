//
//  RoutingCalendarStore.swift
//  BetterCalendar
//
//  按 CalendarSettings.backend 把读写转发给 假日历 或 真 Apple 日历。
//  每次操作都现读设置 → App 内拨开关即时生效，无需重启。
//

import Foundation

final class RoutingCalendarStore: CalendarStore {
    private let fake: FakeCalendarStore
    private let eventKit: EventKitCalendarStore

    init(fake: FakeCalendarStore, eventKit: EventKitCalendarStore) {
        self.fake = fake
        self.eventKit = eventKit
    }

    private var current: CalendarStore {
        CalendarSettings.backend == .eventKit ? eventKit : fake
    }

    func write(_ drafts: [CalendarEventDraft]) async throws {
        try await current.write(drafts)
    }

    func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft] {
        try await current.read(kind: kind)
    }
}
