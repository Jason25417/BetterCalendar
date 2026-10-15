import SwiftUI

/// Direct Form rows: no giant clickable parent row around several buttons.
struct NativeConversationPermissionsPanel: View {
    @Bindable var actions: NativeActionsViewModel
    @Bindable var model: NativeRemoteExecutor
    @State private var items = false
    @State private var alarms = false
    @State private var timer = false
    @State private var journalRead = false
    @State private var journalWrite = false
    @State private var reminderRead = false
    @State private var reminderWrite = false
    @State private var saving = false
    private var busy: Bool { saving || actions.working }
    var body: some View {
        Group {
            Text(model.deviceId == nil ? "这台设备尚未连接" : "在这台设备开启 Dots 对话操作")
                .font(.headline)
            Text(model.alarmSupported
                 ? "一键开启：事项池、共享计时、日记读取与文字修改、单次系统闹钟。首次可能弹出系统闹钟授权。"
                 : "一键开启：事项池、共享计时、日记读取与文字修改。此平台不支持系统闹钟。")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                Task { await actions.enableAllConversationCapabilities(); loadSelections() }
            } label: {
                Text(busy ? "正在保存权限…" : "一键开启常用对话权限（不含普通提醒）")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent).disabled(busy)
            .accessibilityIdentifier("nativePermissions.enableAll")
            if model.deviceId == nil {
                Text("先在「个人状态与 Dot」保存本机设备配置。手机快捷指令上传状态，不代表 BC 已保存连接。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let notice = actions.conversationSetupNotice {
                Text(notice).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("nativePermissions.setupResult")
            }
            Text("已保存：" + enabledSummary).font(.caption).textSelection(.enabled)
            Text(model.message).font(.caption).textSelection(.enabled)
            if let expires = model.expiresAt { Text("授权到期：" + expires.formatted()).font(.caption) }
            Text("授权29天；每次改动仍由你在 Dots 或指定设备的 BC 内确认。没有自动开始计时、自动闹钟或应用屏蔽；读取日记不包含照片内容。iPhone需BC运行时接收请求，后台及时执行尚未保证。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("分别选择权限") {
                Toggle("事项池新增、修改、删除与恢复", isOn: $items)
                Toggle("开始、暂停、继续与结束共享计时", isOn: $timer)
                if model.alarmSupported { Toggle("设置与取消单次系统闹钟", isOn: $alarms) }
                Toggle("读取日记文字与照片引用", isOn: $journalRead)
                Toggle("新增与修改日记文字", isOn: $journalWrite)
                Button("保存以上选择") { saveSelection() }
                    .buttonStyle(.bordered).disabled(busy)
                    .accessibilityIdentifier("nativePermissions.saveSelection")
                Text("只切换选项尚未生效；保存后的实际权限显示在上方。系统闹钟可在下方原生操作里单独授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }.toggleStyle(.switch).disabled(busy)
            DisclosureGroup("普通定时提醒（新增，独立开启）") {
                Text("升级不会自动开启。一键旧权限不包含新提醒。系统通知允许后，明确的单次提醒才可由指定设备排程；每次设置、修改或取消仍需本人批准。已提交系统的计划在 App 退出或断网后也可由系统处理，专注模式等仍可能抑制显示，不保证叫醒。撤回对话权限不会自动取消已经批准的提醒；要停止请先逐条取消。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("读取本机普通提醒与系统排程状态", isOn: $reminderRead)
                Toggle("设置、修改、取消单次普通提醒", isOn: $reminderWrite)
                Button("保存普通提醒与当前权限选择") { saveSelection() }.disabled(busy)
                Text("此处不会申请新的系统通知权限；尚未允许时，请由你在系统设置或审批通知入口允许通知。")
                    .font(.caption).foregroundStyle(.secondary)
            }.toggleStyle(.switch).disabled(busy)
            Button("撤回本机全部对话权限", role: .destructive) {
                save(items: false, alarms: false, timer: false, journalRead: false, journalWrite: false, reminderRead: false, reminderWrite: false)
            }.buttonStyle(.bordered).disabled(busy)
                .accessibilityIdentifier("nativePermissions.revokeAll")
            Button("刷新权限与执行状态") {
                saving = true
                Task { await model.poll(); model.refreshLocal(); loadSelections(); saving = false }
            }
                .buttonStyle(.bordered).disabled(busy)
            DisclosureGroup("本机连接详情") {
                Text(model.deviceId ?? "尚未保存连接").font(.caption).textSelection(.enabled)
            }
        }.task { model.refreshLocal(); loadSelections() }
    }
    private var enabledSummary: String {
        var values: [String] = []
        if model.allowItems { values.append("事项") }
        if model.allowTimer { values.append("计时") }
        if model.allowJournalRead { values.append("日记读取") }
        if model.allowJournalWrite { values.append("日记修改") }
        if model.allowAlarms { values.append("单次闹钟") }
        if model.allowReminderRead { values.append("普通提醒读取") }
        if model.allowReminderWrite { values.append("普通提醒设置") }
        return values.isEmpty ? "尚未启用" : values.joined(separator: "、")
    }
    private func loadSelections() {
        items = model.allowItems; alarms = model.allowAlarms; timer = model.allowTimer
        journalRead = model.allowJournalRead; journalWrite = model.allowJournalWrite
        reminderRead = model.allowReminderRead; reminderWrite = model.allowReminderWrite
    }
    private func saveSelection() { save(items: items, alarms: alarms, timer: timer, journalRead: journalRead, journalWrite: journalWrite, reminderRead: reminderRead, reminderWrite: reminderWrite) }
    private func save(items: Bool, alarms: Bool, timer: Bool, journalRead: Bool, journalWrite: Bool, reminderRead: Bool, reminderWrite: Bool) {
        saving = true; actions.conversationSetupNotice = nil
        Task {
            await model.setCapabilities(items: items, alarm: alarms, journalRead: journalRead, journalWrite: journalWrite, timer: timer, reminderRead: reminderRead, reminderWrite: reminderWrite)
            loadSelections(); saving = false
        }
    }
}
