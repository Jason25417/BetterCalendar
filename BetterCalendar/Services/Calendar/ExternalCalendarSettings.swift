//
//  ExternalCalendarSettings.swift
//  BetterCalendar
//
//  P4 Q4（SPEC §19.13）：你自己的日历作为「已占用」参与排布——默认全部可见日历都算，可按日历挑掉。
//  存日历**名字**（不存 calendarIdentifier：那个每台设备不同），随 iCloud 设置同步，两台设备一致。
//  只影响「排布时绕开谁」；关联（一件事只画一次）始终看全部日历，保证两台设备画出同一张。
//

import Foundation

enum ExternalCalendarSettings {
    static let excludedKey = "calendar.busyExcludedTitles"

    /// 排布时**不**当作已占用的日历名（默认空 = 全部都算）。
    static var excludedTitles: [String] {
        get { UserDefaults.standard.stringArray(forKey: excludedKey) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: excludedKey) }   // 只存 Array（plist 类型）
    }

    /// 按设置过滤出参与排布的事件（纯函数，可单测）。全天事件不占时段。
    static func busy(_ events: [SystemCalendarEvent], excluding excluded: [String]) -> [SystemCalendarEvent] {
        let skip = Set(excluded)
        return events.filter { !$0.isAllDay && !skip.contains($0.calendarTitle) }
    }
}
