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
    let refiner: PlanRefining
    let calendarStore: FakeCalendarStore       // 假日历（预览页观察用）
    let routingStore: RoutingCalendarStore     // 写入走它：按设置转发 假/真
    let reminderStore: FakeReminderStore
    let focus: TimerOnlyFocusService

    init() {
        // 原型期：解析/排程大脑/微调走云端 Claude；未配 key / 离线 / 失败时各自回退本地。
        let anthropic = AnthropicClient()
        self.parser = ClaudeScheduleParser(client: anthropic, fallback: StubScheduleParser())
        self.planner = LLMPlanningEngine(client: anthropic, fallback: NaivePlanningEngine())
        self.refiner = ClaudePlanRefiner(client: anthropic)
        self.calendarStore = FakeCalendarStore()
        self.routingStore = RoutingCalendarStore(fake: calendarStore, eventKit: EventKitCalendarStore())
        self.reminderStore = FakeReminderStore()
        self.focus = TimerOnlyFocusService()
    }

    /// 用例：自然语言 → 排程（不写日历，写入交给确认步骤）。
    var arrangeDay: ArrangeDayUseCase {
        ArrangeDayUseCase(parser: parser, planner: planner)
    }
}
