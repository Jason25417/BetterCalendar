//
//  HomeView.swift
//  BetterCalendar
//
//  首页：说一天 → 排今天 → 可编辑草稿（拖/改/标/删加）→ 自然语言微调 → 确认写入（假）日历。
//

import SwiftUI

struct HomeView: View {
    let container: AppContainer
    @State private var model: HomeViewModel

    init(container: AppContainer) {
        self.container = container
        _model = State(initialValue: HomeViewModel(
            arrangeDay: container.arrangeDay,
            refiner: container.refiner,
            calendarStore: container.routingStore))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("说说你的一天").font(.headline)

                TextField("例：明早9点写代码两小时，11点开会，下午健身",
                          text: $model.inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                HStack {
                    Button { Task { await model.arrange() } } label: {
                        Label("排今天", systemImage: "wand.and.stars")
                    }
                    .disabled(model.isWorking)
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    NavigationLink {
                        CalendarPreviewView(store: container.calendarStore)
                    } label: { Label("预览日历", systemImage: "calendar") }
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
                            Label("确认写入（假）日历", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
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
