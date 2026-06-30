//
//  ReviewLocalStore.swift
//  BetterCalendar
//
//  复盘的本地小数据（原型期 UserDefaults；日后迁 SwiftData + CloudKit / JournalEntry 同步）：
//  ① 活跃天累计（极低门槛 streak：当天做成 ≥1 件即「活跃」）② 今日「最有价值的一件」轻自评。
//

import Foundation

enum ReviewLocalStore {
    private static let d = UserDefaults.standard

    private static func dayKey(_ date: Date = .now) -> String {
        DayContext.dayKey(date)   // 逻辑日（含凌晨 4 点偏移）
    }

    // MARK: 活跃天累计（不是连续；就是「已经活跃使用了多少天」）

    private static let activeKey = "review.activeDays"

    static var activeDayCount: Int { (d.stringArray(forKey: activeKey) ?? []).count }

    /// 当天做成 ≥1 件时调用：把该逻辑日计入活跃日（去重）。date 可注入便于测试。
    static func markActive(on date: Date = .now) {
        var set = Set(d.stringArray(forKey: activeKey) ?? [])
        set.insert(dayKey(date))
        d.set(Array(set), forKey: activeKey)
    }

    // MARK: 今日「最有价值的一件」

    static var todayMVP: String? {
        get { d.string(forKey: "review.mvp." + dayKey()) }
        set { d.set(newValue, forKey: "review.mvp." + dayKey()) }
    }

    static var todayMVPNote: String {
        get { d.string(forKey: "review.mvpNote." + dayKey()) ?? "" }
        set { d.set(newValue, forKey: "review.mvpNote." + dayKey()) }
    }
}
