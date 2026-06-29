//
//  FakeReminderStore.swift
//  BetterCalendar
//
//  开发期假提醒：记录草稿供预览，不碰系统「提醒事项」。
//

import Foundation
import Observation

@Observable
final class FakeReminderStore: ReminderStore {
    private(set) var captured: [ReminderDraft] = []

    func write(_ drafts: [ReminderDraft]) async throws {
        captured.append(contentsOf: drafts)
    }

    func clear() {
        captured.removeAll()
    }
}
