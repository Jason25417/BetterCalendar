import SwiftUI

struct BridgeTaskPanel: View {
    @Bindable var model: BridgeTaskViewModel
    var planned: [ExecutionViewModel.PlannedItem] = []
    /// W37：菜单栏小窗（交付版：只放正在计时的那件 / 下一件 + 开始；开始别的事收进「开始别的…」）
    var compact = false
    var onOpenMain: (() -> Void)? = nil
    @State private var showStartOther = false
    @State private var title = ""
    @State private var mode = BridgeTaskSession.Mode.light
    @State private var focusMinutes = 25
    @AppStorage(DeveloperSettings.key) private var developerOptions = DeveloperSettings.defaultValue   // W37：交付版信息披露（关 = 只留要你处理的）

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("正在做什么").font(.headline)
                Spacer()
                if developerOptions { Button("刷新") { Task { await model.refresh() } }.disabled(model.busy) }
                if compact { moreMenu }
            }
            if developerOptions {
                Text(model.backend == .icloud ? "两端共用 iCloud 计时；结束计时不代表事项完成。" : "与 Dots 共用 BC 计时；结束计时不代表事项完成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.sessions.isEmpty {
                // W31b：读失败了就别再说「等待」——原因在下面橙字里
                if compact, !developerOptions, !model.isStale, let next = nextPlanned {
                    nextRow(next)
                } else {
                    Text(!model.isStale ? (developerOptions ? "目前没有正在计时的事项" : "现在没在计时") : model.lastError == nil ? "等待读取计时状态" : "还没读到计时状态")
                        .foregroundStyle(.secondary)
                }
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
            if model.isStale { Text(model.hasEverRead ? "还没同步到最新状态，上面是上次的记录" : "计时状态还没同步到这台设备")
                    .font(.caption).foregroundStyle(.orange) }
            if model.hasMore, developerOptions { Text("这里只展示前 100 项；其余计时记录仍保留。")
                    .font(.caption).foregroundStyle(.secondary) }
            if compact, !developerOptions {
                DisclosureGroup("开始别的…", isExpanded: $showStartOther) { startControls }.font(.callout)
            } else {
                Divider()
                startControls
            }
            if developerOptions || model.lastError != nil {
                Text(model.message).font(.caption).foregroundStyle(model.lastError == nil ? Color.secondary : Color.orange)
            }
            if model.reviewCount > 0 { Text("\(model.reviewCount) 条冲突或未接受的请求已保留；不会自动覆盖新状态。")
                    .font(.caption).foregroundStyle(.orange) }
            // W31b：开发期通道开关默认收起（原来常驻在今天页顶部，iPhone 上把时间轴挤得只剩两三百 pt）；设置里「共享计时（开发期）」仍完整
            if developerOptions, let control = SharedTimerBackendControl.current {
                DisclosureGroup { SharedTimerBackendPanel(control: control) } label: {
                    Text("计时通道（开发期）").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.refresh() }
    }

    /// 开始计时的那一组控件（方式 / 名字 / 从今天安排里选）。
    @ViewBuilder private var startControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("计时方式", selection: $mode) {
                Text("轻计时").tag(BridgeTaskSession.Mode.light)
                Text("番茄钟").tag(BridgeTaskSession.Mode.pomodoro)
            }.pickerStyle(.segmented)
            if mode == .pomodoro {
                Stepper("专注 \(focusMinutes) 分钟", value: $focusMinutes, in: 1...240)
                if developerOptions {
                    Text("到时静默转为正计时，保留已工作时长；不自动结束或休息。")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        }
    }

    /// 下一件：今天还没过结束时间的第一块。
    private var nextPlanned: ExecutionViewModel.PlannedItem? {
        let now = Date()
        return planned.filter { $0.end > now }.sorted { $0.start < $1.start }.first
    }

    private func nextRow(_ item: ExecutionViewModel.PlannedItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("下一件 · \(item.start.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
            }
            Spacer()
            Button("开始") {
                Task { await model.start(title: item.title, relatedRecordId: "PlanBlock:" + item.id.uuidString, mode: item.timingStyle == .pomodoro ? .pomodoro : .light, focusMinutes: item.timingStyle == .pomodoro ? Int(PomodoroTimer.work / 60) : nil) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSubmit)
        }
    }

    /// 菜单栏小窗右上角的 ⋯：打开主窗口 / 退出。
    private var moreMenu: some View {
        Menu {
            if let onOpenMain { Button("打开 BetterCalendar", action: onOpenMain) }
            #if os(macOS)
            Button { AppLifecycle.shared?.reallyQuit() } label: { Label("退出", systemImage: "power") }
            #endif
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("更多")
    }
    private func startNew() {
        let submitted = title
        guard model.canSubmit else { return }
        guard model.queueStart(title: submitted, mode: mode, focusMinutes: mode == .pomodoro ? focusMinutes : nil) else { return }
        title = ""
        Task { await model.refresh() }
    }
}
