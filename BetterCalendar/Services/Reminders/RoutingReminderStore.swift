//
//  RoutingReminderStore.swift
//  BetterCalendar
//
//  按 CalendarSettings.backend 把提醒写到 假实现 或 真 Apple 提醒事项（与日历同一个开关，热切换）。
//

import Foundation

final class RoutingReminderStore: ReminderStore {
    private let fake: FakeReminderStore
    private let eventKit: EventKitReminderStore

    init(fake: FakeReminderStore, eventKit: EventKitReminderStore) {
        self.fake = fake
        self.eventKit = eventKit
    }

    func write(_ drafts: [ReminderDraft]) async throws {
        let current: ReminderStore = CalendarSettings.backend == .eventKit ? eventKit : fake
        try await current.write(drafts)
    }
}
