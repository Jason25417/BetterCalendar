import Foundation
import UserNotifications

// Explicit, one-off ordinary notifications. This has no AlarmKit, app blocking,
// inference, automatic authorization request, or dependency on a chat session.
nonisolated struct NativeReminderPlan: Codable, Equatable {
    var id: UUID
    var revision: String
    var title: String
    var body: String
    var fireAt: Date
    var sound: Bool
    var experiment: Bool
    var cancelled = false
    var record: BridgeJSON {
        .object(["reminderId": .string(id.uuidString.lowercased()), "revision": .string(revision), "title": .string(title), "body": .string(body),
                 "fireAt": NativeRemoteJSON.timestamp(fireAt), "sound": .bool(sound), "experiment": .bool(experiment), "cancelled": .bool(cancelled)])
    }
    var identifier: String { "bc.explicit-reminder." + id.uuidString.lowercased() }
}
nonisolated struct NativeReminderQuery: Codable {
    var reminderId: UUID? = nil
    var includeCancelled = false
    var limit = 10
    var cursor: String? = nil
}
nonisolated struct NativeReminderChange: Codable, Equatable {
    enum Action: String, Codable { case schedule, update, cancel }
    var commandId: UUID
    var reminderId: UUID
    var action: Action
    var expectedRevision: String?
    var title: String?
    var body: String?
    var fireAt: Date?
    var sound: Bool?
    var experiment: Bool?
}
nonisolated struct NativeReminderAttempt: Codable {
    var commandId: UUID
    var requestHash: String
    var proposed: NativeReminderPlan
    var beforeRevision: String? = nil
    var applied = false
    var checkedAt: Date?
}
nonisolated struct NativeReminderClick: Codable { var reminderId: UUID; var revision: String; var at: Date }
nonisolated struct NativeReminderLedger: Codable {
    var version = 1
    var clicks: [NativeReminderClick]? = nil
    var records: [NativeReminderPlan] = []
    var attempts: [NativeReminderAttempt] = []
    func validate() throws {
        guard version == 1, records.count <= 500, attempts.count <= 2000, (clicks?.count ?? 0) <= 2000,
              Set(records.map(\.id)).count == records.count, Set(attempts.map(\.commandId)).count == attempts.count,
              records.allSatisfy({ $0.revision.count == 64 }), attempts.allSatisfy({ $0.requestHash.count == 64 && $0.proposed.revision.count == 64 }) else {
            throw DataArchiveError.invalid("普通提醒日志损坏或已达容量；保留原文件，未排程")
        }
    }
}
@MainActor protocol NativeReminderPersisting {
    func load() throws -> NativeReminderLedger
    func save(_ value: NativeReminderLedger) throws
}
@MainActor final class NativeReminderMemoryPersistence: NativeReminderPersisting {
    var value = NativeReminderLedger()
    func load() throws -> NativeReminderLedger { value }
    func save(_ value: NativeReminderLedger) throws { try value.validate(); self.value = value }
}
@MainActor final class NativeReminderFilePersistence: NativeReminderPersisting {
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DotStateBridge/explicit-reminders-v1.json")
    }
    func load() throws -> NativeReminderLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true, (attributes.fileSize ?? 0) <= 8 * 1024 * 1024 else { throw DataArchiveError.invalid("普通提醒日志无法安全读取") }
        let value = try JSONDecoder().decode(NativeReminderLedger.self, from: Data(contentsOf: url))
        try value.validate(); return value
    }
    func save(_ value: NativeReminderLedger) throws {
        try value.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8 * 1024 * 1024 else { throw DataArchiveError.invalid("普通提醒日志已达容量；保留原文件") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
@MainActor protocol NativeReminderSystem {
    func authorized() async -> Bool
    func pending(_ identifier: String) async throws -> NativeReminderPlan?
    func delivered(_ identifier: String) async throws -> NativeReminderPlan?
    func submit(_ plan: NativeReminderPlan) async throws
    func remove(_ identifier: String) async
}
extension NativeReminderSystem { func delivered(_ identifier: String) async throws -> NativeReminderPlan? { nil } }
@MainActor final class UNNativeReminderSystem: NativeReminderSystem {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }
    func authorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
    static func request(_ plan: NativeReminderPlan) throws -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = plan.title; content.body = plan.body; content.sound = plan.sound ? .default : nil
        content.userInfo = ["bcExplicitReminder": try JSONEncoder().encode(plan).base64EncodedString()]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.fireAt)
        components.calendar = calendar; components.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: plan.identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
    func pending(_ identifier: String) async throws -> NativeReminderPlan? {
        guard let request = await center.pendingNotificationRequests().first(where: { $0.identifier == identifier }) else { return nil }
        return try decode(request, identifier: identifier)
    }
    func delivered(_ identifier: String) async throws -> NativeReminderPlan? {
        guard let request = await center.deliveredNotifications().first(where: { $0.request.identifier == identifier })?.request else { return nil }
        return try decode(request, identifier: identifier)
    }
    private func decode(_ request: UNNotificationRequest, identifier: String) throws -> NativeReminderPlan {
        guard let raw = request.content.userInfo["bcExplicitReminder"] as? String, let data = Data(base64Encoded: raw),
              let plan = try? JSONDecoder().decode(NativeReminderPlan.self, from: data), plan.identifier == identifier,
              request.content.title == plan.title, request.content.body == plan.body,
              (request.content.sound != nil) == plan.sound,
              let trigger = request.trigger as? UNCalendarNotificationTrigger, !trigger.repeats,
              let date = trigger.dateComponents.date, abs(date.timeIntervalSince(plan.fireAt)) < 1 else {
            throw DataArchiveError.invalid("系统普通提醒的内容或排程不匹配；结果未知")
        }
        return plan
    }
    func submit(_ plan: NativeReminderPlan) async throws { try await center.add(Self.request(plan)) }
    func remove(_ identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
@MainActor final class NativeReminderScheduler {
    private let system: any NativeReminderSystem
    private let persistence: any NativeReminderPersisting
    private let now: () -> Date
    private var busy = false
    init(system: any NativeReminderSystem, persistence: any NativeReminderPersisting, now: @escaping () -> Date = Date.init) {
        self.system = system; self.persistence = persistence; self.now = now
    }
    func records() throws -> [NativeReminderPlan] { try persistence.load().records }
    private func plans(_ ledger: NativeReminderLedger) -> [NativeReminderPlan] {
        var plans = ledger.records
        for attempt in ledger.attempts.reversed() where !attempt.applied && !plans.contains(where: { $0.id == attempt.proposed.id }) { plans.append(attempt.proposed) }
        return plans.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func inspect(_ plan: NativeReminderPlan, ledger: NativeReminderLedger) async throws -> BridgeJSON {
        let actual = try await system.pending(plan.identifier)
        let delivered = try await system.delivered(plan.identifier)
        let unresolved = ledger.attempts.contains { $0.proposed.id == plan.id && !$0.applied && ($0.beforeRevision == plan.revision || $0.proposed.revision == plan.revision) }
        let state: String
        if unresolved { state = "operation_result_unknown" }
        else if plan.cancelled { state = actual == nil && delivered == nil ? "cancelled_system_absence_verified" : "cancellation_not_current_unknown" }
        else if delivered == plan { state = "os_notification_center_reported" }
        else if actual == plan { state = "system_schedule_verified" }
        else { state = plan.fireAt <= now() ? "elapsed_delivery_unknown" : "system_plan_missing_unknown" }
        var value = try NativeRemoteJSON.object(plan.record)
        let clicked = ledger.clicks?.first { $0.reminderId == plan.id && $0.revision == plan.revision }
        value.merge(["deliveryEvidence": .string(delivered == plan ? "os_notification_center_entry" : "unknown"), "clickedAt": clicked.map { NativeRemoteJSON.timestamp($0.at) } ?? .null, "clickEvidence": .string(clicked == nil ? "unknown" : "os_response_device_report"), "state": .string(state), "channel": .string("ordinary_notification"), "userSeen": .string("unknown"), "guaranteedWake": .bool(false)]) { _, new in new }
        return .object(value)
    }
    func status() async throws -> [BridgeJSON] {
        let ledger = try persistence.load(); try ledger.validate()
        var values: [BridgeJSON] = []
        for plan in plans(ledger) { values.append(try await inspect(plan, ledger: ledger)) }
        return values
    }
    func recordClick(_ encodedPlan: String) throws {
        guard encodedPlan.utf8.count <= 32000, let data = Data(base64Encoded: encodedPlan),
              let plan = try? JSONDecoder().decode(NativeReminderPlan.self, from: data) else { throw DataArchiveError.invalid("普通提醒点击内容无效，未记录") }
        var ledger = try persistence.load()
        guard ledger.attempts.contains(where: { $0.proposed == plan }) else { throw DataArchiveError.invalid("点击不属于本机已记录的普通提醒") }
        var clicks = ledger.clicks ?? []
        guard !clicks.contains(where: { $0.reminderId == plan.id && $0.revision == plan.revision }) else { return }
        clicks.append(.init(reminderId: plan.id, revision: plan.revision, at: now())); ledger.clicks = clicks
        try persistence.save(ledger)
    }
    private struct Cursor: Codable { var offset: Int; var catalogHash: String; var queryHash: String }
    func read(_ query: NativeReminderQuery, readAllowed: () -> Bool) async throws -> BridgeJSON {
        guard readAllowed(), (1...20).contains(query.limit), (query.cursor?.count ?? 0) <= 2000 else { throw DataArchiveError.invalid("提醒读取权限或分页无效") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        let ledger = try persistence.load(); try ledger.validate()
        let catalogHash = BridgePoolCodec.hash(try encoder.encode(ledger))
        var filter = query; filter.cursor = nil
        let queryHash = BridgePoolCodec.hash(try encoder.encode(filter))
        let matching = plans(ledger).filter { (query.reminderId == nil || query.reminderId == $0.id) && (query.includeCancelled || !$0.cancelled) }
        var offset = 0
        if let raw = query.cursor {
            guard let data = Data(base64Encoded: raw), let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
                  cursor.catalogHash == catalogHash, cursor.queryHash == queryHash, (0...matching.count).contains(cursor.offset) else { throw DataArchiveError.invalid("提醒目录版本或查询范围变化，请重新读取第一页") }
            offset = cursor.offset
        }
        var values: [BridgeJSON] = []
        while offset < matching.count && values.count < query.limit {
            let value = try await inspect(matching[offset], ledger: ledger)
            if try BridgePoolCodec.encode(.array(values + [value])).count > 40000 { break }
            values.append(value); offset += 1
        }
        guard readAllowed(), catalogHash == BridgePoolCodec.hash(try encoder.encode(persistence.load())) else { throw DataArchiveError.invalid("读取期间提醒权限或目录变化，没有返回混合页") }
        let more = offset < matching.count
        guard !more || !values.isEmpty else { throw DataArchiveError.invalid("单条提醒超出返回容量，未返回无法继续的空页") }
        let cursor = more ? try String(data: encoder.encode(Cursor(offset: offset, catalogHash: catalogHash, queryHash: queryHash)).base64EncodedData(), encoding: .utf8) : nil
        return .object(["records": .array(values), "complete": .bool(true), "hasMore": .bool(more), "nextCursor": cursor.map(BridgeJSON.string) ?? .null,
                        "catalogHash": .string(catalogHash), "totalMatching": .number(Double(matching.count)), "readAt": NativeRemoteJSON.timestamp(now()),
                        "systemStatusWindow": .string("live_read_per_page_not_delivery_receipt"), "operationEffect": .string("read_only")])
    }
    func apply(_ change: NativeReminderChange, userConfirmed: Bool, grantCurrent: () -> Bool) async throws -> BridgeJSON {
        guard !busy, userConfirmed, grantCurrent() else { throw DataArchiveError.invalid("普通提醒需要有效的独立权限及本人具体批准") }
        busy = true; defer { busy = false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        let hash = BridgePoolCodec.hash(try encoder.encode(change))
        var ledger = try persistence.load(); try ledger.validate()
        if let previous = ledger.attempts.first(where: { $0.commandId == change.commandId }) {
            guard previous.requestHash == hash else { throw DataArchiveError.invalid("普通提醒commandId已用于其他内容") }
            if previous.applied { return receipt(previous) }
            guard ledger.records.first(where: { $0.id == change.reminderId })?.revision == previous.beforeRevision else {
                throw DataArchiveError.invalid("原提醒操作后已有新版本；未重放旧决定")
            }
            if previous.proposed.cancelled {
                // Removing the same identifier again has no new notification effect.
                await system.remove(previous.proposed.identifier)
            }
            let actual = try await system.pending(previous.proposed.identifier)
            let delivered = previous.proposed.cancelled ? try await system.delivered(previous.proposed.identifier) : nil
            guard previous.proposed.cancelled ? actual == nil && delivered == nil : actual == previous.proposed else {
                throw DataArchiveError.invalid("原普通提醒操作结果未知；没有自动重新排程，请核对原请求")
            }
            return try finish(previous)
        }
        let old = ledger.records.first(where: { $0.id == change.reminderId })
        if change.action == .schedule {
            guard old == nil, change.expectedRevision == nil else { throw DataArchiveError.invalid("提醒身份已存在，不能重复创建") }
        } else {
            guard let old, !old.cancelled, old.revision == change.expectedRevision else { throw DataArchiveError.invalid("提醒版本已改变或已经取消；未覆盖") }
        }
        var plan: NativeReminderPlan
        if change.action == .cancel {
            guard change.title == nil, change.body == nil, change.fireAt == nil, change.sound == nil, change.experiment == nil, let old else { throw DataArchiveError.invalid("取消提醒不能混入新的排程内容") }
            plan = old; plan.revision = hash; plan.cancelled = true
        } else {
            // Update is a full replacement, so a confirmation never conceals
            // inherited text, sound or time behind a partial patch.
            guard let title = change.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 150,
                  let body = change.body, body.count <= 2000, let fireAt = change.fireAt, fireAt > now(),
                  let sound = change.sound, let experiment = change.experiment, await system.authorized() else {
                throw DataArchiveError.invalid("普通提醒需完整标题/正文/未来时间/声音选择/实验标记，且系统已授权")
            }
            plan = .init(id: change.reminderId, revision: hash, title: title, body: body, fireAt: fireAt, sound: sound, experiment: experiment)
        }
        let attempt = NativeReminderAttempt(commandId: change.commandId, requestHash: hash, proposed: plan, beforeRevision: change.expectedRevision)
        ledger.attempts.append(attempt); try persistence.save(ledger)
        guard grantCurrent() else { throw DataArchiveError.invalid("排程前本机权限已撤回；没有继续操作") }
        if change.action != .schedule { await system.remove(plan.identifier) }
        if !plan.cancelled {
            guard grantCurrent() else { throw DataArchiveError.invalid("替换提醒前本机权限已撤回；结果需核对") }
            guard plan.fireAt > now() else { throw DataArchiveError.invalid("排程前时间已过；没有补发通知") }
            try await system.submit(plan)
        }
        let actual = try await system.pending(plan.identifier)
        let delivered = plan.cancelled ? try await system.delivered(plan.identifier) : nil
        guard plan.cancelled ? actual == nil && delivered == nil : actual == plan else { throw DataArchiveError.invalid("系统普通提醒排程/取消尚未核实；结果未知") }
        return try finish(attempt)
    }
    private func finish(_ attempt: NativeReminderAttempt) throws -> BridgeJSON {
        var ledger = try persistence.load()
        guard let index = ledger.attempts.firstIndex(where: { $0.commandId == attempt.commandId }),
              ledger.attempts[index].requestHash == attempt.requestHash,
              ledger.records.first(where: { $0.id == attempt.proposed.id })?.revision == attempt.beforeRevision else {
            throw DataArchiveError.invalid("普通提醒原操作日志丢失或已有新版本；未覆盖")
        }
        ledger.attempts[index].applied = true; ledger.attempts[index].checkedAt = now()
        ledger.records.removeAll { $0.id == attempt.proposed.id }; ledger.records.append(attempt.proposed)
        try persistence.save(ledger)
        return receipt(ledger.attempts[index])
    }
    private func receipt(_ attempt: NativeReminderAttempt) -> BridgeJSON {
        .object(["reminderId": .string(attempt.proposed.id.uuidString.lowercased()), "revision": .string(attempt.proposed.revision),
                 "stage": .string(attempt.proposed.cancelled ? "system_absence_verified" : "system_schedule_verified"), "channel": .string("ordinary_notification"),
                 "record": attempt.proposed.record, "systemIdentifier": .string(attempt.proposed.identifier), "experiment": .bool(attempt.proposed.experiment),
                 "checkedAt": attempt.checkedAt.map(NativeRemoteJSON.timestamp) ?? .null,
                 "delivered": .string("unknown"), "userSeen": .string("unknown"), "guaranteedWake": .bool(false)])
    }
}
