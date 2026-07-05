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
    #if !os(macOS)
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
            reschedule: container.reschedule,
            notifier: container.notifier,
            longTaskStore: container.longTasks,
            draftStore: container.draftSnapshots))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $navPath) {
            ScrollView {   // 页面过长可整页滚动（0.16.3）
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("说说你的一天").font(.headline)
                    Spacer()
                    targetDayMenu
                }

                // 可滚动多行输入 + 底部把手拖拽调高（写长了也能看全，0.16.3）
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.inputText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                    if model.inputText.isEmpty {
                        Text("例：明早9点写代码两小时，11点开会，下午健身")
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
                    Button { Task { await model.startToday() } } label: {
                        Label("开始今天", systemImage: "sunrise")
                    }
                    .disabled(model.isWorking)
                    .help("开工晚了？按现在的时间把今天重排，固定块不动")
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                }

                if let note = model.note {
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

                if !model.blocks.isEmpty {
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
                        Button { model.addBlock() } label: { Label("加一项", systemImage: "plus") }
                            .font(.caption)
                    }

                    List {
                        ForEach(model.blocks) { item in
                            EditableRow(block: model.binding(for: item.id),
                                        poolTasks: container.longTasks.items,
                                        onDelete: { model.delete(id: item.id) })
                        }
                        .onMove { model.move($0, $1) }
                    }
                    .frame(height: max(140, min(CGFloat(model.blocks.count) * 84 + 16, 440)))

                    HStack {
                        TextField("想微调？告诉 AI，如：把健身挪到上午10点、写代码改成3小时",
                                  text: $model.refineText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await model.refine() } }
                        Button { Task { await model.refine() } } label: {
                            Label("AI 调整", systemImage: "sparkles")
                        }
                        .disabled(model.isWorking)
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
                    #if !os(macOS)
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
                                        onDelete: { model.delete(id: item.id) })
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
                case .startToday: Task { await model.startToday() }
                case .review: navPath = [.review]
                }
                container.router.scheduleRequest = nil   // 消费掉
            }
            .onAppear { model.autoLoadOnAppear() }   // 进页自动加载目标日已确认计划（不覆盖未确认草稿）
            .onChange(of: model.inputText) { _, _ in model.persistDraft() }   // 输入框逐字落盘（崩溃可还原）
            .onChange(of: model.targetDay) { _, newDay in
                if model.hasUnsavedChanges {
                    model.shiftDraftsToDay(newDay)   // 未保存的修改跟人走：平移到新日、不丢
                } else {
                    model.loadConfirmedPlan()        // 已保存视图：切目标日 = 加载那天的计划
                }
            }
            .confirmationDialog(
                "「\(model.reflowConflict?.blockTitle ?? "")」今天排不下了，怎么办？",
                isPresented: Binding(get: { model.reflowConflict != nil },
                                     set: { if !$0 { model.reflowConflict = nil } }),
                presenting: model.reflowConflict
            ) { conflict in
                Button("压缩，全塞进今天") { Task { await model.resolveConflict(.compress) } }
                Button("跳过「\(conflict.blockTitle)」") {
                    Task { await model.resolveConflict(.skip(conflict.blockTitle)) }
                }
                Button("拆成两段塞空隙") { Task { await model.resolveConflict(.split(conflict.blockTitle)) } }
                Button("就这样吧", role: .cancel) { model.reflowConflict = nil }
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
                Button("今天排上") { model.addBlockFromLongTask(task.title, linkedTaskID: task.id) }
                    .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                Button("推一周") { container.longTasks.pushDeadline(task) }
                    .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                Button("先放下") { container.longTasks.shelve(task) }
                    .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
            } else {
                Menu {
                    Button("排进今天") { model.addBlockFromLongTask(task.title, linkedTaskID: task.id) }
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

    // 目标日期标签：默认无感（晚上→明天/白天→今天），点开可改
    private var targetDayMenu: some View {
        Menu {
            Button("今天") { model.targetDay = DayContext.calendarDay(offset: 0) }
            Button("明天") { model.targetDay = DayContext.calendarDay(offset: 1) }
            Button("后天") { model.targetDay = DayContext.calendarDay(offset: 2) }
            Divider()
            Button("昨天（不建议）") { model.targetDay = DayContext.calendarDay(offset: -1) }
        } label: {
            Label("为 \(Self.dayLabel(model.targetDay)) 安排", systemImage: "calendar")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    static func dayLabel(_ d: Date) -> String {
        d.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated))
    }

    /// 目标日的口语词（按钮文案随所选日变）：今天/明天/后天/昨天，再远显日期。
    static func relativeDayWord(_ d: Date, from now: Date = .now) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
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
    var onDelete: () -> Void

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

            // 归属：这件属于哪个未来任务——投入会精确记到它名下（自动匹配，可手动改/清）
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
                            Text(linkedTitle).font(.caption2).foregroundStyle(.purple).lineLimit(1)
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("这件属于哪个未来任务——投入会精确记到它名下")
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("标题", text: $block.title)
                HStack(spacing: 6) {
                    DatePicker("", selection: $block.start, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("", selection: $block.end, displayedComponents: .hourAndMinute)
                        .labelsHidden()
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
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    static func styleLabel(_ s: TimingStyle) -> String {
        switch s {
        case .light: return "轻计时"
        case .pomodoro: return "🍅 番茄"
        case .none: return "不计时"
        }
    }
}
