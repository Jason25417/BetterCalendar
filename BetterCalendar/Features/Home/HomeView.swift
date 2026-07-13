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

    // AI 加一项（0.36.0）：一句话 → LLM 定名字/时长/分块；空白项老路保留
    @State private var showSmartAdd = false
    @State private var smartAddText = ""
    private func submitSmartAdd() {
        let t = smartAddText
        showSmartAdd = false; smartAddText = ""
        Task { await model.addBlockSmart(t) }
    }

    let deps: HomeDeps
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
                    let loose = deps.looseDays.isLoose(model.targetDay)
                    Button { model.toggleLoose() } label: {
                        Label(loose ? "结束松散" : "松散一下",
                              systemImage: loose ? "moon.zzz.fill" : "moon.zzz")
                    }
                    .font(.caption).buttonStyle(.borderless)
                    .foregroundStyle(loose ? .purple : .secondary)
                    .help("把这天标为松散：App 退场陪你——不催、不算落后。随时可结束；短时间的小憩直接留白即可，不必标松散")
                    targetDayMenu
                }

                // 「给明天的一句话」晨间面（#23）：昨晚的你留给今早的你——发出者是用户自己，
                // 不写=不存在；点 ✕ 只收当天（明天有新寄语照常出现）。
                if let tn = TomorrowNote.note(), !TomorrowNote.isDismissed(), !tnDismissTick {
                    MessageStrip(icon: "sunrise", tint: .purple, text: "昨晚的你说：\(tn)") {
                        Button { TomorrowNote.dismiss(); tnDismissTick = true } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }

                // 松散日：退场 + 见证的姿态横幅（不删任何计划、可撕；深层姿态效果后续接）
                if deps.looseDays.isLoose(model.targetDay) {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.stars.fill").foregroundStyle(.purple)
                        Text("松散日 · 已经退场陪你了——不催、不算账。想排还是能排，也可以就好好休息。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.08))
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
                    MessageStrip(icon: "lightbulb", tint: .orange, text: s.text) {
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
                    }
                    .onAppear {   // 埋点：出现按 (天, 建议) 去重
                        BehaviorLog.recordOncePerDay(key: "L3-\(s.id)", "L3建议", "出现")
                    }
                }

                // ===== 输入 / 动作区（渐进披露 v2·按时刻，0.26）=====
                if showSayInput {
                    // 说的时刻（或点了「重说」）：完整输入 + 排今天
                    inputEditor
                    HStack {
                        Button { reSayExpanded = false; Task { await model.arrange() } } label: {
                            Label("排\(Self.relativeDayWord(model.targetDay))", systemImage: "wand.and.stars")
                        }
                        .disabled(model.isWorking)
                        if model.isWorking {
                            ProgressView().controlSize(.small)
                            Text("模型思考中…").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if showingPlanArea {   // 重说态：可收起回到草稿
                            Button("收起") { reSayExpanded = false }
                                .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
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
                } else {
                    // 改/看的时刻：输入折叠成「重说」入口 + AI 调整（原位替换「排今天」）
                    Button { reSayExpanded = true } label: {
                        Label("想重新说一遍今天？", systemImage: "arrow.uturn.backward")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    aiAdjustRow
                }

                // A 状态行（0.26 ABC → 0.28.1 统一消息条）：确定性成功状态「✓ 排好 N 件」——与 note(B) 叠加
                if let n = model.arrangedCount {
                    MessageStrip(icon: "checkmark.circle.fill", tint: .green,
                                 text: "排好 \(n) 件", textStyle: .primary)
                }
                // C 状态行（#15，0.29.0）：微调完成的确定性反馈——N=本地 diff 出的事实，
                // 非模型自由发挥（自由通道审核未过：可能违措辞红线；模型嗓音只走宪法约束的 note=B）
                if let c = model.refinedChangeCount {
                    MessageStrip(icon: c > 0 ? "checkmark.circle.fill" : "info.circle",
                                 tint: c > 0 ? .green : .gray,
                                 text: c > 0 ? "已按指令调整 \(c) 处" : "没识别出要改的动作——一切保持原样",
                                 textStyle: .primary)
                }
                // B：模型 note（宪法约束、温和前向）。防呆：抽风成「1」这种垃圾 → trim 后太短不显
                if let note = model.note,
                   note.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 {
                    MessageStrip(icon: "quote.opening", tint: .blue, text: note)
                }
                if !model.pendingLongTasks.isEmpty {
                    Label("识别到未来事项：\(model.pendingLongTasks.map(\.title).joined(separator: "、"))——确认写入时加入「未来任务」",
                          systemImage: "tray.and.arrow.down")
                        .font(.caption).foregroundStyle(.purple)
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
                            .font(.caption).buttonStyle(.plain).foregroundStyle(.blue).underline()
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
                    .padding(14)
                    .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                }
                if wrapUpCardVisible {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "sunset.fill").font(.title2).foregroundStyle(.orange)
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
                                Label("进入收尾", systemImage: "arrow.right.circle.fill").font(.callout.bold())
                            }
                            .buttonStyle(.borderedProminent).tint(.orange)
                        }
                    }
                    .padding(14)
                    .background(LinearGradient(colors: [Color.orange.opacity(0.16), Color.pink.opacity(0.10)],
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
                    MessageStrip(icon: "arrow.triangle.2.circlepath", tint: .blue,
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

                // 实时橙色（SPEC §11，2026-07-10）：实时日的底=「从现在起」的橙色现实（与橙色预览同口径）——
                // 明确告诉用户这页就是可编辑的橙色，reflow 会自动跟进（无编辑）或亮徽标（有编辑）。
                if model.isLiveTargetDay, !model.blocks.isEmpty {
                    HStack(spacing: 6) {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                        Text("实时 · 从现在起（这就是橙色预览，改完确认即生效）")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                    }
                }

                // 有块、或有未保存修改（含"删到空"）都保留写入区——否则删掉最后一件就没法确认保存
                if !model.blocks.isEmpty || model.hasUnsavedChanges {
                    Divider()
                    HStack {
                        if model.hasUnsavedChanges {
                            Label("未保存修改 · 点「确认写入」保存", systemImage: "pencil.circle")
                                .font(.subheadline.bold()).foregroundStyle(.orange)
                            Button("放弃修改") { model.discardDraft() }
                                .font(.caption).foregroundStyle(.secondary)
                                .buttonStyle(.plain).underline()
                                .help("不保存，回到已保存的计划")
                        } else {
                            Label("已保存 · 与日历一致", systemImage: "checkmark.seal")
                                .font(.subheadline.bold()).foregroundStyle(.green)
                        }
                        Spacer()
                        #if !os(macOS)
                        Button { showDraftExpanded = true } label: {
                            Label("放大", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .font(.caption)
                        #endif
                        // 0.23 C：整份草稿显式挪日（取代退役的"切日自动平移"）
                        if !model.blocks.isEmpty {
                            Menu {
                                Button("挪到今天") { model.moveDraft(to: DayContext.logicalDay(offset: 0)) }
                                Button("挪到明天") { model.moveDraft(to: DayContext.logicalDay(offset: 1)) }
                                Button("挪到后天") { model.moveDraft(to: DayContext.logicalDay(offset: 2)) }
                            } label: {
                                Label("挪到…", systemImage: "arrow.uturn.forward")
                            }
                            .font(.caption)
                            .help("把这一整份草稿挪到别的日子（保留时分）")
                        }
                        Button { showSmartAdd = true } label: { Label("加一项", systemImage: "plus") }
                            .popover(isPresented: $showSmartAdd) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("加一项").font(.headline)
                                    TextField("一句话描述：如 背单词 45 分钟", text: $smartAddText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(minWidth: 240)
                                        .onSubmit { submitSmartAdd() }
                                    HStack {
                                        Button("直接加空白项") {
                                            showSmartAdd = false; smartAddText = ""
                                            model.addBlock()
                                        }
                                        Spacer()
                                        Button("AI 加一项") { submitSmartAdd() }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(smartAddText.trimmingCharacters(in: .whitespaces).isEmpty)
                                    }
                                }
                                .padding()
                            }
                            .font(.caption)
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
                                .contextMenu {
                                    Button { model.duplicate(id: item.id) } label: { Label("复制", systemImage: "plus.square.on.square") }
                                    Button(role: .destructive) { model.delete(id: item.id) } label: { Label("删除", systemImage: "trash") }
                                }
                            }
                            .onMove { model.move($0, $1) }
                        }
                        .frame(height: max(140, min(CGFloat(model.blocks.count) * 84 + 16, 440)))
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
                        // ICS 导出归"看的时刻"、仅高密皮肤露（原皮不出——渐进披露 v2）
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
                        if let c = model.committedCount {
                            Text(model.committedToReal
                                 ? "已写入真日历(Dev) \(c) 项 → 打开 系统日历查看"
                                 : "已写入假日历 \(c) 项 → 看「预览日历」")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding()
            }
            .navigationTitle("BetterCalendar")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // 「预览（假日历）」入口退役（2026-07-11 Jason 定）：假日历 0.19.1 起已无写入路径，
                    // 观察页失去意义；CalendarPreviewView 代码保留（单测/开发排查可用），只撤 UI 入口。
                    #if os(macOS)
                    // 开发期：算法试验台（上架前随「可见报错」条款一起撤）
                    Button { openWindow(id: "algo-bench") } label: { Label("算法试验台", systemImage: "flask") }
                        .help("算法试验台（开发期）：解析/微调/reflow 各变体跑分对比")
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
                            .contextMenu {
                                Button { model.duplicate(id: item.id) } label: { Label("复制", systemImage: "plus.square.on.square") }
                                Button(role: .destructive) { model.delete(id: item.id) } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                        .onMove { model.move($0, $1) }
                    }
                    .navigationTitle("草稿 · \(model.blocks.count) 块")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { model.addBlock() } label: { Image(systemName: "plus") }
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

    /// 完整输入编辑器（含占位、拖高把手）——"说的时刻"用。
    @ViewBuilder private var inputEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.inputText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
            if model.inputText.isEmpty {
                Text(PlaceholderSettings.currentText())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11).padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: CGFloat(inputHeight))
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
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

    /// AI 调整行（"改/看的时刻"原位替换"排今天"）——把已排的草稿用一句话微调。
    @ViewBuilder private var aiAdjustRow: some View {
        HStack(alignment: .bottom) {
            TextField("想微调？告诉 AI，如：把健身挪到上午10点、写代码改成3小时",
                      text: $model.refineText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.refine() } }
            Button { Task { await model.refine() } } label: {
                Label("AI 调整", systemImage: "sparkles")
            }
            .disabled(model.isWorking)
            if model.isWorking {
                ProgressView().controlSize(.small)
            }
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
                    Image(systemName: "tray.full").foregroundStyle(.purple)
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
                            .font(.caption2).buttonStyle(.borderless).foregroundStyle(.green)
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
                        Text(progress).font(.caption2).foregroundStyle(.green)
                    }
                }
                // 增长条（只在有总量时；绿色从零长起、无"还剩"）
                if let f = deps.longTasks.progressFraction(for: task) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(height: 3)
                            Capsule().fill(.green).frame(width: geo.size.width * f, height: 3)
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
                    Button("做成了 🎉") { deps.longTasks.complete(task) }
                    Button("推一周") { deps.longTasks.pushDeadline(task) }
                    Button("先放下") { deps.longTasks.shelve(task) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(6)
        .background((overdue ? Color.orange : Color.purple).opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // 目标日期标签：默认无感（晚上→明天/白天→今天），点开可改。
    // 用**逻辑日**（凌晨 0–4 点「今天」=心智上的今天=日历昨天），与 PlanStore 归桶/defaultTargetDay 一致。
    private var targetDayMenu: some View {
        Menu {
            Button("今天") { model.targetDay = DayContext.logicalDay(offset: 0) }
            Button("明天") { model.targetDay = DayContext.logicalDay(offset: 1) }
            Button("后天") { model.targetDay = DayContext.logicalDay(offset: 2) }
            Divider()
            Button("昨天（不建议）") { model.targetDay = DayContext.logicalDay(offset: -1) }
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
    @Binding var block: EditableBlock
    var poolTasks: [LongTask] = []   // 可选归属的未来任务（0.18.2 手动选归属；空=不显归属菜单）
    var referenceDay: Date?          // 目标日：块不在这天（跨午夜落次日凌晨）→ 显「次日」徽章；nil=不显
    /// 并行组（0.22）：可结组的其它块（id/标题/是否已同组）+ 伙伴标题（徽章 hover）；空=不显链条菜单
    var parallelCandidates: [(id: UUID, title: String, inGroup: Bool)] = []
    var parallelPeers: [String] = []
    var onToggleParallel: ((UUID) -> Void)? = nil
    var onDelete: () -> Void

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

    /// 时限图标：锚点=图钉 / 有硬 DDL=红旗 / 尽早=橙上箭 / 随时=灰钟。
    private var timingLimitIcon: String {
        if block.isAnchor { return "pin.fill" }
        if block.deadline != nil { return "flag.checkered" }
        return block.priority == .important ? "arrow.up.circle.fill" : "clock"
    }
    private var timingLimitColor: Color {
        if block.isAnchor { return .brown }
        if block.deadline != nil { return .red }
        return block.priority == .important ? .orange : .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            // 时限（星标→DDL 统一，2026-07-09）：三态互斥——随时 / 尽早 / 有具体截止。
            // 复用现成字段：priority==.important 即「尽早」（星标继任、reflow 靠前排），deadline 即硬 DDL。
            Menu {
                Button("随时（今天内即可）") { block.priority = .normal; block.deadline = nil; block.isAnchor = false }
                Button("尽早") { block.priority = .important; block.deadline = nil; block.isAnchor = false }
                Button("有具体截止…") {
                    block.priority = .normal; block.isAnchor = false
                    if block.deadline == nil { block.deadline = block.end }
                }
                Divider()
                // 锚点手动开关（Jason 2026-07-09）：午饭/通勤这类=占时间不催完成；能手动设也能改回任务。
                Button(block.isAnchor ? "✓ 生活锚点（不催完成）" : "设为生活锚点（午饭/通勤这类）") {
                    block.isAnchor.toggle()
                    if block.isAnchor { block.priority = .normal; block.deadline = nil }
                }
            } label: {
                Image(systemName: timingLimitIcon).foregroundStyle(timingLimitColor)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("这件事是什么：随时 / 尽早（优先靠前排）/ 有具体截止（DDL）/ 生活锚点")

            VStack(alignment: .leading, spacing: 4) {
                TextField("标题", text: $block.title)
                HStack(spacing: 6) {
                    DatePicker("", selection: $block.start, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("", selection: $block.end, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    if isNextDay {
                        Text("次日")
                            .font(.caption2).foregroundStyle(.indigo)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.indigo.opacity(0.12)).clipShape(Capsule())
                            .help("跨午夜：属同一逻辑日，日历上落在次日凌晨（改时间到 0–4 点会自动归次日）")
                    } else if crossesMidnight {
                        Text("至次日")
                            .font(.caption2).foregroundStyle(.indigo)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.indigo.opacity(0.12)).clipShape(Capsule())
                            .help("结束时间跨过午夜（如 23:30–01:00）：仍属同一逻辑日")
                    }
                    Toggle("固定", isOn: $block.isFixed)
                        .toggleStyle(.button).controlSize(.small)
                    Menu {
                        Button("轻计时") { block.timingStyle = .light }
                        Button("🍅 番茄钟") { block.timingStyle = .pomodoro }
                        Button("不计时") { block.timingStyle = .none }
                    } label: {
                        Text(Self.styleLabel(block.timingStyle))
                    }
                    .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
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
                    Spacer()
                    // 并行组（0.22）：链条菜单——选一块结组（同组=同时段、reflow 绑定）；再选已同组的=解除
                    if let onToggleParallel, !parallelCandidates.isEmpty || block.parallelGroup != nil {
                        Menu {
                            ForEach(parallelCandidates, id: \.id) { c in
                                Button(c.inGroup ? "✓ \(c.title)（点击解除）" : c.title) {
                                    onToggleParallel(c.id)
                                }
                            }
                            if parallelCandidates.isEmpty { Text("没有可结组的块") }
                        } label: {
                            Image(systemName: block.parallelGroup != nil ? "link.circle.fill" : "link")
                                .foregroundStyle(block.parallelGroup != nil ? .teal : .secondary)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help(block.parallelGroup != nil
                              ? "与「\(parallelPeers.joined(separator: "、"))」并行（同时段，重排时绑定）"
                              : "与别的块并行（同时段进行，重排时保持绑定）")
                    }
                    // 归属未来任务：放右侧空位（不破坏左侧标题对齐）；投入精确记到它名下
                    if !poolTasks.isEmpty || block.linkedTaskID != nil {
                        Menu {
                            Button("无归属") { block.linkedTaskID = nil }
                            if !poolTasks.isEmpty { Divider() }
                            ForEach(poolTasks) { t in
                                Button(t.title) { block.linkedTaskID = t.id }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: block.linkedTaskID != nil ? "tray.full.fill" : "tray")
                                    .foregroundStyle(block.linkedTaskID != nil ? .purple : .secondary)
                                if let linkedTitle {
                                    // 0.35.0：修 iPhone 行溢出（TestFlight 反馈#4）——长标题截断限宽，
                                    // 不再把时间胶囊挤出屏幕
                                    Text(linkedTitle).foregroundStyle(.purple)
                                        .lineLimit(1).truncationMode(.tail)
                                        .frame(maxWidth: 150, alignment: .leading)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .help("这件属于哪个未来任务——投入会精确记到它名下")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        // 生活锚点淡显（0.20.3，§5.10 块三角色）：占位不是任务——可看可改时间，但视觉退后一步
        .opacity(block.isAnchor ? 0.55 : 1)
        .help(block.isAnchor ? "生活锚点（午饭/通勤这类）：占时间、塑造节奏，但不是要完成的任务" : "")
    }

    static func styleLabel(_ s: TimingStyle) -> String {
        switch s {
        case .light: return "轻计时"
        case .pomodoro: return "🍅 番茄"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("两个版本，选一个继续").font(.headline)
            Text("最新的底来自：\(sourceLabel)。只读对比——选哪版都不丢另一版的事实（真相源只在你确认时改）。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                column(title: "我的编辑（本页）", blocks: mine, accent: .blue)
                column(title: "最新的底", blocks: fresh, accent: .orange)
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
                .font(.subheadline.bold()).foregroundStyle(accent)
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
                            if b.isFixed { Text("固定").font(.caption2).foregroundStyle(.purple) }
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
