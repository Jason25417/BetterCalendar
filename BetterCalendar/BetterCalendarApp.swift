//
//  BetterCalendarApp.swift
//  BetterCalendar
//
//  @main + 组装点：建 AppContainer、注入 SwiftData 容器与首页。
//

import SwiftUI
import SwiftData

#if !(BC_SCHEMA_SEEDER && DEBUG && os(macOS))
@main
struct BetterCalendarApp: App {
    @State private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(DeveloperSettings.key) private var developerOptions = DeveloperSettings.defaultValue   // W16「开发者选项」
    #if os(macOS)
    // 菜单栏项改由 AppKit NSStatusItem 自管（潮汐式直显计时），不再用 MenuBarExtra。
    @State private var menuBar: MenuBarController?
    // 关窗不退出 → 常驻 menu bar（见 AppDelegate）。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    #if os(iOS)
    // 多端跟随（#30）：静默推送需要 UIKit delegate 缝
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var iosDelegate
    #endif

    init() { if !TestHost.isActive { StateBridgeCollector.shared.start() } }

    var body: some Scene {
        WindowGroup {
            themedRoot()
        }
        .modelContainer(SharedModelContainer.shared)

        #if os(macOS)
        Settings {
            // W19：审批记录与规则 / 晚间复盘 / 哨兵 都在设置里（子页要 NavigationStack 才推得进去）
            NavigationStack {
                SettingsView(trash: container.trash, nativeActions: container.nativeActions,
                             proposals: container.proposals, agentMessages: container.agentMessages,
                             alertPush: container.alertPush, agentHub: container.agentHub, bridge: container.agentBridge,
                             calendarStore: container.calendarStore)
            }
            .environment(container.sentinel)   // SPEC §19 C1 W14 哨兵区块（在「审批记录与规则」里）
            .environment(\.appTheme, ThemeSettings.current)
            .tint(ThemeSettings.current.accent)   // 体检 #9：独立 scene 不吃主窗 tint，跨端选中态一致
            .frame(minWidth: 520, idealWidth: 620, minHeight: 520, idealHeight: 720)
        }

        // 算法试验台（开发期）：入口=Home 工具栏烧瓶按钮 / 系统「窗口」菜单。上架前撤入口。
        Window("算法试验台", id: "algo-bench") {
            BenchView(runner: container.bench)
                .environment(\.appTheme, ThemeSettings.current)
        }
        .commandsRemoved()   // W16：不进「窗口」菜单；入口只在「开发者选项」打开时出现（Home 工具栏 / 设置）

        // 皮肤试衣间（开发期，美术样品阶段）：入口=Home 工具栏调色盘 / 窗口菜单。随开发件 M8 摘除。
        Window("皮肤试衣间", id: "skin-fitting") {
            SkinFittingView()
        }
        .commandsRemoved()   // W16：同上

        // SPEC §19 A1：跟 BetterCalendar 智能体说话。W19 起主窗口有「智能体」页；这个独立窗口只是并排用的便利（同一视图），
        // 入口 = 系统「窗口」菜单。
        Window("BetterCalendar 智能体", id: AgentChatWindow.id) {
            NavigationStack {
                AgentChatView(chat: container.agentChat, proposals: container.proposals, bridge: container.agentBridge, hub: container.agentHub,
                              focusId: container.router.proposalFocusId)
            }
            .environment(\.appTheme, ThemeSettings.current)
            .tint(ThemeSettings.current.accent)
            .frame(minWidth: 380, idealWidth: 460, minHeight: 420, idealHeight: 640)
        }

        // 引擎观察窗（开发期，统一时间线 P1 配套）：W16 起从 设置 → 开发者选项 打开。逐批扩节，M8 摘除。
        Window("引擎观察窗", id: "engine-window") {
            EngineWindowView()
                .environment(\.appTheme, ThemeSettings.current)
                .tint(ThemeSettings.current.accent)
        }
        .commandsRemoved()   // W16：入口改为 设置 → 开发者选项
        #endif
    }

