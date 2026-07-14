//
//  HomeView.swift
//  BetterCalendar
//
//  首页：说一天 → 排今天 → 可编辑草稿（拖/改/标/删加）→ 自然语言微调 → 确认写入（假）日历。
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

enum HomeRoute: Hashable { case preview }   // .review 已退役（0.28：复盘并入日记页）

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
    let routingStore: RoutingCalendarStore
    let routingReminder: RoutingReminderStore
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
    let calendarStore: FakeCalendarStore     // 假日历（预览页观察用）
    let reminderStore: FakeReminderStore
    let reconcile: ReconcileService
}

struct HomeView: View {
    // 收尾卡 v2（0.38）：可见性 = 既有强信号 ∨ 傍晚线后事实性收工；盖章/收起/已有日记则不出现
    @State private var wrapUpDismissTick = 0   // 「先不收尾」后强制重算
    private var wrapUpCardVisible: Bool {
        _ = wrapUpDismissTick
        guard model.isLiveTargetDay, !WrapUpSeal.isSealedToday, !WrapUpSeal.dismissedToday,
              !deps.journalStore.hasContentToday() else { return false }
        if model.wrapUpSignal { return true }
        // 傍晚线后事实性收工：空档且最后一次完成已过去 ≥45 分钟
        return Date.now >= WorkHoursSettings.eveningStart(for: .now)
            && deps.execution.active == nil
            && (deps.execution.lastCompletionAt.map { Date.now.timeIntervalSince($0) >= 45 * 60 } ?? false)
    }

    // 加一项（0.36.0 AI 定名/时长 → 批次3 融进列表尾行）：一句话=addBlockSmart；留空回车=空白项（老路保留）
    @State private var addRowActive = false
    @State private var smartAddText = ""

    let deps: HomeDeps
    @Environment(\.appTheme) private var theme   // 令牌表 v1（换装批次A 起逐点消费）
    @State private var model: HomeViewModel
    @State private var navPath: [HomeRoute] = []   // 程序化导航（通知 deep-link → 复盘）
    @State private var l3Tick = 0                  // 「别再提」后强制重算 L3 建议
    @State private var showFreshCompare = false    // 徽标 v2：两版只读对比 sheet
    @State private var tnDismissTick = false       // 寄语条「今天先收起」即时刷新（存储在 TomorrowNote）
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow   // 算法试验台窗口（开发期）
    #else
    @State private var showSettings = false        // iOS 没有 ⌘, Settings scene → app 内设置页
    @State private var showDraftExpanded = false   // iOS 草稿全屏浏览/编辑（小窗太挤）
    #endif
    // 实时跟随设置里的日历后端开关（按钮文字热切换）
    @AppStorage("calendar.backend") private var calendarBackendRaw: String = "fake"
    @AppStorage("home.inputHeight") private var inputHeight: Double = 96   // 输入框高度（拖拽可调，记忆）
    @State private var dragBaseHeight: Double?
    // 渐进披露 v2（0.26）：有草稿/计划 = 改/看的时刻，输入折叠成"重说"入口；点开临时展开重排。
    @State private var reSayExpanded = false
    /// 有草稿或已加载计划 = 进入"改/看"时刻（写入区显示、输入折叠）。
    private var showingPlanArea: Bool { !model.blocks.isEmpty || model.hasUnsavedChanges }
    /// 是否展示"说"的完整输入（无计划 或 主动点了重说）。
    private var showSayInput: Bool { !showingPlanArea || reSayExpanded }
    /// 「确认写入 + 同步」合一按钮的标题（Jason 2026-07-09）：绿(计划)与蓝(实际)是一天里错开的两相、
    /// 并集覆盖整天——"改/看"时刻是确认写入绿计划，"过"时刻叠加同步蓝色实际的日历改动。
    private var confirmSyncButtonTitle: String {
        let base = calendarBackendRaw == "eventKit" ? "确认写入真日历(Dev)" : "确认写入（假）日历"
        guard model.isLiveTargetDay else { return base }                              // 说/改/看：仅确认写入（绿）
        return model.hasUnsavedChanges ? base + " · 同步日历" : "同步日历改动"          // 过：叠加/单做蓝色对账
    }

