import SwiftUI

struct NativeApprovalContent: View {
    @Bindable var model: NativeApprovalInbox
    var previewRequestId: UUID? = nil
    var body: some View {
        ScrollView { NativeApprovalPanel(model: model, pinnedActions: true, previewRequestId: previewRequestId).padding() }
            .safeAreaInset(edge: .bottom) { NativeApprovalDecisionBar(model: model) }
    }
}

struct NativeApprovalPanel: View {
    @Bindable var model: NativeApprovalInbox
    var pinnedActions = false
    var previewRequestId: UUID? = nil
    @State private var showPreview = false
    @State private var previewModel: NativeApprovalInbox?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待你确认").font(.headline)
                Spacer()
                Button("刷新") { Task { await model.refresh() } }.disabled(model.busy)
            }
            Text(model.crossReviewEnabled ? "可核对同一账户各设备的请求；改动仍只交给指定设备执行。Dots 与这里共用同一状态。" : "目前只核对指定给本机的请求。跨设备查看和确认需要你单独开启。").font(.caption).foregroundStyle(.secondary)
            if model.pending.isEmpty { Text(model.readComplete ? "目前没有需要你确认的请求" : "尚未读完，请刷新").foregroundStyle(.secondary) }
            ForEach(model.pending) { entry in
                Button { Task { await model.open(entry.id) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).lineLimit(2)
                        Text("确认截止：" + entry.expiresAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered).disabled(model.busy)
            }
            ForEach(model.retryCommandIds.filter { id in !model.pending.contains(where: { $0.id == id }) }, id: \.self) { id in
                Button("核对上次审批的回传结果") { Task { await model.open(id) } }.disabled(model.busy)
            }
            if model.entries.contains(where: { $0.state != "awaiting_confirmation" }) {
                DisclosureGroup("最近处理结果") {
                    ForEach(model.entries.filter { $0.state != "awaiting_confirmation" }.suffix(10)) { entry in
                        Button { Task { await model.open(entry.id) } } label: {
                            VStack(alignment: .leading) { Text(entry.title); Text(entry.stateLabel).font(.caption) }
                        }.disabled(model.busy)
                    }
                }
            }
            if let entry = model.selected { NativeApprovalDetail(model: model, entry: entry, pinnedActions: pinnedActions) }
            Divider()
            if !model.isDisplayTest {
                Button("只测审批显示（不会执行）") { previewModel = NativeApprovalPreview.make(); showPreview = true }
            }
            if !model.isDisplayTest && model.notificationsEnabled {
                Button("关闭审批通知") { model.disableNotifications() }.disabled(model.busy)
                Button("发送只读测试通知") { Task { await model.sendDisplayTestNotification() } }.disabled(model.busy)
            } else if !model.isDisplayTest {
                Button("允许审批通知（含批准／拒绝）") { Task { await model.enableNotifications() } }.disabled(model.busy)
            }
            if !model.isDisplayTest {
                Divider()
                Text("跨设备审批与单端提醒").font(.headline)
                Text("独立开启后，本机能查看并确认同一账户其他设备的具体请求，包括其已有授权的事项、计时或闹钟。仍由目标设备执行；不新增目标设备权限。关闭时本机立即停止跨设备确认，服务器撤回结果会明确显示。").font(.caption).foregroundStyle(.secondary)
                if model.crossReviewEnabled {
                    Button("关闭本机跨设备审批") { Task { await model.configurePolicy(review: false) } }.disabled(model.busy)
                    Button("仅在这台设备提醒新的审批") { Task { await model.configurePolicy(primaryHere: true) } }.disabled(model.busy || !model.policy.routingReady || !model.notificationsEnabled || ![.authorized, .provisional].contains(model.notificationAuthorization))
                    Text(model.policy.routingReadinessMessage).font(.caption).foregroundStyle(.secondary)
                    if !model.notificationsEnabled { Text("先在这台设备开启审批通知，再选择主要通知设备。").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Button("允许本机跨设备查看和确认") { Task { await model.configurePolicy(review: true) } }.disabled(model.busy)
                }
                Text(model.policy.primaryDeviceId == nil ? "尚未选择主要通知设备：沿用每个请求指定的执行设备提醒。" : model.primaryNotificationsHere ? "主要通知设备：这台设备。" : "主要通知设备：另一台设备。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("只影响设置之后新建的请求；旧请求保持原提醒设备，不自动故障转移。请先将参与设备全部更新并打开，再选择主要设备。系统通知设置由你决定。").font(.caption).foregroundStyle(.secondary)
                Text(model.notificationAuthorization.label).font(.caption).foregroundStyle(.secondary)
                Text("短且完整的事项改动可展开系统通知，选择批准／拒绝；点通知正文打开详情。长内容必须到详情核对。系统预览可能显示事项和修改内容，可在系统设置隐藏锁屏预览。通知不会代你批准。").font(.caption).foregroundStyle(.secondary)
                Text("当前 BC 运行时约每20秒检查；iPhone锁屏／后台可能延迟，尚未接通服务端远程审批推送。系统专注模式也可能隐藏横幅。").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.message, message != model.displayTestDecision?.title { Text(message).font(.caption).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading).buttonStyle(.bordered).task { await model.refresh() }
        .task(id: previewRequestId) {
            if previewRequestId != nil { previewModel = NativeApprovalPreview.make(); showPreview = true }
        }
        .sheet(isPresented: $showPreview) {
            if let previewModel {
                NavigationStack {
                    NativeApprovalContent(model: previewModel).navigationTitle("只读审批显示测试")
                        .toolbar { Button("关闭") { showPreview = false } }
                }
                #if os(iOS)
                .presentationDetents([.large])
                #endif
                #if os(macOS)
                .frame(minWidth: 480, idealWidth: 620, minHeight: 420, idealHeight: 650)
                #endif
            }
        }
    }
}

private struct NativeApprovalDetail: View {
    @Bindable var model: NativeApprovalInbox
    let entry: NativeApproval
    let pinnedActions: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text(entry.title).font(.title3).textSelection(.enabled)
            Text("设备：" + entry.deviceLabel)
            Text(model.isDisplayTest ? (entry.state == "awaiting_confirmation" ? "仅测试显示；所有选择均不执行操作" : (model.displayTestDecision?.title ?? "显示测试已返回；没有改事项或计时")) : entry.stateLabel).foregroundStyle(.secondary)
            Text("确认截止：" + entry.expiresAt.formatted())
            Text("操作：" + actionLabel)
            ForEach(changes, id: \.0) { key, after in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fieldLabel(key)).font(.headline)
                    if entry.action == "update" {
                        ScrollView { Text("修改前：" + fieldValue(key, before[key])).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 160).foregroundStyle(.secondary)
                    }
                    ScrollView { Text((entry.action == "schedule" || entry.action == "create" ? "新内容：" : "修改后：") + fieldValue(key, after)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 160)
                }
            }
            if entry.kind == "reminder" {
                if entry.action == "cancel" {
                    ForEach(before.sorted { $0.key < $1.key }, id: \.key) { key, content in Text("原" + fieldLabel(key) + "：" + fieldValue(key, content)).textSelection(.enabled) }
                    Text("取消后只移除此设备的这条提醒，不影响其他提醒。")
                }
                Text("普通系统通知，不保证叫醒；只在指定设备排程。")
            } else if let fire = entry.request["fireAt"] { Text("响铃时间：" + date(fire)) }
            if entry.kind == "timer", entry.request["mode"] == .string("pomodoro") { Text("番茄到时静默转为正计时，保留已工作时长；不自动结束、休息或响铃。") }
            if let start = entry.request["effectiveAt"] { Text("明确补记起点：" + date(start)) }
            if case let .object(source) = entry.display["source"], case let .string(freshness) = source["freshness"], freshness != "current" {
                Text("修改前数据时效：" + freshness + "；读取时刻：" + value(source["observedAt"]) + "。执行前仍会核对原版本。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let source = entry.display["beforeSource"] { Text(value(source)).font(.caption).foregroundStyle(.secondary) }
            if let error = entry.displayError { Text("确认内容加载失败：" + error).foregroundStyle(.orange).textSelection(.enabled) }
            if !pinnedActions { NativeApprovalDecisionBar(model: model) }
            if model.retryCommandIds.contains(entry.id) {
                Button("核对原审批并重试原决定") { Task { await model.retryOriginalDecision() } }.disabled(model.busy)
            }
            Text(model.isDisplayTest ? "这是本机显示测试，不会提交给真实设备执行。" : "同意表示交给指定设备；只有设备回执才能说明已应用。平台卡片可能提前结束显示，服务期限独立。").font(.caption).foregroundStyle(.secondary)
            Text(model.isDisplayTest ? "确认或不执行都不会改变你的事项、计时、闹钟或权限。" : "同意还需本机原有操作授权有效且已同步；这里不会扩大授权。").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("技术详情与回执") {
                Text("请求：" + entry.id + "\n版本：" + value(entry.request["expectedRevision"]) + "\n请求哈希：" + entry.requestHash).font(.caption).textSelection(.enabled)
                if let result = entry.result { Text(value(result)).font(.caption).textSelection(.enabled) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var before: [String: BridgeJSON] { (try? NativeRemoteJSON.object(entry.display["before"] ?? .null)) ?? [:] }
    private var changes: [(String, BridgeJSON)] { entry.changeValues.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
    private var actionLabel: String { if entry.kind == "reminder" { return ["schedule":"设置单次普通提醒", "update":"修改普通提醒", "cancel":"取消普通提醒"][entry.action] ?? entry.action }; return ["create":"新增", "update":"修改", "delete":"移入回收站（至少保留30天）", "restore":"恢复", "start":"开始计时", "pause":"暂停计时", "resume":"继续计时", "finish":"结束计时", "schedule":"设置单次闹钟", "cancel":"取消单次闹钟"][entry.action] ?? entry.action }
    private func fieldLabel(_ key: String) -> String { ["mode":"计时方式", "focusMinutes":"番茄分钟数", "title":"标题", "note":"备注", "status":"状态", "body":"正文", "mood":"心情", "tags":"标签", "fireAt":"提醒时刻（本机时区）", "sound":"播放声音", "experiment":"合成测试（不计生活活动）"][key] ?? key }
    private func fieldValue(_ key: String, _ v: BridgeJSON?) -> String {
        if key == "mode", case let .string(mode) = v { return mode == "pomodoro" ? "番茄钟" : "轻计时" }
        if key == "fireAt", let date = try? NativeRemoteJSON.date(v) {
            return date.formatted(date: .abbreviated, time: .standard) + " " + (TimeZone.current.abbreviation(for: date) ?? "本机时区")
        }
        return value(v)
    }
    private func date(_ v: BridgeJSON) -> String { (try? NativeRemoteJSON.date(v).formatted()) ?? value(v) }
    private func value(_ v: BridgeJSON?) -> String {
        guard let v else { return "未读取，不能当作空白" }
        switch v {
        case let .string(s): return s.isEmpty ? "（空白）" : s
        case .bool(let flag): return flag ? "是" : "否"
        case .null: return "清空"
        case let .array(a): return a.map { value($0) }.joined(separator: "、")
        default: return (try? String(data: BridgePoolCodec.encode(v), encoding: .utf8)) ?? "未知"
        }
    }
}

struct NativeApprovalDecisionBar: View {
    @Bindable var model: NativeApprovalInbox
    var body: some View {
        if let decision = model.displayTestDecision {
            NativeApprovalDisplayFeedback(decision: decision)
        } else if let entry = model.selected, entry.state != "awaiting_confirmation" {
            NativeApprovalResultFeedback(entry: entry, message: model.message)
        } else if let entry = model.selected {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                Button(model.isDisplayTest ? "确认显示测试" : "同意这项改动") { Task { await model.decide("accept") } }
                    .disabled(!model.canDecide(entry, accept: true)).accessibilityIdentifier("bc.approvals.accept")
                Button(model.isDisplayTest ? "不执行／结束测试" : "拒绝") { Task { await model.decide("decline") } }
                    .disabled(!model.canDecide(entry, accept: false)).accessibilityIdentifier("bc.approvals.decline")
                }.buttonStyle(.bordered)
                if model.busy { ProgressView("正在回传你的选择…") }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.background)
        }
    }
}

struct NativeApprovalResultFeedback: View {
    let entry: NativeApproval
    let message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.stateLabel, systemImage: entry.state == "applied" ? "checkmark.circle" : "info.circle").font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            if let message, message != entry.stateLabel { Text(message).font(.caption).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.regularMaterial)
            .accessibilityElement(children: .combine).accessibilityIdentifier("bc.approvals.command-result")
    }
    private var detail: String {
        switch entry.state {
        case "queued": "服务已保存批准，尚无设备应用回执。"
        case "dispatching": "设备已接手，结果尚未返回；不要重新提交。"
        case "applied": "设备已回传结果；请核对最终内容，另一端显示仍需单独验证。"
        case "failed": "请查看失败原因；没有把请求标成成功。"
        case "unknown": "执行结果尚不确定；请核对原请求，不要换编号重做。"
        case "declined", "cancelled": "这项请求已关闭，不会自动重新提交。"
        case "expired": "本请求已到期，不会自动续期或重建。"
        default: "权限已撤回或改变；不会按旧授权继续执行。"
        }
    }
}

struct NativeApprovalDisplayFeedback: View {
    let decision: NativeApprovalDisplayDecision
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(decision.title, systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            Text(decision.detail).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.regularMaterial)
            .accessibilityElement(children: .combine).accessibilityIdentifier("bc.approvals.display-result")
    }
}
