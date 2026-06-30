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
    let routingStore: RoutingCalendarStore     // 写日历走它：按设置转发 假/真
    let reminderStore: FakeReminderStore
    let routingReminder: RoutingReminderStore  // 写提醒走它：同一开关，假/真
    let focus: TimerOnlyFocusService
    let exporter: ICSExporting
    let comparer: PlanComparing                // 计划 × 实际 → 完成度（本地启发式）
    let notifier: NotificationScheduling       // 早晚极简通知
    let planStore: PlanStore                   // 计划块真相源（SwiftData，reflow 读元数据）
    let calendarSync: CalendarSyncService      // 日历→真相库反向同步（你在日历改动→PlanBlock 跟着改）
    let reschedule: RescheduleService          // re-flow 编排（晨间 / 全天连续）
    let execution: ExecutionViewModel          // menu bar 单键导航（App 级常驻，共享一份）

    init() {
        // 原型期：解析/排程大脑/微调走云端 Claude；未配 key / 离线 / 失败时各自回退本地。
        let anthropic = AnthropicClient()
        self.parser = ClaudeScheduleParser(client: anthropic, fallback: StubScheduleParser())
        self.planner = LLMPlanningEngine(client: anthropic, fallback: NaivePlanningEngine())
        self.refiner = ClaudePlanRefiner(client: anthropic)
        self.calendarStore = FakeCalendarStore()
        self.routingStore = RoutingCalendarStore(fake: calendarStore, eventKit: EventKitCalendarStore())
        self.reminderStore = FakeReminderStore()
        self.routingReminder = RoutingReminderStore(fake: reminderStore, eventKit: EventKitReminderStore())
        self.focus = TimerOnlyFocusService()
        self.exporter = ICSExporter()
        self.comparer = OverlapTitleComparer()
        self.notifier = UNNotificationService()
        self.planStore = PlanStore()
        self.calendarSync = CalendarSyncService(calendarStore: routingStore, planStore: planStore)
        self.reschedule = RescheduleService(planStore: planStore, planner: planner)
        self.execution = ExecutionViewModel(calendarStore: routingStore, reschedule: reschedule,
                                            planStore: planStore, reminderStore: routingReminder)
        calendarSync.start()
    }

    /// 用例：自然语言 → 排程（不写日历，写入交给确认步骤）。
    var arrangeDay: ArrangeDayUseCase {
        ArrangeDayUseCase(parser: parser, planner: planner)
    }

    /// 复盘 VM（每次进视图新建一份；依赖从容器取）。
    var reviewModel: ReviewViewModel {
        ReviewViewModel(calendarStore: routingStore, comparer: comparer, arrangeDay: arrangeDay)
    }
}
