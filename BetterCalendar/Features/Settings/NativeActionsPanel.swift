import SwiftUI

struct NativeActionsPanel: View {
    @Bindable var model: NativeActionsViewModel
    @State private var deleteConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let remote = model.remote { NativeRemotePanel(model: remote) }
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


private struct NativeRemotePanel: View {
    @Bindable var model: NativeRemoteExecutor
    @State private var items = false
    @State private var alarms = false
    @State private var timer = false
    @State private var journalRead = false
    @State private var journalWrite = false
    @State private var working = false
    var body: some View {
        DisclosureGroup("Dots 对话操作（内测）") {
            Text("本机：" + (model.deviceId ?? "尚未连接")).font(.caption).textSelection(.enabled)
            Toggle("允许对话确认后改动事项池", isOn: $items)
            Toggle("允许对话确认后开始／暂停／继续／结束计时", isOn: $timer)
            if model.alarmSupported { Toggle("允许对话确认后设置／取消单次闹钟", isOn: $alarms) }
            Toggle("允许 Dots 读取日记文字与照片引用", isOn: $journalRead)
            Toggle("允许对话确认后新增／修改日记文字", isOn: $journalWrite)
            Text("计时与事项完成独立，按确认时刻生效；设备离线不自动暂停。读取不包含照片内容或修改权限，只有请求的页经现有私有连接回传。仅限你每次在对话里确认的具体改动，授权29天。长期事项不删除；没有自动提醒或应用屏蔽。iPhone需BC运行时接收请求，后台及时执行尚未保证。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存本机权限") { save(items: items, alarms: alarms, journalRead: journalRead, journalWrite: journalWrite, timer: timer) }.disabled(working || model.deviceId == nil)
                Button("撤回全部对话操作") { save(items: false, alarms: false, journalRead: false, journalWrite: false, timer: false) }.disabled(working || model.deviceId == nil)
            }
            Button("核对待执行请求") { Task { await model.poll() } }.disabled(working)
            Text(model.message).font(.caption).textSelection(.enabled)
            if let expires = model.expiresAt { Text("授权期限：" + expires.formatted()).font(.caption) }
        }.task { model.refreshLocal(); items = model.allowItems; alarms = model.allowAlarms; journalRead = model.allowJournalRead; journalWrite = model.allowJournalWrite; timer = model.allowTimer }
    }
    private func save(items: Bool, alarms: Bool, journalRead: Bool, journalWrite: Bool, timer: Bool) {
        working = true
        Task {
            await model.setCapabilities(items: items, alarm: alarms, journalRead: journalRead, journalWrite: journalWrite, timer: timer)
            self.items = model.allowItems; self.alarms = model.allowAlarms; self.journalRead = model.allowJournalRead; self.journalWrite = model.allowJournalWrite; self.timer = model.allowTimer; working = false
        }
    }
}
