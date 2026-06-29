//
//  HomeView.swift
//  BetterCalendar
//
//  首页：说一天 → 排今天 →（假）日历预览。M0 用本地兜底实现，不接系统 API。
//

import SwiftUI

struct HomeView: View {
    let container: AppContainer
    @State private var model: HomeViewModel

    init(container: AppContainer) {
        self.container = container
        _model = State(initialValue: HomeViewModel(arrangeDay: container.arrangeDay))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("说说你的一天").font(.headline)

                TextField("例：明早9点写代码两小时，11点开会，下午健身",
                          text: $model.inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)

                HStack {
                    Button {
                        Task { await model.arrange() }
                    } label: {
                        Label("排今天", systemImage: "wand.and.stars")
                    }
                    .disabled(model.isWorking)

                    if model.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    NavigationLink {
                        CalendarPreviewView(store: container.calendarStore)
                    } label: {
                        Label("预览日历", systemImage: "calendar")
                    }
                }

                if let note = model.decision?.note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                if let err = model.errorText {
                    Text(err).font(.callout).foregroundStyle(.red)
                }

                // 开发期：把云端/系统调用的失败显出来（产品上架前切回静默）
                if let issue = DevLog.shared.lastIssue {
                    HStack(spacing: 6) {
                        Image(systemName: issue.level == .error
                              ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        Text("[\(issue.source)] \(issue.message)").font(.caption)
                        Spacer()
                        Button("清") { DevLog.shared.clear() }.font(.caption)
                    }
                    .padding(8)
                    .foregroundStyle(issue.level == .error ? .red : .orange)
                    .background((issue.level == .error ? Color.red : Color.orange).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                List(model.decision?.orderedBlocks ?? []) { block in
                    HStack(spacing: 8) {
                        if block.priority == .important {
                            Image(systemName: "star.fill").foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading) {
                            Text(block.title)
                            Text(timeRange(block.start, block.end))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("BetterCalendar")
            .toolbar {
                ToolbarItem {
                    NavigationLink { DevLogView() } label: {
                        Image(systemName: "ladybug")
                    }
                }
                ToolbarItem {
                    NavigationLink { ChangelogView() } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("\(AppInfo.copyright) · v\(AppInfo.version)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        }
    }

    private func timeRange(_ start: Date, _ end: Date) -> String {
        let s = start.formatted(date: .omitted, time: .shortened)
        let e = end.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(e)"
    }
}
