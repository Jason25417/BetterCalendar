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
    #endif
    // 实时跟随设置里的日历后端开关（按钮文字热切换）
    @AppStorage("calendar.backend") private var calendarBackendRaw: String = "fake"

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
            notifier: container.notifier))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $navPath) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("说说你的一天").font(.headline)
                    Spacer()
                    targetDayMenu
                }

                TextField("例：明早9点写代码两小时，11点开会，下午健身",
                          text: $model.inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                HStack {
                    Button { Task { await model.arrange() } } label: {
                        Label("排今天", systemImage: "wand.and.stars")
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
                if let err = model.errorText {
                    Text(err).font(.callout).foregroundStyle(.red)
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

                if !model.blocks.isEmpty {
                    Divider()
                    HStack {
                        Text("草稿 · 可拖动排序、直接编辑").font(.subheadline.bold())
                        Spacer()
                        Button { model.addBlock() } label: { Label("加一项", systemImage: "plus") }
                            .font(.caption)
                    }

                    List {
                        ForEach(model.blocks) { item in
                            EditableRow(block: model.binding(for: item.id),
                                        onDelete: { model.delete(id: item.id) })
                        }
                        .onMove { model.move($0, $1) }
                    }
                    .frame(minHeight: 200)

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
                        .disabled(model.isWorking)
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
                case .startToday: Task { await model.startToday() }
                case .review: navPath = [.review]
                }
                container.router.scheduleRequest = nil   // 消费掉
            }
            .onChange(of: model.targetDay) { _, newDay in
                model.shiftDraftsToDay(newDay)   // 改日期 → 草稿平移到新日，不丢
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
    var onDelete: () -> Void

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
