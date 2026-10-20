//
//  HomeView.swift
//  BetterCalendar
//
//  「今天」首页（W19 S-v2）：现在 / 下一件 + 这一天的时间线（可直接拖、改，自动保存）+ 跟智能体说一句。
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

#if !os(macOS)
/// iOS 分享用：把当前计划的 ICS 文本包成可分享的 .ics 文件（ShareLink）。
struct ICSDocument: Transferable {
    let text: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType(filenameExtension: "ics") ?? .plainText) {
            Data($0.text.utf8)
        }
        .suggestedFileName("BetterCalendar计划.ics")
    }
}
#endif

/// 首页所需依赖（组装点 AppContainer 构造；View 不见 AppContainer——反向依赖清零 2026-07-12）。
/// 字段名对齐 AppContainer 属性，方便对照。
struct HomeDeps {
    let arrangeDay: ArrangeDayUseCase
    let refiner: PlanRefining
    let calendarStore: CalendarReading     // 真 EventKit 的只读角色（P4.1：写日历只经 CalendarSyncEngine）
    let reminderStore: ReminderStore
    let exporter: ICSExporting
    let planStore: PlanStore
    let projection: ProjectionService
    let notifier: NotificationScheduling
    let longTasks: LongTaskStore
    let draftSnapshots: DraftSnapshotStore
    let looseDays: LooseDayStore
    let startedDays: StartedDayStore
    let execution: ExecutionViewModel
    let liveDraft: LiveDraft
    let journalStore: JournalStore
    let router: AppRouter
    let reconcile: ReconcileService
    var trash: (any TrashManaging)? = nil
    var nativeActions: NativeActionsViewModel? = nil
    var timeline: TimelineCoordinator? = nil   // E5d：晨间摘要/痕迹条与一键撤；nil=不显（旧测试兼容）
    var routines: RoutineTemplateStore? = nil  // K1：例行模板物化进草稿；nil=不物化（旧测试兼容）
    var proposals: ProposalCenter? = nil       // SPEC §19：iPhone 的多端审批入口在设置里（iOS 首页无工具栏）
    var agentMessages: AgentMessageCenter? = nil
    var alertPush: ProposalAlertPushControl? = nil
    var agentChat: AgentChatCenter? = nil      // W19：底部「跟智能体说一句」
    var agentHub: AgentHub? = nil              // W20：设置里的「当前智能体」
}

/// W19「今天」页（S-v2 结构层决定，2026-10-19）：原「排日程」与「今天」合并成首页，两端同一套。
/// 自上而下：① 现在 / 下一件（复用执行陪伴面板与它的开始 / 完成逻辑）② 选哪天 ③ 这一天的时间线
///（今天 = 做成了的 + 接下来的计划，可直接拖、直接改，改完自动保存；你拖过的块按原路径成为图钉）
/// ④ 底部常驻「跟智能体说一句」（交给 AgentChatCenter.send，并切到「智能体」页看回复与提案）。
/// 老排程链（「说说你的一天」输入框 / 排今天·排明天 / AI 调整 / 确认写入日历 + 它们的状态行）已从界面退役。
struct HomeView: View {
    // 收尾卡 v2（0.38）：可见性 = 既有强信号 ∨ 傍晚线后事实性收工；盖章/收起/已有日记则不出现
    @State private var wrapUpDismissTick = 0   // 「先不收尾」后强制重算
    private var wrapUpCardVisible: Bool {
        _ = wrapUpDismissTick
        guard axisEnabled ? deps.startedDays.isStarted(DayContext.logicalDay(offset: 0)) : model.isLiveTargetDay,
              !WrapUpSeal.isSealedToday, !WrapUpSeal.dismissedToday,
              !deps.journalStore.hasContentToday() else { return false }
        if axisEnabled {
            // 时间轴：今天从现在起没有绿色了 ∨ 已过收工线（与 W19 的 wrapUpSignal 同口径）
            if !axis.hasRemainingToday(in: axis.days()) || Date.now >= WorkHoursSettings.effectiveWindDown(from: .now) { return true }
        } else if model.wrapUpSignal { return true }
        // 傍晚线后事实性收工：空档且最后一次完成已过去 ≥45 分钟
        return Date.now >= WorkHoursSettings.eveningStart(for: .now)
            && deps.execution.active == nil
            && (deps.execution.lastCompletionAt.map { Date.now.timeIntervalSince($0) >= 45 * 60 } ?? false)
    }

    // 时间线尾行「＋ 加一项」：只写标题，在空档放一小时（不经 AI）
    @State private var addRowActive = false
    /// W31 自测：「现在 / 下一件」卡的自然高度（时间轴页按它给卡定高，超过上限就卡内滚动）。
    @State private var nowCardHeight: CGFloat = 0
    @State private var addRowText = ""

    let deps: HomeDeps
    @Environment(\.appTheme) private var theme   // 令牌表 v1（换装批次A 起逐点消费）
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: HomeViewModel
    @State private var l3Tick = 0                  // 「别再提」后强制重算 L3 建议
    @State private var tnDismissTick = false       // 寄语条「今天先收起」即时刷新（存储在 TomorrowNote）
    @State private var briefDismissTick = 0        // 晨间摘要「今天先不排」即时刷新（E5d，存 UserDefaults）
    @State private var showTraceSheet = false      // 变更痕迹二层 sheet（E5d）
    @State private var showDevLog = false          // W16：🐞 日志页（工具栏入口）
    @State private var sayText = ""                // 底部「跟智能体说一句」
    @FocusState private var sayFocused: Bool
    @AppStorage(DeveloperSettings.key) private var developerOptions = DeveloperSettings.defaultValue   // W16「开发者选项」
    /// W23：今天页用时间轴（日用版默认关；关着 = W19 卡片列表原样）。
    @AppStorage(TimelineAxisSettings.key) private var axisEnabled = TimelineAxisSettings.defaultValue
    @State private var axis: TimelineAxisModel
    @State private var axisEditing: AxisEditTarget?
    @State private var showChangelog = false
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow   // 开发期窗口（开发者选项打开时）
    #else
    @State private var showSettings = false        // iOS 没有 ⌘, Settings scene → app 内设置页
    @State private var showDraftExpanded = false   // iOS 时间线全屏编辑（小屏太挤）
    #endif