    init(deps: HomeDeps) {
        self.deps = deps
        _model = State(initialValue: HomeViewModel(
            arrangeDay: deps.arrangeDay,
            refiner: deps.refiner,
            calendarStore: deps.routingStore,
            reminderStore: deps.routingReminder,
            exporter: deps.exporter,
            planStore: deps.planStore,
            projection: deps.projection,
            notifier: deps.notifier,
            longTaskStore: deps.longTasks,
            draftStore: deps.draftSnapshots,
            looseDays: deps.looseDays,
            startedDays: deps.startedDays,
            progress: deps.execution))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $navPath) {
            ScrollView {   // 页面过长可整页滚动（0.16.3）
            VStack(alignment: .leading, spacing: 12) {
                // 版本/构建标签移到左上（2026-07-09 Jason）：平台·渠道·版本(build)，点开看更新日志
                NavigationLink { ChangelogView() } label: {
                    Text(BuildInfo.tag)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                HStack {
                    Text("说说你的一天").font(.headline)
                    Spacer()
                    // 「松散一下」挪进目标日菜单（批次6）：它是这一天的属性，语义归属日选择器而非常驻顶栏
                    targetDayMenu
                    if model.isLiveTargetDay {
                        // 1b 态标识（方案 A，Jason 2026-07-14 裁）：顶栏胶囊，一眼可辨「列表=从现在起的剩余」
                        Text("实时 · 从现在起")
                            .font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary.opacity(0.6)))
                            .foregroundStyle(.secondary)
                            .help("今天已开始：这里显示并编辑「从现在起」的剩余计划（=橙色预览，改完确认即生效）；已完成/已过去的块在日记页复盘里")
                    }
                }

                // 「给明天的一句话」晨间面（#23）：昨晚的你留给今早的你——发出者是用户自己，
                // 不写=不存在；点 ✕ 只收当天（明天有新寄语照常出现）。
                if let tn = TomorrowNote.note(), !TomorrowNote.isDismissed(), !tnDismissTick {
                    MessageStrip(icon: "sunrise", tint: theme.looseTint, text: "昨晚的你说：\(tn)") {
                        Button { TomorrowNote.dismiss(); tnDismissTick = true } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("今天先收起")
                    }
                }

                // 松散日：退场 + 见证的姿态横幅（不删任何计划、可撕；深层姿态效果后续接）
                if deps.looseDays.isLoose(model.targetDay) {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.stars.fill").foregroundStyle(theme.looseTint)
                        Text("松散日 · 已经退场陪你了——不催、不算账。想排还是能排，也可以就好好休息。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.looseTint.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // L3 主动建议（唯一主动·顶部一行）：休息日全静音、可"别再提"永久静音、强度可调
                let _ = l3Tick   // 让"别再提"后重算（静音集存 UserDefaults、非 @Observable）
                let l3 = deps.longTasks.l3Suggestions(
                    loose: deps.looseDays.isLoose(model.targetDay),
                    intensity: SuggestionSettings.intensity.cap,
                    muted: SuggestionSettings.mutedTaskIDs)
                ForEach(l3) { s in
                    // 统一消息条（0.28.1）：L3 建议与 A+B 状态行同一视觉家族（位置各守其位）
                    // 换装 B：建议=提议未确认 → 预览橙族（同「从现在起」语义，让出系统橙）
                    MessageStrip(icon: "lightbulb", tint: theme.previewTint, text: s.text) {
                        if s.kind == .shelve {
                            Button("先放下") {
                                BehaviorLog.record("L3建议", "点「先放下」")
                                if let t = deps.longTasks.items.first(where: { $0.id == s.id }) {
                                    deps.longTasks.shelve(t)
                                }
                            }.font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                        } else {
                            Button("排进今天") {
                                BehaviorLog.record("L3建议", "点「排进今天」")
                                if let t = deps.longTasks.items.first(where: { $0.id == s.id }) {
                                    model.smartInsertFromLongTask(t)
                                }
                            }.font(.caption2).buttonStyle(.bordered).controlSize(.mini)
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
                    .onAppear {   // 埋点：出现按 (天, 建议) 去重
                        BehaviorLog.recordOncePerDay(key: "L3-\(s.id)", "L3建议", "出现")
                    }
                }

                // ===== 统一输入组件（S2 附录A 合并案，批次3）：一框双模 =====
                // 「说的时刻」（无计划 / ↺ 重说模式）提交=整排；「改/看的时刻」提交=AI 微调（含「再加一项…」）。
                unifiedInput
                if model.isWorking, !deps.liveDraft.streaming.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(deps.liveDraft.streaming) { b in
                            HStack(spacing: 6) {
                                Text(b.start.formatted(date: .omitted, time: .shortened))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(b.title).font(.caption)
                            }
                        }
                    }
                    .padding(.leading, 2)
                }

                // A 状态行（0.26 ABC → 0.28.1 统一消息条）：确定性成功状态「✓ 排好 N 件」——与 note(B) 叠加
                if let n = model.arrangedCount {
                    MessageStrip(icon: "checkmark.circle.fill", tint: theme.positiveTint,
                                 text: "排好 \(n) 件", textStyle: .primary)
                }
                // C 状态行（#15，0.29.0）：微调完成的确定性反馈——N=本地 diff 出的事实，
                // 非模型自由发挥（自由通道审核未过：可能违措辞红线；模型嗓音只走宪法约束的 note=B）
                if let c = model.refinedChangeCount {
                    MessageStrip(icon: c > 0 ? "checkmark.circle.fill" : "info.circle",
                                 tint: c > 0 ? theme.positiveTint : .gray,
                                 text: c > 0 ? "已按指令调整 \(c) 处" : "没识别出要改的动作——一切保持原样",
                                 textStyle: .primary)
                }
                // B：模型 note（宪法约束、温和前向）。防呆：抽风成「1」这种垃圾 → trim 后太短不显
                if let note = model.note,
                   note.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 {
                    // 换装 B：信息蓝并入 actualTint 族——同屏只保留一种蓝（微决策留档）
                    MessageStrip(icon: "quote.opening", tint: theme.actualTint, text: note)
                }
                if !model.pendingLongTasks.isEmpty {
                    Label("识别到未来事项：\(model.pendingLongTasks.map(\.title).joined(separator: "、"))——确认写入时加入「未来任务」",
                          systemImage: "tray.and.arrow.down")
                        .font(.caption).foregroundStyle(theme.looseTint)
                }
                if let err = model.errorText {
                    Text(err).font(.callout).foregroundStyle(.red)
                }
                if let snap = model.pendingRestore {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
                        Text("上次有未保存的修改（为 \(Self.dayLabel(snap.targetDay)) · 存于 \(snap.savedAt.formatted(date: .omitted, time: .shortened))）")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("恢复") { model.applyPendingRestore() }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(theme.actualTint).underline()
                        Button("丢弃") { model.dismissPendingRestore() }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).underline()
                        Spacer()
                    }
                }

                // 未来任务/在途：只在"说的时刻"出现（改/看时收起——渐进披露 v2）
                if !showingPlanArea { ongoingSection }

                // 收尾卡 v2（0.38，#33 拍板）：从橙色小横条升级为独立大卡——与报错带视觉彻底分离，
                // 「先不收尾」一键当天收起。触发新增「傍晚线后事实性收工」（最后完成后空档 ≥45 分钟）。
                // 红线照旧：措辞绝不出现「还剩 N 件」；已盖章/已收起当天不再出现。
                if model.tomorrowReadyCelebration {
                    // 第二仪式（0.38，#33 拍板③）：收尾章后顺手排完明天 → 一次性庆祝
                    VStack(spacing: 6) {
                        CelebrationBurst()
                        Text("明天也就位了——睡个好觉 🌙").font(.headline)
                        Button("收下") { model.tomorrowReadyCelebration = false }
                            .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)   // 换装 C：卡面间距对齐 8pt 网格
                    .background(theme.looseTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))   // 夜/月族归位（C）
                }
                if wrapUpCardVisible {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "sunset.fill").font(.title3).foregroundStyle(theme.accent)   // 字阶收敛（C）
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
                                deps.router.selectedTab = .journal
                                deps.router.journalRequest = .now
                                deps.router.wrapUpRequest = true
                            } label: {
                                Label("进入收尾", systemImage: "arrow.right.circle.fill").font(.callout)
                            }
                            // S3-P2（2026-07-14）：提议卡内用普通音量——最强音量（borderedProminent）
                            // 是页面主务「确认写入」的专属；收尾有三重入口兜底（卡+晚通知+menu bar 回看今天）。
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(16)   // 换装 C：卡面间距对齐 8pt 网格
                    // 换装 B：收口卡=情感时刻场域（条文 11 白名单）→ 暮色橙 accent 打底，粉尾保留暖意
                    .background(LinearGradient(colors: [theme.accent.opacity(0.16), Color.pink.opacity(0.10)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 14))
                    .onAppear {   // 埋点（调研 B 组）：出现按天去重 + 触发信号
                        BehaviorLog.recordOncePerDay(key: "收口卡",
                            "收口卡", "出现·信号=\(model.blocks.isEmpty ? "剩余空" : (Date.now >= WorkHoursSettings.effectiveWindDown(from: .now) ? "过收工线" : "傍晚空档"))")
                    }
                }

