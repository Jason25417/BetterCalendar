import SwiftUI

struct NativeActionsPanel: View {
    @Bindable var model: NativeActionsViewModel
    @State private var deleteConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NativeEvidencePanel()
            DisclosureGroup("事项写入（内测）") {
                Picker("事项", selection: Binding(get: { model.selected }, set: { model.select($0) })) {
                    Text("新待办").tag(Optional<UUID>.none)
                    ForEach(model.records) { item in
                        Text(label(item)).tag(Optional(item.id))
                    }
                }.disabled(model.pendingItem != nil || model.working)
                TextField("标题", text: $model.title).disabled(model.pendingItem != nil)
                TextField("备注", text: $model.note, axis: .vertical).disabled(model.pendingItem != nil)
                Picker("状态", selection: $model.status) {
                    Text("在途").tag("active"); Text("做成了").tag("done"); Text("先放下").tag("shelved")
                }.disabled(model.pendingItem != nil)
                HStack {
                    Button(model.selected == nil ? "收进待办" : "保存修改") { model.executeItem(model.selected == nil ? .create : .update) }
                        .disabled(model.working || model.pendingItem != nil)
                    if model.selected != nil {
                        if selectedInTrash {
                            Button("恢复") { model.executeItem(.restore) }.disabled(model.pendingItem != nil || model.working)
                        } else if selectedTodo {
                            Button("移到回收站", role: .destructive) { deleteConfirmation = true }
                                .disabled(model.pendingItem != nil || model.working)
                        }
                    }
                }
                if model.pendingItem != nil {
                    Button("用原请求重试") { model.retryItem() }.disabled(model.working)
                    Button("重新读取并核对") { model.leaveItemRetry() }.disabled(model.working)
                }
                Text("先核对读取版本再保存；删除至少保留30天。长期事项使用「先放下」。这不是计时操作。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("原生闹钟（内测）") {
                if model.capability.supported {
                    Text("系统授权：" + authorizationLabel).font(.caption)
                    if model.capability.authorization != "authorized" {
                        Button("允许 BC 使用系统闹钟") { Task { await model.authorizeAlarm() } }.disabled(model.working)
                    }
                    TextField("提醒什么", text: $model.alarmTitle).disabled(model.pendingAlarm != nil || model.working)
                    DatePicker("响铃时间", selection: $model.alarmDate).disabled(model.pendingAlarm != nil || model.working)
                    Button(model.pendingAlarm == nil ? "设置这一次闹钟" : "核对原排程请求") { Task { await model.scheduleAlarm() } }
                        .disabled(model.working || model.capability.authorization != "authorized")
                    if model.pendingAlarm != nil { Button("保留原回执并重新填写") { model.leaveAlarmRetry() }.disabled(model.working) }
                    ForEach(model.knownAlarms, id: \.commandId) { alarm in
                        HStack {
                            Text(alarm.title + " · " + alarm.fireAt.formatted())
                            Button("取消") { model.cancelAlarm(alarm.commandId) }.disabled(model.working)
                        }
                    }
                    Text("只设置你明确选择的一次闹钟，由系统排程。未启用自动策略、番茄钟或应用屏蔽；系统排程不保证叫醒。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("本机不支持此原生闹钟；请在 iPhone 上设置。").font(.caption)
                }
            }
            Button("刷新原生操作状态") { model.refresh() }.disabled(model.working)
            if let message = model.message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .buttonStyle(.bordered)
        .task { model.refresh() }
        .confirmationDialog("移到回收站？原记录和阶段内容保留，可以恢复。", isPresented: $deleteConfirmation) {
            Button("移到回收站", role: .destructive) { model.executeItem(.delete) }
        }
    }
    private var authorizationLabel: String {
        switch model.capability.authorization {
        case "authorized": "已允许"
        case "not_determined": "尚未申请"
        case "denied": "未允许"
        default: "未知"
        }
    }
    private var selectedValues: [String: BridgeJSON] {
        guard case let .object(v) = model.records.first(where: { $0.id == model.selected })?.values else { return [:] }
        return v
    }
    private var selectedTodo: Bool { selectedValues["zone"] == .string("todo") }
    private var selectedInTrash: Bool { selectedValues["isInTrash"] == .bool(true) }
    private func label(_ item: NativePoolRecord) -> String {
        guard case let .object(v) = item.values, case let .string(title) = v["title"] else { return item.id.uuidString }
        return (v["isInTrash"] == .bool(true) ? "回收站 · " : "") + title
    }
}
