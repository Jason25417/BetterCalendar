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

enum HomeRoute: Hashable { case review, preview }

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

struct HomeView: View {
    let container: AppContainer
    @State private var model: HomeViewModel
    @State private var navPath: [HomeRoute] = []   // 程序化导航（通知 deep-link → 复盘）
    @State private var l3Tick = 0                  // 「别再提」后强制重算 L3 建议
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

    init(container: AppContainer) {
        self.container = container
        _model = State(initialValue: HomeViewModel(
            arrangeDay: container.arrangeDay,
            refiner: container.refiner,
            calendarStore: container.routingStore,
            reminderStore: container.routingReminder,
            exporter: container.exporter,
            planStore: container.planStore,
            projection: container.projection,
            notifier: container.notifier,
            longTaskStore: container.longTasks,
            draftStore: container.draftSnapshots,
            looseDays: container.looseDays,
            startedDays: container.startedDays,
            progress: container.execution))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $navPath) {
            ScrollView {   // 页面过长可整页滚动（0.16.3）
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("说说你的一天").font(.headline)
                    Spacer()
                    let loose = container.looseDays.isLoose(model.targetDay)
                    Button { model.toggleLoose() } label: {
                        Label(loose ? "结束松散" : "松散一下",
                              systemImage: loose ? "moon.zzz.fill" : "moon.zzz")
                    }
                    .font(.caption).buttonStyle(.borderless)
                    .foregroundStyle(loose ? .purple : .secondary)
                    .help("把这天标为松散：App 退场陪你——不催、不算落后。随时可结束；短时间的小憩直接留白即可，不必标松散")
                    targetDayMenu
                }

                // 松散日：退场 + 见证的姿态横幅（不删任何计划、可撕；深层姿态效果后续接）
                if container.looseDays.isLoose(model.targetDay) {
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
                let l3 = container.longTasks.l3Suggestions(
                    loose: container.looseDays.isLoose(model.targetDay),
                    intensity: SuggestionSettings.intensity.cap,
                    muted: SuggestionSettings.mutedTaskIDs)
                ForEach(l3) { s in
                    HStack(spacing: 8) {
                        Image(systemName: "lightbulb").font(.caption).foregroundStyle(.orange)
                        Text(s.text).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if s.kind == .shelve {
                            Button("先放下") {
                                if let t = container.longTasks.items.first(where: { $0.id == s.id }) {
                                    container.longTasks.shelve(t)
                                }
                            }.font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                        } else {
                            Button("排进今天") {
                                if let t = container.longTasks.items.first(where: { $0.id == s.id }) {
                                    model.smartInsertFromLongTask(t)
                                }
                            }.font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                        }
                        Button { SuggestionSettings.mute(s.id); l3Tick += 1 } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("别再提这件")
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // 可滚动多行输入 + 底部把手拖拽调高（写长了也能看全，0.16.3）
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.inputText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                    if model.inputText.isEmpty {
                        // 预设文本三阶段（0.20.3）：教程示例 → 排满 10 次自动毕业 → 小提示/轻问候（设置可调回）
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

                HStack {
                    Button { Task { await model.arrange() } } label: {
                        Label("排\(Self.relativeDayWord(model.targetDay))", systemImage: "wand.and.stars")
                    }
                    .disabled(model.isWorking)
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                        Text("模型思考中…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // 端侧流式：解析中的部分块边生成边显示（FM streamResponse）
                if model.isWorking, !container.liveDraft.streaming.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(container.liveDraft.streaming) { b in
                            HStack(spacing: 6) {
                                Text(b.start.formatted(date: .omitted, time: .shortened))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(b.title).font(.caption)
                            }
                        }
                    }
                    .padding(.leading, 2)
                }

                // 防呆：模型偶尔把 note 抽风成「1」这种垃圾 → trim 后太短就不显
                if let note = model.note,
                   note.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 {
                    Text(note).font(.callout).foregroundStyle(.secondary)
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

                ongoingSection

                // 复盘常驻入口：随时决定"这一天到此为止"、看看做成了什么（不只藏在工具栏图标里）
                NavigationLink(value: HomeRoute.review) {
                    Label("今日复盘 · 看看做成了什么", systemImage: "checkmark.seal")
                        .font(.callout).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

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

                // 新鲜度徽标（0.24 C2）：中性、不打断——底层变了，两个显式出路，绝不弹窗/自动合并
                if model.freshness {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("这天的日程有更新")
                        Button("载入最新（放弃本页修改）") { model.reloadFreshBase() }
                            .buttonStyle(.plain).underline()
                        Text("· 或继续编辑，确认时以本页为准").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.caption)
                    .padding(6)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
                        Button { model.addBlock() } label: { Label("加一项", systemImage: "plus") }
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
                                            poolTasks: container.longTasks.items,
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

                    // 要紧事软限（≤2）：只温和提示、不硬挡——稀缺才是意义，什么都要紧=什么都不要紧
                    let mitCount = model.blocks.filter { $0.priority == .important }.count
                    if mitCount > 2 {
                        Label("要紧事贵在少（已标 \(mitCount) 件）——越多越稀释，真正最要紧的留 1–2 件就好",
                              systemImage: "sparkles")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    if !model.blocks.isEmpty {
                        HStack(alignment: .bottom) {
                            // 多行输入（2026-07-07 Jason 报：只显 1 行还不能滚）——长指令自动长高到 4 行
                            TextField("想微调？告诉 AI，如：把健身挪到上午10点、写代码改成3小时",
                                      text: $model.refineText, axis: .vertical)
                                .lineLimit(1...4)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await model.refine() } }
                            Button { Task { await model.refine() } } label: {
                                Label("AI 调整", systemImage: "sparkles")
                            }
                            .disabled(model.isWorking)
                        }
                    }

                    HStack {
                        Button { Task { await model.confirm() } } label: {
                            Label(calendarBackendRaw == "eventKit"
                                  ? "确认写入真日历(Dev)" : "确认写入（假）日历",
                                  systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking || !model.hasUnsavedChanges)
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
                        if let c = model.committedCount {
                            Text(model.committedToReal
                                 ? "已写入真日历(Dev) \(c) 项 → 打开 Apple 日历查看"
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
                    NavigationLink(value: HomeRoute.review) { Label("今日复盘", systemImage: "checkmark.seal") }
                    NavigationLink(value: HomeRoute.preview) { Label("预览", systemImage: "calendar") }
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
                                        poolTasks: container.longTasks.items,
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
                case .review: ReviewView(container: container)
                case .preview: CalendarPreviewView(store: container.calendarStore,
                                                   reminderStore: container.reminderStore)
                }
            }
            .onChange(of: container.router.scheduleRequest) { _, req in
                guard let req else { return }
                switch req {
                case .arrangeToday(let text):
                    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.inputText = text
                        Task { await model.arrange() }
                    }
                case .review: navPath = [.review]
                }
                container.router.scheduleRequest = nil   // 消费掉
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
            // 0.20 双向同步：日历里的 删除/新建 → 一个中性对话框合并询问（挂起到主窗口，不发通知）。
            // 关闭 = 本次保留现状、不记住。具体是哪几件列在正文里。
            .confirmationDialog(
                "日历里有改动，要同步吗？",
                isPresented: Binding(get: { container.reconcile.hasPendingChanges },
                                     set: { if !$0 { container.reconcile.resolveChanges(sync: false, remember: false) } }),
                titleVisibility: .visible
            ) {
                Button("同步（照日历的改）", role: .destructive) {
                    container.reconcile.resolveChanges(sync: true, remember: false)
                }
                Button("同步，并记住（以后都这样）", role: .destructive) {
                    container.reconcile.resolveChanges(sync: true, remember: true)
                }
                Button("保留现状（不同步）") {
                    container.reconcile.resolveChanges(sync: false, remember: false)
                }
                Button("保留，并记住（以后都保留）") {
                    container.reconcile.resolveChanges(sync: false, remember: true)
                }
            } message: {
                let dels = container.reconcile.pendingDeletions.map(\.title).joined(separator: "、")
                let adds = container.reconcile.pendingAdditions.map(\.title).joined(separator: "、")
                Text((dels.isEmpty ? "" : "移除了：\(dels)\n")
                     + (adds.isEmpty ? "" : "新建了：\(adds)\n")
                     + "（可随时在 设置→进阶 里改处理策略）")
            }
            .onChange(of: model.inputText) { _, _ in model.persistDraft() }   // 输入框逐字落盘（崩溃可还原）
            // 0.23 C：切目标日 = 切草稿本（每天一页；"平移跟人走"已退役，挪日走显式「挪到…」菜单）
            .onChange(of: model.targetDay) { _, _ in
                model.targetDayDidChange()
            }
            .safeAreaInset(edge: .bottom) {
                NavigationLink {
                    ChangelogView()
                } label: {
                    Text("\(AppInfo.copyright) · v\(AppInfo.version)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 「在途」（M10）：跨日任务池——收起一行，点开轻抽屉；不做管理界面，只做决策现场的入口

    @State private var ongoingExpanded = false
    @State private var newOngoingTitle = ""

    @ViewBuilder private var ongoingSection: some View {
        let store = container.longTasks
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
                    if container.longTasks.looksComplete(for: task) {
                        Button("看起来做完了？") { container.longTasks.complete(task) }
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
                    let progress = container.longTasks.progressText(for: task)
                    if !progress.isEmpty {
                        Text(progress).font(.caption2).foregroundStyle(.green)
                    }
                }
                // 增长条（只在有总量时；绿色从零长起、无"还剩"）
                if let f = container.longTasks.progressFraction(for: task) {
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
                Button("推一周") { container.longTasks.pushDeadline(task) }
                    .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                Button("先放下") { container.longTasks.shelve(task) }
                    .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
            } else {
                Menu {
                    Button("帮我排进今天（智能插空档）") { model.smartInsertFromLongTask(task) }
                    Button("做成了 🎉") { container.longTasks.complete(task) }
                    Button("推一周") { container.longTasks.pushDeadline(task) }
                    Button("先放下") { container.longTasks.shelve(task) }
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
            Label("为 \(Self.relativeDayWord(model.targetDay)) 安排", systemImage: "calendar")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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

    var body: some View {
        HStack(spacing: 8) {
            Button {
                block.priority = (block.priority == .important) ? .normal : .important
            } label: {
                Image(systemName: block.priority == .important ? "star.fill" : "star")
                    .foregroundStyle(block.priority == .important ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help("标为今日要紧事")
            .disabled(block.isAnchor)   // 锚点不是任务，谈不上要紧

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
                    if let ddl = block.deadline {
                        Label(ddl.formatted(.dateTime.hour().minute()), systemImage: "flag.checkered")
                            .font(.caption2).foregroundStyle(.red)
                            .help("硬截止（DDL）：必须在此之前完成——会写进提醒事项、按它提前提醒")
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
                                    Text(linkedTitle).foregroundStyle(.purple).lineLimit(1)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
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
