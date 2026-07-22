//
//  FakeReminderStore.swift
//  BetterCalendarTests
//
//  测试替身假提醒（2026-07-22 迁入测试 target）：记录草稿供断言，不碰系统「提醒事项」。
//

import Foundation
import Observation
@testable import BetterCalendar

@Observable
final class FakeReminderStore: ReminderStore {
    private(set) var captured: [ReminderDraft] = []

    func write(_ drafts: [ReminderDraft]) async throws {
        captured.append(contentsOf: drafts)
    }

    /// 假模式不跟踪打勾（无真提醒），返回空。
    func completedBlockIDs() async -> Set<UUID> { [] }

    func clear() {
        captured.removeAll()
    }
}
