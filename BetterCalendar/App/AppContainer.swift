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
    let calendarStore: CalendarReading         // 真 Apple 日历（EventKit）的只读角色——P4.1：写角色只交给 CalendarSyncEngine
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
    let projection: CalendarSyncEngine         // 日历同步引擎（P4.1）：BetterCalendar 自家日历（绿/蓝）全 App 唯一写者（P4：橙色预览已退役）
    let reconcile: ReconcileService            // 双向同步（0.20）：日历手改按 ID 回流；与旧反向同步本质不同（指纹防回环）
    let reschedule: RescheduleService          // re-flow 编排（晨间 / 全天连续）
    let liveActivity: ExecutionLiveActivity    // 灵动岛/锁屏实时计时（iOS 真实现，macOS no-op）
    let nativeJournal: any NativeJournalAccessing // Independent read/text-write capability, sharing the native command boundary.
    let nativeApprovals: NativeApprovalInbox
    let proposals: ProposalCenter              // SPEC §19 多端审批（CloudKit 中转；旧 nativeApprovals 冻结）
    let proposalStore: CloudKitProposalStore?  // 测试环境为 nil（内存中转）
    let agentMessages: AgentMessageCenter      // SPEC §19 C2–C4 智能体主动消息（打扰规则由 App 强制；默认关）
    let agentChat: AgentChatCenter             // SPEC §19 A1/F1 跟智能体说话（iCloud BCChatMessage；Mac 桥接转交）
    let alertPush: ProposalAlertPushControl?   // SPEC §19 B5 可见推送开关（实验；W8 起没手动关过就默认开；测试环境为 nil）
    let agentBridge: AgentBridge?              // SPEC §19 P2：Mac 上与 BetterCalendar 智能体的桥接目录（iOS/测试为 nil）
    /// W20 智能体适配器：当前接通哪个实现（Claude Code 经桥接 / 内置 DeepSeek），事件只送给它；没接通的没有任何通道。
    let agentHub: AgentHub
    /// P4.1：另一台设备先发现的日历删除 → 转交给智能体（只 Mac 有；iOS/测试为 nil）
    private(set) var deletionRelay: CalendarDeletionRelay?
    let activity: ActivityRecording            // SPEC §19 W13：设备活动记录（实验，默认开；W14 哨兵读 activity.log）
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
    let sentinel: SentinelEngine?              // SPEC §19 C1 W14 哨兵：要不要叫醒智能体（W42 起 Mac 与 iPhone 都有；测试环境为 nil）
    let drift: PlanDriftMonitor?               // W51（0.80）自动顺延：落后 10 分钟本地按原顺序往后挪（可撤回、可点「我在做」）；测试环境为 nil
    /// W30（原则 11）：在场设备（你此刻在哪台）+ 一处响的触达出口。测试环境为 nil（通知照旧、不碰 iCloud KV）。
    let presence: DevicePresence?
    let reach: ReachOutlet?
    /// W30：早晚通知属于哪一天（跨设备，让每台都排一份）；测试环境为 nil。
    private(set) var sharedDailyDay: SharedDailyReminderDay?
    /// W30：「真正在用」的信号（Mac 键鼠 / 锁屏，iOS 前台心跳）。
    private(set) var activityProbe: UserActivityProbe?
    let speech: WhisperKitTranscriber?         // W38 端侧语音（Whisper）：全 App 一个模型；测试环境为 nil（只用苹果听写）
    #if os(macOS)
    var distractionSensor: MacDistractionSensor!   // 分心自动休息感知器（#26；开关关着=只空转 10s tick）
    #endif

    /// 哨兵（两端一份）：判断器首选 TypeSafe Jev（OpenRouter）→ OpenAI Decisions → Claude Haiku（Jason 10-18 同意把摘要发给 OpenRouter / OpenAI）。
    /// 通道跟着当前智能体走（Claude Code = Mac 的桥接目录；内置 = 进程内送达，见 AgentSentinelChannel）。
    private static func makeSentinel(hub: AgentHub, bridge: AgentBridge?, activityLog: FileActivityLog, context: AgentContextGatherer,
                                     proposals: ProposalCenter, chat: AgentChatCenter, messages: AgentMessageCenter,
                                     memory: AgentSharedMemoryStore, presence: DevicePresence?) -> SentinelEngine {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterCalendar/BuiltinAgent/sentinel", isDirectory: true)   // 沙盒容器内：日用 / Dev 各自一份
        let sentinel = SentinelEngine(judges: [JevSentinelJudge(), OpenAIDecisionsSentinelJudge(), ClaudeSentinelJudge()],
                                      log: FileSentinelDecisionLog(),
                                      bridge: AgentSentinelChannel(hub: hub, bridge: bridge, localRoot: root),
                                      activity: activityLog) { await context.gather(now: $0) }
        sentinel.recentAgentWakes = { [weak bridge] in
            (bridge?.runtime?.runs ?? []).filter { ($0.attempt ?? 0) >= 1 }
                .map { SentinelRecentWake(at: $0.at, kind: $0.kind ?? "?", summary: $0.summary ?? "") }
        }
        sentinel.recentNotices = { [weak messages] in
            (messages?.messages ?? []).map { SentinelRecentNotice(at: $0.createdAt, title: $0.title, delivered: $0.delivery == .delivered,
                                                                  suppressReason: $0.suppressReason, reaction: $0.reaction?.rawValue,
                                                                  wakeSignals: $0.wakeSignals ?? [], wakeSignature: $0.wakeSignature) }
        }
        // W42 源头去误报：待批提案在动的块 + 你最近在对话里说的话
        sentinel.pendingBlockIDs = { [weak proposals] in Set((proposals?.pending ?? []).flatMap(\.action.touchedBlockIDs)) }
        sentinel.recentUserChat = { [weak chat] in
            (chat?.messages ?? []).filter { $0.author == .user }.suffix(10).map { (at: $0.createdAt, text: $0.text) }
        }
        sentinel.attention = { [weak messages] in messages?.settings ?? AttentionSettings.load() }
        // W51：共享记忆 / 最近 24 小时对话 / 待批提案（智能体有、哨兵以前没有的）
        sentinel.sharedMemory = { [weak memory] in memory?.memory?.text }
        sentinel.recentChat = { [weak chat] in
            let cut = Date.now.addingTimeInterval(-24 * 3600)
            return (chat?.messages ?? []).filter { $0.createdAt >= cut }.suffix(12).map { (at: $0.createdAt, fromUser: $0.author == .user, text: $0.text) }
        }
        sentinel.pendingProposals = { [weak proposals] in (proposals?.pending ?? []).map { (at: $0.createdAt, title: $0.cardHeadline) } }
        // W42（原则 11）：只有在场设备判断
        sentinel.presenceGate = { [weak presence] in
            guard let p = presence?.current() else { return nil }
            #if os(macOS)
            let isMac = true
            #else
            let isMac = false
            #endif
            return SentinelFeedback.presenceSkip(p, myDeviceID: ProposalDevice.id, isMac: isMac)
        }
        return sentinel
    }

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
        // 读写合一：只在这里构造，写角色只交给下面的 CalendarSyncEngine。
        // W23b：测试宿主里注入内存日历（绝不碰真 EventKit；只按 TestHost 判断，生产恒真日历）
        let eventKitCalendar: any CalendarStore = TestHost.isActive ? TestHostCalendarStore() : EventKitCalendarStore()
        self.calendarStore = eventKitCalendar
        self.exporter = ICSExporter()
        self.comparer = OverlapTitleComparer()
        self.notificationDelegate = NotificationDelegate(router: router)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        // W30 一处响：在场设备 + 触达出口先建（各通知发送方都从它过）；在场记录 = 写权租约，租约建好后再接上（见下方）。
        if TestHost.isActive {
            self.presence = nil
            self.reach = nil
        } else {
            let presence = DevicePresence(deviceID: ProposalDevice.id, deviceLabel: ProposalDevice.label, devices: { KnownDevices.all() })
            let reach = ReachOutlet(deviceID: ProposalDevice.id, deviceLabel: ProposalDevice.label,
                                    presence: { presence.predicted(at: $0) },
                                    kv: ICloudSharedKV.shared, center: SystemReachCenter(), logDefaults: .standard)
            reach.scheduleEscalationCheck = { [weak reach] delay in
                Task { @MainActor [weak reach] in
                    try? await Task.sleep(for: .seconds(delay))
                    await reach?.runEscalations()
                }
            }
            presence.addObserver { [weak reach] in Task { @MainActor [weak reach] in await reach?.reevaluate() } }
            DevicePresence.sharedForDev = presence
            ReachOutlet.sharedForDev = reach
            notificationDelegate.reach = reach
            self.presence = presence
            self.reach = reach
        }
        self.notifier = UNNotificationService(reach: reach)
        self.planStore = PlanStore()
        self.learning = LearningStore()   // E5b：提前建——复盘/日记基线（D11）要用
        // 日记引子基线（E5b/D11）：计划侧=当日最初快照优先（直写绿后真相=活预报，不再当基线用）
        self.reflectionContext = ReflectionContextProvider(planStore: planStore, comparer: comparer,
                                                           learning: learning)
        self.longTasks = LongTaskStore()
        // W12（SPEC §19.13 Q5）：提醒事项 = BetterCalendar 自己东西的原生展示面（不是第二个真相源）。决定在 ReminderProjector，
        // EventKit 只是薄读写层；你在提醒事项里的操作（打勾 / 改时间 / 删除）记进操作留底，待办池截止被勾掉 = 做成了。
        let reminderOps = ReminderOpsRecorder(ledger: TestHost.isActive ? MemoryOperationLedger() : FileOperationLedger(),
                                              deviceId: ProposalDevice.id, pool: longTasks)
        let reminderProjector = ReminderProjector(access: TestHost.isActive ? TestHostReminderList() : EventKitReminderStore(), deviceId: ProposalDevice.id,
                                                  opsSink: { ops in await reminderOps.record(ops) })
        self.reminderStore = reminderProjector
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
        // W16：冻结的 BC 审批通知类别只在配置过 StateBridge 时注册（默认不动；也避免与下方多端审批类别并发覆盖）
        if !TestHost.isActive, StateBridgeClient.shared.configured { Task { await NativeApprovalNotification.registerCategories() } }
        // SPEC §19 多端审批：CloudKit 私有库独立 zone；测试环境走内存中转、不碰网络与通知中心。
        // W1 真改动执行器：事项现在就能接；计时 / 挪动计划块在执行层与时间线建好后挂上（见下方）。
        // 测试 host 不接真执行器（只做空改动），单测各自注入内存数据。
        let actionExecutor: ProposalActionExecutor? = TestHost.isActive ? nil
            : ProposalActionExecutor(items: longTasks, deviceId: ProposalDevice.id)
        // W8 D3：闹钟（iPhone 系统闹钟，复用 AlarmKitNativeAlarms）；提醒的本机通知兜底（复用 NativeReminderScheduler，W12 起提醒先写提醒事项）。
        actionExecutor?.askReminders = reminderProjector   // W12：「几点提醒我」写进提醒事项，两台设备都响
        // W32：你的日程 / 提醒的唯一写者——只交给审批执行器（每次写都是你批准的提案或你点的撤销）。
        // 测试宿主没有真执行器（actionExecutor 为 nil），这里也就不建；写者自身另有 EventKitWriteGuard。
        actionExecutor?.yourItems = EventKitYourItemsWriter()
        if let actionExecutor, let reminders {
            actionExecutor.notifications = NativeProposalNotificationScheduler(reminders: reminders, alarms: nativeAlarms)
            actionExecutor.knownDevices = { KnownDevices.all() }
        }
        if TestHost.isActive {
            self.proposalStore = nil
            self.alertPush = nil
            self.agentMessages = AgentMessageCenter(transport: InMemoryAgentMessageTransport(), notifier: SilentAgentMessageNotifier(),
                                                    ledger: MemoryOperationLedger(), deviceId: "test-host",
                                                    defaults: .standard)   // W25：测试宿主里 .standard = 本次运行的一次性 suite
            self.agentChat = AgentChatCenter(transport: InMemoryAgentChatTransport(), notifier: SilentAgentChatNotifier(),
                                             ledger: MemoryOperationLedger(), deviceId: "test-host", deviceLabel: "测试",
                                             defaults: .standard)
            self.proposals = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(),
                                            notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(),
                                            deviceId: "test-host", deviceLabel: "测试")   // 测试 host：一律先问你（不接规则）
        } else {
            let store = CloudKitProposalStore()
            self.proposalStore = store
            self.alertPush = ProposalAlertPushControl(store: store)
            self.agentMessages = AgentMessageCenter(transport: CloudKitAgentMessageStore(), notifier: LocalAgentMessageNotifier(reach: reach),
                                                    ledger: FileOperationLedger(), deviceId: ProposalDevice.id)
            self.agentChat = AgentChatCenter(transport: CloudKitAgentChatStore(), notifier: LocalAgentChatNotifier(reach: reach),
                                             ledger: FileOperationLedger(), deviceId: ProposalDevice.id, deviceLabel: ProposalDevice.label)
            // W10 分层预授权（A3a）：规则随设置同步（SettingsSync 白名单含 PreauthRuleStore.key）；没有规则 = 一律先问你。
            let rules = PreauthRuleStore()
            self.proposals = ProposalCenter(transport: ConflictCheckedProposalTransport(store: store), gate: PreauthRuleGate(store: rules), rules: rules,
                                            executor: actionExecutor ?? ExperimentOnlyExecutor(),
                                            notifier: LocalProposalNotifier(reach: reach), ledger: FileOperationLedger(),
                                            deviceId: ProposalDevice.id, deviceLabel: ProposalDevice.label, informDefaults: .standard)
            // W30：闹钟镜像——别的设备上设好的闹钟，本机到点安静放一份（「一处响」开关打开时）
            if let reach {
                let mirrors = AlarmMirrorSync(deviceID: ProposalDevice.id, center: SystemReachCenter(), reach: reach,
                                              devices: { KnownDevices.all() })
                proposals.afterNotificationsReconciled = { ps in await mirrors.sync(ps) }
            }
            _ = NotificationCenter.default.addObserver(forName: SettingsSync.didSyncRemotely, object: nil, queue: .main) { [weak rules] _ in
                MainActor.assumeIsolated { rules?.reload() }   // 另一台设备改了规则
            }
        }
        notificationDelegate.handleAgentMessage = { [weak messages = agentMessages] id, reaction in
            if let reaction { await messages?.react(id, reaction) } else { await messages?.refresh() }
        }
        // W8：打扰设置随 iCloud 设置同步——另一台设备改了（如静音）就重读。
        _ = NotificationCenter.default.addObserver(forName: SettingsSync.didSyncRemotely, object: nil, queue: .main) { [weak messages = agentMessages] _ in
            MainActor.assumeIsolated { messages?.reloadSettings() }
        }
        // 对话与主动消息共用同一份打扰设置（静音一处生效）与主动通知额度。
        agentChat.attention = { [weak messages = agentMessages] in messages?.settings ?? AttentionSettings.load() }
        agentChat.recentProactiveDeliveries = { [weak messages = agentMessages] in
            messages?.messages.filter { $0.delivery == .delivered }.map(\.createdAt) ?? []
        }
        notificationDelegate.handleAgentChat = { [weak chat = agentChat] _, text in
            if let text { await chat?.send(text) } else { await chat?.refresh() }
        }
        notificationDelegate.handleProposal = { [weak center = proposals] id, response in
            switch response {
            case .open: await center?.refresh()
            case let .decide(decision, choice): await center?.decide(id, decision, choice: choice)
            case let .reply(text): await center?.reply(id, text: text)   // W10：回一句 → 提案停止等待，转给智能体
            case .undo: await center?.undo(id)                           // W10：规则「做完告诉你」的结果通知上撤销
            }
        }
        // W10：你对提案回的一句话 → 对话消息（关联提案 id），Mac 桥接写成 user_message 事件（带 inReplyToProposal）。
        proposals.forwardReply = { [weak chat = agentChat] p, text in
            await chat?.send(text, inReplyToProposal: p.id) != nil
        }
        if !TestHost.isActive, let store = proposalStore {
            ProposalWake.onPush = { [weak center = proposals, weak messages = agentMessages, weak chat = agentChat] in
                await center?.refresh(); await messages?.refresh(); await chat?.refresh()
            }
            Task { [weak center = proposals, weak push = alertPush] in
                KnownDevices.announce()   // W8 D3：登记本机，智能体才知道 iPhone 的设备 id
                await LocalProposalNotifier.registerCategories()
                await LocalAgentMessageNotifier.registerCategories()
                await LocalAgentChatNotifier.registerCategories()
                do { try await store.ensureSubscription() } catch {
                    DevLog.shared.error("多端审批", "订阅审批推送失败（将靠前台轮询兜底）：\(error.localizedDescription)")
                }
                await push?.autoEnableIfNeverDisabled()   // W8：B5 默认开（你没手动关过时）
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
            // 开发期：带 BC_DEV_SEED_CHAT=1 启动 → 存一条智能体对话消息（主动型，按打扰规则通常不弹），
            // 用于在 CloudKit Development 建出 BCChatMessage 记录类型（字段 payload/author/text/kind/createdAtLocal），再部署到 Production。
            // 开发期：带 BC_DEV_SEED_TIMER=1 启动 → 写一条已结束、不显示的计时探针，在 Development 建出 BCTimerSession（W5）。
            if ProcessInfo.processInfo.environment["BC_DEV_SEED_TIMER"] == "1" {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    do { try await CloudKitSharedTimerStore().seedDevelopmentSchema(now: .now); print("BC_DEV_SEED timer=ok") }
                    catch { print("BC_DEV_SEED timer=FAIL \(error.localizedDescription)") }
                }
            }
            if ProcessInfo.processInfo.environment["BC_DEV_SEED_CHAT"] == "1" {
                Task { [weak chat = agentChat] in
                    try? await Task.sleep(for: .seconds(3))
                    let m = await chat?.receiveAgent(AgentChatReplyDraft(id: UUID(), text: "开发：建立云端数据结构（BCChatMessage），可忽略。"))
                    print("BC_DEV_SEED chat=\(m?.id.uuidString ?? "FAIL \(chat?.lastError ?? "")")")
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
            // W34 发版前自测：BC_DEV_SEED_W34=1 建本机本地测试数据 + 发一组提案；BC_DEV_CLEAN_W34=1 只清理（见 DevW34SelfTest）
            if ProcessInfo.processInfo.environment["BC_DEV_SEED_W34"] == "1" {
                Task { [weak center = proposals, weak items = longTasks] in
                    try? await Task.sleep(for: .seconds(4))
                    if let center, let items { await DevW34SelfTest.seed(center: center, items: items) }
                }
            }
            if ProcessInfo.processInfo.environment["BC_DEV_CLEAN_W34"] == "1" {
                Task { [weak items = longTasks] in if let items { await DevW34SelfTest.clean(items: items) } }
            }
            #endif
            #if DEBUG && os(macOS)
            DevProposalHooks.install(center: proposals, items: longTasks)
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
        actionExecutor?.journal = journalStore   // W32b：审批写日记（开关「允许智能体提议写日记」默认关）
        self.photoStore = PhotoStore(context: SharedModelContainer.shared.mainContext)
        self.projection = CalendarSyncEngine(planStore: planStore, calendarStore: eventKitCalendar)
        // 0.72.1：同步通道卡死时不拿本机（可能落后的）真相去盖 / 判日历（对账经 projection 读同一个开关）
        projection.transportTrusted = { !DataSyncMonitor.shared.isTransportWedged }
        // 0.20 双向同步：按 ID 对账回流（旧的标题模糊匹配反向同步已在 0.19 删除，这是它的安全重生版）
        self.trash = RetainedTrashService(context: SharedModelContainer.shared.mainContext, projection: projection)
        self.reconcile = ReconcileService(planReader: planStore, planWriter: planStore,
                                          calendarStore: calendarStore, projection: projection)
        // P4 Q3：你在苹果日历里删了 BetterCalendar 的块 → 照办后收进待办区（可找回）
        reconcile.collectTodo = { [weak longTasks] block, _ in
            guard let longTasks else { return false }
            _ = longTasks.addTodo(title: block.title, family: block.family, deadline: block.deadline)
            return true
        }
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
        // W26b/W26c：早晚通知重排器（批准的改动 + 时间线协调器的自动写共用一个）。测试宿主不接（不往测试进程里排真通知）
        let looseForReminders = looseDays, poolForReminders = longTasks
        let dailyReminders: DailyReminderRefresher? = TestHost.isActive ? nil : DailyReminderRefresher(
            plans: planStore, notifier: notifier,
            isLoose: { looseForReminders.isLoose($0) },
            pooledFromYesterday: {
                poolForReminders.todoItems()
                    .filter { $0.spilledFromDay.map { DayContext.isSameLogicalDay($0, .now) } ?? false }.count
            })
        // W30：早晚通知属于哪一天跨设备——别的设备保存了计划，本机也排一份（在场的那台响、其余安静）
        if let dailyReminders, reach != nil {
            let shared = SharedDailyReminderDay(kv: ICloudSharedKV.shared, deviceID: ProposalDevice.id, refresher: dailyReminders)
            DailyReminderDay.onRecord = { label in shared.publish(label) }
            self.sharedDailyDay = shared
        }
        if let actionExecutor {
            actionExecutor.timer = execution
            let mover = ApprovedPlanMover(planStore: planStore, projection: projection, startedDays: startedDays)
            mover.progress = execution
            // W18：你的日历 = 已占用（只读，与时间线协调器同一份设置过滤）。读失败 → 这次时间线改动不校验、明说（不当作空）
            let calendarForPlan = calendarStore
            mover.occupiedEvents = { window in
                ExternalCalendarSettings.busy(try await calendarForPlan.externalEvents(in: window),
                                              excluding: ExternalCalendarSettings.excludedTitles)
            }
            // W26b：批准的改动（含跨天挪）涉及已排早晚通知的那一天 → 按新计划重排（与今天页保存同一口径）
            mover.reminderRefresher = dailyReminders
            actionExecutor.mover = mover
        }
        // W13 设备活动记录：测试环境用临时目录、不启动任何采集（各组件单测各自注入假实现）。
        let activityRoot = TestHost.isActive
            ? FileManager.default.temporaryDirectory.appendingPathComponent("bc-test-activity-\(UUID().uuidString)", isDirectory: true)
            : FileActivityLog.defaultRoot
        let activity = ActivityRecording(log: FileActivityLog(root: activityRoot), deviceId: FocusFollow.deviceID)
        self.activity = activity
        ActivityRecording.current = activity
        // SPEC §19 A2：智能体看到的一天（全部只读；日记默认不给，面板开关允许后才附）。
        // W20：两端都建——内置智能体在 iPhone 上也读同一份快照（Claude Code 经 Mac 桥接的 context.json 也是它）。
        let context = AgentContextGatherer(
                planStore: planStore, actualStore: planStore, longTasks: longTasks, calendarStore: calendarStore,
                journalStore: journalStore, reminderStore: reminderStore,
                running: { [weak execution] in
                    guard let execution else { return .init() }
                    return .init(foreground: execution.active.map { .init(title: $0.title, start: $0.start, pausedSeconds: $0.pausedTotal,
                                                                          timingStyle: $0.timingStyle.rawValue) },
                                 background: execution.background.map { .init(title: $0.title, start: $0.start, pausedSeconds: $0.pausedTotal) },
                                 onBreak: execution.isOnBreak)
                },
                actionTargets: { [weak longTasks, weak execution] in
                    AgentBridgeContext.actionTargets(longTasks: longTasks, timer: execution?.proposalTimerState)
                })
        // W13：最近设备活动摘要进 context.json；日文件每轮同步镜像到 bridge/activity/。
        context.activitySummary = { [weak activity] now in await activity?.contextSummary(now: now) }
        // W21：功能使用摘要进 context.json（开关关着只写一句「未开启」）；汇总全表镜像到 bridge/usage.json（开着才写）。
        context.featureUsageSummary = { now in
            FeatureUsageExport.contextSection(FeatureUsageReporter.shared.report(now: now), enabled: FeatureUsageSettings.shareWithAgent)
        }
        // W20：智能体适配器 + 内置智能体（DeepSeek，key 在钥匙串 deepseek-api-key，iCloud 钥匙串同步）+ 角色共享记忆。
        // 测试 host：不读真快照、不接网络（单测各自注入假模型）；当前智能体照常读设置（默认 Claude Code）。
        let agentSelection = AgentSelection()
        let agentMemory = AgentSharedMemoryStore()
        let deepSeek = DeepSeekClient(apiKey: { TestHost.isActive ? nil : KeychainStore.loadAPIKey(account: DeepSeekClient.keychainAccount) })
        let builtinTools = BuiltinAgentToolbox(proposals: proposals, chat: agentChat, messages: agentMessages, memory: agentMemory,
                                               deviceLabel: ProposalDevice.label,
                                               web: TestHost.isActive ? nil : deepSeek,   // W40：搜索 / 读网页走同一个 DeepSeek key
                                               wakes: AgentWakeSchedule(),                  // 0.76：定时唤醒
                                               context: TestHost.isActive ? { [:] } : { await context.snapshot() })
        // W38：端侧 Whisper——开关开着就在后台下载 / 准备（昂贵网络等 Wi-Fi）；状态在设置页看得到
        if TestHost.isActive {
            self.speech = nil
        } else {
            let speech = WhisperKitTranscriber()
            speech.prepare()
            self.speech = speech
            #if DEBUG
            DevWhisperSelfTest.runIfRequested(speech)
            #endif
        }
        let builtinAgent = BuiltinAgentRuntime(model: deepSeek, tools: builtinTools, usage: BuiltinAgentUsageStore())
        builtinAgent.deviceLabel = ProposalDevice.label
        builtinAgent.autoStart = !TestHost.isActive
        #if os(iOS)
        builtinAgent.beginBackgroundWork = { name in BackgroundWork.begin(name) }
        #endif
        let hubLocal: AgentHub
        var sentinelBridge: AgentBridge? = nil
        #if os(macOS)
        if TestHost.isActive {
            self.agentBridge = nil
            hubLocal = AgentHub(selection: agentSelection, builtin: builtinAgent, memory: agentMemory, claudeCode: nil, deviceKind: .mac)
        } else {
            let bridge = AgentBridge(center: proposals, messages: agentMessages) { await context.snapshot() }
            self.agentBridge = bridge
            // W20：桥接只在「当前智能体 = Claude Code」时是通道；共享记忆经桥接给 Claude Code 读写。
            bridge.isActive = { [weak agentSelection] in agentSelection?.kind == .claudeCode }
            bridge.sharedMemory = agentMemory
            let hub = AgentHub(selection: agentSelection, builtin: builtinAgent, memory: agentMemory, claudeCode: bridge, deviceKind: .mac)
            hubLocal = hub
            bridge.activityMirror = { [weak activity] io in await activity?.mirror(to: io) }
            bridge.usageMirror = { io in FeatureUsageBridgeMirror.shared.mirror(to: io) }
            activity.startMac()   // 常驻记录（App 运行即记，含只剩菜单栏时）；开机自启实验期默认开
            // SPEC §19 A1/F1：桥接对话（转交你的消息、导入智能体回复、晚间复盘事件）；推送到达时立即同步一轮，压低转交延迟。
            bridge.chat = agentChat
            bridge.eveningFacts = { [weak execution] in
                AgentChatBridgeStep.eveningFacts(done: execution?.done.map { ($0.title, $0.start, $0.end) } ?? [])
            }
            let wake = ProposalWake.onPush
            ProposalWake.onPush = { [weak bridge] in await wake?(); await bridge?.sync() }
            bridge.start()   // W20：当前智能体不是 Claude Code 时 start 什么都不做（不轮询）
            sentinelBridge = bridge   // W42：哨兵统一在下面建（两端一份），Mac 上 Claude Code 接通时走这个桥接目录
            // P4 Q3：日历里删了块 → 已照办；写事件让智能体按上下文决定要不要问一句（不再弹四选窗）
            // P4.1：iPhone 先发现的删除——回执随 iCloud 到 Mac，中继补发一次（按块 id 去重，Mac 自己先发现的不重发）
            let relay = CalendarDeletionRelay(source: planStore)
            self.deletionRelay = relay
            reconcile.onUserDeleted = { [weak hub, weak relay] deletions in
                hub?.emit(kind: "calendar_user_deleted",
                          summary: AgentCalendarEvents.deletionSummary(deletions),
                          payload: AgentCalendarEvents.deletionPayload(deletions))
                relay?.markRelayed(deletions.map(\.block.id))
            }
        }
        #else
        self.agentBridge = nil
        hubLocal = AgentHub(selection: agentSelection, builtin: builtinAgent, memory: agentMemory, claudeCode: nil, deviceKind: .current)
        // W20：iPhone 上只有内置智能体有通道（Claude Code 的删块事件仍由 Mac 的中继补发，见下方 deletionRelay）。
        reconcile.onUserDeleted = { [weak hub = hubLocal] deletions in
            hub?.emit(kind: "calendar_user_deleted", summary: AgentCalendarEvents.deletionSummary(deletions),
                      payload: AgentCalendarEvents.deletionPayload(deletions))
        }
        if !TestHost.isActive { activity.startPhone() }   // iPhone：回前台传队列 + 回填运动/健康
        #endif
        let agentHub = hubLocal
        self.agentHub = agentHub
        // SPEC §19 C1 W14 哨兵：看设备活动 / 计划 / 计时，判断要不要叫醒智能体（只写 sentinel_wake 事件，从不直接通知你）。
        // W42：Mac 与 iPhone 都有；只有在场设备判断（判断不了时 Mac 判断、iPhone 不判断）；你点的「没用」回来校准它。
        if TestHost.isActive {
            self.sentinel = nil
        } else {
            let sentinel = Self.makeSentinel(hub: agentHub, bridge: sentinelBridge, activityLog: activity.log, context: context,
                                             proposals: proposals, chat: agentChat, messages: agentMessages, memory: agentMemory, presence: presence)
            self.sentinel = sentinel
            sentinel.start()
        }
        // W51（0.80）自动顺延：本地漂移监视器——落后 10 分钟按原顺序往后挪（走审批中心的自动顺延规则，可撤回）；
        // 只有在场设备推（同哨兵）；推过收工线 / 二次漂 / 放不下才叫智能体；回执上的「我在做」= 撤回 + 从原开始时间起计时。
        if TestHost.isActive {
            self.drift = nil
        } else {
            let drift = PlanDriftMonitor(planStore: planStore)
            drift.progress = execution
            let calendarForDrift = calendarStore
            drift.occupiedEvents = { window in
                ExternalCalendarSettings.busy(try await calendarForDrift.externalEvents(in: window), excluding: ExternalCalendarSettings.excludedTitles)
            }
            drift.isLooseDay = { [weak looseDays] in looseDays?.isLoose($0) ?? false }
            drift.presenceGate = { [weak presence] in
                guard let p = presence?.current() else { return nil }
                #if os(macOS)
                let isMac = true
                #else
                let isMac = false
                #endif
                return SentinelFeedback.presenceSkip(p, myDeviceID: ProposalDevice.id, isMac: isMac)
            }
            drift.syncCaution = { now in await DataSyncMonitor.shared.agentCaution(now: now) }
            drift.submit = { [weak proposals] in await proposals?.submit($0) }
            drift.proposal = { [weak proposals] id in proposals?.proposals.first { $0.id == id } }
            drift.undo = { [weak proposals] id in await proposals?.undo(id) ?? false }
            drift.notify = { [weak agentMessages] in await agentMessages?.receive($0) }
            drift.message = { [weak agentMessages] id in agentMessages?.messages.first { $0.id == id } }
            drift.acknowledge = { [weak agentMessages] id in await agentMessages?.react(id, .acknowledged) }
            drift.emit = { [weak agentHub] kind, summary, payload in agentHub?.emit(kind: kind, summary: summary, payload: payload) }
            drift.afterApplied = { [weak sentinel = self.sentinel] in sentinel?.invalidateContext() }
            drift.startTimer = { [weak execution] id, at in try await execution?.proposalStartTimer(blockId: id, title: nil, at: at) }
            notificationDelegate.handleReflowDoing = { [weak drift] id in await drift?.imDoing(messageId: id) }
            self.drift = drift
            drift.start()
        }
        // W20：做完一件事 → 当前智能体（两端；Claude Code 只在 Mac 有通道）。
        execution.onBlockFinished = { [weak agentHub] title, seconds in
            agentHub?.emit(kind: "block_finished", summary: "做完了「\(title)」（用时约 \(max(1, seconds / 60)) 分钟）",
                      payload: ["title": title, "seconds": seconds])
        }
        agentHub.eveningFacts = { [weak execution] in
            AgentChatBridgeStep.eveningFacts(done: execution?.done.map { ($0.title, $0.start, $0.end) } ?? [])
        }
        agentChat.onUserMessageStored = { [weak agentHub] m in agentHub?.userMessageStored(m) }
        // 0.74.1：哪台说的哪台回；Mac 拉到对话就看看有没有别的设备说了、却迟迟没人接的话（等满 20 秒再代接）
        agentChat.onRefreshed = { [weak agentHub] in if agentHub?.isPhone == false { agentHub?.pump() } }
        agentHub.scheduleHandoffCheck = { [weak agentHub, weak agentChat] delay in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay + 1))
                await agentChat?.refresh()
                await agentHub?.pumpMessages()
            }
        }
        proposals.didRefresh = { [weak agentHub] in agentHub?.proposalsRefreshed() }
        agentChat.activeAgent = { [weak agentSelection] in agentSelection?.kind ?? .claudeCode }
        _ = NotificationCenter.default.addObserver(forName: SettingsSync.didSyncRemotely, object: nil, queue: .main) { [weak agentSelection, weak agentMemory] _ in
            MainActor.assumeIsolated { agentSelection?.reload(); agentMemory?.reload() }   // 另一台设备切了智能体 / 改了共享记忆
        }
        if !TestHost.isActive {
            agentHub.apply(agentSelection.kind)
            agentHub.startTicking()
        }
        #if DEBUG
        // 开发期：带 BC_DEV_SEED_ACTIVITY=1 启动 → 往 iCloud zone BCActivity 传一条测试活动记录，
        // 用于在 CloudKit Development 建出 BCActivityEvent（字段 payload/at/kind/deviceId/platform/appName），再部署到 Production。
        if !TestHost.isActive, ProcessInfo.processInfo.environment["BC_DEV_SEED_ACTIVITY"] == "1" {
            Task {
                try? await Task.sleep(for: .seconds(3))
                let probe = ActivityEvent(at: .now, kind: .other, source: .live, deviceId: FocusFollow.deviceID, platform: ActivityShortcutRecorder.platform,
                                          appName: "开发：建立云端数据结构", detail: ["signal": "devSeed"])
                do { try await CloudKitActivityStore().upload([probe]); print("BC_DEV_SEED activity=ok \(probe.id.uuidString)") }
                catch { print("BC_DEV_SEED activity=FAIL \(error.localizedDescription)") }
            }
        }
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
        timeline.reminderRefresher = dailyReminders   // W26c：本机真写了自动调整 → 涉及已排早晚通知那天就重排
        // W22 写权租约：两台设备只让一台写自动调整（计时中的设备 > 最近回前台的 > 到期后先续约的）；租约存 iCloud KV。
        // 测试 host 不建（不碰真实 KV；协调器 writeLease=nil 即旧行为）
        if !TestHost.isActive {
            #if os(iOS)
            let releasesOnBackground = true    // iPhone 回后台会被挂起：没在计时就主动交出
            #else
            let releasesOnBackground = false   // Mac 后台照常运行
            #endif
            let lease = TimelineWriteLease(store: ICloudKVWriteLeaseStore(), deviceID: ProposalDevice.id,
                                           deviceLabel: ProposalDevice.label, deviceKind: ActivityDeviceKind.current.rawValue,
                                           releasesOnBackground: releasesOnBackground)
            lease.timing = { [weak execution] in
                guard let execution else { return (false, nil) }
                return (execution.active != nil || !execution.background.isEmpty, execution.activePrediction?.end)
            }
            timeline.writeLease = lease
            // W22b：手改冷却跨设备（同一 KV 存储的另一个键）
            timeline.sharedEdits = SharedRecentEdits(store: ICloudKVWriteLeaseStore(key: SharedRecentEdits.key))
            // W27：溢出「已结算」跨设备标记 + 被动完成（固定块到点 / 提醒打勾）也只由持有写权的设备记进真相
            timeline.sharedSpillMarks = SharedSpillMarks(store: ICloudKVWriteLeaseStore(key: SharedSpillMarks.key))
            execution.automaticWriteGate = { [weak lease] in lease?.mayWriteAutomatically() ?? true }
            TimelineWriteLease.sharedForDev = lease
            // W30：在场设备读这份租约；「真正在用」的信号只在「一处响」打开时去抢 / 交出租约（关着 = W22 行为不变，只刷新显示）
            presence?.attach(lease)
            #if os(macOS)
            let read: @MainActor () -> UserActivityProbe.Reading = { UserActivityProbe.macReading() }
            #else
            let read: @MainActor () -> UserActivityProbe.Reading = { [weak lease] in
                UserActivityProbe.Reading(idleSeconds: lease?.isForeground == true ? 0 : .infinity, locked: false)
            }
            #endif
            let probe = UserActivityProbe(read: read) { [weak lease, weak presence = self.presence] active, transition in
                if ReachSettings.onePlaceEnabled { lease?.noteUserActivity(active: active, transition: transition) }
                presence?.tick()
            }
            probe.start()
            self.activityProbe = probe
        }
        // P4 Q4：你的日历事件作为「已占用」参与排布（只读；按设置挑日历，默认全部）。读失败 = 不看（记日志）
        let calendarForBusy = calendarStore
        timeline.externalBusy = { window in
            do {
                return ExternalCalendarSettings.busy(try await calendarForBusy.externalEvents(in: window),
                                                     excluding: ExternalCalendarSettings.excludedTitles)
            } catch {
                DevLog.shared.warn("时间线", "读你的日历失败，这一轮排布不绕开它：\(error.localizedDescription)")
                return []
            }
        }
        projection.startFollowingTimeline()   // P4 Q2：协调器改了今天的真相 → 绿色跟着重画
        timeline.start()
        TimelineCoordinator.sharedForDev = timeline   // 引擎观察窗桥（开发期，M8 摘除）
        execution.minutePulse = { [weak timeline] in timeline?.notePulse() }   // 分钟兜底（不新增定时器）
        self.logSync = LogSyncService()
        if !TestHost.isActive { logSync.start() }
        SettingsSync.start()   // #35：设置跨端同步（平台中立偏好镜像 iCloud KV；白名单外/设备专属项不同步）
        reconcile.start()
        DataSyncMonitor.shared.start { [weak longTasks, weak execution, weak aggregator, weak learning, weak deletionRelay = self.deletionRelay, weak agentBridge = self.agentBridge, weak sharedDaily = self.sharedDailyDay] in
            longTasks?.reload(); execution?.reloadImportedData()
            // W30：计划数据同步到了 → 按共享的那一天重排本机的早晚通知（一处响打开时；关着 = no-op）
            if let sharedDaily { Task { await sharedDaily.adopt() } }
            // P4.1：另一台设备记下的日历删除 → 转交智能体（桥接没接通 / 事件关着就留着下次再试）
            deletionRelay?.relay { ds in
                guard let bridge = agentBridge, bridge.isActive(), bridge.eventsEnabled(), bridge.connected else { return false }
                bridge.emit(kind: "calendar_user_deleted", summary: AgentCalendarEvents.deletionSummary(ds),
                            payload: AgentCalendarEvents.deletionPayload(ds))
                return true
            }
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

    /// W30：回到前台——重算在场设备、按共享的那一天补排早晚通知、对齐一处响（收起别处已处理的 / 改派 / 升级）。
    @MainActor func reachForeground() async {
        presence?.tick()
        await sharedDailyDay?.adopt()
        await reach?.reevaluate()
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
                        timeline: timeline,    // E5c：溢出软标展示+逐件覆写
                        engine: projection)    // P4.1：补一笔画蓝经日历唯一写者
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
                 proposals: proposals, agentMessages: agentMessages, alertPush: alertPush,
                 agentChat: agentChat,   // W19：今天页底部「跟智能体说一句」
                 agentHub: agentHub)     // W20：设置里的「当前智能体」
    }

    var journalDeps: JournalDeps {
        JournalDeps(journalStore: journalStore, milestones: milestones, photoStore: photoStore,
                    reflectionContext: reflectionContext, router: router,
                    makeReviewModel: { self.reviewModel },
                    longTasks: longTasks,   // #40 批3：收尾轻问「推进到哪了？」
                    timeline: timeline)     // E5c：盖章=溢出硬执行
    }
}
