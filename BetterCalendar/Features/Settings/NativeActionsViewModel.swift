import Foundation
import Observation

@MainActor @Observable final class NativeActionsViewModel {
    let writer: any NativeItemWriting
    let alarms: any NativeAlarmScheduling
    var records: [NativePoolRecord] = []
    var selected: UUID?
    var title = ""
    var note = ""
    var status = "active"
    var alarmTitle = ""
    var alarmDate = Date.now.addingTimeInterval(600)
    var pendingItem: NativeItemCommand?
    var pendingAlarm: NativeAlarmRequest?
    var pendingCancel: (UUID, UUID)?
    var knownAlarms: [NativeAlarmRequest] = []
    var capability: NativeAlarmCapability
    var message: String?
    var working = false
    init(writer: any NativeItemWriting, alarms: any NativeAlarmScheduling) {
        self.writer = writer; self.alarms = alarms; self.capability = alarms.inspect()
    }
    func refresh() {
        do {
            records = try writer.records()
            capability = alarms.inspect()
            knownAlarms = capability.authorization == "authorized" ? try alarms.recordedAlarms() : []
        } catch { fail(error) }
    }
    func select(_ id: UUID?) {
        guard pendingItem == nil else { return }
        selected = id
        guard let item = records.first(where: { $0.id == id }), case let .object(v) = item.values else { title = ""; note = ""; status = "active"; return }
        if case let .string(value) = v["title"] { title = value }
        if case let .string(value) = v["note"] { note = value }
        if case let .string(value) = v["status"] { status = value }
    }
    func executeItem(_ action: NativeItemCommand.Action) {
        guard !working, pendingItem == nil else { return }
        let record = records.first { $0.id == selected }
        let id = action == .create ? UUID() : selected
        guard let id else { message = "先选择一个事项"; return }
        let patch: [String: BridgeJSON] = action == .update || action == .create
            ? ["title": .string(title), "note": .string(note), "status": .string(status)] : [:]
        let command = NativeItemCommand(commandId: UUID(), recordId: id, action: action,
                                        expectedRevision: action == .create ? nil : record?.revision, patch: patch,
                                        occurredAt: .now, userAuthorizationRef: "native-button:" + UUID().uuidString)
        pendingItem = command; retryItem()
    }
    func retryItem() {
        guard let command = pendingItem, !working else { return }
        working = true; defer { working = false }
        do {
            _ = try writer.execute(command, userConfirmed: true)
            pendingItem = nil; message = "已保存到本机；另一台设备同步尚待核验"
            refresh(); select(command.recordId)
        } catch { fail(error) }
    }
    func leaveItemRetry() {
        // Keeps the durable intent for inspection. Not an undo or a new command.
        pendingItem = nil; refresh(); message = "原请求回执保留，未撤销已发生的改动；请核对当前内容"
    }
    func authorizeAlarm() async {
        guard !working else { return }
        working = true; defer { working = false }
        do { capability = try await alarms.requestAuthorization(); refresh() }
        catch { fail(error) }
    }
    func scheduleAlarm() async {
        guard !working else { return }
        if pendingAlarm == nil {
            guard !alarmTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, alarmDate > .now else { message = "请填写标题并选择未来时间"; return }
            pendingAlarm = NativeAlarmRequest(commandId: UUID(), fireAt: alarmDate, title: alarmTitle,
                                             userAuthorizationRef: "native-button:" + UUID().uuidString)
        }
        working = true; defer { working = false }
        do {
            guard let request = pendingAlarm else { return }
            _ = try await alarms.schedule(request, userConfirmed: true)
            pendingAlarm = nil; message = "系统排程已核验；实际响铃和你是否听到仍需真机验证"
            refresh()
        } catch { fail(error) }
    }
    func leaveAlarmRetry() {
        pendingAlarm = nil; refresh()
        message = "原请求回执保留，未取消可能已排的闹钟；请先核对当前清单，再决定是否设置新闹钟"
    }
    func cancelAlarm(_ id: UUID) {
        guard !working else { return }
        if let pendingCancel, pendingCancel.1 != id { message = "先核对上一条取消请求"; return }
        let command = pendingCancel?.0 ?? UUID()
        pendingCancel = (command, id)
        do {
            _ = try alarms.cancel(commandId: command, alarmId: id, userConfirmed: true)
            pendingCancel = nil; message = "已核验系统中没有这条闹钟"; refresh()
        } catch { fail(error) }
    }
    func fail(_ error: Error) {
        message = error.localizedDescription
        DevLog.shared.warn("原生操作", error.localizedDescription)
    }
}

