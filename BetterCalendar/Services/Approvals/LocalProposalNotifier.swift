//
//  LocalProposalNotifier.swift
//  BetterCalendar
//
//  SPEC §19 B1：带「批准 / 拒绝」按钮的系统通知（Duo 式）。标题写是什么事，正文写改动前后 + 理由。
//  本机按提案内容生成通知（推送只负责唤醒），所以各端内容一致；决定后由 ProposalCenter 统一收起（B2）。
//

import Foundation
import UserNotifications
import Observation

@MainActor final class LocalProposalNotifier: ProposalNotifying {
    static let category = "BC_PROPOSAL"
    static let approveAction = "BC_PROPOSAL_APPROVE"
    static let declineAction = "BC_PROPOSAL_DECLINE"
    static let openAction = "BC_PROPOSAL_OPEN"
    static let idPrefix = "bc.proposal."
    static let userInfoKey = "bcProposalId"

    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    /// 与已有类别合并注册（setNotificationCategories 是整体替换，不能覆盖旧审批/提醒的类别）。
    static func registerCategories(center: UNUserNotificationCenter = .current()) async {
        let approve = UNNotificationAction(identifier: approveAction, title: "批准", options: [.authenticationRequired])
        let decline = UNNotificationAction(identifier: declineAction, title: "拒绝", options: [.authenticationRequired, .destructive])
        let open = UNNotificationAction(identifier: openAction, title: "查看详情", options: [.foreground])
        let proposals = UNNotificationCategory(identifier: category, actions: [approve, decline, open],
                                               intentIdentifiers: [], options: [])
        var categories = await center.notificationCategories()
        categories = categories.filter { $0.identifier != category }
        categories.insert(proposals)
        center.setNotificationCategories(categories)
    }

    static func request(for p: Proposal) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = p.title
        content.subtitle = (p.experiment ? "测试 · " : "") + "截止 " + p.expiresAt.formatted(date: .omitted, time: .shortened)
        content.body = p.notificationBody
        content.categoryIdentifier = category
        content.threadIdentifier = "bc.proposals"
        content.sound = .default
        content.userInfo = [userInfoKey: p.id.uuidString]
        return UNNotificationRequest(identifier: idPrefix + p.id.uuidString, content: content, trigger: nil)
    }

    /// 解析通知点击：批准/拒绝 → 带决定；点通知本身或「查看详情」→ 只打开详情，绝不当作批准。
    /// 本机通知（bcProposalId）或云端可见推送（B5，记录名）都能解析出提案 id。
    static func proposalId(from userInfo: [AnyHashable: Any]) -> UUID? {
        if let raw = userInfo[userInfoKey] as? String { return UUID(uuidString: raw) }
        return CloudKitProposalStore.proposalId(fromAlertPush: userInfo)
    }

    /// 是否是 B5 云端代发的可见推送（而非本机生成的通知）。
    static func isRemoteAlert(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[userInfoKey] == nil && CloudKitProposalStore.proposalId(fromAlertPush: userInfo) != nil
    }

    static func route(userInfo: [AnyHashable: Any], actionIdentifier: String) -> (id: UUID, decision: ProposalDecision?)? {
        guard let id = proposalId(from: userInfo) else { return nil }
        switch actionIdentifier {
        case approveAction: return (id, .approve)
        case declineAction: return (id, .decline)
        case openAction, UNNotificationDefaultActionIdentifier: return (id, nil)
        default: return nil
        }
    }

    func show(_ proposal: Proposal) async {
        do { try await center.add(Self.request(for: proposal)) } catch {
            DevLog.shared.error("多端审批", "审批通知发送失败：\(error.localizedDescription)")
        }
    }

    func withdraw(_ id: UUID) async {
        let identifier = Self.idPrefix + id.uuidString
        // 云端代发的可见推送（B5）标识由系统生成，按载荷里的记录名找到再收起。
        let remote = await center.deliveredNotifications()
            .filter { Self.isRemoteAlert($0.request.content.userInfo) && Self.proposalId(from: $0.request.content.userInfo) == id }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: [identifier] + remote)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// 本机已挂着通知的提案：本机生成的 + 云端代发的（避免同一提案弹两条）。
    func shownIds() async -> Set<UUID> {
        let delivered = await center.deliveredNotifications()
        let pending = await center.pendingNotificationRequests()
        let local = (delivered.map(\.request.identifier) + pending.map(\.identifier)).compactMap { identifier in
            identifier.hasPrefix(Self.idPrefix) ? UUID(uuidString: String(identifier.dropFirst(Self.idPrefix.count))) : nil
        }
        let remote = delivered.compactMap { Self.isRemoteAlert($0.request.content.userInfo) ? Self.proposalId(from: $0.request.content.userInfo) : nil }
        return Set(local + remote)
    }

    /// 前台去重：本机已为同一提案挂了通知时，云端代发的那条不再展示。
    func hasLocalNotification(for id: UUID) async -> Bool {
        await center.deliveredNotifications().contains { $0.request.identifier == Self.idPrefix + id.uuidString }
    }

    func permission() async -> Bool? {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        case .denied: false
        default: nil
        }
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

