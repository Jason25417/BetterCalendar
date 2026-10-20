import SwiftUI

struct BridgeTaskPanel: View {
    @Bindable var model: BridgeTaskViewModel
    var planned: [ExecutionViewModel.PlannedItem] = []
    @State private var title = ""
    @State private var mode = BridgeTaskSession.Mode.light
    @State private var focusMinutes = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("正在做什么").font(.headline)
                Spacer()
                Button("刷新") { Task { await model.refresh() } }.disabled(model.busy)
            }
            Text(model.backend == .icloud ? "两端共用 iCloud 计时；结束计时不代表事项完成。" : "与 Dots 共用 BC 计时；结束计时不代表事项完成。")
                .font(.caption).foregroundStyle(.secondary)
            if model.sessions.isEmpty {
                // W31b：读失败了就别再说「等待」——原因在下面橙字里
                Text(!model.isStale ? "目前没有正在计时的事项" : model.lastError == nil ? "等待读取计时状态" : "还没读到计时状态")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.sessions) { session in
                VStack(alignment: .leading, spacing: 6) {
                    Text((session.isExperiment ? "测试 · " : "") + session.title).font(.body.weight(.medium))
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let phase = session.presentation(elapsed: model.elapsed(session, at: timeline.date))
                        Text("\(session.status == .paused ? "已暂停 · " : "")\(phase.label) · \(ExecutionPanel.hms(phase.displaySeconds))")
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
            if model.isStale { Text(model.hasEverRead ? "尚未取得最新状态；以上只是最后一次同步的记录。" : "本机还没从云端读到过计时状态。")
                    .font(.caption).foregroundStyle(.orange) }
            if model.hasMore { Text("这里只展示前 100 项；其余计时记录仍保留。")
                    .font(.caption).foregroundStyle(.secondary) }
            Divider()
            Picker("计时方式", selection: $mode) {
                Text("轻计时").tag(BridgeTaskSession.Mode.light)
                Text("番茄钟").tag(BridgeTaskSession.Mode.pomodoro)
            }.pickerStyle(.segmented)
            if mode == .pomodoro {
                Stepper("专注 \(focusMinutes) 分钟", value: $focusMinutes, in: 1...240)
                Text("到时静默转为正计时，保留已工作时长；不自动结束或休息。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("开始什么事项", text: $title)
                .onSubmit { startNew() }
            HStack {
                Button("开始计时") { startNew() }
                    .disabled(!model.canSubmit || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !planned.isEmpty {
                    Menu("从今天安排里选") {
                        ForEach(planned) { item in
                            Button(item.title) {
                                Task { await model.start(title: item.title, relatedRecordId: "PlanBlock:" + item.id.uuidString, mode: item.timingStyle == .pomodoro ? .pomodoro : .light, focusMinutes: item.timingStyle == .pomodoro ? Int(PomodoroTimer.work / 60) : nil) }
                            }
                        }
                    }.disabled(!model.canSubmit)
                }
            }
            Text(model.message).font(.caption).foregroundStyle(model.lastError == nil ? Color.secondary : Color.orange)
            if model.reviewCount > 0 { Text("\(model.reviewCount) 条冲突或未接受的请求已保留；不会自动覆盖新状态。")
                    .font(.caption).foregroundStyle(.orange) }
            // W31b：开发期通道开关默认收起（原来常驻在今天页顶部，iPhone 上把时间轴挤得只剩两三百 pt）；设置里「共享计时（开发期）」仍完整
            if let control = SharedTimerBackendControl.current {
                DisclosureGroup { SharedTimerBackendPanel(control: control) } label: {
                    Text("计时通道（开发期）").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.refresh() }
    }
    private func startNew() {
        let submitted = title
        guard model.canSubmit else { return }
        guard model.queueStart(title: submitted, mode: mode, focusMinutes: mode == .pomodoro ? focusMinutes : nil) else { return }
        title = ""
        Task { await model.refresh() }
    }
}
