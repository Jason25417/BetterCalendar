//
//  EveningReviewSchedule.swift
//  BetterCalendar
//
//  SPEC §19 F1：对话式晚间复盘。到了你设的时刻（默认关），Mac 端写一个 evening_review 事件，
//  智能体按正反馈原则在对话里写「今天做成了什么」，你可以回一句补充。
//  设置随 iCloud 设置同步（SettingsSync 白名单），所以在 iPhone 上开、由 Mac 触发也成立。
//

import Foundation

nonisolated enum EveningReviewSettings {
    static let enabledKey = "agentChat.eveningReview.enabled"
    /// 一天中的分钟数（21:30 = 1290）。凌晨 4 点前的时刻算前一个逻辑日的晚上。
    static let minuteKey = "agentChat.eveningReview.minute"
    static let defaultMinute = 21 * 60 + 30
    /// 本机（Mac）最近一次发出复盘事件的逻辑日（不同步：只有接着 bridge 的那台 Mac 触发）。
    static let lastDayKey = "agentChat.eveningReview.lastDay"
    /// 错过时刻后最多补发多久（Mac 睡着醒来时不发一条过时的复盘）。
    static let lateWindow: TimeInterval = 3 * 3600

    static func enabled(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: enabledKey) }
    static func minute(_ d: UserDefaults = .standard) -> Int {
        let v = d.object(forKey: minuteKey) as? Int ?? defaultMinute
        return min(max(v, 0), 24 * 60 - 1)
    }

    /// 此刻该不该发复盘事件；该发时返回逻辑日键（发完写进 lastDayKey，保证一天只发一次）。
    static func dueDayKey(enabled: Bool, minute: Int, lastDayKey: String?, now: Date, calendar: Calendar = .current) -> String? {
        guard enabled else { return nil }
        let label = DayContext.logicalStartOfDay(now)
        let key = DayContext.dayKey(now)
        guard lastDayKey != key else { return nil }
        // 逻辑日零点 + 分钟数；凌晨日界线前的时刻（如 0:30）落在逻辑日的次日日历日。
        var target = calendar.date(byAdding: .minute, value: minute, to: label) ?? label
        if minute < DayContext.dayBoundaryHour * 60 { target = calendar.date(byAdding: .day, value: 1, to: target) ?? target }
        guard now >= target, now.timeIntervalSince(target) < lateWindow else { return nil }
        return key
    }
}
