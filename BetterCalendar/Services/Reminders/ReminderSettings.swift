//
//  ReminderSettings.swift
//  BetterCalendar
//
//  提醒事项设置：提前提醒分钟数。
//

import Foundation

enum ReminderSettings {
    private static let defaults = UserDefaults.standard

    /// 要紧事提前多少分钟提醒（0 = 准点）。
    static var leadMinutes: Int {
        get { defaults.object(forKey: "reminder.lead") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "reminder.lead") }
    }
}
