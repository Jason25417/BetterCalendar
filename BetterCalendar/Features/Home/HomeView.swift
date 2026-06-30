//
//  HomeView.swift
//  BetterCalendar
//
//  首页：说一天 → 排今天 → 可编辑草稿（拖/改/标/删加）→ 自然语言微调 → 确认写入（假）日历。
//

import SwiftUI
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

struct HomeView: View {
    let container: AppContainer
    @State private var model: HomeViewModel
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
        NavigationStack {
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
                    NavigationLink {
                        ReviewView(container: container)
                    } label: { Label("今日复盘", systemImage: "checkmark.seal") }
                    NavigationLink {
                        CalendarPreviewView(store: container.calendarStore,
                                            reminderStore: container.reminderStore)
                    } label: { Label("预览", systemImage: "calendar") }
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
                        Button { exportICS() } label: {
                            Label("导出 ICS", systemImage: "square.and.arrow.up")
                        }
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
            Button("今天") { model.targetDay = DayContext.logicalDay(offset: 0) }
            Button("明天") { model.targetDay = DayContext.logicalDay(offset: 1) }
            Button("后天") { model.targetDay = DayContext.logicalDay(offset: 2) }
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

    private func exportICS() {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "BetterCalendar计划.ics"
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            try? model.currentICS().write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }
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
}