    /// 根视图 + 皮肤注入（§5.9 接口：换主题=换这里注入的令牌组，视图逐步迁移消费）。
    @ViewBuilder
    private func themedRoot() -> some View {
        mainTabs()
            .environment(\.appTheme, ThemeSettings.current)
            // 换装批次A（2026-07-14，令牌表 v1）：全局 accent=暮色橙——所有主按钮/选中态一次换装
            .tint(ThemeSettings.current.accent)
            // #36 成就 toast：根级顶部浮层（8s 自动收/上划走/点进成就页；执行中由门控攒着）
            .overlay(alignment: .top) { AchievementToastView() }
            .toolbar {
                // 已冻结的 Dots 时代「BC 审批」入口（W16）：收在「开发者选项」后；通知点进来的路径（openNativeApprovals）不变
                if developerOptions {
                    Button { container.router.nativeApprovalPreviewRequest = nil; container.router.openNativeApprovals = true } label: { Label("待确认（已冻结）", systemImage: "checkmark.bubble").accessibilityIdentifier("bc.approvals.open") }
                }
                #if os(macOS)
                // W19（U6）：工具栏只留强约定的设置齿轮；原「对话」「多端审批」两个图标退役（智能体是主窗口里的一页，
                // 待确认卡置顶在那里，审批记录与规则在设置里）
                SettingsLink { Label("设置", systemImage: "gearshape") }
                    .help("设置（⌘,）")
                    .accessibilityIdentifier("bc.settings.open")
                #endif
            }
            // W19：通知「查看详情」/ 智能体消息 → 「智能体」页（待确认卡置顶在那里，按 proposalFocusId 高亮）
            .onChange(of: container.router.openProposals) { _, want in
                guard want else { return }
                container.router.openProposals = false
                container.router.selectedTab = .chat
            }
            .sheet(isPresented: Binding(get: { container.router.openNativeApprovals }, set: { container.router.openNativeApprovals = $0 })) {
                NavigationStack {
                    NativeApprovalContent(model: container.nativeApprovals, previewRequestId: container.router.nativeApprovalPreviewRequest)
                        .navigationTitle("BC 审批")
                        .toolbar { Button("关闭") { container.router.openNativeApprovals = false } }
                        .task(id: container.router.nativeApprovalCommandId) {
                            if let id = container.router.nativeApprovalCommandId {
                                await container.nativeApprovals.requestOpen(id)
                                if container.router.nativeApprovalCommandId == id { container.router.nativeApprovalCommandId = nil }
                            }
                        }
                }
                #if os(iOS)
                .presentationDetents([.large])
                #endif
                #if os(macOS)
                .frame(minWidth: 480, idealWidth: 620, maxWidth: 760, minHeight: 420, idealHeight: 650)
                #endif
            }
            .task { StateBridgeCollector.shared.start(); await StateBridgeCollector.shared.sample() }
    }

