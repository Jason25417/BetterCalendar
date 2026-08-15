//
//  AppContainer.swift
//  BetterCalendar
//
//  唯一组装点：在这里创建所有 Service 实现并注入。换实现（本地→云端等）只改这里。
//  日历/提醒 = 真 EventKit（假日历族 2026-07-22 删除）；解析/排程 = 云端优先、本地兜底。
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
    /// 长期任务的「说一句」（2026-07-20）：同一个框既能加新的、也能改现有的。
    let longTaskRefiner: LongTaskRefining
    // 假日历族退役删除（2026-07-22 Jason 拍板「直接删掉」）：Routing/Fake/CalendarSettings/预览页全删——
    // 生产只有一条路=真 EventKit；Fake 仅测试注入（文件已挪 BetterCalendarTests/）。
    let calendarStore: CalendarStore           // 写/读真 Apple 日历（EventKit）
    let reminderStore: ReminderStore           // 写真提醒事项（EventKit VTODO）
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
    let milestones: MilestoneStore             // 成就系统（#27）：累计里程碑（iCloud KV，零 schema）
    let journalStore: JournalStore             // 反思层（日记）数据（M9/R1）
    let photoStore: PhotoStore                 // 日记照片：SwiftData(CKAsset 跨端) + 本地缓存
    let projection: ProjectionService          // PlanStore→日历 单向投影（重构 P2）：唯一写绿/橙计划事件的地方
    let reconcile: ReconcileService            // 双向同步（0.20）：日历手改按 ID 回流；与旧反向同步本质不同（指纹防回环）
    let reschedule: RescheduleService          // re-flow 编排（晨间 / 全天连续）
    let liveActivity: ExecutionLiveActivity    // 灵动岛/锁屏实时计时（iOS 真实现，macOS no-op）
    let execution: ExecutionViewModel          // menu bar 单键导航（App 级常驻，共享一份）
    let bench: BenchRunner                     // 算法试验台（开发期，macOS 窗口；不碰真日历/真相源）
    let learning: LearningStore                // 学习层采集端（E4：快照 save-once + 残差兜底折算）
    let changeTraces = ChangeTraceStore()      // 变更痕迹（E5b 数据层：直写绿的配套义务，UI=E5d）
    let timeline: TimelineCoordinator          // 时间线协调器（E5b 影子接生产：算/写/标/记）
    #if os(macOS)
    var distractionSensor: MacDistractionSensor!   // 分心自动休息感知器（#26；开关关着=只空转 10s tick）
    #endif

    init() {
        // 日历后端唯一实现=EventKit（假日历族 2026-07-22 全删，历史见 handoff/记忆 calendar-backend-retired-force-eventkit）。
        // 原型期：解析/排程大脑/微调走云端 Claude；未配 key / 离线 / 失败时各自回退本地。
        let anthropic = AnthropicClient()
        // 解析链 v2（2026-07-11「只使用端侧」定稿）：默认=云端 Claude（Haiku·三路对冲）优先、
        // 失败→端侧 FM 兜底、再失败=FailedScheduleParser 干净失败态（0.26 删 Stub，不产垃圾草稿）；
        // 「只使用端侧」开=FM only 绝不出云。两级都接流式冒块（0.20.1 云端也流式）。
        let cloudParser = ClaudeScheduleParser(client: anthropic, fallback: FailedScheduleParser(),
                                               liveDraft: liveDraft)
        self.parser = FoundationModelsScheduleParser(fallback: cloudParser, liveDraft: liveDraft)
        // 排程大脑（#41 跑分定案，2026-07-20 Jason 拍板切换）：默认=**分步排序** HybridArranger——
        // LLM 只做语义标注（认知负荷/宜趁早/先后依赖），排布交本地确定性算法。
        // 跑分实证（10 轮 × 6 题）：分步 50/60 > 规则 40/60 > 现行单步 LLM 33/60；
        // 现行单步在 S3 锚点 0/10、S4 ★序 3/10 稳定翻车（给标题反而让模型自作主张覆盖机械规则）。
        // 失败回退 Naive；「只使用端侧」开 → 直接 Naive（隐私闸，见 PrivacyGatedPlanningEngine）。
        // 脱敏变体（#41②）跑分被规则组严格支配（同分更慢更贵隐私更弱）→ 留在试验台不进生产。
        self.planner = PrivacyGatedPlanningEngine(
            llm: HybridArranger(client: anthropic, fallback: NaivePlanningEngine()),
            local: NaivePlanningEngine())
        // 微调链 v2：默认=云端 Claude 优先、失败→端侧 FM 兜底、均败=保持原样；「只使用端侧」开=FM only
        self.refiner = FoundationModelsPlanRefiner(fallback: ClaudePlanRefiner(client: anthropic))
        self.calendarStore = EventKitCalendarStore()
        self.reminderStore = EventKitReminderStore()
        self.exporter = ICSExporter()
        self.comparer = OverlapTitleComparer()
        self.notificationDelegate = NotificationDelegate(router: router)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        self.notifier = UNNotificationService()
        self.planStore = PlanStore()
        self.learning = LearningStore()   // E5b：提前建——复盘/日记基线（D11）要用
        // 日记引子基线（E5b/D11）：计划侧=当日最初快照优先（直写绿后真相=活预报，不再当基线用）
        self.reflectionContext = ReflectionContextProvider(planStore: planStore, comparer: comparer,
                                                           learning: learning)
        self.longTasks = LongTaskStore()
        self.reviewStore = ReviewLocalStore()
        self.milestones = MilestoneStore(reviewStore: reviewStore)
        self.journalStore = JournalStore()
        self.photoStore = PhotoStore(context: SharedModelContainer.shared.mainContext)
        self.projection = ProjectionService(planStore: planStore, calendarStore: calendarStore,
                                            startedDays: startedDays)
        // 0.20 双向同步：按 ID 对账回流（旧的标题模糊匹配反向同步已在 0.19 删除，这是它的安全重生版）
        self.reconcile = ReconcileService(planReader: planStore, planWriter: planStore,
                                          calendarStore: calendarStore, projection: projection,
                                          startedDays: startedDays)
        // L2 固化（2026-07-10 拍板）：reflow 默认走本地 V2（试验台 50/50 满分、瞬时、零出云）；
        // LLM reflow 保留在试验台作对照。arrange 仍走 LLM（self.planner），待试验台跑分后再议。
        self.reschedule = RescheduleService(planStore: planStore, planner: NaivePlanningEngine())
        #if os(iOS)
        self.liveActivity = ActivityKitLiveActivity()   // iOS：灵动岛 + 锁屏实时模块
        #else
        self.liveActivity = NoLiveActivity()            // macOS：无 Live Activity → no-op
        #endif
        self.execution = ExecutionViewModel(calendarStore: calendarStore, reschedule: reschedule,
                                            planStore: planStore, reminderStore: reminderStore,
                                            liveActivity: liveActivity,
                                            sessionStore: ExecutionSessionStore(),
                                            startedDays: startedDays, projection: projection)
        self.longTaskRefiner = ClaudeLongTaskRefiner(client: anthropic)
        self.bench = BenchRunner(client: anthropic)
        // E5b 时间线协调器（影子期：只动实时日真相、不碰投影；三层分频见 §14.1）
        self.timeline = TimelineCoordinator(planStore: planStore, startedDays: startedDays,
                                            traces: changeTraces)
        timeline.progress = execution
        timeline.start()
        TimelineCoordinator.sharedForDev = timeline   // 引擎观察窗桥（开发期，M8 摘除）
        execution.minutePulse = { [weak timeline] in timeline?.notePulse() }   // 分钟兜底（不新增定时器）
        self.logSync = LogSyncService()
        logSync.start()
        SettingsSync.start()   // #35：设置跨端同步（平台中立偏好镜像 iCloud KV；白名单外/设备专属项不同步）
        reconcile.start()
        ExecutionBridge.shared = execution   // Focus Filter 联动直达口（§5.7）
        #if os(macOS)
        // 分心自动休息（#26 V1）：mac 前台感知 → 执行层换挡（iOS 腿=快捷指令自动化调同一入口）
        let exec = execution
        self.distractionSensor = MacDistractionSensor { enable in
            await ExecutionBridge.shared?.distractionAutoBreak(enable)
        }
        distractionSensor.isRelevant = { [weak exec] in exec?.active != nil }
        #endif
    }

    /// 用例：自然语言 → 排程（不写日历，写入交给确认步骤）。
    var arrangeDay: ArrangeDayUseCase {
        ArrangeDayUseCase(parser: parser, planner: planner)
    }

    /// 复盘 VM（每次进视图新建一份；依赖从容器取）。
    var reviewModel: ReviewViewModel {
        ReviewViewModel(calendarStore: calendarStore, comparer: comparer,
                        arrangeDay: arrangeDay, localStore: reviewStore,
                        longTasks: longTasks, planStore: planStore, looseDays: looseDays,
                        learning: learning)   // E5b/D11：计划基线=当日最初快照
    }

    // MARK: 页面依赖包（反向依赖清零 2026-07-12：Features 不再见 AppContainer，按页注入所需具体依赖）

    var homeDeps: HomeDeps {
        HomeDeps(arrangeDay: arrangeDay, refiner: refiner,
                 calendarStore: calendarStore, reminderStore: reminderStore,
                 exporter: exporter, planStore: planStore, projection: projection,
                 notifier: notifier, longTasks: longTasks, draftSnapshots: draftSnapshots,
                 looseDays: looseDays, startedDays: startedDays, execution: execution,
                 liveDraft: liveDraft, journalStore: journalStore, router: router,
                 reconcile: reconcile)
    }

    var journalDeps: JournalDeps {
        JournalDeps(journalStore: journalStore, milestones: milestones, photoStore: photoStore,
                    reflectionContext: reflectionContext, router: router,
                    makeReviewModel: { self.reviewModel },
                    longTasks: longTasks)   // #40 批3：收尾轻问「推进到哪了？」
    }
}
