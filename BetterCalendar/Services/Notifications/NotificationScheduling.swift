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
    /// W30 一处响：每条都从触达出口过（nil = 测试 / 没接 = 照旧响）。
    private let reach: ReachOutlet?
    init(reach: ReachOutlet? = nil) { self.reach = reach }
    private static let morningID = "bc.reminder.morning"
    private static let eveningID = "bc.reminder.evening"

    func requestAuthorizationIfNeeded() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            DevLog.shared.warn("通知", "请求授权失败：\(error.localizedDescription)")
        }
    }

    /// 静音埋点按天去重：松散日 loadToday 会反复调 cancel，一天记一条就够分析用
    private static var lastMuteLogDay: Date?

    func cancelDailyReminders() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.morningID, Self.eveningID])
        // 埋点（调研 A 组地基）：静音也是事实——A3 要拿「没通知的日子」当对照组
        let day = Calendar.current.startOfDay(for: .now)
        if Self.lastMuteLogDay != day {
            Self.lastMuteLogDay = day
            BehaviorLog.record("通知静音", "早晚提醒已清（松散日或用户清计划）")
        }
    }

    func scheduleDailyReminders(morning: Date?, evening: Date?, summary: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.morningID, Self.eveningID])
        if let m = morning, m > .now, await add(id: Self.morningID, title: "开始今天", body: summary, at: m, kind: .morning) {
            // 埋点口径：本地通知没有「已送达/已看到」回执，用**排定的触发时刻**近似发出时刻
            BehaviorLog.record("通知排定", "早 \(Self.stamp(m)) · \(summary) ·口径=排定时刻(无送达回执)")
        } else if let m = morning {
            // 0.33.1 可见化（7-12 凌晨排查教训：跳过静默=通知没来查无对证）
            DevLog.shared.warn("通知", "早提醒没排：\(Self.stamp(m)) 已过当前时刻")
        }
        if let e = evening, e > .now, await add(id: Self.eveningID, title: "30 秒记录今天",
                                                body: "给今天收个尾吧——一句话、30 秒。", at: e, kind: .evening) {
            BehaviorLog.record("通知排定", "晚 \(Self.stamp(e)) ·口径=排定时刻(无送达回执)")
        } else if let e = evening {
            DevLog.shared.warn("通知", "晚提醒没排：\(Self.stamp(e)) 已过当前时刻")
        }
    }

    static func dayStamp(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    /// 埋点用的触发时刻戳（本地时区、到分）——分析脚本按它算「通知→首次开始」间隔，别用 at 字段（那是排定动作的时刻）。
    private static func stamp(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: date)
    }

    func notifyNow(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        do {   // trigger=nil → 立刻送达
            let id = UUID().uuidString
            let request = UNNotificationRequest(identifier: "bc.ddl.\(id)", content: content, trigger: nil)
            try await center.add(reach?.route(request, kind: .ddlNudge, reachID: "ddl:\(id)") ?? request)
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

    @discardableResult
    private func add(id: String, title: String, body: String, at date: Date, kind: ReachKind) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        do {
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            // reachID 按触发那一天：各台设备按同一份计划算出同一天 → 同一个 id（「早通知 2026-10-20」）
            try await center.add(reach?.route(request, kind: kind, reachID: "\(kind.rawValue):\(Self.dayStamp(date))", fireAt: date) ?? request)
            return true
        } catch {
            DevLog.shared.warn("通知", "排通知失败：\(error.localizedDescription)")
            return false
        }
    }
}
