//
//  AttentionPolicy.swift
//  BetterCalendar
//
//  SPEC §19 C3：智能体主动通知的打扰规则——由 App 强制执行，不依赖智能体自觉。
//  智能体自己判断「要不要通知」（C2）；这里只判断「此刻允不允许打扰」：总开关、静音、安静时段、频率上限。
//  被拦下的消息照样保存（面板里可见），只是不弹通知；拦下原因写清楚（失败可见）。
//

import Foundation

nonisolated struct AttentionSettings: Codable, Equatable, Sendable {
    /// 总开关：允许智能体主动通知你（实验，默认关）。
    var enabled = false
    var maxPerHour = 2
    var maxPerDay = 8
    /// 安静时段 [quietStartHour, quietEndHour)，跨午夜（如 23→8）。两者相等 = 不设安静时段。
    var quietStartHour = 23
    var quietEndHour = 8
    /// 一键静音到此刻为止。
    var mutedUntil: Date? = nil

    static let key = "attention.settings.v1"

    static func load(_ defaults: UserDefaults = .standard) -> AttentionSettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return s
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

nonisolated enum AttentionVerdict: Equatable, Sendable {
    case allow
    case suppress(String)
}

nonisolated enum AttentionPolicy {
    /// recentDeliveries = 之前真正弹出过的通知时刻（被拦下的不算）。
    static func evaluate(_ s: AttentionSettings, at now: Date, recentDeliveries: [Date],
                         calendar: Calendar = .current) -> AttentionVerdict {
        guard s.enabled else { return .suppress("智能体主动通知未开启") }
        if let until = s.mutedUntil, now < until {
            return .suppress("静音中（到 \(until.formatted(date: .omitted, time: .shortened))）")
        }
        if inQuietHours(s, at: now, calendar: calendar) {
            return .suppress("安静时段（\(s.quietStartHour):00–\(s.quietEndHour):00）")
        }
        let lastHour = recentDeliveries.filter { now.timeIntervalSince($0) < 3600 && $0 <= now }.count
        if lastHour >= s.maxPerHour { return .suppress("已达每小时上限（\(s.maxPerHour) 条）") }
        let startOfDay = DayContext.logicalStartOfDay(now)
        let today = recentDeliveries.filter { $0 >= startOfDay && $0 <= now }.count
        if today >= s.maxPerDay { return .suppress("已达今天上限（\(s.maxPerDay) 条）") }
        return .allow
    }

    static func inQuietHours(_ s: AttentionSettings, at now: Date, calendar: Calendar = .current) -> Bool {
        guard s.quietStartHour != s.quietEndHour else { return false }
        let h = calendar.component(.hour, from: now)
        return s.quietStartHour < s.quietEndHour
            ? (h >= s.quietStartHour && h < s.quietEndHour)
            : (h >= s.quietStartHour || h < s.quietEndHour)
    }
}