    init(deps: HomeDeps) {
        self.deps = deps
        let vm = HomeViewModel(
            arrangeDay: deps.arrangeDay,
            refiner: deps.refiner,
            calendarStore: deps.calendarStore,
            reminderStore: deps.reminderStore,
            exporter: deps.exporter,
            planStore: deps.planStore,
            projection: deps.projection,
            notifier: deps.notifier,
            longTaskStore: deps.longTasks,
            draftStore: deps.draftSnapshots,
            looseDays: deps.looseDays,
            startedDays: deps.startedDays,
            progress: deps.execution,
            routines: deps.routines)
        vm.autoCommit = true   // W19：直接操作即保存（没有「确认写入」这一步了）
        vm.relayoutLiveDay = !TimelineAxisSettings.enabled   // W23：时间轴按闸门自己呈现，列表拿库里原样
        _model = State(initialValue: vm)
        _axis = State(initialValue: TimelineAxisModel(plans: deps.planStore, actuals: deps.planStore,
                                                      calendar: deps.calendarStore, live: deps.execution, home: vm))
    }

    struct AxisEditTarget: Identifiable { let id: UUID }

    /// 选中的是不是逻辑今天（「现在 / 下一件」与「做成了」只属于今天）。
    private var isTodaySelected: Bool {
        Calendar.current.startOfDay(for: model.targetDay) == DayContext.logicalDay(offset: 0)
    }

