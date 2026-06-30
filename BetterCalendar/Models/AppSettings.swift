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
    var defaultTimingStyle: TimingStyle = TimingStyle.light
    var hideCompletionRate: Bool = true
    var notifyMode: NotifyMode = NotifyMode.withFixedBlocks
    var parserMode: ParserMode = ParserMode.cloudLLM
    var calendarBackend: CalendarBackend = CalendarBackend.fake
    var pushIntensity: Int = 0   // 0 温和（默认）… 2 强
    // 反思层（日记）预留项，功能后做
    var journalPrivacyLock: Bool = false
    var defaultEditorFormat: String = "markdown"   // "markdown" | "richtext"

    init(defaultTimingStyle: TimingStyle = .light,
         hideCompletionRate: Bool = true,
         notifyMode: NotifyMode = .withFixedBlocks,
         parserMode: ParserMode = .cloudLLM,
         calendarBackend: CalendarBackend = .fake,
         pushIntensity: Int = 0,
         journalPrivacyLock: Bool = false,
         defaultEditorFormat: String = "markdown") {
        self.defaultTimingStyle = defaultTimingStyle
        self.hideCompletionRate = hideCompletionRate
        self.notifyMode = notifyMode
        self.parserMode = parserMode
        self.calendarBackend = calendarBackend
        self.pushIntensity = pushIntensity
        self.journalPrivacyLock = journalPrivacyLock
        self.defaultEditorFormat = defaultEditorFormat
    }
}
