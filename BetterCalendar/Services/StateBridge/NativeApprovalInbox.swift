import Foundation
import Observation

nonisolated struct NativeApproval: Identifiable {
    var id: String
    var deviceId: String
    var requestHash: String
    var grantRevision: Int
    var state: String
    var expiresAt: Date
    var approvedAt: Date?
    var request: [String: BridgeJSON]
    var display: [String: BridgeJSON]
    var displayError: String?
    var result: BridgeJSON?
    init(_ value: BridgeJSON, deviceId: String) throws {
        let v = try NativeRemoteJSON.object(value)
        id = try NativeRemoteJSON.string(v["commandId"])
        self.deviceId = try NativeRemoteJSON.string(v["deviceId"])
        requestHash = try NativeRemoteJSON.string(v["requestHash"])
        grantRevision = try NativeRemoteJSON.integer(v["grantRevision"])
        state = try NativeRemoteJSON.string(v["state"])
        expiresAt = try NativeRemoteJSON.date(v["expiresAt"])
        approvedAt = v["approvedAt"] == nil || v["approvedAt"] == .null ? nil : try NativeRemoteJSON.date(v["approvedAt"])
        request = try NativeRemoteJSON.object(v["request"] ?? .null)
        display = (try? NativeRemoteJSON.object(v["display"] ?? .null)) ?? [:]
        displayError = try? NativeRemoteJSON.string(v["displayError"])
        result = v["result"] == .null ? nil : v["result"]
        guard UUID(uuidString: id) != nil, self.deviceId == deviceId, grantRevision > 0,
              v["version"] == .number(1), request["version"] == .number(1), v["serverAccepted"] == .bool(true),
              v["nativeCommandId"] == .string(id), request["commandId"] == .string(id), request["deviceId"] == .string(deviceId),
              ["awaiting_confirmation", "queued", "dispatching", "applied", "failed", "unknown", "expired", "revoked", "cancelled", "declined"].contains(state),
              BridgePoolCodec.hash(try BridgePoolCodec.encode(.object(request))) == requestHash else {
            throw DataArchiveError.invalid("审批身份、请求哈希或状态不一致；未批准")
        }
        try NativeRemoteRequestValidation.validate(request, expiresAt: v["expiresAt"])
    }
    var title: String {
        (try? NativeRemoteJSON.string(display["recordTitle"])) ?? (try? NativeRemoteJSON.string(request["title"])) ??
        (try? NativeRemoteJSON.string((try? NativeRemoteJSON.object(request["patch"] ?? .null))?["title"])) ?? "具体改动"
    }
    var deviceLabel: String { (try? NativeRemoteJSON.string(display["deviceLabel"])) ?? "本机" }
    var kind: String { (try? NativeRemoteJSON.string(request["kind"])) ?? "unknown" }
    var action: String { (try? NativeRemoteJSON.string(request["action"])) ?? "unknown" }
    var stateLabel: String {
        switch state {
        case "awaiting_confirmation": "待你确认"
        case "queued": "已同意，等待设备接手"
        case "dispatching": "设备正在处理，尚无完成回执"
        case "applied": "设备报告已应用"
        case "failed": "设备报告失败"
        case "unknown": "执行结果未知，请核对原请求"
        case "expired": "已过期，不会重新执行"
        case "revoked": "授权已撤回或改变"
        case "declined": "已拒绝"
        default: "请求已关闭"
        }
    }
    func decision(_ decision: String) -> BridgeJSON {
        .object(["commandId": .string(id), "requestHash": .string(requestHash), "grantRevision": .number(Double(grantRevision)),
                 "expectedRevision": request["expectedRevision"] ?? .null, "decision": .string(decision)])
    }
}

