//
//  ReminderStore.swift
//  BetterCalendar
//
//  写标准 VTODO 提醒（标题/备注/截止/优先级）。priority 走 EKReminder 口径：0 无 / 1 高 / 5 中 / 9 低。
//  ⚠️ 旗标/标签/子任务是私有 ReminderKit，不可写——要紧事只能用 priority 表达。
//  开发期实现 = FakeReminderStore；之后换复用 EasyReminder 的写 VTODO 能力。
//

import Foundation

struct ReminderDraft: Sendable, Identifiable {
    var id = UUID()
    var title: String
    var due: Date?
    var priority: Int = 0
    var notes: String?
}

protocol ReminderStore: AnyObject {
    func write(_ drafts: [ReminderDraft]) async throws
}
