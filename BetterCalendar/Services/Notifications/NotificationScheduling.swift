//
//  NotificationScheduling.swift
//  BetterCalendar
//
//  极简本地通知（原则 5：早晚各一条，绝不催促弹性块）。本地通知无需特殊 entitlement，只需运行时授权。
//  时间「据当天安排智能定」——原型期启发式（首块前 / 末块后）；后续可换 LLM 精调，藏在协议后。
//

import Foundation
import UserNotifications

protocol NotificationScheduling {
    func requestAuthorizationIfNeeded() async
    /// 排当天早晚两条（先清旧的）。morning/evening 为 nil 或已过则不排。
    func scheduleDailyReminders(morning: Date?, evening: Date?, summary: String) async
    /// 取消已排的早晚提醒（松散日静音：标松散时清掉，即使昨晚已排今早的也不响）。同步。
    func cancelDailyReminders()
    /// 立刻发一条一次性本地通知。DDL 过点补发用（p−m−N 已过去 → 不写提醒事项、直接发消息）。默认 no-op。
    func notifyNow(title: String, body: String) async
}

extension NotificationScheduling {
    func cancelDailyReminders() {}   // 默认 no-op（旧 stub/测试兼容）
    func notifyNow(title: String, body: String) async {}
}

final class UNNotificationService: NotificationScheduling {
    private let center = UNUserNotificationCenter.current()
    private static let morningID = "bc.reminder.morning"
    private static let eveningID = "bc.reminder.evening"

    func requestAuthorizationIfNeeded() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            DevLog.shared.warn("通知", "请求授权失败：\(error.localizedDescription)")
        }
    }

    func cancelDailyReminders() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.morningID, Self.eveningID])
    }

    func scheduleDailyReminders(morning: Date?, evening: Date?, summary: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.morningID, Self.eveningID])
        if let m = morning, m > .now {
            await add(id: Self.morningID, title: "开始今天", body: summary, at: m)
        }
        if let e = evening, e > .now {
            await add(id: Self.eveningID, title: "30 秒记录今天", body: "做成的都替你记好了——花半分钟收个尾就好。", at: e)
        }
    }

    func notifyNow(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        do {   // trigger=nil → 立刻送达
            try await center.add(UNNotificationRequest(identifier: "bc.ddl.\(UUID().uuidString)",
                                                       content: content, trigger: nil))
        } catch {
            DevLog.shared.warn("通知", "DDL 过点补发失败：\(error.localizedDescription)")
        }
    }

    /// 「给明天的一句话」并入已排的早通知（#23）：找到 pending 的早提醒 → 原触发器重建、body 追加寄语。
    /// 早通知还没排（明天的计划还没确认）则什么都不做——确认时 morningSummary 不含寄语，这里事后补。
    static func appendTomorrowNoteToMorning(_ note: String) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard let req = pending.first(where: { $0.identifier == morningID }),
              let content = req.content.mutableCopy() as? UNMutableNotificationContent else { return }
        let line = "昨晚的你说：\(note)"
        guard !content.body.contains(line) else { return }   // 幂等：重复保存不重复追加
        // 换行前先把旧寄语行去掉（用户改了寄语 → 以最新为准）
        let kept = content.body.split(separator: "\n").filter { !$0.hasPrefix("昨晚的你说：") }
        content.body = (kept.joined(separator: "\n") + "\n" + line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? await center.add(UNNotificationRequest(identifier: morningID, content: content,
                                                    trigger: req.trigger))
    }

    private func add(id: String, title: String, body: String, at date: Date) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        } catch {
            DevLog.shared.warn("通知", "排通知失败：\(error.localizedDescription)")
        }
    }
}