    /// 只属于今天的提示（晨间摘要 / 痕迹条 / 建议…）：时间轴一直是「今天为主」的一根轴，W19 列表按所选那天。
    private var showsTodayNotices: Bool { axisEnabled || isTodaySelected }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if axisEnabled {
                    axisPage
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            nowNextCard
                            dayStrip
                            notices
                            timeline
                            footerTag
                        }
                        .padding()
                    }
                }
                Divider()
                sayBar
            }
            // 换装批次A：微暖中性阶页底（条文 1B，令牌 bg）
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle("今天")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarItems }
            .sheet(isPresented: $showDevLog) { DevLogSheet(isPresented: $showDevLog) }
            .sheet(isPresented: $showTraceSheet) {
                // E5d 变更痕迹二层：清单 + 一键撤（deps.timeline 为 nil 时提示条根本不显示，进不来）
                if let timeline = deps.timeline { ChangeTraceSheet(timeline: timeline) }
            }
            #if !os(macOS)
            .sheet(isPresented: $showDraftExpanded) { expandedEditor }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView(trash: deps.trash, nativeActions: deps.nativeActions,
                                 proposals: deps.proposals, agentMessages: deps.agentMessages, alertPush: deps.alertPush,
                                 agentHub: deps.agentHub, calendarStore: deps.calendarStore)
                        .navigationTitle("设置")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showSettings = false }
                            }
                        }
                }
            }
            #endif
            .onChange(of: deps.router.scheduleRequest) { _, req in
                guard let req else { return }
                switch req {
                case .arrangeToday:
                    // W19：老排程链退役——这条请求不再从这里进（App 级入口直接交给智能体），只回到今天
                    Task { await model.selectDay(DayContext.logicalDay(offset: 0)) }
                case .planTomorrow:   // 0.38（#33）：收尾章后「顺手排一下明天」→ 切到明天的时间线
                    Task { await model.selectDay(DayContext.logicalDay(offset: 1)) }
                case .insertLongTask(let id):   // #40 批1：长期页「排进今天」→ 智能插空档
                    if let t = deps.longTasks.items.first(where: { $0.id == id })
                        ?? deps.longTasks.todoItems().first(where: { $0.id == id }) {
                        if model.hasUnsavedChanges || model.draftSource == .arranged {
                            model.smartInsertFromLongTask(t)
                        } else {
                            Task { await model.admitFromPool(t) }
                        }
                    }
                }
                deps.router.scheduleRequest = nil   // 消费掉
            }
            .onAppear {
                model.autoLoadOnAppear()   // 进页自动加载所选那天的计划
                FeatureUsage.seen(.todayPage)
            }
            .onDisappear { Task { await model.flushAutosave() } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { Task { await model.flushAutosave() } }   // 回后台前把等着的改动存掉
            }
            // 双向同步回流 / 智能体批准的改动执行后 / 协调器重排后：干净视图直接刷新；编辑中 → 保存时只叠你的改动（commitEdits）
            .onReceive(NotificationCenter.default.publisher(for: ReconcileService.planChangedExternally)) { _ in
                model.noteExternalPlanChange()
            }
            // 执行进展（开始/完成/换件）→ 今天的时间线跟着现实走
            .onReceive(NotificationCenter.default.publisher(for: ExecutionProgressSignal.changed)) { _ in
                model.noteExecutionProgress()
            }
            // 另一台设备点了提示上的「知道了」→ 本机也收起（W19）
            .onReceive(NotificationCenter.default.publisher(for: SettingsSync.didSyncRemotely)) { _ in
                deps.reconcile.refreshNoticeAfterSync()
            }
            // 切天 = 换一页（每天一页）；时间轴 focusDay 已切过的不重复加载
            .onChange(of: model.targetDay) { _, _ in
                model.targetDayDidChangeIfNeeded()
            }
            .onChange(of: axisEnabled) { _, on in
                model.relayoutLiveDay = !on
                model.autoLoadOnAppear()
            }
            .navigationDestination(isPresented: $showChangelog) { ChangelogView() }
            .sheet(item: $axisEditing) { target in
                AxisBlockEditor(block: model.binding(for: target.id),
                                onDelete: { model.delete(id: target.id); axisEditing = nil },
                                onDone: { axisEditing = nil; Task { await model.flushAutosave() } })
            }
        }
    }

    // MARK: W23 时间轴页

    /// 时间轴版今天页：现在 / 下一件（顶上常驻）→ 提示 → 一根连续的时间轴（填满剩下的高度）。
    private var axisPage: some View {
        GeometryReader { page in
        VStack(alignment: .leading, spacing: 8) {
            // W31 自测：大字号 / 矮窗口下这张卡会把时间轴挤到零高（轴整个消失）——卡最多占页面四成，多出的在卡内滚动
            ScrollView(.vertical) {
                nowNextCard
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nowCardHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: Self.nowCardFrameHeight(natural: nowCardHeight, page: page.size.height))
            notices
            if addRowActive { addTailRow }
            TimelineAxisView(axis: axis, onEdit: { item in
                guard let id = item.blockID, let ps = item.plannedStart else { return }
                Task {
                    await model.focusDay(DayContext.logicalStartOfDay(ps))
                    if model.blocks.contains(where: { $0.id == id }) {
                        FeatureUsage.used(.todayAxisEdit)
                        axisEditing = AxisEditTarget(id: id)
                    } else {
                        FeatureUsage.record(.todayAxisEdit, .failed, "找不到块")
                        DevLog.shared.warn("今天页", "点时间轴上的块没打开编辑：这一页里找不到那一块（可能刚被别处改过）")
                    }
                }
            }, dayMenu: { day in axisDayMenu(day) })
        }
        }
        .padding(.horizontal).padding(.top, 10)
    }

    /// 「现在 / 下一件」卡在时间轴页的高度：自然高度，但不超过页面四成（还没量到时先给上限，免得首帧塌成 0）。纯函数、可单测。
    nonisolated static func nowCardFrameHeight(natural: CGFloat, page: CGFloat) -> CGFloat {
        let cap = max(120, page * 0.4)   // W31b：0.5 → 0.4，iPhone 上给时间轴留出六成
        guard natural > 0 else { return cap }
        return min(natural, cap)
    }

    /// 时间轴的「这一天」菜单（U2 第二层）：作用于视口里正在看的那一天。
    private func axisDayMenu(_ day: Date) -> some View {
        let isToday = day == DayContext.logicalDay(offset: 0)
        return Menu {
            Button {
                Task { await model.focusDay(day); addRowActive = true }
            } label: {
                Label("在\(Self.relativeDayWord(day))加一项", systemImage: "plus")
            }
            Button {
                Task { await model.focusDay(day); model.toggleLoose() }
            } label: {
                let loose = deps.looseDays.isLoose(day)
                Label(loose ? "结束松散" : "这天松散一下", systemImage: loose ? "moon.zzz.fill" : "moon.zzz")
            }
            if isToday {
                Button {
                    FeatureUsage.used(.todayUpdateDoneFromCalendar, "时间轴")
                    Task { await deps.execution.reconcileCalendarActuals() }
                } label: {
                    Label("按系统日历更新今天做成的事", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            let planned = axis.planned(on: day)
            if DisclosureSettings.showsDeepFeatures, !planned.isEmpty {
                #if os(macOS)
                Button { exportICS(model.ics(for: planned), via: "时间轴") } label: {
                    Label("导出 ICS", systemImage: "square.and.arrow.up")
                }
                #else
                ShareLink(item: ICSDocument(text: model.ics(for: planned)),   // iOS 分享面板：点了没有回调，探针记不到（同 W21 日记导出）
                          preview: SharePreview("BetterCalendar 计划.ics")) {
                    Label("导出 ICS", systemImage: "square.and.arrow.up")
                }
                #endif
            }
            Divider()
            Button { showChangelog = true } label: { Label("更新日志（\(BuildInfo.tag)）", systemImage: "info.circle") }
        } label: {
            Label("这一天", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(.primary)
        .help("这一天的更多操作")
        .accessibilityLabel("这一天的更多操作")
    }

    // MARK: ① 现在 / 下一件

    @ViewBuilder private var nowNextCard: some View {
        ExecutionPanel(model: deps.execution,
                       onOpenJournal: {
                           deps.router.selectedTab = .journal
                           deps.router.journalRequest = .now
                       },
                       compactCapable: true, fillsWidth: true)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary.opacity(0.6)))
            .accessibilityIdentifier("bc.today.nowNext")
    }

    // MARK: ② 选哪天

    private static let dayOffsets = Array(0..<7)

    @ViewBuilder private var dayStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.dayOffsets, id: \.self) { offset in
                        let day = DayContext.logicalDay(offset: offset)
                        let selected = Calendar.current.isDate(day, inSameDayAs: model.targetDay)
                        Button {
                            if !selected { FeatureUsage.used(.todayDaySwitch, offset == 0 ? "回今天" : "+\(offset)天") }
                            Task { await model.selectDay(day) }
                        } label: {
                            Text(Self.chipLabel(day, offset: offset))
                                .font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(selected ? AnyShapeStyle(theme.accent.opacity(0.18))
                                                                    : AnyShapeStyle(.quaternary.opacity(0.5))))
                                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.relativeDayWord(day) + " " + Self.dayLabel(day))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            dayMenu
        }
        let hint = Self.smallHoursHint(for: model.targetDay)
        if !hint.isEmpty {
            Text(Self.dayLabel(model.targetDay) + hint).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// 这一天的低频动作（U2 第二层）：松散一下 / 全屏编辑（iPhone）/ 按日历更新做成的事 / 导出 ICS。
    private var dayMenu: some View {
        Menu {
            Button {
                model.toggleLoose()
            } label: {
                let loose = deps.looseDays.isLoose(model.targetDay)
                Label(loose ? "结束松散" : "这天松散一下", systemImage: loose ? "moon.zzz.fill" : "moon.zzz")
            }
            #if !os(macOS)
            if !model.blocks.isEmpty {
                Button { showDraftExpanded = true } label: {
                    Label("全屏编辑这一天", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            #endif
            if isTodaySelected {
                // 原「同步日历改动」：你在系统日历里删改了今天的蓝色实际 → 按日历更新（低频，收进这里）
                Button {
                    FeatureUsage.used(.todayUpdateDoneFromCalendar, "卡片列表")
                    Task { await deps.execution.reconcileCalendarActuals() }
                } label: {
                    Label("按系统日历更新今天做成的事", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if DisclosureSettings.showsDeepFeatures, !model.blocks.isEmpty {
                #if os(macOS)
                Button { exportICS(model.currentICS(), via: "卡片列表") } label: { Label("导出 ICS", systemImage: "square.and.arrow.up") }
                #else
                ShareLink(item: ICSDocument(text: model.currentICS()),
                          preview: SharePreview("BetterCalendar 计划.ics")) {
                    Label("导出 ICS", systemImage: "square.and.arrow.up")
                }
                #endif
            }
        } label: {
            Label("这一天", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(.primary)
        .help("这一天的更多操作")
    }

    static func chipLabel(_ day: Date, offset: Int) -> String {
        switch offset {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default: return day.formatted(.dateTime.weekday(.abbreviated)) + " " + day.formatted(.dateTime.day())
        }
    }

    // MARK: 提示（P2：每条都从注意力预算里扣——只留做成的、要你动手的、自动做过要你看得见的）

    @ViewBuilder private var notices: some View {
        // 「给明天的一句话」晨间面（#23）：昨晚的你留给今早的你；点 ✕ 只收当天
        if showsTodayNotices, let tn = TomorrowNote.note(), !TomorrowNote.isDismissed(), !tnDismissTick {
            MessageStrip(icon: "sunrise", tint: theme.looseTint, text: "昨晚的你说：\(tn)") {
                Button { TomorrowNote.dismiss(); tnDismissTick = true } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("今天先收起")
            }
        }

        // 晨间摘要（E5d）：昨日收池露脸 + 一键入线；当天可收
        let _ = briefDismissTick
        if showsTodayNotices, !MorningBrief.isDismissedToday {
            MorningBriefStrip(longTasks: deps.longTasks, router: deps.router,
                              onDismiss: { briefDismissTick += 1 })
        }

        // 自动调整事后可见、可撤（P4）：一行计数 → 点开清单，逐条或一键撤
        if showsTodayNotices, let timeline = deps.timeline, timeline.todayTraceCount() > 0 {
            MessageStrip(icon: "arrow.triangle.2.circlepath", tint: theme.looseTint,
                         text: "今天的计划自动调整过 \(timeline.todayTraceCount()) 处") {
                Button("查看 / 撤销") { showTraceSheet = true }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(theme.accent)
            }
        }

        // P4 Q1：BetterCalendar 自家日历里有你的事件——提示一次，点「知道了」后不再出现（随 iCloud 同步）
        if let notice = deps.reconcile.calendarNotice {
            MessageStrip(icon: "calendar.badge.exclamationmark", tint: .secondary, text: notice) {
                Button("知道了") { deps.reconcile.dismissCalendarNotice() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(theme.accent)
                    .accessibilityIdentifier("bc.today.calendarNotice.dismiss")
            }
        }

        // 松散日：退场 + 见证的姿态横幅
        if deps.looseDays.isLoose(model.targetDay) {
            MessageStrip(icon: "moon.stars.fill", tint: theme.looseTint,
                         text: "松散日 · 已经退场陪你了——不催、不算账。想排还是能排，也可以就好好休息。")
        }

        // L3 主动建议（唯一主动·一行）：休息日全静音、可"别再提"永久静音、强度可调
        let _ = l3Tick
        let l3 = showsTodayNotices ? deps.longTasks.l3Suggestions(
            loose: deps.looseDays.isLoose(model.targetDay),
            intensity: SuggestionSettings.intensity.cap,
            muted: SuggestionSettings.mutedTaskIDs) : []
        ForEach(l3) { s in
            MessageStrip(icon: "lightbulb", tint: theme.previewTint, text: s.text) {
                if s.kind == .shelve {
                    Button("先放下") {
                        BehaviorLog.record("L3建议", "点「先放下」")
                        FeatureUsage.used(.todaySuggestion, "先放下")
                        if let t = deps.longTasks.items.first(where: { $0.id == s.id }) {
                            deps.longTasks.shelve(t)
                        }
                    }.font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                    .tint(.primary)
                } else {
                    Button {
                        BehaviorLog.record("L3建议", "点「排进今天」")
                        FeatureUsage.used(.todaySuggestion, "排进今天")
                        if let t = deps.longTasks.items.first(where: { $0.id == s.id }) {
                            Task { await model.admitFromPool(t) }
                        }
                    } label: {
                        Label("排进今天", systemImage: "calendar.badge.plus")   // 审计 #13：同动作同文案同图标（U7）
                    }.font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                    .tint(.primary)
                }
                Button {
                    BehaviorLog.record("L3建议", "静音（别再提）")
                    SuggestionSettings.mute(s.id); l3Tick += 1
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("别再提这件")
                .accessibilityLabel("别再提这件")
            }
            .onAppear {
                BehaviorLog.recordOncePerDay(key: "L3-\(s.id)", "L3建议", "出现")
                FeatureUsage.seen(.todaySuggestion)   // 「别再提」不记用过：那是「不需要」的信号
            }
        }

        // 结果上的话（中性、前向）：例「2 件在你编辑期间已完成，保持原样」
        if let note = model.note, note.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 {
            MessageStrip(icon: "quote.opening", tint: theme.actualTint, text: note)
        }
        // 保存失败必须在结果上说（P4）
        if let err = model.errorText {
            MessageStrip(icon: "exclamationmark.triangle.fill", tint: .orange, text: err, textStyle: .primary) {
                Button("知道了") { model.errorText = nil }.buttonStyle(.plain).font(.caption)
            }
        }
        if let snap = model.pendingRestore {
            MessageStrip(icon: "clock.arrow.circlepath", tint: theme.actualTint,
                         text: "上次退出前有一处改动没来得及保存（\(Self.dayLabel(snap.targetDay)) · \(snap.savedAt.formatted(date: .omitted, time: .shortened))）") {
                Button("恢复") { model.applyPendingRestore() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(theme.actualTint)
                Button("不要了") { model.dismissPendingRestore() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }

        // 收尾卡 v2（0.38）：强信号 ∨ 傍晚线后空档 ≥45 分钟；「先不收尾」一键当天收起
        if wrapUpCardVisible { wrapUpCard }

        // 开发期失败横幅（W16「安静但可见」）：判定统一在 IssueTriage
        IssueBanner()
    }

    private var wrapUpCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sunset.fill").font(.title3).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("今天的工作差不多了").font(.headline)
                    Text("花 30 秒收个尾——看看做成了什么，给今天写一句话。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("先不收尾") { WrapUpSeal.dismissToday(); wrapUpDismissTick += 1 }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button {
                    BehaviorLog.record("收口卡", "点击进收尾流程")
                    FeatureUsage.used(.todayWrapUpCard)
                    deps.router.selectedTab = .journal
                    deps.router.journalRequest = .now
                    deps.router.wrapUpRequest = true
                } label: {
                    Label("进入收尾", systemImage: "arrow.right.circle.fill").font(.callout)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [theme.accent.opacity(0.16), Color.pink.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14))
        .onAppear {
            FeatureUsage.seen(.todayWrapUpCard)   // 「先不收尾」不记用过
            BehaviorLog.recordOncePerDay(key: "收口卡",
                "收口卡", "出现·信号=\(model.blocks.isEmpty ? "剩余空" : (Date.now >= WorkHoursSettings.effectiveWindDown(from: .now) ? "过收工线" : "傍晚空档"))")
        }
    }

    // MARK: ③ 时间线（今天 = 做成了的 + 接下来的；其他天 = 那天的计划）

    /// 今天做成的事（蓝色实际，只读）：做成的事拿音量（U5），缺口不出现。
    private var doneToday: [ExecutionViewModel.ActualRecord] {
        guard isTodaySelected else { return [] }
        return deps.execution.done.sorted { $0.start < $1.start }
    }

    @ViewBuilder private var timeline: some View {
        if !doneToday.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("做成了 \(doneToday.count) 件", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(theme.actualTint)
                ForEach(doneToday) { r in
                    HStack(spacing: 8) {
                        Text(Self.hm(r.start) + "–" + Self.hm(r.end))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(r.title).font(.callout).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .background(theme.actualTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .accessibilityIdentifier("bc.today.done")
        }

        HStack {
            Text(isTodaySelected ? (doneToday.isEmpty ? "今天的安排" : "接下来") : "\(Self.relativeDayWord(model.targetDay))的安排")
                .font(.subheadline.weight(.semibold))
            if let terrain = model.terrainLine {
                Text("· " + terrain).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small) }
        }

        if model.blocks.isEmpty {
            Label(isTodaySelected && !doneToday.isEmpty
                  ? "接下来没有安排了——想加什么，跟智能体说一句，或在下面加一项"
                  : "这天还没有安排——跟智能体说一句，或在下面加一项",
                  systemImage: "calendar")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.vertical, 6)
            addTailRow
        } else {
            List {
                ForEach(model.blocks) { item in
                    editableRow(item)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                .onMove { model.move($0, $1) }   // 拖动 = 按新位置自动填时间（保时长），保存后成为图钉
                addTailRow
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            // W19b：去掉 List 默认的顶部留白与左右缩进（macOS inset 样式 / iOS insetGrouped 自带的 section 边距），
            // 时间线第一行紧贴「今天的安排」标题、与上方卡片左对齐。行间距由行自己的 listRowInsets 给。
            .listStyle(.plain)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .frame(height: max(120, min(CGFloat(model.blocks.count) * 84 + 44, 480)))
            .accessibilityIdentifier("bc.today.timeline")
        }

        // 「尽早」软限（≤2）：只温和提示、不硬挡
        let mitCount = model.blocks.filter { $0.priority == .important }.count
        if mitCount > 2 {
            Label("「尽早」贵在少（已标 \(mitCount) 件）——越多越稀释，真正想优先的留 1–2 件就好",
                  systemImage: "sparkles")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func editableRow(_ item: EditableBlock) -> some View {
        EditableRow(block: model.binding(for: item.id),
                    poolTasks: deps.longTasks.items,
                    referenceDay: model.targetDay,
                    parallelCandidates: model.blocks
                        .filter { $0.id != item.id && !$0.isAnchor }
                        .map { ($0.id, $0.title,
                                $0.parallelGroup != nil && $0.parallelGroup == item.parallelGroup) },
                    parallelPeers: model.parallelPeerTitles(of: item.id),
                    onToggleParallel: { model.toggleParallel(item.id, with: $0) },
                    onDelete: { model.delete(id: item.id) })
    }

    /// 列表尾行「＋ 加一项」：写个标题回车，放进这天的空档（一小时，时间在列表里直接改）。
    @ViewBuilder private var addTailRow: some View {
        if addRowActive {
            HStack(spacing: 6) {
                TextField("写个标题，回车加进空档", text: $addRowText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let t = addRowText.trimmingCharacters(in: .whitespaces)
                        addRowActive = false; addRowText = ""
                        if !t.isEmpty { Task { await model.admitPlain(t) } }
                    }
                Button("取消") { addRowActive = false; addRowText = "" }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        } else {
            Button { addRowActive = true } label: {
                Label("加一项", systemImage: "plus")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    /// 页底弱字：版本标签（点开看更新日志）。
    private var footerTag: some View {
        NavigationLink { ChangelogView() } label: {
            Text(BuildInfo.tag).font(.caption2).foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    // MARK: ④ 跟智能体说一句

    private var sayBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(deps.agentChat == nil ? "智能体还没接上" : "跟智能体说一句（比如：明天上午排三小时写论文）",
                      text: $sayText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($sayFocused)
                .onSubmit(sendToAgent)
                .disabled(deps.agentChat == nil)
                .accessibilityIdentifier("bc.today.say")
                // W21：打了字 = 开了头；清空没发 = 没做完（发出去 = 做完，见 sendToAgent）
                .onChange(of: sayText) { old, new in
                    let wasEmpty = old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let isEmpty = new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if wasEmpty, !isEmpty { FeatureUsage.begin(.todaySayToAgent) }
                    if !wasEmpty, isEmpty { FeatureUsage.abandonIfOpen(.todaySayToAgent) }
                }
            Button(action: sendToAgent) {
                Label("发给智能体", systemImage: "arrow.up.circle.fill").labelStyle(.iconOnly).font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(deps.agentChat == nil || sayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("bc.today.say.send")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.bg)
    }

    private func sendToAgent() {
        let text = sayText
        guard let chat = deps.agentChat, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        FeatureUsage.complete(.todaySayToAgent)   // 先关开头，下面清空输入框不算没做完
        sayText = ""
        sayFocused = false
        deps.router.selectedTab = .chat   // 回复与提案都在「智能体」页
        Task { await chat.send(text) }
    }

    // MARK: 工具栏（U6：只放本页主务需要的；无字图标只留强约定的设置齿轮）

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // W16：🐞 日志入口常驻（开发期失败可见，U13 豁免）；短暂问题只在这里计数
            IssueLogButton(isPresented: $showDevLog)
            #if os(macOS)
            if developerOptions {
                Button { openWindow(id: "algo-bench") } label: { Label("算法试验台", systemImage: "flask") }
                    .help("算法试验台（开发期）")
                Button { openWindow(id: "skin-fitting") } label: { Label("皮肤试衣间", systemImage: "paintpalette") }
                    .help("皮肤试衣间（开发期）")
            }
            #else
            Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
                .accessibilityIdentifier("bc.settings.open")
            #endif
        }
    }

    #if !os(macOS)
    /// iPhone 全屏编辑这一天（同一份数据，改动即保存；小屏只是入口）。
    private var expandedEditor: some View {
        NavigationStack {
            List {
                ForEach(model.blocks) { item in editableRow(item) }
                    .onMove { model.move($0, $1) }
            }
            .navigationTitle("\(Self.relativeDayWord(model.targetDay)) · \(model.blocks.count) 件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showDraftExpanded = false }
                }
            }
        }
    }
    #endif

    /// 凌晨口径澄清（#28）：0–4 点且目标日=逻辑今天时，标注「已过午夜·仍算今天」；其余时段为空。
    static func smallHoursHint(for target: Date, now: Date = .now) -> String {
        let logicalToday = DayContext.logicalStartOfDay(now)
        guard Calendar.current.startOfDay(for: now) != logicalToday,   // 现在处于凌晨窗口
              Calendar.current.isDate(target, inSameDayAs: logicalToday) else { return "" }
        return " · 已过午夜仍算今天"
    }

    static func dayLabel(_ d: Date) -> String {
        d.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated))
    }

    private static func hm(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// 目标日的口语词：今天/明天/后天/昨天，再远显日期。以**逻辑今天**为基准（凌晨 0–4 点"今天"=日历昨天）。
    static func relativeDayWord(_ d: Date, from now: Date = .now) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: DayContext.logicalStartOfDay(now),
                                      to: cal.startOfDay(for: d)).day ?? 0
        switch days {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case -1: return "昨天"
        default: return d.formatted(.dateTime.month(.defaultDigits).day())
        }
    }

    #if os(macOS)
    private func exportICS(_ text: String, via surface: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "BetterCalendar计划.ics"
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            FeatureUsage.used(.todayExportICS, surface)
        } catch {
            // 失败可见（开发期约定）：原来是 try? 静默吞掉
            FeatureUsage.record(.todayExportICS, .failed, surface)
            DevLog.shared.error("今天页", "导出 ICS 没写成：\(error.localizedDescription)")
            model.errorText = "导出 ICS 没写成：\(error.localizedDescription)"
        }
    }
    #endif
}

/// 单个草稿块的可编辑行。
struct EditableRow: View {
    @Environment(\.appTheme) private var theme   // 令牌表 v1（换装批次 B）
    @Binding var block: EditableBlock
    var poolTasks: [LongTask] = []   // 可选归属的未来任务（0.18.2 手动选归属；空=不显归属菜单）
    var referenceDay: Date?          // 目标日：块不在这天（跨午夜落次日凌晨）→ 显「次日」徽章；nil=不显
    /// 并行组（0.22）：可结组的其它块（id/标题/是否已同组）+ 伙伴标题（徽章 hover）；空=不显链条菜单
    var parallelCandidates: [(id: UUID, title: String, inGroup: Bool)] = []
    var parallelPeers: [String] = []
    var onToggleParallel: ((UUID) -> Void)? = nil
    var onDelete: () -> Void
    // P4-2（Jason 2026-07-14）：时间点击弹选择器（iOS 滚轮），行内不再常驻步进箭头
    @State private var editingStart = false
    @State private var editingEnd = false

    private var isNextDay: Bool {
        guard let ref = referenceDay else { return false }
        return !Calendar.current.isDate(block.start, inSameDayAs: ref)
    }

    /// 开始在当天、结束跨过午夜（如 23:30–01:00）→ 显「至次日」（Jason 2026-07-08 报：只标开始在次日的不够）。
    private var crossesMidnight: Bool {
        !isNextDay && !Calendar.current.isDate(block.end, inSameDayAs: block.start)
    }

    /// 当前归属任务的标题（已完成/放下则可能取不到 → 只显图标）。
    private var linkedTitle: String? { poolTasks.first { $0.id == block.linkedTaskID }?.title }

    /// 排时间（批次7 从行首菜单迁入 ⋯ 与可点 tag 共用）：随时 / 尽早 / DDL / 固定 / 生活锚点。
    @ViewBuilder private var timingNatureItems: some View {
        Button("随时（今天内即可）") { block.priority = .normal; block.deadline = nil; block.isAnchor = false }
        Button(block.priority == .important ? "✓ 尽早" : "尽早") {
            block.priority = .important; block.deadline = nil; block.isAnchor = false
        }
        Button("有具体截止…") {
            block.priority = .normal; block.isAnchor = false
            if block.deadline == nil { block.deadline = block.end }
        }
        Divider()
        Button(block.isFixed ? "✓ 固定（与他人约定，时刻不可改）" : "固定（与他人约定，时刻不可改）") {
            block.isFixed.toggle()
        }
        Button(block.isAnchor ? "✓ 生活锚点（不催完成）" : "设为生活锚点（午饭/通勤这类）") {
            block.isAnchor.toggle()
            if block.isAnchor { block.priority = .normal; block.deadline = nil }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // 批次7（Jason 2026-07-14）：行首「排时间」按钮退役——菜单并入 ⋯ 的「排时间…」子菜单
            //（timingNatureItems）；状态可见性由标签区承担：尽早/固定=可点 tag，DDL=控件行旗+时间，
            // 锚点=整行淡显。「随时」=默认态零标签（常态零噪音）。
            VStack(alignment: .leading, spacing: 4) {
                // 标题行（P4-B）：标题 + 可变宽 tags 右对齐——控件行只留定宽件，右端全列表对齐
                HStack(spacing: 6) {
                    TextField("标题", text: $block.title)
                    tagStrip
                }
                // 控件行：时间胶囊（点击弹选择器，P4-2）· DDL · 计时 · ⋯（P4-3）
                HStack(spacing: 6) {
                    timeChip($block.start, "开始时间", $editingStart)
                    Text("–").foregroundStyle(.secondary)
                    timeChip($block.end, "结束时间", $editingEnd)
                    if block.deadline != nil {
                        HStack(spacing: 2) {
                            Image(systemName: "flag.checkered").foregroundStyle(.red).font(.caption2)
                            DatePicker("", selection: Binding(get: { block.deadline ?? block.end },
                                                              set: { block.deadline = $0 }),
                                       displayedComponents: .hourAndMinute)
                                .labelsHidden().controlSize(.small)
                        }
                        .help("硬截止（DDL）：必须在此之前完成——点时间可调；写进提醒事项、按它提醒。清除请在时限菜单选「随时/尽早」")
                    }
                    Menu {
                        Button("轻计时") { block.timingStyle = .light }
                        Button("番茄钟") { block.timingStyle = .pomodoro }
                        Button("不计时") { block.timingStyle = .none }
                    } label: {
                        Text(Self.styleLabel(block.timingStyle))
                    }
                    .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
                    Spacer()
                    // P4-3（(a)+(b) 都要）：复制/并行/归属/删除收进一个 ⋯，右键同一份内容
                    Menu {
                        rowMenuItems
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("更多：复制 · 并行 · 归属 · 删除")
                }
                .font(.caption)
            }
        }
        .contextMenu { rowMenuItems }
        // O1（批次7 行容器化 → 换装 C 落令牌）：行=surface 白卡浮于微暖页底（条文 6：平面层级=色差，无阴影），
        // 淡描边补 light 模式下 bg/surface 色差过小的 definition。排日程列表密度=组件级取紧（条文 7 例外通道），padding 保 10。
        .padding(10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary.opacity(0.4)))
        // 修正批 D（条文 2+U2）：行内高频控件（时间/计时/⋯）收中性——accent 只留给情感时刻与主按钮；
        // 行内 tag 等显式着色不受 tint 影响。白卡已承担行边界 → List 分隔线退场（双重边界去其一）。
        .tint(.primary)
        .listRowSeparator(.hidden)
        // 生活锚点淡显（0.20.3，§5.10 块三角色）：占位不是任务——可看可改时间，但视觉退后一步
        .opacity(block.isAnchor ? 0.55 : 1)
        .help(block.isAnchor ? "生活锚点（午饭/通勤这类）：占时间、塑造节奏，但不是要完成的任务" : "")
    }

    // MARK: P4 行内重构件（2026-07-14 Jason 四条建议过审落地）

    /// 标题行 tags（P4-4）：状态即入口——并行/归属 tag 可点直改（带 ▾）；次日/固定为陈述 tag。
    @ViewBuilder private var tagStrip: some View {
        HStack(spacing: 4) {
            if isNextDay {
                tagText("次日").foregroundStyle(.indigo).background(Color.indigo.opacity(0.12), in: Capsule())
                    .help("跨午夜：属同一逻辑日，日历上落在次日凌晨（改时间到 0–4 点会自动归次日）")
            } else if crossesMidnight {
                tagText("至次日").foregroundStyle(.indigo).background(Color.indigo.opacity(0.12), in: Capsule())
                    .help("结束时间跨过午夜（如 23:30–01:00）：仍属同一逻辑日")
            }
            if block.priority == .important {
                Menu {
                    timingNatureItems
                } label: {
                    tagText("尽早 ▾")
                }
                .menuStyle(.borderlessButton).fixedSize()
                // 换装 B 微决策：尽早=自设的情感承诺 → accent（暮色橙）；同时解掉与预览橙的同屏相撞
                .foregroundStyle(theme.accent)
                .background(theme.accent.opacity(0.12), in: Capsule())
                .help("你标了「尽早」：重排时优先靠前；点击可改排时间性质")
            }
            if block.isFixed {
                Menu {
                    timingNatureItems
                } label: {
                    tagText("固定 ▾")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .foregroundStyle(.secondary)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .help("与他人约定、时刻不可改（重排不动它）；点击可改排时间性质")
            }
            if block.parallelGroup != nil, onToggleParallel != nil {
                Menu {
                    parallelMenuItems
                } label: {
                    tagText("并行 \(parallelGroupMark) ▾")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .foregroundStyle(.teal)
                .background(.teal.opacity(0.12), in: Capsule())
                .help("与「\(parallelPeers.joined(separator: "、"))」并行（同组同款标记；点击直改结组）")
            }
            if block.linkedTaskID != nil {
                Menu {
                    linkMenuItems
                } label: {
                    tagText("\(linkedTitle ?? "归属") ▾").frame(maxWidth: 140)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .foregroundStyle(theme.looseTint)
                .background(theme.looseTint.opacity(0.12), in: Capsule())
                .help("归属的未来任务——投入精确记到它名下；点击直改")
            }
        }
    }

    private func tagText(_ s: String) -> some View {
        Text(s).font(.caption2).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6).padding(.vertical, 1)
    }

    /// 并行组标记（P4-4c）：同组同款、异组异款——组名尾数字转 ①②③；无数字取组名末字符。
    /// 结构线用记号区分（无色觉依赖）；组配色留美术换装。
    private var parallelGroupMark: String {
        guard let g = block.parallelGroup else { return "" }
        let digits = g.filter(\.isNumber)
        if let n = Int(digits), n >= 1, n <= 9 {
            return ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"][n - 1]
        }
        return g.isEmpty ? "" : String(g.suffix(1))
    }

    /// 时间胶囊（P4-2）：点击弹选择器（iOS=滚轮；macOS 无 wheel 样式，用紧凑选择器），行内不再常驻步进箭头。
    private func timeChip(_ selection: Binding<Date>, _ name: String, _ editing: Binding<Bool>) -> some View {
        Button(Self.hmFormatter.string(from: selection.wrappedValue)) { editing.wrappedValue = true }
            .buttonStyle(.bordered).controlSize(.small)
            .monospacedDigit()
            .accessibilityLabel(name)
            .popover(isPresented: editing) {
                DatePicker(name, selection: selection, displayedComponents: .hourAndMinute)
                    #if !os(macOS)
                    .datePickerStyle(.wheel)
                    #endif
                    .labelsHidden()
                    .padding(12)
            }
    }

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    // 并行组（0.22 语义不变）：选一块结组（同组=同时段、reflow 绑定）；再选已同组的=解除
    @ViewBuilder private var parallelMenuItems: some View {
        ForEach(parallelCandidates, id: \.id) { c in
            Button(c.inGroup ? "✓ \(c.title)（点击解除）" : c.title) { onToggleParallel?(c.id) }
        }
        if parallelCandidates.isEmpty { Text("没有可结组的块") }
    }

    @ViewBuilder private var linkMenuItems: some View {
        Button("无归属") { block.linkedTaskID = nil }
        if !poolTasks.isEmpty { Divider() }
        ForEach(poolTasks) { t in
            Button(t.title) { block.linkedTaskID = t.id }
        }
    }

    /// ⋯ 与右键共用的一份菜单（P4-3：可见入口+快捷路径，内容永远一致）。
    /// 复制已删（批次7 审核：低频且「加一项」一句话可覆盖——判例登记兜底）。
    @ViewBuilder private var rowMenuItems: some View {
        Menu {
            timingNatureItems
        } label: {
            Label("排时间…", systemImage: "clock")
        }
        if onToggleParallel != nil, !parallelCandidates.isEmpty || block.parallelGroup != nil {
            Menu {
                parallelMenuItems
            } label: {
                Label("并行…", systemImage: "link")
            }
        }
        if !poolTasks.isEmpty || block.linkedTaskID != nil {
            Menu {
                linkMenuItems
            } label: {
                Label("归属…", systemImage: "tray")
            }
        }
        Divider()
        Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
    }

    static func styleLabel(_ s: TimingStyle) -> String {
        switch s {
        case .light: return "轻计时"
        case .pomodoro: return "番茄"
        case .none: return "不计时"
        }
    }
}
