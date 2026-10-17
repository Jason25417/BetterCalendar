import Foundation

nonisolated struct NativeApprovalReviewContext: Equatable {
    var reviewerDeviceId: String
    var executionDeviceId: String
    var grantRevision: Int
    var policyRevision: Int
    var expiresAt: Date
    init(_ value: BridgeJSON) throws {
        let v = try NativeRemoteJSON.object(value)
        reviewerDeviceId = try NativeRemoteJSON.string(v["reviewerDeviceId"])
        executionDeviceId = try NativeRemoteJSON.string(v["executionDeviceId"])
        grantRevision = try NativeRemoteJSON.integer(v["grantRevision"])
        policyRevision = try NativeRemoteJSON.integer(v["policyRevision"])
        expiresAt = try NativeRemoteJSON.date(v["expiresAt"])
        guard grantRevision > 0, policyRevision > 0, reviewerDeviceId != executionDeviceId,
              v["authority"] == .string("explicit_cross_device_review") else {
            throw DataArchiveError.invalid("跨设备审批授权信息无效；未批准")
        }
    }
}

nonisolated struct NativeApprovalPolicy: Equatable {
    var revision = 0
    var reviewOtherDevices = false
    var primaryDeviceId: String?
    var notificationMode = "single_device"
    var routingReady = false
    var routingReadinessMessage = "尚未核实各设备的审批协议"
    init() {}
    init(_ value: BridgeJSON) throws {
        let v = try NativeRemoteJSON.object(value)
        revision = try NativeRemoteJSON.integer(v["revision"])
        guard v["version"] == .number(1), revision >= 0, case let .bool(review) = v["reviewOtherDevices"] else {
            throw DataArchiveError.invalid("审批设置回执无效；保留本机限制")
        }
        if case let .object(readiness) = v["routingReadiness"], case let .bool(ready) = readiness["ready"] {
            routingReady = ready
            routingReadinessMessage = ready ? "参与设备已报告新版审批协议" : "请更新并打开所有参与设备；旧版本或超过15分钟的状态不能启用单端提醒"
        }
        reviewOtherDevices = review
        if let mode = v["notificationMode"] {
            notificationMode = try NativeRemoteJSON.string(mode)
            guard ["single_device", "all_reviewers"].contains(notificationMode) else {
                throw DataArchiveError.invalid("审批通知模式未知；未扩大通知范围")
            }
        }
        primaryDeviceId = v["primaryDeviceId"] == .null ? nil : try NativeRemoteJSON.string(v["primaryDeviceId"])
    }
}

nonisolated struct NativeApprovalNoticeIntent: Codable, Equatable {
    enum Phase: String, Codable { case prepared, submitted, unknown, reported }
    var commandId: String
    var requestHash: String
    var deviceId: String
    var claimId: String
    var phase: Phase
    var clickedAt: Date? = nil
    var clickReported: Bool? = nil
}

@MainActor protocol NativeApprovalNoticePersisting {
    func load() throws -> [NativeApprovalNoticeIntent]
    func save(_ values: [NativeApprovalNoticeIntent]) throws
}

@MainActor final class NativeApprovalNoticeMemoryPersistence: NativeApprovalNoticePersisting {
    var values: [NativeApprovalNoticeIntent] = []
    func load() throws -> [NativeApprovalNoticeIntent] { values }
    func save(_ values: [NativeApprovalNoticeIntent]) throws { self.values = values }
}

@MainActor final class NativeApprovalNoticeFilePersistence: NativeApprovalNoticePersisting {
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DotStateBridge/native-approval-notices-v1.json")
    }
    func load() throws -> [NativeApprovalNoticeIntent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard (try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])).isSymbolicLink != true,
              (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 2 * 1024 * 1024 else {
            throw DataArchiveError.invalid("审批通知日志无法安全读取；保留原文件，不重发")
        }
        let values = try JSONDecoder().decode([NativeApprovalNoticeIntent].self, from: Data(contentsOf: url))
        try validate(values); return values
    }
    func save(_ values: [NativeApprovalNoticeIntent]) throws {
        try validate(values)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    private func validate(_ values: [NativeApprovalNoticeIntent]) throws {
        guard values.count <= 2000, Set(values.map(\.commandId)).count == values.count,
              values.allSatisfy({ UUID(uuidString: $0.commandId) != nil && UUID(uuidString: $0.claimId) != nil &&
                  !$0.deviceId.isEmpty && $0.requestHash.count == 64 }) else {
            throw DataArchiveError.invalid("审批通知日志身份或容量异常；保留原文件，不重发")
        }
    }
}

