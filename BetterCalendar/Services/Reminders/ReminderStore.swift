//
//  ReminderStore.swift
//  BetterCalendar
//
//  写标准 VTODO 提醒（标题/备注/截止/优先级）。priority 走 EKReminder 口径：0 无 / 1 高 / 5 中 / 9 低。
//  ⚠️ 旗标/标签/子任务是私有 ReminderKit，不可写——要紧事只能用 priority 表达。
//  生产唯一实现 = EventKitReminderStore（标准 VTODO）；测试注入 FakeReminderStore（测试 target）。
//

import Foundation

struct ReminderDraft: Sendable, Identifiable {
    var id = UUID()
    var title: String
    var due: Date?
    var priority: Int = 0        // EKReminder 口径：0 无 / 1 高 / 5 中 / 9 低
    var notes: String?
    var leadMinutes: Int?        // 提前提醒：到期前 N 分钟响（nil = 不提醒）
    var blockID: UUID?           // 0.25.4：盖进提醒 URL（bettercalendar://block/UUID）——完成信号按 ID 精确匹配，不按标题
}

protocol ReminderStore: AnyObject {
    func write(_ drafts: [ReminderDraft]) async throws
    /// **今天**打勾完成、且带本 App 身份章的提醒的 blockID（被动信号按 ID 精确匹配——0.25.4 根治
    /// 「同名任务被往日打勾的旧提醒误标完成」）。无章老提醒不参与（宁可漏认，绝不误认）。
    func completedBlockIDs() async -> Set<UUID>
    /// 某日历日到期、未完成的提醒标题（排除本 App 自建列表），给排程当上下文。默认空。
    func dueReminders(on day: Date) async -> [String]
    /// 在 App 内完成一件事 → 把它对应的（带本 App 身份章的）提醒事项也勾成完成（双向：App→提醒事项）。
    /// 幂等：已完成的再勾一次无副作用。无章/无对应提醒的 blockID 忽略。默认 no-op（假实现/测试桩）。
    func markCompleted(blockIDs: Set<UUID>) async
}

extension ReminderStore {
    func dueReminders(on day: Date) async -> [String] { [] }
    func markCompleted(blockIDs: Set<UUID>) async {}
}
