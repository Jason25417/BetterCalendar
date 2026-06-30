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
    var priority: Int = 0        // EKReminder 口径：0 无 / 1 高 / 5 中 / 9 低
    var notes: String?
    var leadMinutes: Int?        // 提前提醒：到期前 N 分钟响（nil = 不提醒）
}

protocol ReminderStore: AnyObject {
    func write(_ drafts: [ReminderDraft]) async throws
    /// 已打勾完成的提醒标题（被动信号：提醒打勾 → 对应要紧事标完成）。
    func completedTitles() async -> [String]
}