@MainActor final class NativeApprovalNoticeDelivery {
    private let service: any NativeRemoteServing
    private let notifier: any NativeApprovalNotifying
    private let persistence: any NativeApprovalNoticePersisting
    private let now: () -> Date
    private(set) var warning: String?
    private var submitting: Set<String> = []
    init(service: any NativeRemoteServing, notifier: any NativeApprovalNotifying, persistence: any NativeApprovalNoticePersisting, now: @escaping () -> Date = Date.init) {
        self.service = service; self.notifier = notifier; self.persistence = persistence; self.now = now
    }
    func submit(_ entry: NativeApproval) async throws -> Bool {
        guard !submitting.contains(entry.id) else { return false }
        submitting.insert(entry.id); defer { submitting.remove(entry.id) }
        warning = nil
        guard let device = service.nativeDeviceId else { throw DataArchiveError.invalid("本机设备身份未配置") }
        let identity: [String: BridgeJSON] = ["commandId": .string(entry.id), "requestHash": .string(entry.requestHash)]
        let claim = try NativeRemoteJSON.object(await service.nativeRequest("native/notification/claim", body: .object(identity)))
        guard service.nativeDeviceId == device, claim["version"] == .number(1), claim["commandId"] == .string(entry.id),
              claim["requestHash"] == .string(entry.requestHash), case let .bool(maySubmit) = claim["maySubmit"] else {
            throw DataArchiveError.invalid("审批通知预留回执身份不一致；没有发送")
        }
        if claim["deviceId"] != .string(device) { return false }
        let claimId = try NativeRemoteJSON.string(claim["claimId"])
        guard UUID(uuidString: claimId) != nil else { throw DataArchiveError.invalid("审批通知预留身份无效") }
        let values = try persistence.load()
        let previous = values.first { $0.commandId == entry.id }
        if let previous {
            guard previous.deviceId == device, previous.requestHash == entry.requestHash, previous.claimId == claimId else {
                throw DataArchiveError.invalid("原通知身份改变；保留日志，不重发")
            }
            if previous.phase == .reported {
                if previous.clickedAt != nil, previous.clickReported != true { try await clicked(commandId: entry.id) }
                return true
            }
        }
        // Persist before the non-transactional OS operation. A restart in this
        // gap queries existing OS notifications; absence is not proof of failure.
        var intent = previous ?? .init(commandId: entry.id, requestHash: entry.requestHash, deviceId: device, claimId: claimId, phase: .prepared)
        func save() throws { try store(intent) }
        if previous?.phase == .submitted {
            // OS accepted it earlier; only retry the original evidence report.
        } else if previous != nil || claim["beginSubmission"] != .bool(true) || !maySubmit {
            if await notifier.contains(commandId: entry.id) { intent.phase = .submitted }
            else { intent.phase = .unknown; warning = "这条审批的通知提交结果未知；没有自动重发，请在待确认列表核对。" }
            try save()
        } else {
            try save()
            do {
                // Re-read immediately before OS submission. A closed request
                // must not be emitted just because its earlier claim succeeded.
                let fresh = try NativeApproval(await service.nativeRequest("native/approval/read", body: .object(["commandId": .string(entry.id)])), deviceId: device)
                guard fresh.requestHash == entry.requestHash, fresh.deviceId == entry.deviceId, fresh.grantRevision == entry.grantRevision, fresh.review == entry.review, fresh.state == "awaiting_confirmation", fresh.expiresAt > now() else {
                    intent.phase = .unknown; try save(); return false
                }
                // Use the already verified full display, not an empty readback.
                try await notifier.send(entry)
                intent.phase = .submitted; try save()
            } catch {
                intent.phase = .unknown
                try save()
                throw error
            }
        }
        var body = identity; body["claimId"] = .string(claimId)
        body["state"] = .string(intent.phase == .submitted ? "system_submitted" : "unknown")
        let reported = try NativeRemoteJSON.object(await service.nativeRequest("native/notification/receipt", body: .object(body)))
        guard reported["version"] == .number(1), reported["commandId"] == .string(entry.id),
              let state = try? NativeRemoteJSON.string(reported["state"]),
              (intent.phase == .submitted ? ["system_submitted", "clicked"].contains(state) : ["unknown", "system_submitted", "clicked"].contains(state)) else {
            throw DataArchiveError.invalid("通知回执未核实；保留原预留，不重复发送")
        }
        if intent.phase == .submitted || ["system_submitted", "clicked"].contains(state) { intent.phase = .reported; try save(); return true }
        return false
    }
    private func store(_ intent: NativeApprovalNoticeIntent) throws {
        // Re-read after every suspension so a concurrent human click is never
        // erased by the sender's older in-memory snapshot.
        var values = try persistence.load(), merged = intent
        if let current = values.first(where: { $0.commandId == intent.commandId }) {
            guard current.requestHash == intent.requestHash, current.deviceId == intent.deviceId, current.claimId == intent.claimId else {
                throw DataArchiveError.invalid("通知本地身份冲突；没有覆盖原日志")
            }
            merged.clickedAt = current.clickedAt ?? intent.clickedAt
            merged.clickReported = current.clickReported == true || intent.clickReported == true
            if current.phase == .reported { merged.phase = .reported }
        }
        values.removeAll { $0.commandId == intent.commandId }; values.append(merged)
        try persistence.save(values)
    }
    func flushEvidence() async throws {
        guard let device = service.nativeDeviceId else { return }
        // Includes closed approvals: a late receipt must not depend on the
        // command still being present in the pending-notification loop.
        for entry in try persistence.load() where entry.deviceId == device {
            if entry.clickedAt != nil, entry.clickReported != true { try await reportClick(entry) }
            else if entry.phase == .submitted {
                let response = try NativeRemoteJSON.object(await service.nativeRequest("native/notification/receipt", body: .object([
                    "commandId": .string(entry.commandId), "requestHash": .string(entry.requestHash), "claimId": .string(entry.claimId), "state": .string("system_submitted")])))
                guard service.nativeDeviceId == device, response["version"] == .number(1), response["commandId"] == .string(entry.commandId),
                      response["state"] == .string("system_submitted") || response["state"] == .string("clicked") else {
                    throw DataArchiveError.invalid("通知提交回执身份或状态未核实")
                }
                var reported = entry; reported.phase = .reported; try store(reported)
            }
        }
    }
    func clicked(commandId: String) async throws {
        guard let device = service.nativeDeviceId,
              var entry = try persistence.load().first(where: { $0.commandId == commandId && $0.deviceId == device }),
              entry.clickReported != true else { return }
        entry.clickedAt = entry.clickedAt ?? now(); entry.clickReported = false; try store(entry)
        try await reportClick(entry)
    }
    private func reportClick(_ entry: NativeApprovalNoticeIntent) async throws {
        let response = try NativeRemoteJSON.object(await service.nativeRequest("native/notification/receipt", body: .object([
            "commandId": .string(entry.commandId), "requestHash": .string(entry.requestHash), "claimId": .string(entry.claimId), "state": .string("clicked")])))
        guard service.nativeDeviceId == entry.deviceId, response["version"] == .number(1), response["commandId"] == .string(entry.commandId), response["state"] == .string("clicked") else {
            throw DataArchiveError.invalid("通知点击回执身份或状态未核实；保留重传记录")
        }
        var reported = entry; reported.phase = .reported; reported.clickReported = true; try store(reported)
    }
}
