//
//  AppContainer.swift
//  BetterCalendar
//
//  唯一组装点：在这里创建所有 Service 实现并注入。换实现（假→真、本地→云端）只改这里。
//  原型期：解析/排程走本地兜底；日历/提醒走假 Store（不碰系统）。
//

import Foundation
import Observation
import SwiftData
import UserNotifications

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
    let router = AppRouter()                    // 跨标签页导航（复盘「写下今天」→ 日记页）
    let notificationDelegate: NotificationDelegate    // 通知 deep-link（点通知 → 对应页）
    let reflectionContext: ReflectionContextProvider  // 日记第一方情境（用当天数据当写作素材）
    let notifier: NotificationScheduling       // 早晚极简通知
    let planStore: PlanStore                   // 计划块真相源（SwiftData，reflow 读元数据）
    let longTasks: LongTaskStore               // 「在途」池：跨日任务/长线作业（M10）
    let draftSnapshots = DraftSnapshotStore()  // 排日程草稿快照（崩溃/重启还原）
    let looseDays = LooseDayStore()            // 松散日标记（退场姿态；iCloud KV，无 schema）
    let startedDays = StartedDayStore()        // 「已开始今天」标记（绿色淡出=实时模式）
    let liveDraft = LiveDraft()                // 端侧流式解析的「进行中部分块」（边生成边显示）
    let logSync: LogSyncService                // 跨端日志：DevLog→CloudKit→(Mac)容器纯文本
    let reviewStore: ReviewLocalStore          // 活跃天数 + 今日 MVP（SwiftData，跨端同步）
    let journalStore: JournalStore             // 反思层（日记）数据（M9/R1）
    let photoStore: PhotoStore                 // 日记照片：SwiftData(CKAsset 跨端) + 本地缓存
    let projection: ProjectionService          // PlanStore→日历 单向投影（重构 P2）：唯一写绿/橙计划事件的地方
    let reconcile: ReconcileService            // 双向同步（0.20）：日历手改按 ID 回流；与旧反向同步本质不同（指纹防回环）
    let reschedule: RescheduleService          // re-flow 编排（晨间 / 全天连续）
    let liveActivity: ExecutionLiveActivity    // 灵动岛/锁屏实时计时（iOS 真实现，macOS no-op）
    let execution: ExecutionViewModel          // menu bar 单键导航（App 级常驻，共享一份）
    let bench: BenchRunner                     // 算法试验台（开发期，macOS 窗口；不碰真日历/真相源）

    init() {
        // 假日历退役（2026-07-07 Jason 定）：设置页不再提供切换、一律写真 Apple 日历。
        // Fake 仅供单测/预览页；老设备存的 fake 选项在此收敛（tests 不建 AppContainer、不受影响）。
        CalendarSettings.backend = .eventKit
        // 原型期：解析/排程大脑/微调走云端 Claude；未配 key / 离线 / 失败时各自回退本地。
        let anthropic = AnthropicClient()
        // 解析兜底链：端侧 FM（试点、进阶设置开）→ 云端 Claude → 本地 Stub；两级都接流式冒块（0.20.1 云端也流式）
        // 终端兜底改 FailedScheduleParser（0.26 删 Stub）：端云全失败=干净失败态，不产垃圾草稿
        let cloudParser = ClaudeScheduleParser(client: anthropic, fallback: FailedScheduleParser(),
                                               liveDraft: liveDraft)
        self.parser = FoundationModelsScheduleParser(fallback: cloudParser, liveDraft: liveDraft)
        self.planner = LLMPlanningEngine(client: anthropic, fallback: NaivePlanningEngine())
        // 微调兜底链：端侧 FM（试点、进阶设置开）→ 云端 Claude
        self.refiner = FoundationModelsPlanRefiner(fallback: ClaudePlanRefiner(client: anthropic))
        self.calendarStore = FakeCalendarStore()
        self.routingStore = RoutingCalendarStore(fake: calendarStore, eventKit: EventKitCalendarStore())
        self.reminderStore = FakeReminderStore()
        self.routingReminder = RoutingReminderStore(fake: reminderStore, eventKit: EventKitReminderStore())
        self.focus = TimerOnlyFocusService()
        self.exporter = ICSExporter()
        self.comparer = OverlapTitleComparer()
        self.notificationDelegate = NotificationDelegate(router: router)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        self.notifier = UNNotificationService()
        self.planStore = PlanStore()
        // 日记引子读真相源（0.26.15 补迁移）：日历是投影——实时模式绿色淡出，从日历读会把做成的事全算成计划外
        self.reflectionContext = ReflectionContextProvider(planStore: planStore, comparer: comparer)
        self.longTasks = LongTaskStore()
        self.reviewStore = ReviewLocalStore()
        self.journalStore = JournalStore()
        self.photoStore = PhotoStore(context: SharedModelContainer.shared.mainContext)
        self.projection = ProjectionService(planStore: planStore, calendarStore: routingStore,
                                            startedDays: startedDays)
        // 0.20 双向同步：按 ID 对账回流（旧的标题模糊匹配反向同步已在 0.19 删除，这是它的安全重生版）
        self.reconcile = ReconcileService(planReader: planStore, planWriter: planStore,
                                          calendarStore: routingStore, projection: projection,
                                          startedDays: startedDays)
        self.reschedule = RescheduleService(planStore: planStore, planner: planner)
        #if os(iOS)
        self.liveActivity = ActivityKitLiveActivity()   // iOS：灵动岛 + 锁屏实时模块
        #else
        self.liveActivity = NoLiveActivity()            // macOS：无 Live Activity → no-op
        #endif
        self.execution = ExecutionViewModel(calendarStore: routingStore, reschedule: reschedule,
                                            planStore: planStore, reminderStore: routingReminder,
                                            liveActivity: liveActivity,
                                            sessionStore: ExecutionSessionStore(),
                                            startedDays: startedDays, projection: projection)
        self.bench = BenchRunner(client: anthropic)
        self.logSync = LogSyncService()
        logSync.start()
        reconcile.start()
        ExecutionBridge.shared = execution   // Focus Filter 联动直达口（§5.7）
    }

    /// 用例：自然语言 → 排程（不写日历，写入交给确认步骤）。
    var arrangeDay: ArrangeDayUseCase {
        ArrangeDayUseCase(parser: parser, planner: planner)
    }

    /// 复盘 VM（每次进视图新建一份；依赖从容器取）。
    var reviewModel: ReviewViewModel {
        ReviewViewModel(calendarStore: routingStore, comparer: comparer,
                        arrangeDay: arrangeDay, localStore: reviewStore,
                        longTasks: longTasks, planStore: planStore, looseDays: looseDays)
    }
}