                // 开发期：失败横幅，点开看错误日志（产品上架前切回静默）
                if let issue = DevLog.shared.lastIssue {
                    NavigationLink {
                        DevLogView()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: issue.level == .error
                                  ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            Text("[\(issue.source)] \(issue.message)").font(.caption)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .padding(8)
                        .foregroundStyle(issue.level == .error ? .red : .orange)
                        .background((issue.level == .error ? Color.red : Color.orange).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                // 新鲜度徽标（0.24 C2 → v2 两边再选）：中性、不打断——底层变了，
                // 三个显式出路：对比两版 / 载入最新 / 继续编辑。绝不弹窗打断、绝不自动合并。
                if model.freshness {
                    MessageStrip(icon: "arrow.triangle.2.circlepath", tint: theme.actualTint,
                                 text: "这天有更新：\(model.freshnessSource.label)") {
                        HStack(spacing: 6) {
                            if model.freshBase != nil {
                                Button("对比两版…") { BehaviorLog.record("徽标", "打开对比两版"); showFreshCompare = true }
                                    .buttonStyle(.plain).underline()
                            }
                            Button("载入最新") { model.reloadFreshBase() }
                                .buttonStyle(.plain).underline()
                            Text("· 或继续编辑，确认时以本页为准")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    .sheet(isPresented: $showFreshCompare) {
                        FreshCompareSheet(mine: model.blocks,
                                          fresh: model.freshBase ?? [],
                                          sourceLabel: model.freshnessSource.label,
                                          onAdoptFresh: { model.adoptFreshBase(); showFreshCompare = false },
                                          onKeepMine: { model.keepMyDraft(); showFreshCompare = false })
                    }
                }

                // 实时态标识已升级为顶栏胶囊（1b 方案 A，批次3）——原橙色说明行退役，语义并入胶囊 help

                // 有块、或有未保存修改（含"删到空"）都保留写入区——否则删掉最后一件就没法确认保存
                if !model.blocks.isEmpty || model.hasUnsavedChanges {
                    Divider()
                    HStack {
                        // 状态陈述已迁区域底部弱字行（U3 落地，批次3）；「加一项」融进列表尾行（#37/S3）
                        Spacer()
                        // S3 归位（2026-07-14）：草稿低中频动作（放大/挪日/导出/放弃）从三处散排
                        // 收进一个 ⋯（U2 第二层；破坏性「放弃修改」菜单内隔开，U10）
                        Menu {
                            #if !os(macOS)
                            Button { showDraftExpanded = true } label: {
                                Label("放大编辑", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            #endif
                            // 0.23 C：整份草稿显式挪日（取代退役的"切日自动平移"）
                            if !model.blocks.isEmpty {
                                Menu("挪到…") {
                                    Button("挪到今天") { model.moveDraft(to: DayContext.logicalDay(offset: 0)) }
                                    Button("挪到明天") { model.moveDraft(to: DayContext.logicalDay(offset: 1)) }
                                    Button("挪到后天") { model.moveDraft(to: DayContext.logicalDay(offset: 2)) }
                                }
                            }
                            // ICS 导出归"看的时刻"、仅高密皮肤露（渐进披露 v2）
                            if DisclosureSettings.showsDeepFeatures {
                                #if os(macOS)
                                Button { exportICS() } label: {
                                    Label("导出 ICS", systemImage: "square.and.arrow.up")
                                }
                                #else
                                ShareLink(item: ICSDocument(text: model.currentICS()),
                                          preview: SharePreview("BetterCalendar 计划.ics")) {
                                    Label("导出 ICS", systemImage: "square.and.arrow.up")
                                }
                                #endif
                            }
                            if model.hasUnsavedChanges {
                                Divider()
                                Button("放弃修改", role: .destructive) { model.discardDraft() }
                            }
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                        }
                        .font(.caption)
                        .help("草稿与列表的更多操作")
                    }

                    if model.blocks.isEmpty {
                        Label("这天已清空 · 点「确认写入」保存为没有安排的一天，或再加一项",
                              systemImage: "calendar.badge.minus")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        List {
                            ForEach(model.blocks) { item in
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
                                // 右键菜单已由 EditableRow 内部统一挂载（P4-3：与 ⋯ 同一份内容）
                            }
                            .onMove { model.move($0, $1) }
                            // 「加一项」融进列表（#37/S3 裁决）：最后一行 +，就地输入——
                            // 一句话=AI 定名字/时长/排位（addBlockSmart）；留空回车=空白项（老路保留）
                            addTailRow
                        }
                        .frame(height: max(140, min(CGFloat(model.blocks.count) * 84 + 60, 480)))
                    }

                    // 「尽早」软限（≤2）：只温和提示、不硬挡——稀缺才是意义，什么都尽早=什么都不尽早
                    let mitCount = model.blocks.filter { $0.priority == .important }.count
                    if mitCount > 2 {
                        Label("「尽早」贵在少（已标 \(mitCount) 件）——越多越稀释，真正想优先的留 1–2 件就好",
                              systemImage: "sparkles")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    // AI 调整已移到输入区上方（改/看的时刻·原位替换排今天）——此处不再重复

                    HStack {
                        Button {
                            Task {
                                // 合一（Jason 2026-07-09）：确认写入绿计划（push，有改动才）+ 实时日同步蓝色实际改动（pull）。
                                // 主动点=用户此刻本机日历最新 → 对账直接信任日历、不弹窗。
                                if model.hasUnsavedChanges { await model.confirm() }
                                if model.isLiveTargetDay { await deps.execution.reconcileCalendarActuals() }
                            }
                        } label: {
                            Label(confirmSyncButtonTitle, systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking || (!model.hasUnsavedChanges && !model.isLiveTargetDay))
                    }

                    // U3 状态行落地（批次3）：陈述句一律住区域底部弱字行，不混操作区
                    Group {
                        if model.hasUnsavedChanges {
                            Label("未保存修改 · 点上方「确认写入」保存", systemImage: "pencil.circle")
                        } else if let c = model.committedCount {
                            Label(model.committedToReal ? "已写入真日历(Dev) \(c) 项 · 系统日历可见"
                                                        : "已写入假日历 \(c) 项", systemImage: "checkmark.seal")
                        } else {
                            Label("已保存 · 与日历一致", systemImage: "checkmark.seal")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding()
            }
            // 换装批次A：微暖中性阶页底（条文 1B，令牌 bg）
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle("BetterCalendar")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // 「预览（假日历）」入口退役（2026-07-11 Jason 定）：假日历 0.19.1 起已无写入路径，
                    // 观察页失去意义；CalendarPreviewView 代码保留（单测/开发排查可用），只撤 UI 入口。
                    #if os(macOS)
                    // 开发期：算法试验台（上架前随「可见报错」条款一起撤）
                    Button { openWindow(id: "algo-bench") } label: { Label("算法试验台", systemImage: "flask") }
                        .help("算法试验台（开发期）：解析/微调/reflow 各变体跑分对比")
                    // 开发期：皮肤试衣间（美术样品阶段；M8 摘除）
                    Button { openWindow(id: "skin-fitting") } label: { Label("皮肤试衣间", systemImage: "paintpalette") }
                        .help("皮肤试衣间（开发期）：语义色 4 案 × 数字 2 案 × 明暗并排——样品评审")
                    #else
                    Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
                    #endif
                }
            }
            #if !os(macOS)
            // 草稿全屏浏览/编辑（同一份数据，改动即生效；小窗只是入口）
            .sheet(isPresented: $showDraftExpanded) {
                NavigationStack {
                    List {
                        ForEach(model.blocks) { item in
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
                            // 右键菜单已由 EditableRow 内部统一挂载（P4-3）
                        }
                        .onMove { model.move($0, $1) }
                    }
                    .navigationTitle("草稿 · \(model.blocks.count) 块")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { model.addBlock() } label: { Image(systemName: "plus") }
                                .accessibilityLabel("加一项")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showDraftExpanded = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
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
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .preview: CalendarPreviewView(store: deps.calendarStore,
                                                   reminderStore: deps.reminderStore)
                }
            }
            .onChange(of: deps.router.scheduleRequest) { _, req in
                guard let req else { return }
                switch req {
                case .arrangeToday(let text):
                    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.inputText = text
                        Task { await model.arrange() }
                    }
                case .planTomorrow:   // 0.38（#33）：收尾章后「顺手排一下明天」
                    model.targetDay = DayContext.logicalDay(offset: 1)
                    model.autoLoadOnAppear()
                }
                deps.router.scheduleRequest = nil   // 消费掉
            }
            .onAppear { model.autoLoadOnAppear() }   // 进页自动加载目标日已确认计划（不覆盖未确认草稿）
            // 双向同步回流后（0.22.2→0.24 C2）：干净视图直接刷新；编辑中亮新鲜度徽标（不打扰、不弹窗）
            .onReceive(NotificationCenter.default.publisher(for: ReconcileService.planChangedExternally)) { _ in
                model.noteExternalPlanChange()
            }
            // 执行进展（开始/完成/换件）→ 实时日精修台跟着现实走；编辑中亮徽标（0.24 C2）
            .onReceive(NotificationCenter.default.publisher(for: ExecutionProgressSignal.changed)) { _ in
                model.noteExecutionProgress()
            }
            // 0.20 双向同步 → 0.25.6 改带「不再询问」勾选 sheet（与运行态恢复统一交互）。
            .sheet(isPresented: Binding(get: { deps.reconcile.hasPendingChanges },
                                        set: { if !$0, deps.reconcile.hasPendingChanges {
                                            deps.reconcile.resolveChanges(sync: false, remember: false) } })) {
                let dels = deps.reconcile.pendingDeletions.map(\.title).joined(separator: "、")
                let adds = deps.reconcile.pendingAdditions.map(\.title).joined(separator: "、")
                RememberableConfirmSheet(
                    title: "日历里有改动，要同步吗？",
                    message: (dels.isEmpty ? "" : "移除了：\(dels)\n")
                        + (adds.isEmpty ? "" : "新建了：\(adds)\n")
                        + "（可随时在 设置→进阶 里改处理策略）",
                    options: [
                        .init(label: "同步（照日历的改）", role: .destructive, appliesRemember: true),
                        .init(label: "保留现状（不同步）", role: nil, appliesRemember: true),
                    ],
                    onChoose: { i, remember in
                        deps.reconcile.resolveChanges(sync: i == 0, remember: remember)
                    })
            }
            .onChange(of: model.inputText) { _, _ in model.persistDraft() }   // 输入框逐字落盘（崩溃可还原）
            // 0.23 C：切目标日 = 切草稿本（每天一页；"平移跟人走"已退役，挪日走显式「挪到…」菜单）
            .onChange(of: model.targetDay) { _, _ in
                model.targetDayDidChange()
            }
        }
    }

    // MARK: 渐进披露 v2 抽出的子视图（0.26）

    /// 统一输入组件（S2 附录A，批次3 落地）：同一个框、意图随时刻自动切换——
    /// 「说的时刻」（无计划 / ↺ 重说模式）提交=整排；「改/看的时刻」提交=AI 微调（可含「再加一项…」）。
    /// 内嵌提交钮（右下）+ ↺ 重说切换（左下，仅改/看时刻出现）+ 拖高把手照旧。文本双仓不丢字：
    /// 整排走 model.inputText、微调走 model.refineText——切模式互不覆盖。
    private var arrangeMode: Bool { !showingPlanArea || reSayExpanded }

    private var unifiedText: Binding<String> {
        arrangeMode ? $model.inputText : $model.refineText
    }

    @ViewBuilder private var unifiedInput: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: unifiedText)
                .font(.callout)   // 字阶收敛（C）：正文档=callout（body 档值）
                .scrollContentBackground(.hidden)
                .padding(6)
                .padding(.bottom, 24)   // 给底部内嵌控件行让位
            if unifiedText.wrappedValue.isEmpty {
                Text(arrangeMode
                     ? (reSayExpanded ? "重新说一遍这一天——排出的新计划会替换当前草稿" : PlaceholderSettings.currentText())
                     : "想怎么调？例：把健身挪到上午10点 · 再加一项背单词45分钟")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11).padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: CGFloat(inputHeight))
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface))   // 换装 C：输入区=surface 纸面
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .overlay(alignment: .bottomLeading) {
            if showingPlanArea {
                Button { reSayExpanded.toggle() } label: {
                    Label(reSayExpanded ? "回到微调" : "重说一遍",
                          systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly).font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(reSayExpanded ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .padding(8)
                .help(reSayExpanded ? "回到微调模式（当前草稿原样保留）" : "重新说一遍这一天（排出后替换当前草稿）")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                    Text("模型思考中…").font(.caption2).foregroundStyle(.secondary)
                }
                // 批次6（Jason 反馈）：提交钮从裸文字升级为有容器的小按钮——一眼可辨「这能点」
                Button { submitUnified() } label: {
                    Label(arrangeMode ? "排\(Self.relativeDayWord(model.targetDay))" : "AI 调整",
                          systemImage: arrangeMode ? "wand.and.stars" : "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.isWorking)
            }
            .padding(6)
        }
        Capsule().fill(.quaternary)
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if dragBaseHeight == nil { dragBaseHeight = inputHeight }
                        inputHeight = min(max(72, (dragBaseHeight ?? inputHeight) + v.translation.height), 420)
                    }
                    .onEnded { _ in dragBaseHeight = nil }
            )
            .help("拖动调整输入框高度")
    }

    private func submitUnified() {
        if arrangeMode {
            reSayExpanded = false
            Task { await model.arrange() }
        } else {
            Task { await model.refine() }
        }
    }

    /// 列表尾行「+ 加一项」（#37/S3 裁决：不做独立按钮，融进列表交互）。
    @ViewBuilder private var addTailRow: some View {
        if addRowActive {
            HStack(spacing: 6) {
                TextField("一句话加一项（回车确认；留空回车=空白项）", text: $smartAddText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let t = smartAddText.trimmingCharacters(in: .whitespaces)
                        addRowActive = false; smartAddText = ""
                        if t.isEmpty { model.addBlock() } else { Task { await model.addBlockSmart(t) } }
                    }
                Button("取消") { addRowActive = false; smartAddText = "" }
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

    // MARK: 「在途」（M10）：跨日任务池——收起一行，点开轻抽屉；不做管理界面，只做决策现场的入口

    @State private var ongoingExpanded = false
    @State private var newOngoingTitle = ""

    @ViewBuilder private var ongoingSection: some View {
        let store = deps.longTasks
        DisclosureGroup(isExpanded: $ongoingExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.items) { task in
                        ongoingRow(task, overdue: (task.deadline ?? .distantFuture) < .now)
                    }
                    HStack {
                        TextField("手动加一件（主路径是直接在上面说）", text: $newOngoingTitle)
                            .textFieldStyle(.roundedBorder)
                        Button("加入") {
                            let t = newOngoingTitle.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            store.add(title: t)
                            newOngoingTitle = ""
                        }
                        .disabled(newOngoingTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .font(.caption)
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full").foregroundStyle(theme.looseTint)
                    if store.items.isEmpty {
                        Text("未来任务 · 空").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("未来任务 \(store.items.count) 件"
                             + nearestDDLLabel(store.items)).font(.caption)
                    }
                }
            }
    }

    private func nearestDDLLabel(_ items: [LongTask]) -> String {
        guard let next = items.compactMap(\.deadline).min() else { return "" }
        return " · 最近：\(next.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated)))"
    }

    private func ongoingRow(_ task: LongTask, overdue: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.title).font(.callout)
                    // 进度达/超估算 → 标题右边轻声邀请（问句、非断言；点一下才标完成）
                    if deps.longTasks.looksComplete(for: task) {
                        Button("看起来做完了？") { deps.longTasks.complete(task) }
                            .font(.caption2).buttonStyle(.borderless).foregroundStyle(theme.positiveTint)
                            .help("投入已达到你估的总量——做成了就点一下（不点也没关系）")
                    }
                }
                HStack(spacing: 6) {
                    if let d = task.deadline {
                        Text((overdue ? "原定 " : "DDL ") + d.formatted(.dateTime.month(.defaultDigits).day()))
                            .font(.caption2)
                            .foregroundStyle(overdue ? .orange : .secondary)
                    }
                    if let c = task.cadenceMinutesPerWeek {
                        Text("每周约 \(c / 60) 小时").font(.caption2).foregroundStyle(.secondary)
                    }
                    // 进度（A，三红线）：单元优先/无单元退时长；永远锚定"已"
                    let progress = deps.longTasks.progressText(for: task)
                    if !progress.isEmpty {
                        Text(progress).font(.caption2).foregroundStyle(theme.positiveTint)
                    }
                }
                // 增长条（只在有总量时；绿色从零长起、无"还剩"）
                if let f = deps.longTasks.progressFraction(for: task) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(height: 3)
                            Capsule().fill(theme.positiveTint).frame(width: geo.size.width * f, height: 3)
                        }
                    }
                    .frame(height: 3)
                }
            }
            Spacer()
            if overdue {
                // 温和三选（D-d 拍板）：不留红色残留、放下也是体面出口
                Button("排进今天") { model.smartInsertFromLongTask(task) }
                    .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                Button("推一周") { deps.longTasks.pushDeadline(task) }
                    .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                Button("先放下") { deps.longTasks.shelve(task) }
                    .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
            } else {
                Menu {
                    Button("帮我排进今天（智能插空档）") { model.smartInsertFromLongTask(task) }
                    Button("做成了") { deps.longTasks.complete(task) }
                    Button("推一周") { deps.longTasks.pushDeadline(task) }
                    Button("先放下") { deps.longTasks.shelve(task) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(6)
        .background((overdue ? Color.orange : theme.looseTint).opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // 目标日期标签：默认无感（晚上→明天/白天→今天），点开可改。
    // 用**逻辑日**（凌晨 0–4 点「今天」=心智上的今天=日历昨天），与 PlanStore 归桶/defaultTargetDay 一致。
    private var targetDayMenu: some View {
        Menu {
            Button("今天") { model.targetDay = DayContext.logicalDay(offset: 0) }
            Button("明天") { model.targetDay = DayContext.logicalDay(offset: 1) }
            Button("后天") { model.targetDay = DayContext.logicalDay(offset: 2) }
            // 「昨天（不建议）」已删（S3-P3，2026-07-14）：回填过去的正道=日记页复盘「补一笔」；
            // 判例登记兜底——真有直排昨天的需求再按判例复活。
            Divider()
            // 松散=这一天的属性（批次6 从顶栏挪入）：App 退场陪你——不催、不算落后；随时可结束
            Button {
                model.toggleLoose()
            } label: {
                let loose = deps.looseDays.isLoose(model.targetDay)
                Label(loose ? "结束松散" : "松散一下",
                      systemImage: loose ? "moon.zzz.fill" : "moon.zzz")
            }
        } label: {
            // 口语词 + 具体日期（2026-07-09 Jason 要求「为今天安排」标上是哪天）
            // #28（2026-07-11 审核定稿）：凌晨窗口给一句口径澄清——逻辑日语义不开开关（口径分叉否决），
            // 但「今天=昨天的日期」要向真实日心智的人解释清楚（困惑的解药是标注，不是语义分叉）。
            Label("为 \(Self.relativeDayWord(model.targetDay))（\(Self.dayLabel(model.targetDay))\(Self.smallHoursHint(for: model.targetDay))）安排",
                  systemImage: "calendar")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

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

    /// 目标日的口语词（按钮文案随所选日变）：今天/明天/后天/昨天，再远显日期。
    /// 以**逻辑今天**为基准（凌晨 0–4 点"今天"=日历昨天）——否则凌晨会把逻辑今天叫成"昨天"（2026-07-08 Jason 报）。
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
    private func exportICS() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "BetterCalendar计划.ics"
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            try? model.currentICS().write(to: url, atomically: true, encoding: .utf8)
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

// MARK: - 徽标 v2「预览两边再选」（2026-07-10）：两版只读对比，用户看清差异再拍板。
// 原则7：不自动合并、不替用户选——左=你的编辑（确认时生效），右=最新的底（reflow/日历改动后的现实）。

struct FreshCompareSheet: View {
    var mine: [EditableBlock]
    var fresh: [EditableBlock]
    var sourceLabel: String
    var onAdoptFresh: () -> Void
    var onKeepMine: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme   // 令牌表 v1（换装批次 B）

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("两个版本，选一个继续").font(.headline)
            Text("最新的底来自：\(sourceLabel)。只读对比——选哪版都不丢另一版的事实（真相源只在你确认时改）。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                // 换装 B：按 App 通用色语言重映射——本页未确认的编辑=预览橙、日历里的计划事实=计划绿
                column(title: "我的编辑（本页）", blocks: mine, accent: theme.previewTint)
                column(title: "最新的底", blocks: fresh, accent: theme.plannedTint)
            }
            HStack {
                Spacer()
                Button("保留我的编辑") { onKeepMine() }
                Button("用最新的底") { onAdoptFresh() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 380)
    }

    @ViewBuilder private func column(title: String, blocks: [EditableBlock], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "list.bullet.rectangle")
                .font(.headline).foregroundStyle(accent)   // 字阶收敛（C）：列标题→headline 档
            if blocks.isEmpty {
                Text("（空）").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(blocks) { b in
                        HStack(spacing: 6) {
                            Text(Self.hm(b.start) + "–" + Self.hm(b.end))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(b.title).font(.caption).lineLimit(1)
                            if b.isFixed { Text("固定").font(.caption2).foregroundStyle(.secondary) }   // U7：同行内「固定」tag 同款（灰）
                            if b.isAnchor { Text("锚").font(.caption2).foregroundStyle(.brown) }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func hm(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