/// 推送唤醒的接缝：AppDelegate 收到本 zone 的推送后调用；由组装点挂上 ProposalCenter.refresh。
@MainActor enum ProposalWake {
    static var onPush: (() async -> Void)?
}

/// B5 可见推送订阅的读写缝（生产 = CloudKitProposalStore；测试 = 内存假实现）。
nonisolated protocol ProposalAlertPushing: Sendable {
    func isAlertPushEnabled() async throws -> Bool
    func setAlertPush(enabled: Bool) async throws
}
extension CloudKitProposalStore: ProposalAlertPushing {}

/// B5 可见推送开关（实验；W8 起你没手动关过就默认开）。订阅存在 iCloud 账户里：一端打开，所有设备生效；状态以云端为准。
@MainActor @Observable final class ProposalAlertPushControl {
    static let key = "approvals.alertPush.enabled"
    /// W8：用户**手动关过**的记号（只有面板上亲手关掉才写；亲手打开时清掉）。随设置同步——订阅属于 iCloud 账户、
    /// 全设备生效，iPhone 上关了，Mac 启动时不能又自动打开。
    static let userDisabledKey = "approvals.alertPush.userDisabled"
    private(set) var enabled: Bool
    private(set) var lastError: String?
    private let store: any ProposalAlertPushing
    private let defaults: UserDefaults
    init(store: any ProposalAlertPushing, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
        enabled = defaults.bool(forKey: Self.key)
    }
    /// 从云端读真实状态（其他设备可能已切换过）。
    func reload() async {
        do { enabled = try await store.isAlertPushEnabled(); defaults.set(enabled, forKey: Self.key); lastError = nil }
        catch { lastError = "读取推送状态失败：\(error.localizedDescription)" }
    }

    /// byUser=false 只用于启动时的默认打开（不改「手动关过」记号）。
    func set(_ on: Bool, byUser: Bool = true) async {
        do {
            try await store.setAlertPush(enabled: on)
            enabled = on; lastError = nil
            defaults.set(on, forKey: Self.key)
            if byUser {
                if on { defaults.removeObject(forKey: Self.userDisabledKey) } else { defaults.set(true, forKey: Self.userDisabledKey) }
            }
            DevLog.shared.info("多端审批", "App 关闭时推送（实验）已\(on ? "开启" : "关闭")" + (byUser ? "" : "（默认打开）"))
        } catch {
            lastError = "切换失败：\(error.localizedDescription)"
            DevLog.shared.error("多端审批", lastError!)
        }
    }

    /// W8（Jason 2026-10-18）：B5 默认开——App 启动时，若你从没手动关过，就自动打开订阅。
    /// 先读云端真实状态（已开 = 什么都不做）；读失败或打开失败照常可见（lastError + DevLog），下次启动再试。
    func autoEnableIfNeverDisabled() async {
        guard ExperimentDefaults.neverSet(Self.userDisabledKey, in: defaults) else { return }
        await reload()
        if let lastError {
            DevLog.shared.error("多端审批", "默认打开 iCloud 直接推送前读取状态失败：\(lastError)")
            return
        }
        guard !enabled else { return }
        await set(true, byUser: false)
    }
}
