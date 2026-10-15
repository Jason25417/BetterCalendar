import Foundation
import Observation

nonisolated enum NativeApprovalDisplayDecision: String {
    case accept, decline
    var title: String { self == .accept ? "显示测试完成：已收到确认" : "显示测试结束：已收到不执行" }
    var detail: String { "未修改任何事项、计时、闹钟或权限。你可以关闭此页面。" }
}

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
    var review: NativeApprovalReviewContext?
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
        review = try v["reviewContext"].flatMap { $0 == .null ? nil : try NativeApprovalReviewContext($0) }
        guard UUID(uuidString: id) != nil, !self.deviceId.isEmpty, grantRevision > 0,
              self.deviceId == deviceId ? review == nil : review?.reviewerDeviceId == deviceId && review?.executionDeviceId == self.deviceId,
              v["version"] == .number(1), request["version"] == .number(1), v["serverAccepted"] == .bool(true),
              v["nativeCommandId"] == .string(id), request["commandId"] == .string(id), request["deviceId"] == .string(self.deviceId),
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
    var changeValues: [String: BridgeJSON] {
        if kind == "timer", action == "start" {
            var values = request.filter { ["title", "mode", "focusMinutes", "experiment"].contains($0.key) }
            if values["mode"] == nil { values["mode"] = .string("light") }
            if values["experiment"] == nil { values["experiment"] = .bool(false) }
            return values
        }
        if kind == "reminder" {
            return action == "cancel" ? [:] : request.filter { ["title", "body", "fireAt", "sound", "experiment"].contains($0.key) }
        }
        return (try? NativeRemoteJSON.object(request["patch"] ?? .null)) ?? [:]
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
        var body: [String: BridgeJSON] = ["commandId": .string(id), "requestHash": .string(requestHash), "grantRevision": .number(Double(grantRevision)),
                 "expectedRevision": request["expectedRevision"] ?? .null, "decision": .string(decision)]
        if let review {
            body["reviewerGrantRevision"] = .number(Double(review.grantRevision))
            body["reviewerPolicyRevision"] = .number(Double(review.policyRevision))
        }
        return .object(body)
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
                  Set(body.keys).subtracting(["reviewerGrantRevision", "reviewerPolicyRevision"]) == ["commandId", "requestHash", "grantRevision", "expectedRevision", "decision"],
                  (body["reviewerGrantRevision"] == nil && body["reviewerPolicyRevision"] == nil) ||
                    ((try? NativeRemoteJSON.integer(body["reviewerGrantRevision"])) ?? 0 > 0 && (try? NativeRemoteJSON.integer(body["reviewerPolicyRevision"])) ?? 0 > 0) else {
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
    func send(_ approval: NativeApproval) async throws
    func authorization() async -> NativeApprovalNotificationAuthorization
    func sendDisplayTest() async throws
    func reconcile(pendingCommandIds: Set<String>) async
    func feedback(commandId: String, title: String, body: String) async throws
    func contains(commandId: String) async -> Bool
}

extension NativeApprovalNotifying {
    func contains(commandId: String) async -> Bool { false }
}

@MainActor @Observable final class NativeApprovalInbox {
    private let service: any NativeRemoteServing
    private let persistence: any NativeApprovalPersisting
    private let notifier: (any NativeApprovalNotifying)?
    private let preferences: UserDefaults
    private let noticeDelivery: NativeApprovalNoticeDelivery?
    private let writer: (any NativeItemWriting)?
    private let reminders: NativeReminderScheduler?
    private let journal: (any NativeJournalAccessing)?
    private let now: () -> Date
    private let mayReadOther: () -> Bool
    private let mayReviewOther: (NativeApprovalReviewContext) -> Bool
    private let mayApprove: (NativeApproval) -> Bool
    private var timer: Timer?
    private var lastFailure: String?
    private var requestedOpenId: String?
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    let isDisplayTest: Bool
    var entries: [NativeApproval] = []
    var selected: NativeApproval?
    var displayTestDecision: NativeApprovalDisplayDecision?
    var message: String?
    var busy = false
    var readComplete = false
    var retryCommandIds: [String] = []
    private(set) var policy = NativeApprovalPolicy()
    private(set) var crossReviewLocallyEnabled: Bool
    var crossReviewEnabled: Bool { crossReviewLocallyEnabled && policy.reviewOtherDevices && mayReadOther() }
    var primaryNotificationsHere: Bool { policy.primaryDeviceId != nil && policy.primaryDeviceId == service.nativeDeviceId }
    private(set) var notificationsEnabled: Bool
    private(set) var notificationAuthorization: NativeApprovalNotificationAuthorization = .unknown
    var pending: [NativeApproval] { entries.filter { $0.state == "awaiting_confirmation" && $0.expiresAt > now() } }
    func canDecide(_ entry: NativeApproval, accept: Bool) -> Bool {
        !busy && mayReview(entry) && entry.state == "awaiting_confirmation" && entry.expiresAt > now() && (!accept || entry.displayError == nil && (entry.review != nil || mayApprove(entry)))
    }
    init(service: any NativeRemoteServing, persistence: any NativeApprovalPersisting, notifier: (any NativeApprovalNotifying)? = nil,
         preferences: UserDefaults = .standard, notices: (any NativeApprovalNoticePersisting)? = nil, writer: (any NativeItemWriting)? = nil, journal: (any NativeJournalAccessing)? = nil, reminders: NativeReminderScheduler? = nil, now: @escaping () -> Date = Date.init, mayApprove: @escaping (NativeApproval) -> Bool = { _ in false }, mayReviewOther: @escaping (NativeApprovalReviewContext) -> Bool = { _ in false }, mayReadOther: @escaping () -> Bool = { false }, isDisplayTest: Bool = false) {
        self.service = service; self.persistence = persistence; self.notifier = notifier; self.preferences = preferences
        self.noticeDelivery = notifier.map { NativeApprovalNoticeDelivery(service: service, notifier: $0, persistence: notices ?? NativeApprovalNoticeMemoryPersistence(), now: now) }
        self.crossReviewLocallyEnabled = preferences.bool(forKey: "bc.nativeApprovalCrossReview")
        self.reminders = reminders; self.writer = writer; self.journal = journal; self.now = now
        self.mayReadOther = mayReadOther; self.mayReviewOther = mayReviewOther; self.mayApprove = mayApprove; self.isDisplayTest = isDisplayTest
        self.notificationsEnabled = preferences.bool(forKey: "bc.nativeApprovalNotifications")
    }
    func start() {
        guard !TestHost.isActive, timer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        Task { await refresh() }
    }
    func refresh() async {
        guard !busy, let deviceId = service.nativeDeviceId else { return }
        busy = true; defer { finishOperation() }
        do {
            if !isDisplayTest { try await refreshPolicy(deviceId) }
            var after = "", through: String?, collected: [NativeApproval] = []
            readComplete = false
            for _ in 0..<100 {
                var body: [String: BridgeJSON] = ["after": .string(after), "limit": .number(20), "includeShared": .bool(crossReviewEnabled)]
                if let through { body["through"] = .string(through) }
                let page = try NativeRemoteJSON.object(await service.nativeRequest("native/approvals", body: .object(body)))
                guard case let .array(values) = page["commands"], values.count <= 20, case let .bool(more) = page["hasMore"] else { throw URLError(.cannotParseResponse) }
                let next = try NativeRemoteJSON.string(page["nextCursor"]), upper = try NativeRemoteJSON.string(page["through"])
                let parsed = try values.map { try NativeApproval($0, deviceId: deviceId) }, ids = parsed.map(\.id)
                guard service.nativeDeviceId == deviceId, through == nil || through == upper, ids == ids.sorted(),
                      Set(ids).count == ids.count, parsed.allSatisfy({ $0.deviceId == deviceId || crossReviewEnabled }), ids.allSatisfy({ $0 > after && $0 <= upper }),
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
            if let notifier, !isDisplayTest {
                notificationAuthorization = await notifier.authorization()
                await notifier.reconcile(pendingCommandIds: Set(pending.map(\.id)))
            }
            if !isDisplayTest { try await noticeDelivery?.flushEvidence() }
            if notificationsEnabled, notifier != nil, !isDisplayTest {
                let pendingIds = Set(pending.map(\.id))
                var notified = Set(preferences.stringArray(forKey: "bc.nativeApprovalNotified") ?? []).intersection(pendingIds)
                // Retain all current pending IDs (bounded by the verified 100 x 20
                // page window); random UUID sorting must not evict live IDs.
                preferences.set(Array(notified).sorted(), forKey: "bc.nativeApprovalNotified")
                for entry in pending where !notified.contains(entry.id) {
                    let prepared = try await read(entry.id, deviceId: deviceId)
                    guard prepared.state == "awaiting_confirmation", prepared.expiresAt > now() else { continue }
                    if let noticeDelivery, try await noticeDelivery.submit(prepared) {
                        notified.insert(entry.id)
                        preferences.set(Array(notified).sorted(), forKey: "bc.nativeApprovalNotified")
                    } else if let warning = noticeDelivery?.warning { fail(DataArchiveError.invalid(warning)) }
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
        guard mayReview(value) else { throw DataArchiveError.invalid("本机尚未允许跨设备核对，或审核权限已变更") }
        if value.state == "awaiting_confirmation" {
            if value.deviceId == deviceId { do { try localBefore(&value) } catch { value.displayError = error.localizedDescription } }
            else if value.action == "update" || value.kind == "reminder" && value.action == "cancel" {
                let patch = value.kind == "reminder" ? Dictionary(uniqueKeysWithValues: ["title", "body", "fireAt", "sound", "experiment"].map { ($0, BridgeJSON.null) }) : value.changeValues
                let before = (try? NativeRemoteJSON.object(value.display["before"] ?? .null)) ?? [:]
                if patch.keys.contains(where: { before[$0] == nil }) { value.displayError = "指定设备的修改前内容未读全；不能批准" }
            }
        }
        return value
    }
    // User-opened native detail reads local truth; it does not export it or
    // enlarge the agent's independently granted journal.read permission.
    private func localBefore(_ value: inout NativeApproval) throws {
        if value.kind == "reminder", ["update", "cancel"].contains(value.action) {
            guard let reminders, let id = UUID(uuidString: try NativeRemoteJSON.string(value.request["reminderId"])),
                  let record = try reminders.records().first(where: { $0.id == id }), !record.cancelled,
                  value.request["expectedRevision"] == .string(record.revision) else { value.displayError = "本机原提醒或版本已改变，不能批准"; return }
            var fields = try NativeRemoteJSON.object(record.record); fields.removeValue(forKey: "reminderId"); fields.removeValue(forKey: "revision"); fields.removeValue(forKey: "cancelled")
            value.display["before"] = .object(fields); value.display["recordTitle"] = .string(record.title)
            value.display["beforeSource"] = .string("本机已保存的普通提醒；执行前会再次核对版本")
            value.displayError = nil
            return
        }
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
    private func mayReview(_ entry: NativeApproval) -> Bool {
        guard let device = service.nativeDeviceId else { return false }
        if entry.deviceId == device { return entry.review == nil }
        guard crossReviewEnabled, let review = entry.review else { return false }
        return review.reviewerDeviceId == device && review.executionDeviceId == entry.deviceId &&
            review.policyRevision == policy.revision && review.expiresAt > now() && mayReviewOther(review)
    }
    private func refreshPolicy(_ device: String) async throws {
        var latest = try NativeApprovalPolicy(await service.nativeRequest("native/approval-policy/read", body: .object([:])))
        guard service.nativeDeviceId == device else { throw DataArchiveError.invalid("审批设置响应设备已改变") }
        if preferences.bool(forKey: "bc.nativeApprovalPendingRevoke"), latest.reviewOtherDevices {
            latest = try NativeApprovalPolicy(await service.nativeRequest("native/approval-policy/configure", body: .object([
                "expectedRevision": .number(Double(latest.revision)), "reviewOtherDevices": .bool(false)])))
            guard !latest.reviewOtherDevices else { throw DataArchiveError.invalid("服务器尚未确认关闭跨设备审批；本机已锁定") }
            preferences.set(false, forKey: "bc.nativeApprovalPendingRevoke")
        }
        policy = latest
    }
    func configurePolicy(review: Bool? = nil, primaryHere: Bool? = nil) async {
        guard !isDisplayTest, !busy, let device = service.nativeDeviceId else { return }
        if review == false {
            crossReviewLocallyEnabled = false; preferences.set(false, forKey: "bc.nativeApprovalCrossReview")
            preferences.set(true, forKey: "bc.nativeApprovalPendingRevoke")
            entries.removeAll { $0.deviceId != device }
            if selected?.deviceId != device { selected = nil }
        }
        busy = true; defer { finishOperation() }
        do {
            if review == false { await notifier?.reconcile(pendingCommandIds: Set(pending.map(\.id))) }
            let current = try NativeApprovalPolicy(await service.nativeRequest("native/approval-policy/read", body: .object([:])))
            var body: [String: BridgeJSON] = ["expectedRevision": .number(Double(current.revision))]
            if let review { body["reviewOtherDevices"] = .bool(review) }
            if let primaryHere { body["primaryHere"] = .bool(primaryHere) }
            let latest = try NativeApprovalPolicy(await service.nativeRequest("native/approval-policy/configure", body: .object(body)))
            guard service.nativeDeviceId == device, latest.revision > current.revision,
                  review == nil || latest.reviewOtherDevices == review,
                  primaryHere != true || latest.primaryDeviceId == device else { throw DataArchiveError.invalid("审批设置回执未核实，没有扩大本机权限") }
            policy = latest
            if let review {
                crossReviewLocallyEnabled = review
                preferences.set(review, forKey: "bc.nativeApprovalCrossReview")
                preferences.set(false, forKey: "bc.nativeApprovalPendingRevoke")
            }
            message = "审批设置已保存；只有本人具体确认才执行。主要设备仅影响之后新建的请求，不自动故障转移。"
        } catch { fail(error) }
    }
    func recordNotificationClick(_ id: String) async {
        do { try await noticeDelivery?.clicked(commandId: id) } catch { fail(error) }
    }
    // Notification navigation may arrive while a refresh is suspended. Keep
    // the latest requested destination instead of silently dropping it.
    func requestOpen(_ id: String) async {
        guard UUID(uuidString: id) != nil else { return }
        requestedOpenId = id
        await drainRequestedOpen()
    }
    private func drainRequestedOpen() async {
        guard !busy, let id = requestedOpenId else { return }
        requestedOpenId = nil
        await open(id)
    }
    private func finishOperation() {
        busy = false
        let waiting = operationWaiters; operationWaiters.removeAll(); waiting.forEach { $0.resume() }
        if requestedOpenId != nil { Task { await self.drainRequestedOpen() } }
    }
    func open(_ id: String) async {
        guard !busy, let deviceId = service.nativeDeviceId else { return }; busy = true; defer { finishOperation() }
        selected = nil; displayTestDecision = nil
        do {
            if !isDisplayTest { try await refreshPolicy(deviceId) }
            selected = try await read(id, deviceId: deviceId); message = nil
        } catch { fail(error) }
    }
    func decide(_ decision: String) async {
        guard !busy, let value = selected, let deviceId = service.nativeDeviceId,
              mayReview(value), value.state == "awaiting_confirmation", value.expiresAt > now(),
              ["accept", "decline"].contains(decision), decision != "accept" || value.displayError == nil && (value.review != nil || mayApprove(value)) else { return }
        busy = true; defer { finishOperation() }
        do {
            var intents = try persistence.load()
            let intent = NativeApprovalIntent(deviceId: deviceId, commandId: value.id, body: value.decision(decision))
            if let existing = intents.first(where: { $0.commandId == value.id }), existing != intent { throw DataArchiveError.invalid("有尚未核对的原审批决定，不能换成相反选择") }
            if !intents.contains(intent) { intents.append(intent); try persistence.save(intents) }
            retryCommandIds = intents.filter { $0.deviceId == deviceId }.map(\.commandId)
            try await transmit(intent)
        } catch { fail(error) }
    }
    // Invoked only by a concrete OS notification action selected by the human.
    // A default tap/dismissal, agent claim or incomplete preview cannot enter it.
    func decideFromNotification(_ binding: NativeApprovalNotificationBinding, decision: String) async {
        guard !isDisplayTest, ["accept", "decline"].contains(decision), service.nativeDeviceId == (binding.reviewerDeviceId ?? binding.deviceId) else { return }
        while busy {
            await withCheckedContinuation { operationWaiters.append($0) }
            if Task.isCancelled { return }
        }
        await open(binding.commandId)
        guard let entry = selected, binding.matchesRequest(entry) else {
            fail(DataArchiveError.invalid("通知对应的审批内容或版本已改变；未提交，请打开原请求核对"))
            await notificationFeedback(binding.commandId, title: "通知审批未提交", body: "内容或版本无法核对；请打开原请求查看，不要重复创建。")
            return
        }
        guard entry.state == "awaiting_confirmation", entry.expiresAt > now() else {
            await notificationFeedback(entry.id, title: entry.expiresAt <= now() && entry.state == "awaiting_confirmation" ? "审批请求已过期" : entry.stateLabel, body: "原请求已结束或到期；没有重建或重复执行。")
            return
        }
        guard binding.matches(entry) else {
            fail(DataArchiveError.invalid("通知展示的修改前后内容已改变；未提交，请重新核对原请求"))
            await notificationFeedback(entry.id, title: "通知审批未提交", body: "修改前后展示内容已改变；请打开原请求核对。")
            return
        }
        guard decision != "accept" || NativeApprovalNotificationSummary(entry).allowsDirectDecision && canDecide(entry, accept: true) else {
            fail(DataArchiveError.invalid("通知批准未提交：完整内容或本机操作授权未通过，请打开详情"))
            await notificationFeedback(entry.id, title: "通知批准未提交", body: "需打开完整详情核对内容和本机权限。没有扩大授权。")
            return
        }
        await decide(decision)
        let latest = selected
        await notificationFeedback(entry.id, title: latest?.state == "awaiting_confirmation" ? "审批回传尚未确认" : (latest?.stateLabel ?? "审批结果未知"),
                                   body: latest?.state == "applied" ? "设备已回传应用结果；点此核对最终内容。" : "点此核对原请求与设备回执；服务接受不等于设备已应用。")
    }
    private func notificationFeedback(_ id: String, title: String, body: String) async {
        guard notificationsEnabled, !isDisplayTest, let notifier else { return }
        do { try await notifier.feedback(commandId: id, title: title, body: body) } catch { fail(error) }
    }
    func retryOriginalDecision() async {
        guard !busy, let selected, let deviceId = service.nativeDeviceId else { return }; busy = true; defer { finishOperation() }
        do {
            guard let intent = try persistence.load().first(where: { $0.commandId == selected.id && $0.deviceId == deviceId }) else { return }
            try await transmit(intent)
        } catch { fail(error) }
    }
    private func transmit(_ intent: NativeApprovalIntent) async throws {
        guard service.nativeDeviceId == intent.deviceId else { throw DataArchiveError.invalid("设备配置已改变，未发送原审批") }
        if case let .object(body) = intent.body, body["reviewerGrantRevision"] != nil {
            guard let current = selected, current.id == intent.commandId, mayReview(current),
                  current.decision(try NativeRemoteJSON.string(body["decision"])) == intent.body else {
                throw DataArchiveError.invalid("跨设备审批权限或版本已变，未重发原决定")
            }
        }
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
            entries.removeAll { $0.id == value.id }; entries.append(value)
            if let notifier, !isDisplayTest { await notifier.reconcile(pendingCommandIds: Set(pending.map(\.id))) }
            // Feedback follows an identity-checked reply and completed local
            // persistence. Never describe a simulated queued state as execution.
            if isDisplayTest, case let .object(result) = value.result,
               result["executed"] == .bool(false), result["operationEffect"] == .string("read_only_display") {
                displayTestDecision = NativeApprovalDisplayDecision(rawValue: decision)
            }
            message = displayTestDecision?.title ?? value.stateLabel
        } catch {
            // Keep the exact persisted request on lost responses; a read does
            // not approve, replace, or silently retry it after restart.
            if let latest = try? await read(intent.commandId, deviceId: intent.deviceId) { selected = latest }
            throw error
        }
    }
    func enableNotifications() async {
        guard !isDisplayTest, !busy, let notifier else { return }
        // Establish a verified baseline before opt-in; no burst of old requests.
        await refresh()
        guard readComplete else { return }
        busy = true; defer { finishOperation() }
        do {
            guard try await notifier.authorize() else { throw DataArchiveError.invalid("系统未允许通知；审批仍可在 BC 内完成") }
            notificationAuthorization = await notifier.authorization()
            preferences.set(pending.map(\.id), forKey: "bc.nativeApprovalNotified")
            preferences.set(true, forKey: "bc.nativeApprovalNotifications"); notificationsEnabled = true
            message = "已开启：只提醒后续新请求；短改动可展开通知，由你选择批准／拒绝，长改动需打开详情。"
        } catch {
            notificationAuthorization = await notifier.authorization()
            fail(error)
        }
    }
    func sendDisplayTestNotification() async {
        guard !isDisplayTest, !busy, let notifier else { return }
        guard notificationsEnabled else { message = "请先单独允许审批通知，再发送只读测试。"; return }
        busy = true; defer { finishOperation() }
        do {
            try await notifier.sendDisplayTest()
            message = "只读测试通知已交给系统；这不代表横幅已显示。点它打开本机演示，所有选择都不会执行。"
        } catch { fail(error) }
    }
    func disableNotifications() {
        preferences.set(false, forKey: "bc.nativeApprovalNotifications"); notificationsEnabled = false
        // Remove this feature's delivered/pending reminders; never revoke an
        // operation or touch unrelated calendar/other notification categories.
        if let notifier, !isDisplayTest { Task { await notifier.reconcile(pendingCommandIds: []) } }
        message = "审批通知已关闭；请求仍可在待确认中处理，不会自动同意或拒绝。"
    }
    private func fail(_ error: Error) { message = error.localizedDescription; if lastFailure != message { DevLog.shared.warn("BC 审批", message ?? "审批失败"); lastFailure = message } }
}
