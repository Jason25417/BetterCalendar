//
//  AppSettings.swift
//  BetterCalendar
//
//  App 自有设置。calendarBackend 决定写假日历还是真系统日历（开发期默认 fake）。
//

import Foundation
import SwiftData

@Model
final class AppSettings {
    var plannedCalendarID: String?
    var actualCalendarID: String?
    var defaultTimingStyle: TimingStyle
    var hideCompletionRate: Bool
    var notifyMode: NotifyMode
    var parserMode: ParserMode
    var calendarBackend: CalendarBackend
    var pushIntensity: Int   // 0 温和（默认）… 2 强

    init(defaultTimingStyle: TimingStyle = .light,
         hideCompletionRate: Bool = true,
         notifyMode: NotifyMode = .withFixedBlocks,
         parserMode: ParserMode = .cloudLLM,
         calendarBackend: CalendarBackend = .fake,
         pushIntensity: Int = 0) {
        self.defaultTimingStyle = defaultTimingStyle
        self.hideCompletionRate = hideCompletionRate
        self.notifyMode = notifyMode
        self.parserMode = parserMode
        self.calendarBackend = calendarBackend
        self.pushIntensity = pushIntensity
    }
}
