//
//  CalendarSettings.swift
//  BetterCalendar
//
//  日历后端开关（假日历预览 / 真 Apple 日历）。运行时热切换：每次写读都读它。
//

import Foundation

enum CalendarSettings {
    private static let defaults = UserDefaults.standard

    static var backend: CalendarBackend {
        get { CalendarBackend(rawValue: defaults.string(forKey: "calendar.backend") ?? "fake") ?? .fake }
        set { defaults.set(newValue.rawValue, forKey: "calendar.backend") }
    }
}
