//
//  PlanSuggestSchedule.swift
//  BetterCalendar
//
//  0.77（Jason 10-26：「学习层要开始做投放的话，那其实就是模型智能体试着加入——我没有明确说要干的事情，它应该给一些建议，
//  或者说给我提案」）：每天一次「投放」时刻，叫醒智能体（事件 plan_suggest）看待办区 / 长期事项里还没排的事 + 今天的空档，
//  挑几件给建议或直接提案（BetterCalendar 自己的新块低风险会自动排上，可撤销）。SPEC §14.6 投放管道的智能体版。
//  · 设置随 iCloud 同步；几台设备按类别错开（同晚间复盘：Mac 到点、iPhone 晚 3 分钟、iPad 晚 6 分钟），
//    且同步的「今天已发」键在了就不再发——两台不会各叫一次（iCloud 延迟极少数可能两次，可见不丢）。
//

import Foundation

nonisolated enum PlanSuggestSettings {
    static let enabledKey = "agent.planSuggest.enabled"
    static let minuteKey = "agent.planSuggest.minute"
    /// Jason 一般 10 点起（共享记忆）：默认 10:30。
    static let defaultMinute = 10 * 60 + 30
    static let defaultEnabled = true
    /// 本机最近一次发的逻辑日（不同步）。
    static let lastDayKey = "agent.planSuggest.lastDay"
    /// 任一台发过的逻辑日（随 iCloud 同步，跨设备去重）。
    static let sentDayKey = "agent.planSuggest.sentDay"

    static func enabled(_ d: UserDefaults = .standard) -> Bool { ExperimentDefaults.bool(enabledKey, default: defaultEnabled, in: d) }
    static func minute(_ d: UserDefaults = .standard) -> Int {
        let v = d.object(forKey: minuteKey) as? Int ?? defaultMinute
        return min(max(v, 0), 24 * 60 - 1)
    }

    /// 此刻该不该发（同晚间复盘的时刻规则：到点后 3 小时内补发，过了当天不再发）。
    static func dueDayKey(_ d: UserDefaults, now: Date) -> String? {
        guard let key = EveningReviewSettings.dueDayKey(enabled: enabled(d), minute: minute(d),
                                                        lastDayKey: d.string(forKey: lastDayKey), now: now) else { return nil }
        if d.string(forKey: sentDayKey) == key { d.set(key, forKey: lastDayKey); return nil }   // 另一台已经发过
        return key
    }
}
