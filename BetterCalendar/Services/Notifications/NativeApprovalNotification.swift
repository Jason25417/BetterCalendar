import Foundation
import UserNotifications

nonisolated enum NativeApprovalNotificationAuthorization: String {
    case notDetermined, denied, authorized, provisional, unknown
    var label: String {
        switch self {
        case .notDetermined: "尚未请求系统通知权限"
        case .denied: "系统通知已关闭；可到系统设置重新允许"
        case .authorized: "系统已允许通知；横幅、预览及专注模式仍由系统控制"
        case .provisional: "系统仅临时允许，可能只放入通知中心"
        case .unknown: "系统通知权限状态未知"
        }
    }
}

// Public notification payload is only a binding, never an execution grant.
nonisolated struct NativeApprovalNotificationBinding: Codable, Equatable {
    var version = 1
    var commandId: String
    var deviceId: String
    var requestHash: String
    var grantRevision: Int
    var expiresAt: Date
    var expectedRevision: String?
    var displayHash: String
    init(_ entry: NativeApproval) throws {
        commandId = entry.id; deviceId = entry.deviceId; requestHash = entry.requestHash
        grantRevision = entry.grantRevision; expiresAt = entry.expiresAt
        expectedRevision = try? NativeRemoteJSON.string(entry.request["expectedRevision"])
        displayHash = try Self.hashDisplay(entry)
    }
    private static func hashDisplay(_ entry: NativeApproval) throws -> String {
        BridgePoolCodec.hash(try BridgePoolCodec.encode(.object([
            "title": .string(entry.title), "device": .string(entry.deviceLabel),
            "before": entry.display["before"] ?? .null, "request": .object(entry.request)
        ])))
    }
    func matchesRequest(_ entry: NativeApproval) -> Bool {
        guard version == 1, commandId == entry.id, deviceId == entry.deviceId,
              requestHash == entry.requestHash, grantRevision == entry.grantRevision,
              expiresAt == entry.expiresAt,
              expectedRevision == (try? NativeRemoteJSON.string(entry.request["expectedRevision"])) else { return false }
        return true
    }
    func matches(_ entry: NativeApproval) -> Bool {
        matchesRequest(entry) && displayHash == (try? Self.hashDisplay(entry))
    }
    static func diagnostics(enabled: Bool, authorization: NativeApprovalNotificationAuthorization) -> BridgeJSON {
        .object(["enabled": .bool(enabled), "systemAuthorization": .string(authorization.rawValue),
                 "delivery": .string("local_poll_20s_while_app_runs"), "remoteApprovalPush": .bool(false),
                 "notificationDecision": .string("short_complete_item_title_note_only_requires_human_action")])
    }
    var encoded: String? { try? String(data: JSONEncoder().encode(self), encoding: .utf8) }
    static func decode(_ string: String) -> Self? {
        guard string.utf8.count <= 4096, let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1,
              UUID(uuidString: value.commandId) != nil, !value.deviceId.isEmpty,
              value.grantRevision > 0, value.requestHash.count == 64, value.displayHash.count == 64 else { return nil }
        return value
    }
}

nonisolated struct NativeApprovalNotificationSummary {
    var title: String
    var subtitle: String
    var body: String
    var allowsDirectDecision: Bool
    init(_ entry: NativeApproval) {
        title = entry.kind == "item" ? (entry.action == "create" ? "批准新增事项？" : "批准修改事项？") : "BC 有一项改动等你确认"
        subtitle = entry.title + " · " + entry.deviceLabel
        var lines: [String] = []
        let patch = (try? NativeRemoteJSON.object(entry.request["patch"] ?? .null)) ?? [:]
        let before = (try? NativeRemoteJSON.object(entry.display["before"] ?? .null)) ?? [:]
        var complete = entry.kind == "item" && ["create", "update"].contains(entry.action) && !patch.isEmpty &&
            Set(patch.keys).isSubset(of: ["title", "note"]) && entry.displayError == nil &&
            entry.title.utf16.count <= 80 && entry.deviceLabel.utf16.count <= 60
        func text(_ value: BridgeJSON?) -> String? {
            switch value {
            case let .string(s): s.isEmpty ? "（空白）" : "「" + s + "」"
            case .null: "清空"
            default: nil
            }
        }
        for key in patch.keys.sorted() {
            guard let after = text(patch[key]) else { complete = false; continue }
            let label = key == "title" ? "标题" : "备注"
            if entry.action == "update" {
                guard let old = text(before[key]) else { complete = false; continue }
                lines.append(label + "\n原：" + old + "\n改为：" + after)
            } else { lines.append(label + "：" + after) }
        }
        lines.append("截止：" + entry.expiresAt.formatted(date: .numeric, time: .shortened))
        let full = lines.joined(separator: "\n")
        // Larger/richer changes must be reviewed in BC. Never truncate a change
        // and leave an authoritative Approve button next to an incomplete diff.
        allowsDirectDecision = complete && full.utf16.count <= 420
        body = allowsDirectDecision ? full : "请打开完整改动详情核对后再决定。" + "\n" + lines.last!
        if !allowsDirectDecision { title = "BC 有一项改动等你确认"; subtitle = "完整内容见审批详情" }
    }
}

