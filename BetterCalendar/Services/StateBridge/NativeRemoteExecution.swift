import Foundation
import Observation

nonisolated struct NativeRemoteGrant: Codable {
    var deviceId: String
    var revision: Int
    var capabilities: [String]
    var expiresAt: Date
    var synchronized = false
}
nonisolated struct NativeRemoteAttempt: Codable {
    var commandId: String
    var requestHash: String
    var attemptId: String
    var envelope: BridgeJSON
    var phase = "prepared"
    var outcome: String?
    var receipt: BridgeJSON?
    var attempts = 0
    var lastError: String?
    var receivedAt: Date
    var updatedAt: Date
}
nonisolated struct NativeRemoteFailure: Codable {
    var at: Date
    var commandId: String?
    var error: String
}
nonisolated struct NativeRemoteFile: Codable {
    var version = 1
    var grant: NativeRemoteGrant?
    var requests: [NativeRemoteAttempt] = []
    var failures: [NativeRemoteFailure] = []
    func validate() throws {
        guard version == 1, failures.count <= 10000, requests.count <= 1000, Set(requests.map(\.commandId)).count == requests.count,
              requests.allSatisfy({ UUID(uuidString: $0.commandId) != nil && UUID(uuidString: $0.attemptId) != nil &&
                  $0.requestHash.count == 64 && ["prepared", "claimed", "result", "reported"].contains($0.phase) &&
                  (!["result", "reported"].contains($0.phase) || ($0.outcome != nil && $0.receipt != nil)) }) else {
            throw DataArchiveError.invalid("远程操作日志有损坏，保留原文件，未重放")
        }
    }
}
@MainActor protocol NativeRemotePersisting {
    func load() throws -> NativeRemoteFile
    func save(_ file: NativeRemoteFile) throws
}
@MainActor final class NativeRemoteFilePersistence: NativeRemotePersisting {
    let location: URL
    init(location: URL? = nil) {
        self.location = location ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DotStateBridge/native-remote-v1.json")
    }
    func load() throws -> NativeRemoteFile {
        guard FileManager.default.fileExists(atPath: location.path) else { return .init() }
        let file = try JSONDecoder().decode(NativeRemoteFile.self, from: Data(contentsOf: location))
        try file.validate(); return file
    }
    func save(_ file: NativeRemoteFile) throws {
        try file.validate(); let data = try JSONEncoder().encode(file)
        guard data.count <= 16 * 1024 * 1024 else { throw DataArchiveError.invalid("远程操作日志容量已满，保留原文件") }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: location, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: location.path)
        #endif
    }
}
@MainActor final class NativeRemoteMemoryPersistence: NativeRemotePersisting {
    var file = NativeRemoteFile()
    func load() throws -> NativeRemoteFile { file }
    func save(_ file: NativeRemoteFile) throws { try file.validate(); self.file = file }
}
@MainActor protocol NativeRemoteServing {
    var nativeDeviceId: String? { get }
    func nativeRequest(_ path: String, body: BridgeJSON) async throws -> BridgeJSON
}
nonisolated enum NativeRemoteJSON {
    static func object(_ v: BridgeJSON) throws -> [String: BridgeJSON] {
        guard case let .object(fields) = v else { throw URLError(.cannotParseResponse) }; return fields
    }
    static func string(_ v: BridgeJSON?) throws -> String {
        guard case let .string(s) = v else { throw URLError(.cannotParseResponse) }; return s
    }
    static func integer(_ v: BridgeJSON?) throws -> Int {
        guard case let .number(n) = v, n.isFinite, n >= 0, n.rounded() == n, n < Double(Int.max) else { throw URLError(.cannotParseResponse) }; return Int(n)
    }
    static func date(_ v: BridgeJSON?) throws -> Date {
        let string = try string(v), formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: string) else { throw URLError(.cannotParseResponse) }; return date
    }
    static func timestamp(_ date: Date) -> BridgeJSON {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: date))
    }
}