    @ViewBuilder
    private func mainTabs() -> some View {
            TabView(selection: Binding(get: { container.router.selectedTab },
                                       set: { container.router.selectedTab = $0 })) {
                // W19（S-v2）：两端同一套四页——今天 / 智能体 / 长期 / 日记。
                // 「今天」= 原「排日程」与 iPhone「今天」合并（现在 / 下一件 + 当天时间线 + 跟智能体说一句）。
                HomeView(deps: container.homeDeps)
                    .tag(AppRouter.Tab.schedule)
                    .tabItem { Label("今天", systemImage: "sun.max") }
                NavigationStack {
                    AgentChatView(chat: container.agentChat, proposals: container.proposals, bridge: container.agentBridge, hub: container.agentHub,
                                  focusId: container.router.proposalFocusId)
                }
                .tag(AppRouter.Tab.chat)
                .tabItem { Label("智能体", systemImage: "bubble.left.and.bubble.right") }
                #if os(iOS)
                .badge(container.agentChat.unreadCount)   // 只数智能体的新回复；待确认提案不进红点（U4：不处理就过期，零残留）
                #endif
                // #40 长期 tab（2026-07-15 S1 修订四 tab 终局）：第二时间尺度——跨日周期的排程态
                LongTermView(store: container.longTasks, router: container.router,
                             parser: container.parser,          // #40 批3：主入口=说一句
                             refiner: container.longTaskRefiner) // 2026-07-20：同一个框也能改现有
                    .tag(AppRouter.Tab.longterm)
                    .tabItem { Label("长期", systemImage: "tray.full") }
                JournalView(deps: container.journalDeps)
                    .tag(AppRouter.Tab.journal)
                    .tabItem { Label("日记", systemImage: "book") }
            }
            #if os(macOS)
            .onAppear {
                if menuBar == nil { menuBar = MenuBarController(model: container.execution) }
                handlePendingAppIntent()
                consumePrimeNextStart()
            }
            .onReceive(NotificationCenter.default.publisher(for: MenuBarPopoverHold.openJournalNotice)) { _ in
                // menu bar「回看今天」（0.28 收口轻入口）→ 主窗口切到日记页、展开今天
                container.router.selectedTab = .journal
                container.router.journalRequest = .now
            }
            #else
            .onAppear { handlePendingAppIntent(); consumePrimeNextStart() }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    handlePendingAppIntent(); consumePrimeNextStart()
                    DataSyncMonitor.shared.refreshNow()
                    StateBridgeCollector.shared.start()
                    Task { await StateBridgeCollector.shared.recover() }
                    Task { await container.bridgeTasks.refresh() }
                    Task { await container.nativeApprovals.refresh() }
                    // W16：冻结子系统的定时器只在已配置时才建；配置发生在启动之后的，回到前台补建（都幂等）
                    container.bridgeTasks.startPolling()
                    container.nativeApprovals.start()
                    container.nativeActions.remote?.startPolling()
                    Task { await container.proposals.refresh() }
                    Task { await container.agentMessages.refresh() }
                    // W20：内置智能体接通时，回前台补上没接手的你的消息 / 提案结论 / 晚间复盘（Claude Code 时什么都不做）
                    if container.agentHub.active == .builtin { Task { await container.agentChat.refresh(); container.agentHub.pump() } }
                }
                container.proposals.isForeground = phase == .active
                FocusFollow.setForeground(phase == .active)
            }
            // 早通知 deep-link（0.23 A）：打开执行界面 + 第一件「待开始」（不自动计时）
            .onChange(of: container.router.primeNextStart) { _, want in
                if want { consumePrimeNextStart() }
            }
            // 启动同步（0.20.2）：先对账（识别日历里攒的手改/新建/删除）再投影补章自愈；
            // 有待确认新建的日子暂缓投影（防止问都没问就清掉用户新建的事件）。幂等、无变更时零写入。
            .task { await container.reconcile.startupSync() }
            // E4：残差兜底折算——补折过去 7 天「有快照无样本」的日子（幂等；学习层采集端）；
            // E5c：随后补执行过去日欠着的溢出硬结算（先折后执行——数据面不相交，叙事顺序）
            .task {
                container.learning.foldPendingDays(planStore: container.planStore,
                                                   sessionStore: ExecutionSessionStore())
                // 测试 host 不动真库/真文件（闸放调用点：本体保持可测）
                if !TestHost.isActive {
                    container.timeline.executePendingSpills()
                    // L3：样本 → 聚合桶（幂等游标；只算不用，L5 回放过门才进排布）
                    container.aggregator.reconcile(samples: container.learning.allSamples())
                }
            }
            // 多端跟随（#30）：启动/回前台 catch-up（推送错过也收敛，同聪音对账哲学）+ 屏蔽联动接线
            .task {
                FollowRunState.shared.onChange = { [execution = container.execution] in
                    execution.syncFollowPresentation()
                }
                container.execution.syncFollowPresentation()
                // #36：执行中不弹 toast（红线①）+ 点击直达成就页
                AchievementToastCenter.shared.isBusy = { [execution = container.execution] in
                    execution.active != nil
                }
                AchievementToastCenter.shared.onTap = { [router = container.router] in
                    router.selectedTab = .journal
                    router.openAchievements = true
                }
                // #35 设置同步后：本机跟随开关可能是「另一台设备打开、同步过来的」→ 启动即补建订阅
                //（ensureSubscription/refreshAndApply 内部各自查开关，关时是 no-op）。
                await FocusFollow.ensureSubscription()
                await FocusFollow.refreshAndApply(reason: "启动")
            }
            .userActivity(BetterCalendarHandoff.activityType, isActive: true) { activity in
                BetterCalendarHandoff.configure(activity,
                                                router: container.router,
                                                execution: container.execution)
            }
            .onContinueUserActivity(BetterCalendarHandoff.activityType) { activity in
                continueFromHandoff(activity)
            }
    }

    @MainActor
    private func handlePendingAppIntent() {
        let payload = AppIntentRequest.payload()
        guard let request = AppIntentRequest.consume() else { return }
        switch request {
        case .arrangeToday:
            // W19：老排程链退役——「排今天」快捷指令的那句话交给智能体（它提出的安排等你批准）；没说话 = 打开今天
            if let text = payload, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let chat = container.agentChat
                Task { await chat.send(text) }
                container.router.selectedTab = .chat
            } else {
                container.router.selectedTab = .schedule
            }
        case .openSchedule:
            container.router.selectedTab = .schedule
        case .openToday:
            selectTodayTab()
        case .openJournal:
            container.router.selectedTab = .journal
        case .startFocus:
            selectTodayTab()
            startNextFromIntent()
        case .completeCurrent:
            selectTodayTab()
            completeOrStartFromIntent()
        case .markDone:
            selectTodayTab()
            if let title = payload, !title.isEmpty {
                let execution = container.execution
                Task { await execution.markDone(titleLike: title) }
            }
        case .review:
            // 0.28：复盘并入日记页——「今日复盘」快捷指令直达日记（回看今天在顶部）
            container.router.selectedTab = .journal
            container.router.journalRequest = .now
        }
    }

    @MainActor
    private func continueFromHandoff(_ activity: NSUserActivity) {
        guard let route = BetterCalendarHandoff.route(from: activity) else { return }
        switch route.tab {
        case .schedule:
            container.router.selectedTab = .schedule
        case .today:
            selectTodayTab()
        case .longterm:   // #40：Handoff 带长期页则直达（跨端语义等价）
            container.router.selectedTab = .longterm
        case .journal:
            container.router.selectedTab = .journal
            container.router.journalRequest = .now
        case .chat:
            container.router.openChat()
        }
    }

    @MainActor
    private func consumePrimeNextStart() {
        guard container.router.primeNextStart else { return }
        container.router.primeNextStart = false
        selectTodayTab()
        let execution = container.execution
        Task { await execution.primeNextForStart() }
    }

    @MainActor
    private func selectTodayTab() {
        container.router.selectedTab = .schedule   // W19：「今天」页两端都是首页（原 iPhone「今天」标签已并入）
    }

    @MainActor
    private func startNextFromIntent() {
        let execution = container.execution
        Task {
            if !execution.loaded { await execution.loadToday() }
            if execution.active != nil { return }
            if execution.selected != nil {
                await execution.startSelected()
            } else if let next = execution.nextSuggested {
                await execution.startBlock(next)
            }
        }
    }

    @MainActor
    private func completeOrStartFromIntent() {
        let execution = container.execution
        Task {
            if !execution.loaded { await execution.loadToday() }
            if execution.active != nil {
                await execution.completeCurrent()
            } else if execution.selected != nil {
                await execution.startSelected()
            } else if let next = execution.nextSuggested {
                await execution.startBlock(next)
            }
        }
    }
}

#endif
