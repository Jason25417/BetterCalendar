//
//  ExecutionPanel.swift
//  BetterCalendar
//
//  执行陪伴面板（跨平台）：当前块 · 已用时长 · 下一件，单键 完成/下一件/换一件 + 休息toggle + 番茄段确认。
//  macOS：装进 menu bar 的 NSPopover；iOS：直接嵌进排日程页（没 menu bar）。「记录 = 导航」的入口。
//
//  六态主按钮矩阵（S3 状态宪法，2026-07-14 成文——新增任何状态，先回答「它的唯一主按钮是什么」）：
//  空闲=开始下一件 · 选中=开始任务 · 进行=完成当前 · 休息=结束休息 · 番茄段间=再来一段/回到专注 · 新事项表单=同时开始/开始
//  三层模型（S2）：缩略层=menu bar label（iOS 将来=Live Activity）· 展开层=popover（compactCapable=true，
//  默认精简子集+底部 chevron 就地展开，展开态记住上次）· 全屏层=iOS「今天」页（恒全量）。
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct ExecutionPanel: View {
    @Environment(\.appTheme) private var theme   // 令牌表 v1（换装批次 B）
    @Bindable var model: ExecutionViewModel
    /// 回看今天/收尾入口（批次7 F6）：宿主注入跳转闭包——macOS=开主窗+切日记；iOS=router 切 tab。
    /// 帧2 承诺的「收尾入口」由此跨端可用（此前 macOS-only）。
    var onOpenJournal: (() -> Void)? = nil
    /// 展开层裁剪（S3-P1，2026-07-14 Jason 修订版）：menu bar 宿主传 true → 默认精简子集
    /// （当前件+主键+同时做+边缘行），底部 chevron 就地展开为全量、再点收回；展开态记住上次选择。
    var compactCapable: Bool = false
    /// W19：嵌进「今天」页顶部时铺满宽度（menu bar 弹窗仍是固定 280 宽）。
    var fillsWidth: Bool = false
    @AppStorage("execPanelExpanded") private var panelExpanded = false
    private var isCompact: Bool { compactCapable && !panelExpanded }
    @State private var earlyBreakConfirming = false   // 「提前休息」的小摩擦确认（0.20.5）

    // 计划外「+ 新事项…」输入态（0.25，点子 #1 过审）：临时冒出的事当场开始 = bonus，不写计划
    enum AdHocKind { case foreground, parallel }
    @State private var adHocKind: AdHocKind? = nil
    @State private var adHocTitle = ""
    @State private var adHocStyle: TimingStyle = .light
    @FocusState private var adHocFocused: Bool

    /// 多端跟随（#30）：另一台设备在做而本机空档 → 陪伴条（一键退出=审核红线③）。
    @ViewBuilder private var followStrip: some View {
        if model.active == nil, let f = FollowRunState.shared.run {
            HStack(spacing: 6) {
                Image(systemName: "ipad.and.iphone").foregroundStyle(.secondary)
                Text("另一台设备正在做「\(f.title)」· 已 \(Self.hms(f.elapsed()))")
                    .font(.caption)
                Spacer()
                Button("退出跟随") { FollowRunState.shared.exitFollow() }
                    .font(.caption).tint(.primary)   // 体检 #6
            }
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))   // 体检 #4：圆角归三档
        }
    }

    var body: some View {
        Group {
        if model.usesCanonicalTiming, let tasks = model.canonicalTasks {
            BridgeTaskPanel(model: tasks, planned: model.planned)
        } else {
        VStack(alignment: .leading, spacing: 10) {
            header
            followStrip
            if !isCompact { mitStrip }
            Divider()
            adHocInput
            actions(compact: isCompact)
            if !isCompact { focusHint }
            backgroundSection
            if isCompact {
                compactEdgeRow
            } else {
                Divider()
                footer
            }
            InlineIssueText(source: "执行", message: model.lastError, font: .caption2)   // W16：同一判定
            if compactCapable { expandToggle }
        }
        }
        }
        .padding(12)
        #if os(macOS)
        .frame(width: fillsWidth ? nil : 280)
        #endif
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .task { await model.loadToday() }
        #if os(macOS)
        // 弹窗重新打开 → 清掉遗留的「新事项」输入态（防 hold 卡死导致点外面关不掉，0.26.19）
        .onReceive(NotificationCenter.default.publisher(for: MenuBarPopoverHold.resetAdHocNotice)) { _ in
            if adHocKind != nil { resetAdHoc() }
        }
        #endif
        // 三选恢复（0.22.1 → 0.25.6 改带「不再询问」勾选 sheet）：退出/闪退/清后台前有任务在进行 → 问怎么接
        .sheet(isPresented: Binding(get: { model.pendingRunRestore != nil },
                                    set: { if !$0, model.pendingRunRestore != nil {
                                        model.resolveRunRestore(.continueWithoutGap) } })) {
            RememberableConfirmSheet(
                title: "退出时「\(model.pendingRunRestore?.active?.title ?? model.pendingRunRestore?.background.first?.title ?? "任务")」正在进行，想继续吗？",
                message: "同一逻辑日内的计时可以接上；并行任务与番茄段状态会一并恢复。",
                options: [
                    .init(label: "继续（离开的 \(Self.gapText(model.pendingRunRestore)) 也算上）", role: nil, appliesRemember: true),
                    .init(label: "直接继续（离开的时间不算）", role: nil, appliesRemember: true),
                    .init(label: "重新开始（当作没做过）", role: .destructive, appliesRemember: true),
                ],
                onChoose: { i, remember in
                    let choice: ExecutionViewModel.RunRestoreChoice =
                        [.continueWithGap, .continueWithoutGap, .discard][i]
                    if remember { ExecutionViewModel.RunRestoreSettings.policy = choice }
                    model.resolveRunRestore(choice)
                })
        }
    }

    /// 离开时长的口语描述（恢复对话框用）。
    static func gapText(_ snap: ExecutionViewModel.RunStateSnapshot?) -> String {
        guard let saved = snap?.savedAt else { return "时间" }
        let m = max(1, Int(Date.now.timeIntervalSince(saved) / 60))
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分钟" : "\(m) 分钟"
    }

    // MARK: 今日最要紧（★兑现红利）——做成打 🎯，没做成不罚（只是不亮），至多软限 ≤2 件
    @ViewBuilder private var mitStrip: some View {
        if !model.importantItems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.importantItems) { item in
                    if model.isImportantDone(item) {
                        // 体检 #13：与 ReviewView 同语义句同款（target Symbol，条文9 emoji 构件退场）
                        Label("想尽早的「\(item.title)」做成了", systemImage: "target")
                            .font(.caption.weight(.medium)).foregroundStyle(theme.positiveTint)
                    } else {
                        // 换装 B 微决策：尽早=accent（同行内 tag，让出与预览橙的相撞）
                        Label("尽早：\(item.title)", systemImage: "arrow.up.circle.fill")
                            .font(.caption).foregroundStyle(theme.accent)
                    }
                }
            }
        }
    }

    // MARK: 计划外「+ 新事项…」（0.25，点子 #1 过审）——临时冒出的事当场开始，算 bonus 不写计划

    @ViewBuilder private var adHocInput: some View {
        if let kind = adHocKind {
            VStack(alignment: .leading, spacing: 6) {
                Text(kind == .parallel ? "同时做一件新事（后台并行）" : "开始一件新事")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("要做的事…", text: $adHocTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($adHocFocused)
                    .onSubmit { commitAdHoc(kind) }   // 回车即开始（两步走完，低地板）
                HStack(spacing: 8) {
                    if kind == .foreground {
                        Menu("计时：\(Self.styleLabel(adHocStyle))") {   // 可选步（高天花板）
                            Button("轻计时") { adHocStyle = .light }
                            Button("不计时") { adHocStyle = TimingStyle.none }
                            Button("番茄钟") { adHocStyle = .pomodoro }
                        }
                        .font(.caption).fixedSize()
                    }
                    Spacer()
                    Button("取消") { resetAdHoc() }.font(.caption).buttonStyle(.plain)
                    Button(kind == .parallel ? "同时开始" : "开始新事项") { commitAdHoc(kind) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(adHocTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(8)
            .background(theme.actualTint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))   // 新事→记入蓝色实际
        }
    }

    private func openAdHoc(_ kind: AdHocKind) {
        adHocKind = kind; adHocTitle = ""; adHocStyle = .light
        setPopoverHold(true)   // 输入期间挂起弹窗自动关闭（中文空格选字不误关）
        DispatchQueue.main.async { adHocFocused = true }
    }

    /// macOS：新事项输入中 → menu bar 弹窗不自动关（transient 会被输入法候选窗抢焦点误关）。
    private func setPopoverHold(_ hold: Bool) {
        #if os(macOS)
        MenuBarPopoverHold.isHeld = hold
        #endif
    }

    private func commitAdHoc(_ kind: AdHocKind) {
        let t = adHocTitle
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        switch kind {
        case .foreground: Task { await model.startAdHoc(title: t, timingStyle: adHocStyle) }
        case .parallel: model.startAlsoAdHoc(title: t)
        }
        resetAdHoc()
    }

    private func resetAdHoc() { adHocKind = nil; adHocTitle = ""; adHocStyle = .light; setPopoverHold(false) }

    static func styleLabel(_ s: TimingStyle) -> String {
        switch s { case .pomodoro: "番茄"; case .light: "轻计时"; case .none: "不计时" }
    }

    // MARK: 头部状态

    @ViewBuilder private var header: some View {
        if model.isOnBreak {
            Label("休息中", systemImage: "cup.and.saucer")
                .font(.headline).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Label(Self.hms(model.breakElapsed), systemImage: "timer")
                    .font(.callout.monospacedDigit()).fontDesign(.rounded).foregroundStyle(.secondary)
            }
            if let a = model.active {
                Text("回来继续：\(a.title)").font(.caption).foregroundStyle(.secondary)
            }
        } else if let a = model.active {
            Text("正在做").font(.caption).foregroundStyle(.secondary)
            // 事件名即按钮（0.21，Jason 设计）：点开=剩余事项一步切换 + 已完成再来一段——收编「换一件」入口
            Menu {
                if !model.remaining.isEmpty {
                    Section("换一件（这件的投入会保留）") {
                        ForEach(model.remaining) { item in
                            Button(item.title) { Task { await model.startBlock(item) } }
                        }
                    }
                }
                let redoable = model.planned.filter { model.isDone($0) && $0.id != a.plannedID }
                if !redoable.isEmpty {
                    Section("已完成 · 再来一段") {
                        ForEach(redoable) { item in
                            Button("✓ \(item.title)") { Task { await model.startBlock(item) } }
                        }
                    }
                }
                Divider()
                Button { openAdHoc(.foreground) } label: { Label("新事项…", systemImage: "plus") }
            } label: {
                HStack(spacing: 4) {
                    Text(a.title).font(.headline)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("点击切换到别的事（当前投入自动保留）；已完成的可再来一段（复盘里合并计时）")
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                // 换装批次A：计时数字=Rounded（条文 8，Jason 裁 b 案；tabular 各点位 monospacedDigit 恒开）
                activeTiming.fontDesign(.rounded)
            }
        } else if let s = model.selected {
            Text("待开始").font(.caption).foregroundStyle(.secondary)
            Text(s.title).font(.headline)
        } else {
            Text("空档").font(.headline).foregroundStyle(.secondary)
            if let next = model.nextSuggested {
                Text("下一件：\(next.title)").font(.caption).foregroundStyle(.secondary)
            } else if model.loaded {
                // 体检 #14：四页唯一无前向指引的空态 → 补「现状+下一步」句式；#15：文案 emoji 按 0.60 先例清理
                Text(model.planned.isEmpty ? "今天还没排计划——跟智能体说一句就能排" : "今天的计划都做完了")
                    .font(.caption).foregroundStyle(.secondary)
                // 收口轻入口（0.28 → 批次7 跨端化）：做完即回看=最顺的时机；信号与收口卡同源（全完成）
                if !model.planned.isEmpty, let onOpenJournal {
                    Button("回看今天 →") { onOpenJournal() }
                        .font(.caption).buttonStyle(.plain).underline().foregroundStyle(theme.accent)   // 收尾入口=情感时刻族
                }
            }
        }
    }

    // 番茄钟显段(专注/休息+段内进度/段满确认)、轻计时显已用、不计时不显
    @ViewBuilder private var activeTiming: some View {
        if let phase = model.pomodoroPhase {
            let isWork = phase.kind == .work
            if phase.pendingConfirm {
                VStack(alignment: .leading, spacing: 4) {
                    if isWork {
                        // 工作段满：两选（顶替原「开始休息」）——继续=转不计时逃生舱、再来一段=休息+专注循环
                        Text("专注完成").font(.callout).foregroundStyle(theme.actualTint)   // 体检 #15：emoji 清理（庆祝感由段间卡与星光承载）
                        HStack(spacing: 8) {
                            Button("继续计时") { model.continueUntimed() }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("不休息、接着做——转成往上记的计时（从已专注时长起），从此不再打断")
                            Button("再来一段") { model.confirmPomodoroNext() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .help("先休息一小段，再来一段专注")
                        }
                    } else {
                        // 休息段满：回到专注 / 转轻计时（段间=可改计时方式的窗口，工作段中锁定——Jason 定 2026-07-08）
                        Text("休息好了，回到专注？").font(.callout).foregroundStyle(theme.positiveTint)   // 休息绿归队（D，Jason 裁）
                        HStack(spacing: 8) {
                            Button("回到专注") { model.confirmPomodoroNext() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Button("继续计时") { model.continueUntimed() }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("不再来一段——转成往上记的计时（净专注续走）")
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Label("\(isWork ? "专注" : "番茄休息") \(Self.hms(phase.elapsedInPhase)) / \(Self.hms(phase.phaseLength))",
                          systemImage: isWork ? "timer" : "cup.and.saucer")
                        .font(.callout.monospacedDigit())
                        // 换装 B/D：专注=实际蓝族（执行→回填实际）；休息=positiveTint 归队（Jason 裁）
                        .foregroundStyle(isWork ? theme.actualTint : theme.positiveTint)
                    if isWork {
                        // 工作段中逃生口：小摩擦确认 + 自设周上限（预先承诺，默认不限；用完=温和禁用）
                        let remaining = PomodoroDiscipline.remaining()
                        if remaining == 0 {
                            Text("本周自设的提前休息次数已用完")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("这是你在 设置→进阶 给自己设的约束，随时可调")
                        } else {
                            Button(remaining.map { "提前休息（本周还可 \($0) 次）" } ?? "提前休息") {
                                earlyBreakConfirming = true
                            }
                            .font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary).underline()
                            .help("不必等满，现在就去休息")
                            .confirmationDialog(
                                "这段还剩 \(Self.hms(phase.remaining))，现在就休息？",
                                isPresented: $earlyBreakConfirming, titleVisibility: .visible
                            ) {
                                Button(remaining.map { "休息（之后本周还可 \($0 - 1) 次）" } ?? "休息") {
                                    PomodoroDiscipline.consume()
                                    model.confirmPomodoroNext()
                                }
                                Button("继续专注", role: .cancel) {}
                            }
                        }
                    } else {
                        Button("提前结束") { model.confirmPomodoroNext() }
                            .font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary).underline()
                            .help("不必等满，现在就回到专注")
                        Button("继续计时") { model.continueUntimed() }
                            .font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary).underline()
                            .help("休息段中改主意——转成往上记的计时（净专注续走）")
                    }
                }
            }
        } else {
            // 轻计时=已 X · 计划 Y（超计划撤计划）；不计时=已 X。到分 XhYm、中性色（2026-07-09 敲定）。
            Label(model.timerDisplay, systemImage: "timer")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: 动作区

    @ViewBuilder private func actions(compact: Bool) -> some View {
        if model.isOnBreak {
            Button { Task { await model.toggleBreak() } } label: {
                Label("结束休息，回来", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else if model.active != nil {
            // 批次6（Jason 反馈：语义重复）：标题只住 header 事件名（那也是换一件入口），按钮回归通用词
            //（帧2 线框原案即「完成这件」）
            // 体检 #7（U1）：番茄段间确认态时，段间卡的「再来一段/回到专注」才是当刻主键——
            // 「完成这件」降为 bordered，六态「互斥各持一颗 prominent」在渲染层真实成立
            if model.pomodoroPhase?.pendingConfirm == true {
                Button { Task { await model.completeCurrent() } } label: {
                    Label("完成这件", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.primary)
            } else {
                Button { Task { await model.completeCurrent() } } label: {
                    Label("完成这件", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            // 「换一件」退役（0.21）：事件名按钮已收编；空位给「计时」切换菜单
            // compact：次要排收进边缘 ⋯（S3-P1），主按钮独占
            if !compact { HStack { timingMenu; alsoMenu; breakButton }.tint(.primary) }   // 体检 #6：次要排收中性
            // 分心自动休息的撤销口（#26 红线④）：感知误判（其实在查资料）→ 一键把那段算回投入。
            // 只在自动休息刚结束的 10 分钟内出现；判定权在用户——安全阀，compact 也保留。
            if model.canUndoAutoBreak {
                Button { model.undoLastAutoBreak() } label: {
                    Label("刚才不算休息（算回投入）", systemImage: "arrow.uturn.backward")
                }
                .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).underline()
            }
        } else if model.selected != nil {
            // 标题展示归 header「待开始」区（语义去重，批次6）
            Button { Task { await model.startSelected() } } label: {
                Label("开始这件", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if !compact { HStack { switchMenu; alsoMenu; breakButton }.tint(.primary) }   // 体检 #6
        } else {
            if let next = model.nextSuggested {
                // 标题展示归 header「下一件：X」（语义去重，批次6）
                Button { Task { await model.startBlock(next) } } label: {
                    Label("开始下一件", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            if !compact { HStack { switchMenu; alsoMenu; breakButton }.tint(.primary) }   // 体检 #6
        }
    }

    /// 实时改当前块计时方式（0.21）：番茄工作段中锁定（预先承诺）、段满/休息中开放；
    /// 转番茄可选段数（做满自动转轻计时续走）；只改运行态，块存的风格不动。
    /// 菜单内容抽出（S3-P1）：常规排与 compact ⋯ 溢出共用同一份内容，不复制逻辑。
    @ViewBuilder private var timingMenuItems: some View {
        Button("轻计时") { model.changeTiming(to: .light) }
        Button("不计时") { model.changeTiming(to: TimingStyle.none) }
        Menu("番茄钟") {
            Button("1 段") { model.changeTiming(to: .pomodoro, pomodoroSegments: 1) }
            Button("2 段") { model.changeTiming(to: .pomodoro, pomodoroSegments: 2) }
            Button("3 段") { model.changeTiming(to: .pomodoro, pomodoroSegments: 3) }
            Button("不限段") { model.changeTiming(to: .pomodoro, pomodoroSegments: nil) }
        }
    }

    private var timingMenu: some View {
        Menu {
            timingMenuItems
        } label: {
            // 直接显示当前计时状态（轻计时/不计时/🍅番茄），不再是通用「计时」——Jason 2026-07-09
            Label(Self.styleLabel(model.activeStyle ?? .light), systemImage: "stopwatch")
        }
        .menuStyle(.borderlessButton)
        .disabled(!model.canChangeTimingNow)
        .help(model.canChangeTimingNow
              ? "改当前这件的计时方式（转番茄可选做几段，做满自动转轻计时）"
              : "番茄工作段进行中锁定——段满或休息时可改（你选的约束）")
    }

    /// 已完成的事（可再来一段）——0.25.2 补：换一件/同时做 菜单曾漏了它，空档时完成的事就没法继续做。
    private var redoable: [ExecutionViewModel.PlannedItem] {
        model.planned.filter { model.isDone($0) && $0.id != model.active?.plannedID }
    }

    @ViewBuilder private var switchMenuItems: some View {
        if model.remaining.isEmpty {
            Text("没有其它待做的事")
        } else {
            ForEach(model.remaining) { item in
                Button(item.title) { Task { await model.switchTo(item) } }
            }
        }
        if !redoable.isEmpty {
            Section("已完成 · 再来一段") {
                ForEach(redoable) { item in
                    Button("✓ \(item.title)") { Task { await model.startBlock(item) } }
                }
            }
        }
        Divider()
        Button { openAdHoc(.foreground) } label: { Label("新事项…", systemImage: "plus") }
    }

    private var switchMenu: some View {
        Menu {
            switchMenuItems
        } label: {
            Label("换一件", systemImage: "arrow.triangle.swap")
        }
        .menuStyle(.borderlessButton)
        // 0.25：即使没有待做的事也不禁用——「+ 新事项…」是空档时临时起意的入口
    }

    @ViewBuilder private var alsoMenuItems: some View {
        if model.remaining.isEmpty {
            Text("没有其它待做的事")
        } else {
            ForEach(model.remaining) { item in
                Button(item.title) { model.startAlso(item) }
            }
        }
        if !redoable.isEmpty {
            Section("已完成 · 再来一段") {
                ForEach(redoable) { item in
                    Button("✓ \(item.title)") { model.startAlso(item) }
                }
            }
        }
        Divider()
        Button { openAdHoc(.parallel) } label: { Label("新事项…", systemImage: "plus") }
    }

    /// 同时做另一件（后台并行，不打断前台计时）。
    private var alsoMenu: some View {
        Menu {
            alsoMenuItems
        } label: {
            Label("同时做", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
    }

    private var breakButton: some View {
        Button { Task { await model.toggleBreak() } } label: {
            Label("开始休息", systemImage: "cup.and.saucer")
        }
    }

    // MARK: 专注引导（macOS 无屏蔽 API 的降级：番茄钟时温和提示可开系统专注模式，不强推）

    @ViewBuilder private var focusHint: some View {
        #if os(macOS)
        if model.activeStyle == .pomodoro, !model.isOnBreak {
            HStack(spacing: 6) {
                Image(systemName: "moon.circle").font(.caption).foregroundStyle(theme.looseTint)   // 夜/月族归位（C）
                Text("想更沉浸？可顺手开系统专注模式").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("打开设置") {
                    // 专注模式无公开 API 可编程开启 → 引导到系统设置的专注面板
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption2).controlSize(.mini)
            }
        }
        #endif
    }

    // MARK: 后台并行区（同时进行的其它事，各自按墙钟计时；点 ✓ 完成即记蓝色实际）

    @ViewBuilder private var backgroundSection: some View {
        if !model.background.isEmpty {
            Divider()
            Text("同时进行（后台）").font(.caption).foregroundStyle(.secondary)
            ForEach(model.background) { run in
                HStack(spacing: 8) {
                    Image(systemName: "circle.dotted").foregroundStyle(theme.looseTint).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.title).font(.caption).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Self.hms(model.backgroundElapsed(run)))
                                .font(.caption2.monospacedDigit()).fontDesign(.rounded).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { Task { await model.completeBackground(run.id) } } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.positiveTint)
                    .help("完成这件后台任务")
                    .accessibilityLabel("完成「\(run.title)」")
                }
            }
        }
    }

    // MARK: 紧凑层（展开层子集，S2 帧5 / S3-P1）——边缘行 + ⋯ 溢出 + chevron 展开

    private var compactEdgeRow: some View {
        HStack(spacing: 6) {
            Text("今日：完成 \(model.doneCount)").font(.caption).foregroundStyle(.secondary)
            if model.active != nil, let up = model.remaining.first {
                Text("· 接下来 \(up.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            compactOverflow
        }
    }

    /// compact 的 ⋯：常规排的三菜单内容原样复用（不复制逻辑）+ macOS 专属（回看今天/退出——S3 批次1 遗留的收纳）。
    private var compactOverflow: some View {
        Menu {
            if model.active != nil {
                Menu {
                    timingMenuItems
                } label: {
                    Label(Self.styleLabel(model.activeStyle ?? .light), systemImage: "stopwatch")
                }
                .disabled(!model.canChangeTimingNow)
            } else {
                Menu {
                    switchMenuItems
                } label: {
                    Label("换一件", systemImage: "arrow.triangle.swap")
                }
            }
            Menu {
                alsoMenuItems
            } label: {
                Label("同时做", systemImage: "plus.circle")
            }
            breakButton
            if let onOpenJournal {
                Divider()
                Button("回看今天") { onOpenJournal() }
            }
            #if os(macOS)
            Button { AppLifecycle.shared?.reallyQuit() } label: { Label("退出", systemImage: "power") }
            #endif
        } label: {
            Label("更多", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("计时 · 换一件 · 同时做 · 休息 · 更多")
    }

    private var expandToggle: some View {
        Button { withAnimation(Motion.emphasis) { panelExpanded.toggle() } } label: {   // 动效令牌（条文10）
            HStack {
                Spacer()
                Label(panelExpanded ? "收起为精简面板" : "展开完整面板",
                      systemImage: panelExpanded ? "chevron.up" : "chevron.down")
                    .labelStyle(.iconOnly).font(.caption)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help(panelExpanded ? "收起为精简面板" : "展开完整面板（记住这个选择）")
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("今日：完成 \(model.doneCount)"
                     + (model.background.isEmpty ? "" : " · 同时 \(model.background.count)"))
                    .font(.caption).foregroundStyle(.secondary)
                // 版本标签（2026-07-09 Jason）：仅内测/Debug 显示，发行版不打扰
                if BuildInfo.isPreRelease {
                    Text(BuildInfo.tag).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            #if os(macOS)
            // 走 reallyQuit：菜单栏面板里明确的「退出」，即使开了「保留在菜单栏」也应真退（否则被 applicationShouldTerminate 拦成隐藏）
            Button { AppLifecycle.shared?.reallyQuit() } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            .help("退出 BetterCalendar")
            #endif
        }
    }

    // 时:分:秒 / 分:秒
    static func hms(_ ti: TimeInterval) -> String {
        let total = Int(ti)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}