/// The remote model never supplies native authorization. The independent local
/// grant, authenticated server confirmation and fixed payload are checked here.
@MainActor @Observable final class NativeRemoteExecutor {
    private let service: any NativeRemoteServing
    private let persistence: any NativeRemotePersisting
    private let writer: any NativeItemWriting
    private let alarms: any NativeAlarmScheduling
    private let journal: (any NativeJournalAccessing)?
    private let now: () -> Date
    private var timer: Timer?
    private var polling = false
    private var granting = false
    private var lastFailure: String?
    var message = "对话操作尚未启用"
    var allowItems = false
    var allowAlarms = false
    var allowJournalRead = false
    var allowJournalWrite = false
    var grantRevision = 0
    var expiresAt: Date?
    var deviceId: String? { service.nativeDeviceId }
    var alarmSupported: Bool { alarms.inspect().supported }
    init(service: any NativeRemoteServing, persistence: any NativeRemotePersisting,
         writer: any NativeItemWriting, alarms: any NativeAlarmScheduling, journal: (any NativeJournalAccessing)? = nil, now: @escaping () -> Date = Date.init) {
        self.service = service; self.persistence = persistence; self.writer = writer; self.alarms = alarms; self.journal = journal; self.now = now
        refreshLocal()
    }
    func refreshLocal() {
        do {
            let grant = try persistence.load().grant
            grantRevision = grant?.revision ?? 0; expiresAt = grant?.expiresAt
            let active = grant?.synchronized == true && grant?.deviceId == deviceId && (grant?.expiresAt ?? .distantPast) > now()
            allowItems = active && (grant?.capabilities.contains("item.create") ?? false)
            allowAlarms = active && (grant?.capabilities.contains("alarm.schedule") ?? false)
            allowJournalRead = active && (grant?.capabilities.contains("journal.read") ?? false)
            allowJournalWrite = active && (grant?.capabilities.contains("journal.update") ?? false)
            message = active ? "每次改动都需在 Dots 对话里点确认；本机执行" : "对话操作未启用、未完成授权同步或已到期"
        } catch { fail(error) }
    }
    // Called only by the human's native settings button, never a remote tool.
    func setCapabilities(items: Bool, alarm: Bool, journalRead: Bool = false, journalWrite: Bool = false) async {
        guard !granting, let deviceId else { message = "先配置个人状态连接"; return }
        granting = true; defer { granting = false }
        do {
            // A human change immediately disables local execution, even if
            // offline revocation cannot yet be delivered to the server.
            var locked = try persistence.load(); locked.grant?.synchronized = false; try persistence.save(locked)
            refreshLocal()
            if alarm { guard alarms.inspect().supported, alarms.inspect().authorization == "authorized" else { throw DataArchiveError.invalid("先在原生闹钟面板主动取得系统授权") } }
            if journalRead || journalWrite { guard journal != nil else { throw DataArchiveError.invalid("本机尚未提供日记入口") } }
            let server = try NativeRemoteJSON.object(await service.nativeRequest("native/grant/read", body: .object([:])))
            let revision = try NativeRemoteJSON.integer(server["revision"]) + 1
            let caps = (items ? ["item.create", "item.update", "item.delete", "item.restore"] : []) + (alarm ? ["alarm.schedule", "alarm.cancel"] : []) +
                (journalRead ? ["journal.read"] : []) + (journalWrite ? ["journal.create", "journal.update"] : [])
            let grant = NativeRemoteGrant(deviceId: deviceId, revision: revision, capabilities: caps, expiresAt: now().addingTimeInterval(29 * 86400))
            var file = try persistence.load(); file.grant = grant; try persistence.save(file)
            let result = try NativeRemoteJSON.object(await service.nativeRequest("native/grant", body: .object([
                "revision": .number(Double(revision)), "capabilities": .array(caps.map(BridgeJSON.string)), "expiresAt": NativeRemoteJSON.timestamp(grant.expiresAt)
            ])))
            guard service.nativeDeviceId == deviceId, try NativeRemoteJSON.integer(result["revision"]) == revision else { throw URLError(.cannotParseResponse) }
            file = try persistence.load(); guard file.grant?.revision == revision else { throw DataArchiveError.invalid("授权在同步时改变，未启用") }
            file.grant?.synchronized = true; try persistence.save(file); refreshLocal()
        } catch { refreshLocal(); fail(error) }
    }
    func startPolling() {
        guard !TestHost.isActive, timer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in await self?.poll() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        Task { await poll() }
    }
    func poll() async {
        guard !polling, !granting, let deviceId else { return }
        polling = true; defer { polling = false }
        do {
            let file = try persistence.load()
            // Retransmit saved outcomes even after local capability revocation.
            for attempt in file.requests where attempt.phase == "result" { try await report(attempt) }
            guard let grant = try persistence.load().grant, grant.synchronized, grant.deviceId == deviceId,
                  grant.expiresAt > now(), !grant.capabilities.isEmpty else { return }
            var after = "", through: String? = nil
            for _ in 0..<20 {
                var input: [String: BridgeJSON] = ["after": .string(after), "limit": .number(10)]
                if let through { input["through"] = .string(through) }
                let page = try NativeRemoteJSON.object(await service.nativeRequest("native/pending", body: .object(input)))
                guard case let .array(commands) = page["commands"], commands.count <= 10,
                      case let .bool(hasMore) = page["hasMore"] else { throw URLError(.cannotParseResponse) }
                let next = try NativeRemoteJSON.string(page["nextCursor"]), upper = try NativeRemoteJSON.string(page["through"])
                guard through == nil || through == upper, !hasMore || next > after else { throw URLError(.cannotParseResponse) }
                // Validate the whole offered page before operating any member.
                for command in commands { try validate(command, deviceId: deviceId) }
                for command in commands { try await execute(command, deviceId: deviceId) }
                if !hasMore { break }; after = next; through = upper
            }
            lastFailure = nil
        } catch {
            do {
                var failed = try persistence.load()
                let index = failed.requests.firstIndex { $0.phase != "reported" }
                if let index { failed.requests[index].lastError = error.localizedDescription; failed.requests[index].updatedAt = now() }
                failed.failures.append(.init(at: now(), commandId: index.map { failed.requests[$0].commandId }, error: error.localizedDescription))
                try persistence.save(failed)
            } catch { DevLog.shared.warn("对话操作日志", "失败记录无法保存；原日志保留，未标记完成") }
            fail(error)
        }
    }
    private func validate(_ envelope: BridgeJSON, deviceId: String) throws {
        let v = try NativeRemoteJSON.object(envelope), r = try NativeRemoteJSON.object(v["request"] ?? .null)
        let id = try NativeRemoteJSON.string(v["commandId"]), hash = try NativeRemoteJSON.string(v["requestHash"])
        guard try NativeRemoteJSON.string(v["deviceId"]) == deviceId, try NativeRemoteJSON.string(r["deviceId"]) == deviceId,
              UUID(uuidString: id) != nil, try NativeRemoteJSON.string(r["commandId"]) == id,
              try NativeRemoteJSON.integer(r["version"]) == 1, hash.count == 64,
              BridgePoolCodec.hash(try BridgePoolCodec.encode(.object(r))) == hash else { throw DataArchiveError.invalid("请求原文、设备身份或哈希不一致，未执行整页") }
        let kind = try NativeRemoteJSON.string(r["kind"]), action = try NativeRemoteJSON.string(r["action"])
        guard kind == "item" && ["create", "update", "delete", "restore"].contains(action) || kind == "alarm" && ["schedule", "cancel"].contains(action) || kind == "journal" && ["read", "create", "update"].contains(action),
              try NativeRemoteJSON.string(v["permission"]) == kind + "." + action else { throw URLError(.cannotParseResponse) }
        _ = try NativeRemoteJSON.date(r["occurredAt"]); _ = try NativeRemoteJSON.date(v["expiresAt"])
    }
    private func execute(_ envelope: BridgeJSON, deviceId: String) async throws {
        let v = try NativeRemoteJSON.object(envelope), id = try NativeRemoteJSON.string(v["commandId"])
        let state = try NativeRemoteJSON.string(v["state"])
        guard ["queued", "dispatching"].contains(state) else { return }
        var file = try persistence.load()
        if let saved = file.requests.first(where: { $0.commandId == id }) {
            if saved.phase == "reported" { return }
            if saved.phase == "result" { try await report(saved); return }
            guard try NativeRemoteJSON.string(v["requestHash"]) == saved.requestHash else { throw DataArchiveError.invalid("旧请求身份的内容改变，未执行") }
        } else {
            // A dispatching command without our persisted attempt means lost
            // local state; it must not acquire another attempt or re-execute.
            guard state == "queued" else { throw DataArchiveError.invalid("设备接手过但本地执行日志缺失，结果未知，不盲目重放") }
            let at = now()
            file.requests.append(.init(commandId: id, requestHash: try NativeRemoteJSON.string(v["requestHash"]),
                                       attemptId: UUID().uuidString.lowercased(), envelope: envelope, receivedAt: at, updatedAt: at))
            try persistence.save(file)
        }
        guard var attempt = try persistence.load().requests.first(where: { $0.commandId == id }) else { throw URLError(.cannotParseResponse) }
        attempt.attempts += 1; attempt.updatedAt = now(); try update(attempt)
        let claim = try await service.nativeRequest("native/claim", body: identity(attempt))
        try validate(claim, deviceId: deviceId)
        let c = try NativeRemoteJSON.object(claim)
        if ["applied", "failed", "unknown"].contains(try NativeRemoteJSON.string(c["state"])) {
            guard let receipt = c["result"], receipt != .null else { throw URLError(.cannotParseResponse) }
            attempt.phase = "reported"; attempt.outcome = try NativeRemoteJSON.string(c["state"]); attempt.receipt = receipt; try update(attempt); return
        }
        let readOnly = try NativeRemoteJSON.string(c["permission"]) == "journal.read"
        guard try NativeRemoteJSON.string(c["state"]) == "dispatching",
              try NativeRemoteJSON.string(c["attemptId"]) == attempt.attemptId,
              try NativeRemoteJSON.string(c["requestHash"]) == attempt.requestHash,
              (readOnly || (c["approvedAt"] != .null && c["approvedAt"] != nil)) else { throw DataArchiveError.invalid("未取得经用户确认的设备执行权") }
        attempt.envelope = claim; attempt.phase = "claimed"; try update(attempt)
        let local = try persistence.load().grant
        guard let local, local.synchronized, local.deviceId == deviceId, service.nativeDeviceId == deviceId,
              try NativeRemoteJSON.integer(c["grantRevision"]) == local.revision, local.expiresAt > now(),
              local.capabilities.contains(try NativeRemoteJSON.string(c["permission"])), try NativeRemoteJSON.date(c["expiresAt"]) > now() else {
            attempt.outcome = "failed"; attempt.receipt = .object(["reason": .string("本机权限在接手后变更或到期，未执行")]); attempt.phase = "result"; try update(attempt); try await report(attempt); return
        }
        // No suspension between the independent checks and synchronous item
        // mutation. AlarmKit async uses its durable native intent/reconciliation.
        do {
            let r = try NativeRemoteJSON.object(c["request"] ?? .null), ref = "chat-confirmation:" + id
            let commandId = UUID(uuidString: id)!
            if try NativeRemoteJSON.string(r["kind"]) == "item" {
                guard let recordId = UUID(uuidString: try NativeRemoteJSON.string(r["recordId"])),
                      let action = NativeItemCommand.Action(rawValue: try NativeRemoteJSON.string(r["action"])) else { throw URLError(.cannotParseResponse) }
                let command = NativeItemCommand(commandId: commandId, recordId: recordId, action: action,
                                                expectedRevision: r["expectedRevision"].flatMap { if case let .string(s) = $0 { s } else { nil } },
                                                patch: try NativeRemoteJSON.object(r["patch"] ?? .object([:])),
                                                occurredAt: try NativeRemoteJSON.date(r["occurredAt"]), userAuthorizationRef: ref)
                attempt.receipt = try writer.execute(command, userConfirmed: true)
            } else if try NativeRemoteJSON.string(r["kind"]) == "journal" {
                guard let journal else { throw DataArchiveError.invalid("本机尚未提供日记入口") }
                if readOnly {
                    let q = try NativeRemoteJSON.object(r["query"] ?? .object([:]))
                    var query = NativeJournalQuery()
                    if let start = q["start"] { query.start = try NativeRemoteJSON.date(start) }
                    if let end = q["end"] { query.end = try NativeRemoteJSON.date(end) }
                    if let text = q["text"] { query.text = try NativeRemoteJSON.string(text) }
                    if let trash = q["includeTrash"] { guard case let .bool(value) = trash else { throw URLError(.cannotParseResponse) }; query.includeTrash = value }
                    if let limit = q["limit"] { query.limit = try NativeRemoteJSON.integer(limit) }
                    if let cursor = q["cursor"] { query.cursor = try NativeRemoteJSON.string(cursor) }
                    attempt.receipt = try journal.read(query, readAllowed: true)
                } else {
                    guard let recordId = UUID(uuidString: try NativeRemoteJSON.string(r["recordId"])),
                          let action = NativeJournalCommand.Action(rawValue: try NativeRemoteJSON.string(r["action"])) else { throw URLError(.cannotParseResponse) }
                    attempt.receipt = try journal.execute(.init(commandId: commandId, recordId: recordId, action: action,
                        entryDate: try r["entryDate"].map { try NativeRemoteJSON.date($0) },
                        expectedRevision: r["expectedRevision"].flatMap { if case let .string(s) = $0 { s } else { nil } },
                        patch: try NativeRemoteJSON.object(r["patch"] ?? .object([:])), occurredAt: try NativeRemoteJSON.date(r["occurredAt"]),
                        userAuthorizationRef: ref), userConfirmed: true)
                }
            } else if try NativeRemoteJSON.string(r["action"]) == "schedule" {
                attempt.receipt = try await alarms.schedule(.init(commandId: commandId, fireAt: try NativeRemoteJSON.date(r["fireAt"]),
                                                                  title: try NativeRemoteJSON.string(r["title"]), userAuthorizationRef: ref), userConfirmed: true)
            } else {
                guard let alarmId = UUID(uuidString: try NativeRemoteJSON.string(r["alarmId"])) else { throw URLError(.cannotParseResponse) }
                attempt.receipt = try alarms.cancel(commandId: commandId, alarmId: alarmId, userConfirmed: true)
            }
            attempt.outcome = "applied"
        } catch {
            // An error may occur after the side effect (receipt disk failure or
            // system response loss). Preserve unknown rather than false failure.
            attempt.outcome = readOnly ? "failed" : "unknown"; attempt.receipt = .object(["error": .string(error.localizedDescription), "effect": .string(readOnly ? "read_only_no_mutation" : "unknown_check_native_intent")])
            attempt.lastError = error.localizedDescription; DevLog.shared.warn("对话操作", error.localizedDescription)
        }
        attempt.phase = "result"; attempt.updatedAt = now(); try update(attempt)
        try await report(attempt)
    }
    private func identity(_ a: NativeRemoteAttempt) -> BridgeJSON {
        .object(["commandId": .string(a.commandId), "requestHash": .string(a.requestHash), "attemptId": .string(a.attemptId)])
    }
    private func update(_ attempt: NativeRemoteAttempt) throws {
        var file = try persistence.load()
        guard let index = file.requests.firstIndex(where: { $0.commandId == attempt.commandId }) else { throw URLError(.cannotParseResponse) }
        file.requests[index] = attempt; try persistence.save(file)
    }
    private func report(_ attempt: NativeRemoteAttempt) async throws {
        guard case var .object(body) = identity(attempt), let outcome = attempt.outcome, let receipt = attempt.receipt else { throw URLError(.cannotParseResponse) }
        body["outcome"] = .string(outcome); body["receipt"] = receipt
        let result = try NativeRemoteJSON.object(await service.nativeRequest("native/receipt", body: .object(body)))
        guard try NativeRemoteJSON.string(result["commandId"]) == attempt.commandId,
              try NativeRemoteJSON.string(result["state"]) == outcome,
              try NativeRemoteJSON.string(result["requestHash"]) == attempt.requestHash else { throw URLError(.cannotParseResponse) }
        var saved = attempt; saved.phase = "reported"; saved.updatedAt = now(); try update(saved)
        let isRead = (try? NativeRemoteJSON.object(attempt.envelope)["permission"]) == .string("journal.read")
        message = outcome == "applied" ? (isRead ? "日记读取结果已回传；是否读完以分页信息为准" : "设备执行结果已回传；其他设备同步仍需核对") : "结果已回传：" + outcome + "；请查看原请求"
    }
    private func fail(_ error: Error) {
        message = error.localizedDescription
        if lastFailure != message { DevLog.shared.warn("对话操作", message); lastFailure = message }
    }
}
