//
//  LocalProposalNotifier.swift
//  BetterCalendar
//
//  SPEC §19 B1：带「批准 / 拒绝」按钮的系统通知（Duo 式）。标题写是什么事，正文写改动前后 + 理由。
//  本机按提案内容生成通知（推送只负责唤醒），所以各端内容一致；决定后由 ProposalCenter 统一收起（B2）。
//

import Foundation
import UserNotifications

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
    static func route(userInfo: [AnyHashable: Any], actionIdentifier: String) -> (id: UUID, decision: ProposalDecision?)? {
        guard let raw = userInfo[userInfoKey] as? String, let id = UUID(uuidString: raw) else { return nil }
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
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func shownIds() async -> Set<UUID> {
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        return Set((delivered + pending).compactMap { identifier in
            identifier.hasPrefix(Self.idPrefix) ? UUID(uuidString: String(identifier.dropFirst(Self.idPrefix.count))) : nil
        })
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
