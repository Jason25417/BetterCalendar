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
    let startedDays = StartedDayStore(persisted: !TestHost.isActive)        // 「已开始今天」标记（绿色淡出=实时模式）
    let liveDraft = LiveDraft()                // 端侧流式解析的「进行中部分块」（边生成边显示）
    let logSync: LogSyncService                // 跨端日志：DevLog→CloudKit→(Mac)容器纯文本
    let reviewStore: ReviewLocalStore          // 活跃天数 + 今日 MVP（SwiftData，跨端同步）
    let milestones: MilestoneStore             // 成就系统（#27）：累计里程碑（iCloud KV，零 schema）
    let journalStore: JournalStore             // 反思层（日记）数据（M9/R1）
    let photoStore: PhotoStore                 // 日记照片：SwiftData(CKAsset 跨端) + 本地缓存
    let trash: RetainedTrashService
    let projection: ProjectionService          // PlanStore→日历 单向投影（重构 P2）：唯一写绿/橙计划事件的地方
    let reconcile: ReconcileService            // 双向同步（0.20）：日历手改按 ID 回流；与旧反向同步本质不同（指纹防回环）
    let reschedule: RescheduleService          // re-flow 编排（晨间 / 全天连续）
    let liveActivity: ExecutionLiveActivity    // 灵动岛/锁屏实时计时（iOS 真实现，macOS no-op）
    let nativeJournal: any NativeJournalAccessing // Independent read/text-write capability, sharing the native command boundary.
    let nativeApprovals: NativeApprovalInbox
    let proposals: ProposalCenter              // SPEC §19 多端审批（CloudKit 中转；旧 nativeApprovals 冻结）
    let proposalStore: CloudKitProposalStore?  // 测试环境为 nil（内存中转）
    let agentMessages: AgentMessageCenter      // SPEC §19 C2–C4 智能体主动消息（打扰规则由 App 强制；默认关）
    let alertPush: ProposalAlertPushControl?   // SPEC §19 B5 可见推送开关（实验，默认关；测试环境为 nil）
    let agentBridge: AgentBridge?              // SPEC §19 P2：Mac 上与 BetterCalendar 智能体的桥接目录（iOS/测试为 nil）
    let nativeActions: NativeActionsViewModel
    let bridgeTasks: BridgeTaskViewModel       // BC 云端统一计时；与 Dots 共用同一记录（W5：开关开时改记在 iCloud）
    let sharedTimerControl: SharedTimerBackendControl   // W5 共享计时后端开关（默认旧通道；下次启动生效）
    private let sharedTimerStore: CloudKitSharedTimerStore?   // 仅 iCloud 后端时非 nil
    let execution: ExecutionViewModel          // menu bar 单键导航（App 级常驻，共享一份）
    let bench: BenchRunner                     // 算法试验台（开发期，macOS 窗口；不碰真日历/真相源）
    let learning: LearningStore                // 学习层采集端（E4：快照 save-once + 残差兜底折算）
    let changeTraces = ChangeTraceStore()      // 变更痕迹（E5b 数据层：直写绿的配套义务，UI=E5d）
    let aggregator = LearningAggregator()      // 学习层聚合桶（L3：只算不用，切生产=L5 回放门控）
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
        let actionJournal: any NativeActionJournaling = TestHost.isActive ? NativeActionMemoryJournal() : NativeActionFileJournal()
        self.nativeJournal = SwiftDataNativeJournal(context: SharedModelContainer.shared.mainContext, journal: actionJournal)
        let nativeItems = SwiftDataNativeItemWriter(context: SharedModelContainer.shared.mainContext, journal: actionJournal,
                                                    didSave: { [weak longTasks] in longTasks?.reload() })
        let nativeAlarms: any NativeAlarmScheduling
        #if os(iOS)
        nativeAlarms = AlarmKitNativeAlarms(journal: actionJournal)
        #else
        nativeAlarms = UnsupportedNativeAlarms()
        #endif
        // W5（SPEC §19.5 D1）：共享计时后端启动时决定一次。开关关（默认）= 旧通道，与改动前逐字一致；
        // 开关开且旧通道无进行中计时/待发命令时才切到 iCloud。设计见 docs/bc-shared-timer-icloud.md。
        let legacyTimerPersistence: any BridgeTaskPersisting = TestHost.isActive ? BridgeTaskMemoryPersistence() : BridgeTaskFilePersistence()
        let timerLaunch = TestHost.isActive ? (backend: SharedTimerBackend.stateBridge, note: String?.none)
            : SharedTimerSettings.launchDecision(requested: SharedTimerSettings.requested(), legacy: { try legacyTimerPersistence.load() })
        if let note = timerLaunch.note { DevLog.shared.warn("共享计时", note) }
        self.sharedTimerControl = SharedTimerBackendControl(active: timerLaunch.backend, launchNote: timerLaunch.note)
        switch timerLaunch.backend {
        case .stateBridge:
            self.sharedTimerStore = nil
            self.bridgeTasks = BridgeTaskViewModel(service: StateBridgeClient.shared,
                                                  persistence: legacyTimerPersistence,
                                                  enabled: { StateBridgeClient.shared.configured })
        case .icloud:
            let store = CloudKitSharedTimerStore(), persistence = BridgeTaskFilePersistence(relativePath: "SharedTimer/icloud-timer-v1.json")
            self.sharedTimerStore = store
            self.bridgeTasks = BridgeTaskViewModel(service: ICloudSharedTimerService(store: store, deviceId: FocusFollow.deviceID,
                                                                                     readFloor: (try? persistence.load())?.state?.readAt),
                                                  persistence: persistence, enabled: { true },
                                                  backend: .icloud, activePoll: 10, idlePoll: 30)
            DevLog.shared.info("共享计时", "本次运行计时记在 iCloud（zone BCSharedTimer）")
        }
        sharedTimerControl.tasks = bridgeTasks
        SharedTimerBackendControl.current = sharedTimerControl
        let reminders: NativeReminderScheduler? = TestHost.isActive ? nil : NativeReminderScheduler(system: UNNativeReminderSystem(), persistence: NativeReminderFilePersistence())
        let remote = NativeRemoteExecutor(service: StateBridgeClient.shared,
                                          persistence: TestHost.isActive ? NativeRemoteMemoryPersistence() : NativeRemoteFilePersistence(),
                                          writer: nativeItems, alarms: nativeAlarms, journal: nativeJournal, canonicalTasks: bridgeTasks, reminders: reminders)
        self.nativeApprovals = NativeApprovalInbox(service: StateBridgeClient.shared, persistence: TestHost.isActive ? NativeApprovalMemoryPersistence() : NativeApprovalFilePersistence(), notifier: NativeApprovalNotification(), notices: TestHost.isActive ? NativeApprovalNoticeMemoryPersistence() : NativeApprovalNoticeFilePersistence(), writer: nativeItems, journal: nativeJournal, reminders: reminders, mayApprove: { remote.permitsApproval($0) }, mayReviewOther: { remote.permitsCrossReview($0) }, mayReadOther: { remote.hasCurrentReviewGrant() })
        self.nativeActions = NativeActionsViewModel(writer: nativeItems, alarms: nativeAlarms, remote: remote, approvals: nativeApprovals)
        notificationDelegate.handleReminderViewed = { [weak reminders] raw in
            do { try reminders?.recordClick(raw) } catch { DevLog.shared.warn("普通提醒点击", error.localizedDescription) }
        }
        notificationDelegate.handleApprovalViewed = { [weak inbox = nativeApprovals] id in await inbox?.recordNotificationClick(id) }
        notificationDelegate.handleApprovalDecision = { [weak inbox = nativeApprovals] binding, decision in
            await inbox?.decideFromNotification(binding, decision: decision)
        }
        if !TestHost.isActive { Task { await NativeApprovalNotification.registerCategories() } }
        // SPEC §19 多端审批：CloudKit 私有库独立 zone；测试环境走内存中转、不碰网络与通知中心。
        if TestHost.isActive {
            self.proposalStore = nil
            self.alertPush = nil
            self.agentMessages = AgentMessageCenter(transport: InMemoryAgentMessageTransport(), notifier: SilentAgentMessageNotifier(),
                                                    ledger: MemoryOperationLedger(), deviceId: "test-host",
                                                    defaults: UserDefaults(suiteName: "bc-test-attention")!)
            self.proposals = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(),
                                            notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(),
                                            deviceId: "test-host", deviceLabel: "测试")
        } else {
            let store = CloudKitProposalStore()
            self.proposalStore = store
            self.alertPush = ProposalAlertPushControl(store: store)
            self.agentMessages = AgentMessageCenter(transport: CloudKitAgentMessageStore(), notifier: LocalAgentMessageNotifier(),
                                                    ledger: FileOperationLedger(), deviceId: ProposalDevice.id)
            self.proposals = ProposalCenter(transport: ConflictCheckedProposalTransport(store: store), executor: ExperimentOnlyExecutor(),
                                            notifier: LocalProposalNotifier(), ledger: FileOperationLedger(),
                                            deviceId: ProposalDevice.id, deviceLabel: ProposalDevice.label)
        }
        notificationDelegate.handleAgentMessage = { [weak messages = agentMessages] id, reaction in
            if let reaction { await messages?.react(id, reaction) } else { await messages?.refresh() }
        }
        notificationDelegate.handleProposal = { [weak center = proposals] id, decision in
            if let decision { await center?.decide(id, decision) } else { await center?.refresh() }
        }
        if !TestHost.isActive, let store = proposalStore {
            ProposalWake.onPush = { [weak center = proposals, weak messages = agentMessages] in
                await center?.refresh(); await messages?.refresh()
            }
            Task { [weak center = proposals] in
                await LocalProposalNotifier.registerCategories()
                await LocalAgentMessageNotifier.registerCategories()
                do { try await store.ensureSubscription() } catch {
                    DevLog.shared.error("多端审批", "订阅审批推送失败（将靠前台轮询兜底）：\(error.localizedDescription)")
                }
                await center?.refresh()
            }
            proposals.startPolling()
            #if DEBUG
            // 开发期：带 BC_DEV_SEED_CLOUDKIT=1 启动 → 发一条测试提案 + 一条测试消息（空改动、不碰真实数据），
            // 用于在 CloudKit Development 环境建出 BCProposal / BCAgentMessage 记录类型，再部署到 Production。
            // 开发期：带 BC_DEV_SEED_ALERT_SUB=1 启动 → 在 Development 建出 B5 的查询订阅（订阅类型属于 schema，须部署后正式环境才能开）。
            if ProcessInfo.processInfo.environment["BC_DEV_SEED_ALERT_SUB"] == "1", let alertPush {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await alertPush.set(true)
                    print("BC_DEV_SEED alertSub enabled=\(alertPush.enabled) error=\(alertPush.lastError ?? "none")")
                }
            }
            if ProcessInfo.processInfo.environment["BC_DEV_SEED_CLOUDKIT"] == "1" {
                Task { [weak center = proposals, weak messages = agentMessages] in
                    try? await Task.sleep(for: .seconds(3))
                    let p = await center?.submit(ProposalDraft(origin: .user, originLabel: "Claude（开发：建立云端数据结构）",
                        title: "测试改动（建立数据结构）", changes: [ProposalChange(field: "测试字段", before: "旧值", after: "新值")],
                        reason: "开发：在 CloudKit Development 建出记录类型", action: .experimentNoop(note: "seed"), experiment: true))
                    let m = await messages?.receive(AgentMessageDraft(title: "测试消息", body: "开发：建立云端数据结构，无需操作。", reason: "seed"))
                    DevLog.shared.info("多端审批·种子", "提案=\(p.map { $0.id.uuidString } ?? "失败：\(center?.lastError ?? "?")") 消息=\(m.map { $0.id.uuidString } ?? "失败：\(messages?.lastError ?? "?")")")
                    print("BC_DEV_SEED proposal=\(p?.id.uuidString ?? "FAIL \(center?.lastError ?? "")") message=\(m?.id.uuidString ?? "FAIL \(messages?.lastError ?? "")")")
                }
            }
            #endif
            #if DEBUG && os(macOS)
            DevProposalHooks.install(center: proposals)
            #endif
        }
        nativeApprovals.start()
        remote.startPolling()
        if !TestHost.isActive {
            StateBridgeCollector.shared.installPoolReader(SwiftDataBridgePoolReader(context: SharedModelContainer.shared.mainContext))
        }
        self.reviewStore = ReviewLocalStore()
        self.milestones = MilestoneStore(reviewStore: reviewStore)
        self.journalStore = JournalStore()
        self.photoStore = PhotoStore(context: SharedModelContainer.shared.mainContext)
        self.projection = ProjectionService(planStore: planStore, calendarStore: calendarStore,
                                            startedDays: startedDays)
        // 0.20 双向同步：按 ID 对账回流（旧的标题模糊匹配反向同步已在 0.19 删除，这是它的安全重生版）
        self.trash = RetainedTrashService(context: SharedModelContainer.shared.mainContext,
                                          calendar: calendarStore, projection: projection)
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
                                            persistsRunState: !TestHost.isActive,
                                            startedDays: startedDays, projection: projection,
                                            canonicalTasks: bridgeTasks)
        bridgeTasks.onChange = { [weak execution] in execution?.syncCanonicalPresentation() }
        #if os(macOS)
        if TestHost.isActive {
            self.agentBridge = nil
        } else {
            // SPEC §19 A2：智能体看到的一天（全部只读；日记默认不给，面板开关允许后才附）。
            let context = AgentContextGatherer(
                planStore: planStore, actualStore: planStore, longTasks: longTasks, calendarStore: calendarStore,
                journalStore: journalStore,
                running: { [weak execution] in
                    guard let execution else { return .init() }
                    return .init(foreground: execution.active.map { .init(title: $0.title, start: $0.start, pausedSeconds: $0.pausedTotal,
                                                                          timingStyle: $0.timingStyle.rawValue) },
                                 background: execution.background.map { .init(title: $0.title, start: $0.start, pausedSeconds: $0.pausedTotal) },
                                 onBreak: execution.isOnBreak)
                })
            let bridge = AgentBridge(center: proposals, messages: agentMessages) { await context.snapshot() }
            self.agentBridge = bridge
            bridge.start()
            execution.onBlockFinished = { [weak bridge] title, seconds in
                bridge?.emit(kind: "block_finished", summary: "做完了「\(title)」（用时约 \(max(1, seconds / 60)) 分钟）",
                             payload: ["title": title, "seconds": seconds])
            }
        }
        #else
        self.agentBridge = nil
        #endif
        FocusFollow.personalTaskRefresh = { [weak bridgeTasks] in await bridgeTasks?.refresh(allowCommands: false) }
        if let sharedTimerStore {
            SharedTimerWake.onPush = { [weak bridgeTasks] in await bridgeTasks?.refresh(allowCommands: false) }
            Task {
                do { try await sharedTimerStore.ensureSubscription() }
                catch { DevLog.shared.warn("共享计时", "iCloud 计时订阅未建立（靠轮询兜底）：\(error.localizedDescription)") }
            }
        }
        bridgeTasks.startPolling()
        self.longTaskRefiner = ClaudeLongTaskRefiner(client: anthropic)
        self.bench = BenchRunner(client: anthropic)
        // E5b 时间线协调器（影子期：只动实时日真相、不碰投影；三层分频见 §14.1）
        self.timeline = TimelineCoordinator(planStore: planStore, startedDays: startedDays,
                                            traces: changeTraces)
        timeline.progress = execution
        timeline.longTasks = longTasks   // E5c：溢出硬执行 → 收待办区/回长期池
        timeline.start()
        TimelineCoordinator.sharedForDev = timeline   // 引擎观察窗桥（开发期，M8 摘除）
        execution.minutePulse = { [weak timeline] in timeline?.notePulse() }   // 分钟兜底（不新增定时器）
        self.logSync = LogSyncService()
        if !TestHost.isActive { logSync.start() }
        SettingsSync.start()   // #35：设置跨端同步（平台中立偏好镜像 iCloud KV；白名单外/设备专属项不同步）
        reconcile.start()
        DataSyncMonitor.shared.start { [weak longTasks, weak execution, weak aggregator, weak learning] in
            longTasks?.reload(); execution?.reloadImportedData()
            if let learning { aggregator?.reconcile(samples: learning.allSamples()) }
        }
        DataMaintenance.shared.start()
        FocusFollow.localHeartbeat = { [weak execution] in execution?.exportFocusStateNow() }
        FocusFollow.startPolling()
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
                        learning: learning,    // E5b/D11：计划基线=当日最初快照
                        timeline: timeline)    // E5c：溢出软标展示+逐件覆写
    }

    // MARK: 页面依赖包（反向依赖清零 2026-07-12：Features 不再见 AppContainer，按页注入所需具体依赖）

    var homeDeps: HomeDeps {
        HomeDeps(arrangeDay: arrangeDay, refiner: refiner,
                 calendarStore: calendarStore, reminderStore: reminderStore,
                 exporter: exporter, planStore: planStore, projection: projection,
                 notifier: notifier, longTasks: longTasks, draftSnapshots: draftSnapshots,
                 looseDays: looseDays, startedDays: startedDays, execution: execution,
                 liveDraft: liveDraft, journalStore: journalStore, router: router,
                 reconcile: reconcile, trash: trash, nativeActions: nativeActions,
                 timeline: timeline,                     // E5d：晨间摘要/痕迹条/一键撤
                 routines: RoutineTemplateStore.shared,  // K1：例行模板物化
                 proposals: proposals, agentMessages: agentMessages, alertPush: alertPush)
    }

    var journalDeps: JournalDeps {
        JournalDeps(journalStore: journalStore, milestones: milestones, photoStore: photoStore,
                    reflectionContext: reflectionContext, router: router,
                    makeReviewModel: { self.reviewModel },
                    longTasks: longTasks,   // #40 批3：收尾轻问「推进到哪了？」
                    timeline: timeline)     // E5c：盖章=溢出硬执行
    }
}
