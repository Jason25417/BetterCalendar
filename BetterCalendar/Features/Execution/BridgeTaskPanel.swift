import SwiftUI

struct BridgeTaskPanel: View {
    @Bindable var model: BridgeTaskViewModel
    var planned: [ExecutionViewModel.PlannedItem] = []
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("正在做什么").font(.headline)
                Spacer()
                Button("刷新") { Task { await model.refresh() } }.disabled(model.busy)
            }
            Text("与 Dots 共用 BC 计时；结束计时不代表事项完成。")
                .font(.caption).foregroundStyle(.secondary)
            if model.sessions.isEmpty { Text(model.isStale ? "等待读取计时状态" : "目前没有正在计时的事项").foregroundStyle(.secondary) }
            ForEach(model.sessions) { session in
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.title).font(.body.weight(.medium))
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text("\(session.status == .paused ? "已暂停" : "已用") · \(ExecutionPanel.hms(model.elapsed(session, at: timeline.date)))")
                            .font(.callout.monospacedDigit())
                    }
                    HStack {
                        Button(session.status == .paused ? "继续" : "暂停") {
                            Task { await model.act(session.status == .paused ? .resume : .pause, on: session) }
                        }
                        Button("结束计时") { Task { await model.act(.finish, on: session) } }
                    }.disabled(!model.canSubmit)
                }.padding(.vertical, 4)
            }
            if model.isStale { Text("尚未取得最新状态；以上只是最后一次同步的记录。")
                    .font(.caption).foregroundStyle(.orange) }
            if model.hasMore { Text("这里只展示前 100 项；其余计时记录仍保留。")
                    .font(.caption).foregroundStyle(.secondary) }
            Divider()
            TextField("开始什么事项", text: $title)
                .onSubmit { startNew() }
            HStack {
                Button("开始计时") { startNew() }
                    .disabled(!model.canSubmit || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !planned.isEmpty {
                    Menu("从今天安排里选") {
                        ForEach(planned) { item in
                            Button(item.title) {
                                Task { await model.start(title: item.title, relatedRecordId: "PlanBlock:" + item.id.uuidString) }
                            }
                        }
                    }.disabled(!model.canSubmit)
                }
            }
            Text(model.message).font(.caption).foregroundStyle(model.lastError == nil ? Color.secondary : Color.orange)
            if model.reviewCount > 0 { Text("\(model.reviewCount) 条冲突或未接受的请求已保留；不会自动覆盖新状态。")
                    .font(.caption).foregroundStyle(.orange) }
        }
        .task { await model.refresh() }
    }
    private func startNew() {
        let submitted = title
        guard model.canSubmit else { return }
        guard model.queueStart(title: submitted) else { return }
        title = ""
        Task { await model.refresh() }
    }
}
