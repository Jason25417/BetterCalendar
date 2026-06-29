//
//  AppContainer.swift
//  BetterCalendar
//
//  唯一组装点：在这里创建所有 Service 实现并注入。换实现（假→真、本地→云端）只改这里。
//  原型期：解析/排程走本地兜底；日历/提醒走假 Store（不碰系统）。
//

import Foundation
import Observation

@Observable
final class AppContainer {
    let parser: ScheduleParsing
    let planner: PlanningEngine
    let calendarStore: FakeCalendarStore
    let reminderStore: FakeReminderStore
    let focus: TimerOnlyFocusService

    init() {
        self.parser = StubScheduleParser()
        self.planner = NaivePlanningEngine()
        self.calendarStore = FakeCalendarStore()
        self.reminderStore = FakeReminderStore()
        self.focus = TimerOnlyFocusService()
    }

    /// 用例：自然语言 → 排程 → 写（假）日历。GUI 与未来的 App Intent 共用。
    var arrangeDay: ArrangeDayUseCase {
        ArrangeDayUseCase(parser: parser, planner: planner, calendarStore: calendarStore)
    }
}