nonisolated struct NativeApprovalIntent: Codable, Equatable {
    var deviceId: String
    var commandId: String
    var body: BridgeJSON
}
@MainActor protocol NativeApprovalPersisting {
    func load() throws -> [NativeApprovalIntent]
    func save(_ intents: [NativeApprovalIntent]) throws
}
@MainActor final class NativeApprovalFilePersistence: NativeApprovalPersisting {
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DotStateBridge/native-approval-decisions-v1.json")
    }
    func load() throws -> [NativeApprovalIntent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let value = try JSONDecoder().decode([NativeApprovalIntent].self, from: Data(contentsOf: url))
        try validate(value); return value
    }
    func save(_ value: [NativeApprovalIntent]) throws {
        try validate(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    private func validate(_ values: [NativeApprovalIntent]) throws {
        guard values.count <= 100, Set(values.map(\.commandId)).count == values.count else { throw DataArchiveError.invalid("审批重试文件异常；保留原文件") }
        for v in values {
            let body = try NativeRemoteJSON.object(v.body)
            guard UUID(uuidString: v.commandId) != nil, body["commandId"] == .string(v.commandId),
                  [BridgeJSON.string("accept"), .string("decline")].contains(body["decision"] ?? .null),
                  Set(body.keys) == ["commandId", "requestHash", "grantRevision", "expectedRevision", "decision"] else {
                throw DataArchiveError.invalid("审批重试身份损坏；未发送")
            }
        }
    }
}
@MainActor final class NativeApprovalMemoryPersistence: NativeApprovalPersisting {
    var values: [NativeApprovalIntent] = []
    func load() throws -> [NativeApprovalIntent] { values }
    func save(_ values: [NativeApprovalIntent]) throws { self.values = values }
}
@MainActor protocol NativeApprovalNotifying {
    func authorize() async throws -> Bool
    func send(commandId: String) async throws
}

@MainActor @Observable final class NativeApprovalInbox {
    private let service: any NativeRemoteServing
    private let persistence: any NativeApprovalPersisting
    private let notifier: (any NativeApprovalNotifying)?
    private let preferences: UserDefaults
    private let writer: (any NativeItemWriting)?
    private let journal: (any NativeJournalAccessing)?
    private let now: () -> Date
    private let mayApprove: (NativeApproval) -> Bool
    private var timer: Timer?
    private var lastFailure: String?
    var entries: [NativeApproval] = []
    var selected: NativeApproval?
    var message: String?
    var busy = false
    var readComplete = false
    var retryCommandIds: [String] = []
    var notificationsEnabled: Bool { preferences.bool(forKey: "bc.nativeApprovalNotifications") }
    var pending: [NativeApproval] { entries.filter { $0.state == "awaiting_confirmation" && $0.expiresAt > now() } }
    func canDecide(_ entry: NativeApproval, accept: Bool) -> Bool {
        !busy && entry.deviceId == service.nativeDeviceId && entry.state == "awaiting_confirmation" && entry.expiresAt > now() && (!accept || entry.displayError == nil && mayApprove(entry))
    }
    init(service: any NativeRemoteServing, persistence: any NativeApprovalPersisting, notifier: (any NativeApprovalNotifying)? = nil,
         preferences: UserDefaults = .standard, writer: (any NativeItemWriting)? = nil, journal: (any NativeJournalAccessing)? = nil, now: @escaping () -> Date = Date.init, mayApprove: @escaping (NativeApproval) -> Bool = { _ in false }) {
        self.service = service; self.persistence = persistence; self.notifier = notifier; self.preferences = preferences
        self.writer = writer; self.journal = journal; self.now = now
        self.mayApprove = mayApprove
    }
    func start() {
        guard !TestHost.isActive, timer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        Task { await refresh() }
    }
    func refresh() async {
        guard !busy, let deviceId = service.nativeDeviceId else { return }
        busy = true; defer { busy = false }
        do {
            var after = "", through: String?, collected: [NativeApproval] = []
            readComplete = false
            for _ in 0..<100 {
                var body: [String: BridgeJSON] = ["after": .string(after), "limit": .number(20)]
                if let through { body["through"] = .string(through) }
                let page = try NativeRemoteJSON.object(await service.nativeRequest("native/approvals", body: .object(body)))
                guard case let .array(values) = page["commands"], values.count <= 20, case let .bool(more) = page["hasMore"] else { throw URLError(.cannotParseResponse) }
                let next = try NativeRemoteJSON.string(page["nextCursor"]), upper = try NativeRemoteJSON.string(page["through"])
                let parsed = try values.map { try NativeApproval($0, deviceId: deviceId) }, ids = parsed.map(\.id)
                guard service.nativeDeviceId == deviceId, through == nil || through == upper, ids == ids.sorted(),
                      Set(ids).count == ids.count, ids.allSatisfy({ $0 > after && $0 <= upper }),
                      next == (ids.last ?? after), !more || next > after else { throw DataArchiveError.invalid("审批分页或设备身份改变；不拼接不完整列表") }
                collected += parsed
                if !more { readComplete = true; break }; after = next; through = upper
            }
            guard readComplete else { throw DataArchiveError.invalid("审批列表未读完；保留旧列表，请刷新") }
            entries = collected; message = nil; lastFailure = nil
            let intents = try persistence.load().filter { $0.deviceId == deviceId }
            retryCommandIds = intents.map(\.commandId)
            // A persisted human decision is not silently resubmitted here.
            // Query its original state, and expose an explicit retry if needed.
            if let id = selected?.id ?? intents.first?.commandId {
                let latest = try await read(id, deviceId: deviceId)
                if let original = intents.first(where: { $0.commandId == id }),
                   latest.requestHash != (try NativeRemoteJSON.string(NativeRemoteJSON.object(original.body)["requestHash"])) {
                    throw DataArchiveError.invalid("原审批身份改变；未自动重试")
                }
                self.selected = latest
            }
            if notificationsEnabled, let notifier {
                var notified = Set(preferences.stringArray(forKey: "bc.nativeApprovalNotified") ?? [])
                for entry in pending where !notified.contains(entry.id) {
                    try await notifier.send(commandId: entry.id); notified.insert(entry.id)
                    preferences.set(Array(notified).sorted().suffix(500).map { $0 }, forKey: "bc.nativeApprovalNotified")
                }
            }
        } catch { fail(error) }
    }
    private func read(_ id: String, deviceId: String) async throws -> NativeApproval {
        var value = try NativeApproval(await service.nativeRequest("native/approval/read", body: .object(["commandId": .string(id)])), deviceId: deviceId)
        guard service.nativeDeviceId == deviceId, value.id == id else { throw DataArchiveError.invalid("审批响应身份改变；未批准") }
        if value.state != "awaiting_confirmation", let previous = selected, previous.id == value.id, previous.requestHash == value.requestHash {
            value.display = previous.display
        }
        if value.state == "awaiting_confirmation" {
            do { try localBefore(&value) } catch { value.displayError = error.localizedDescription }
        }
        return value
    }
    // User-opened native detail reads local truth; it does not export it or
    // enlarge the agent's independently granted journal.read permission.
    private func localBefore(_ value: inout NativeApproval) throws {
        let patch = try NativeRemoteJSON.object(value.request["patch"] ?? .object([:]))
        var values: [String: BridgeJSON]?
        if value.kind == "item", value.action != "create", let writer {
            let id = try NativeRemoteJSON.string(value.request["recordId"])
            guard let record = try writer.records().first(where: { $0.id.uuidString.lowercased() == id.lowercased() }),
                  .string(record.revision) == value.request["expectedRevision"] else { value.displayError = "本机事项版本已改变，先重读原事项"; return }
            values = try NativeRemoteJSON.object(record.values)
        } else if value.kind == "journal", value.action == "update", let journal {
            var query = NativeJournalQuery(includeTrash: true, limit: 50)
            let id = try NativeRemoteJSON.string(value.request["recordId"])
            for _ in 0..<100 {
                let page = try NativeRemoteJSON.object(journal.read(query, readAllowed: true))
                guard case let .array(records) = page["records"], case let .bool(more) = page["hasMore"] else { throw URLError(.cannotParseResponse) }
                if let record = try records.map(NativeRemoteJSON.object).first(where: { (try? NativeRemoteJSON.string($0["id"]))?.lowercased() == id.lowercased() }) {
                    guard record["revision"] == value.request["expectedRevision"] else { value.displayError = "本机日记版本已改变，先重读原文"; return }
                    values = try NativeRemoteJSON.object(record["values"] ?? .null); break
                }
                if !more { break }; query.cursor = try NativeRemoteJSON.string(page["nextCursor"])
            }
            if values == nil { value.displayError = "本机没有读到完整原日记，未批准"; return }
        }
        if let values {
            var before: [String: BridgeJSON] = [:]
            for key in patch.keys { guard let original = values[key] else { value.displayError = "原字段未知，不能当作空白"; return }; before[key] = original }
            value.display["before"] = .object(before)
            if let title = values["title"] { value.display["recordTitle"] = title }
            value.display["beforeSource"] = .string("本机已保存数据；设备执行前仍会核对版本")
        }
        if value.action == "update" {
            let before = (try? NativeRemoteJSON.object(value.display["before"] ?? .null)) ?? [:]
            if patch.keys.contains(where: { before[$0] == nil }) { value.displayError = "未读取完整修改前内容；不把未知当作空白" }
        }
    }
    func open(_ id: String) async {
        guard !busy, let deviceId = service.nativeDeviceId else { return }; busy = true; defer { busy = false }
        selected = nil
        do { selected = try await read(id, deviceId: deviceId); message = nil } catch { fail(error) }
    }
    func decide(_ decision: String) async {
        guard !busy, let value = selected, let deviceId = service.nativeDeviceId,
              value.deviceId == deviceId, value.state == "awaiting_confirmation", value.expiresAt > now(),
              ["accept", "decline"].contains(decision), decision != "accept" || value.displayError == nil && mayApprove(value) else { return }
        busy = true; defer { busy = false }
        do {
            var intents = try persistence.load()
            let intent = NativeApprovalIntent(deviceId: deviceId, commandId: value.id, body: value.decision(decision))
            if let existing = intents.first(where: { $0.commandId == value.id }), existing != intent { throw DataArchiveError.invalid("有尚未核对的原审批决定，不能换成相反选择") }
            if !intents.contains(intent) { intents.append(intent); try persistence.save(intents) }
            retryCommandIds = intents.filter { $0.deviceId == deviceId }.map(\.commandId)
            try await transmit(intent)
        } catch { fail(error) }
    }
    func retryOriginalDecision() async {
        guard !busy, let selected, let deviceId = service.nativeDeviceId else { return }; busy = true; defer { busy = false }
        do {
            guard let intent = try persistence.load().first(where: { $0.commandId == selected.id && $0.deviceId == deviceId }) else { return }
            try await transmit(intent)
        } catch { fail(error) }
    }
    private func transmit(_ intent: NativeApprovalIntent) async throws {
        guard service.nativeDeviceId == intent.deviceId else { throw DataArchiveError.invalid("设备配置已改变，未发送原审批") }
        do {
            var value = try NativeApproval(await service.nativeRequest("native/approval/decide", body: intent.body), deviceId: intent.deviceId)
            guard value.id == intent.commandId, value.requestHash == (try NativeRemoteJSON.string(NativeRemoteJSON.object(intent.body)["requestHash"])) else { throw DataArchiveError.invalid("审批回执与原请求不一致；结果未知") }
            let decision = try NativeRemoteJSON.string(NativeRemoteJSON.object(intent.body)["decision"])
            guard decision == "accept" ? value.approvedAt != nil && ["queued", "dispatching", "applied", "failed", "unknown", "expired", "revoked"].contains(value.state)
                : ["declined", "expired", "revoked"].contains(value.state) else { throw DataArchiveError.invalid("尚未收到原决定的有效回执；保留原请求，不标记已确认") }
            if let previous = selected, previous.id == value.id, previous.requestHash == value.requestHash { value.display = previous.display }
            selected = value
            var intents = try persistence.load(); intents.removeAll { $0 == intent }; try persistence.save(intents)
            retryCommandIds = intents.filter { $0.deviceId == intent.deviceId }.map(\.commandId)
            entries.removeAll { $0.id == value.id }; message = value.stateLabel
        } catch {
            // Keep the exact persisted request on lost responses; a read does
            // not approve, replace, or silently retry it after restart.
            if let latest = try? await read(intent.commandId, deviceId: intent.deviceId) { selected = latest }
            throw error
        }
    }
    func enableNotifications() async {
        guard let notifier else { return }
        do {
            guard try await notifier.authorize() else { throw DataArchiveError.invalid("系统未允许通知；审批仍可在 BC 内完成") }
            preferences.set(true, forKey: "bc.nativeApprovalNotifications")
            preferences.set(pending.map(\.id), forKey: "bc.nativeApprovalNotified")
            message = "只提醒后续新请求；点通知只打开详情"
        } catch { fail(error) }
    }
    func disableNotifications() { preferences.set(false, forKey: "bc.nativeApprovalNotifications") }
    private func fail(_ error: Error) { message = error.localizedDescription; if lastFailure != message { DevLog.shared.warn("BC 审批", message ?? "审批失败"); lastFailure = message } }
}
