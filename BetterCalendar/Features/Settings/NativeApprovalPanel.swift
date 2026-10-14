import SwiftUI

struct NativeApprovalContent: View {
    @Bindable var model: NativeApprovalInbox
    var body: some View {
        ScrollView { NativeApprovalPanel(model: model, pinnedActions: true).padding() }
            .safeAreaInset(edge: .bottom) { NativeApprovalDecisionBar(model: model) }
    }
}

struct NativeApprovalPanel: View {
    @Bindable var model: NativeApprovalInbox
    var pinnedActions = false
    @State private var showPreview = false
    @State private var previewModel: NativeApprovalInbox?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待你确认").font(.headline)
                Spacer()
                Button("刷新") { Task { await model.refresh() } }.disabled(model.busy)
            }
            Text("这里只处理指定给本机的请求。你可以在 Dots 卡片或这里决定；两处共用同一状态。").font(.caption).foregroundStyle(.secondary)
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
            if let entry = model.selected { NativeApprovalDetail(model: model, entry: entry, pinnedActions: pinnedActions) }
            Divider()
            if !model.isDisplayTest {
                Button("只测审批显示（不会执行）") { previewModel = NativeApprovalPreview.make(); showPreview = true }
            }
            if !model.isDisplayTest && model.notificationsEnabled {
                Button("关闭审批通知") { model.disableNotifications() }
            } else if !model.isDisplayTest {
                Button("单独允许新审批通知") { Task { await model.enableNotifications() } }
            }
            Text("通知默认关闭，单独取得系统授权后才启用；点通知仅打开详情，不会批准或执行。后台到达时间取决于设备联网与系统调度。").font(.caption).foregroundStyle(.secondary)
            if let message = model.message, message != model.displayTestDecision?.title { Text(message).font(.caption).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading).buttonStyle(.bordered).task { await model.refresh() }
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
                        ScrollView { Text("修改前：" + value(before[key])).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 160).foregroundStyle(.secondary)
                    }
                    ScrollView { Text("修改后：" + value(after)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 160)
                }
            }
            if let fire = entry.request["fireAt"] { Text("响铃时间：" + date(fire)) }
            if let start = entry.request["effectiveAt"] { Text("明确补记起点：" + date(start)) }
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
    private var changes: [(String, BridgeJSON)] { ((try? NativeRemoteJSON.object(entry.request["patch"] ?? .null)) ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
    private var actionLabel: String { ["create":"新增", "update":"修改", "delete":"移入回收站（至少保留30天）", "restore":"恢复", "start":"开始计时", "pause":"暂停计时", "resume":"继续计时", "finish":"结束计时", "schedule":"设置单次闹钟", "cancel":"取消单次闹钟"][entry.action] ?? entry.action }
    private func fieldLabel(_ key: String) -> String { ["title":"标题", "note":"备注", "status":"状态", "body":"正文", "mood":"心情", "tags":"标签"][key] ?? key }
    private func date(_ v: BridgeJSON) -> String { (try? NativeRemoteJSON.date(v).formatted()) ?? value(v) }
    private func value(_ v: BridgeJSON?) -> String {
        guard let v else { return "未读取，不能当作空白" }
        switch v {
        case let .string(s): return s.isEmpty ? "（空白）" : s
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
            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
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