@MainActor enum NativeApprovalNotificationRoute: Equatable {
    case command(String), displayTest, decision(NativeApprovalNotificationBinding, String)
    static let reviewAction = "BC_NATIVE_APPROVAL_REVIEW"
    static let approveAction = "BC_NATIVE_APPROVAL_ACCEPT"
    static let declineAction = "BC_NATIVE_APPROVAL_DECLINE"
    static let category = "BC_NATIVE_APPROVAL"
    static let directCategory = "BC_NATIVE_APPROVAL_DIRECT"
    static func parse(userInfo: [AnyHashable: Any], actionIdentifier: String) -> Self? {
        if [approveAction, declineAction].contains(actionIdentifier) {
            guard userInfo["bcApprovalDisplayTest"] == nil,
                  let raw = userInfo["bcApprovalBinding"] as? String,
                  let binding = NativeApprovalNotificationBinding.decode(raw),
                  userInfo["bcApprovalCommandId"] as? String == binding.commandId else { return nil }
            return .decision(binding, actionIdentifier == approveAction ? "accept" : "decline")
        }
        guard [UNNotificationDefaultActionIdentifier, reviewAction].contains(actionIdentifier) else { return nil }
        if userInfo["bcApprovalDisplayTest"] as? Bool == true {
            return userInfo["bcApprovalCommandId"] == nil ? .displayTest : nil
        }
        guard let id = userInfo["bcApprovalCommandId"] as? String, UUID(uuidString: id) != nil else { return nil }
        return .command(id)
    }
}

@MainActor final class NativeApprovalNotification: NativeApprovalNotifying {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }
    static func registerCategories(center: UNUserNotificationCenter = .current()) async {
        let review = UNNotificationAction(identifier: NativeApprovalNotificationRoute.reviewAction,
                                          title: "查看改动并确认", options: [.foreground])
        let category = UNNotificationCategory(identifier: NativeApprovalNotificationRoute.category,
                                               actions: [review], intentIdentifiers: [], options: [])
        let accept = UNNotificationAction(identifier: NativeApprovalNotificationRoute.approveAction, title: "批准", options: [.authenticationRequired])
        let decline = UNNotificationAction(identifier: NativeApprovalNotificationRoute.declineAction, title: "拒绝", options: [.authenticationRequired, .destructive])
        let direct = UNNotificationCategory(identifier: NativeApprovalNotificationRoute.directCategory,
                                             actions: [accept, decline, review], intentIdentifiers: [], options: [])
        var categories = await center.notificationCategories()
        categories = Set(categories.filter { ![category.identifier, direct.identifier].contains($0.identifier) })
        categories.insert(category); categories.insert(direct); center.setNotificationCategories(categories)
    }
    func authorize() async throws -> Bool {
        // Only the separate human settings button calls this method.
        try await center.requestAuthorization(options: [.alert])
    }
    func authorization() async -> NativeApprovalNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized: .authorized
        case .provisional: .provisional
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .unknown
        }
    }
    static func request(approval: NativeApproval) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let summary = NativeApprovalNotificationSummary(approval)
        content.title = summary.title; content.subtitle = summary.subtitle; content.body = summary.body
        let binding = try? NativeApprovalNotificationBinding(approval)
        content.categoryIdentifier = summary.allowsDirectDecision && binding?.encoded != nil ? NativeApprovalNotificationRoute.directCategory : NativeApprovalNotificationRoute.category
        content.threadIdentifier = "bc.approvals"
        // Exact short diffs may appear in system previews, controlled by the
        // user's OS notification settings. No execution grant or credentials.
        content.userInfo = ["bcApprovalCommandId": approval.id]
        if summary.allowsDirectDecision, let raw = binding?.encoded { content.userInfo["bcApprovalBinding"] = raw }
        return UNNotificationRequest(identifier: "bc.approval." + approval.id, content: content, trigger: nil)
    }
    private func checkAndRegister() async throws {
        let status = await authorization()
        guard status == .authorized || status == .provisional else {
            throw DataArchiveError.invalid("审批通知未获系统授权；未发送。" + status.label)
        }
        await Self.registerCategories(center: center)
    }
    func send(_ approval: NativeApproval) async throws {
        try await checkAndRegister()
        try await center.add(Self.request(approval: approval))
    }
    func sendDisplayTest() async throws {
        try await checkAndRegister()
        let content = UNMutableNotificationContent()
        content.title = "BC 审批通知测试（不会执行）"
        content.body = "点通知或“查看改动并确认”打开本机演示。所有选择都不会修改事项或计时。"
        content.categoryIdentifier = NativeApprovalNotificationRoute.category
        content.threadIdentifier = "bc.approvals"
        content.userInfo = ["bcApprovalDisplayTest": true]
        try await center.add(UNNotificationRequest(identifier: "bc.approval-preview." + UUID().uuidString, content: content, trigger: nil))
    }
    func feedback(commandId: String, title: String, body: String) async throws {
        try await checkAndRegister()
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        content.threadIdentifier = "bc.approvals"
        content.categoryIdentifier = NativeApprovalNotificationRoute.category
        content.userInfo = ["bcApprovalCommandId": commandId]
        try await center.add(UNNotificationRequest(identifier: "bc.approval-result." + commandId, content: content, trigger: nil))
    }
    func reconcile(pendingCommandIds: Set<String>) async {
        let prefix = "bc.approval."
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }
        let scheduled = await center.pendingNotificationRequests().map(\.identifier)
        let stale = Set((delivered + scheduled).filter { $0.hasPrefix(prefix) && !pendingCommandIds.contains(String($0.dropFirst(prefix.count))) })
        guard !stale.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: Array(stale))
        center.removePendingNotificationRequests(withIdentifiers: Array(stale))
    }
}
