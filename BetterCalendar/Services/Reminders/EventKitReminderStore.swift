//
//  EventKitReminderStore.swift
//  BetterCalendar
//
//  真 Apple「提醒事项」后端（M3）：把★要紧事写成标准 VTODO（标题/备注/截止/优先级/提前提醒）。
//  ⚠️ 只写标准字段；子任务/标签/旗标等私有 ReminderKit 不可写。需提醒事项 full access。
//

import Foundation
import EventKit

final class EventKitReminderStore: ReminderStore {
    private let store = EKEventStore()

    func write(_ drafts: [ReminderDraft]) async throws {
        try await ensureAccess()
        guard !drafts.isEmpty else { return }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw CalendarError(message: "没有可写的提醒事项列表")
        }
        for d in drafts {
            let r = EKReminder(eventStore: store)
            r.calendar = list
            r.title = d.title
            r.notes = d.notes
            r.priority = d.priority
            if let due = d.due {
                r.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: due)
                if let lead = d.leadMinutes {
                    r.addAlarm(EKAlarm(relativeOffset: TimeInterval(-lead * 60)))   // 到期前 N 分钟
                }
            }
            try store.save(r, commit: false)
        }
        try store.commit()
        DevLog.shared.info("提醒", "写入提醒事项 \(drafts.count) 项")
    }

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await store.requestFullAccessToReminders()
            if !granted { throw CalendarError(message: "提醒事项权限被拒绝") }
        default:
            throw CalendarError(message: "无提醒事项 full access（系统设置 → 隐私与安全性 → 提醒事项 开启）")
        }
    }
}
