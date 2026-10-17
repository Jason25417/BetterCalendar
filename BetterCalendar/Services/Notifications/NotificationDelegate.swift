//
//  NotificationDelegate.swift
//  BetterCalendar
//
//  通知 deep-link：点早通知 → 开始今天、点晚通知 → 复盘。点击事件 → 设 AppRouter，UI 跟着跳。
//

import Foundation
import UserNotifications

@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let router: AppRouter
    var handleReminderViewed: ((String) async -> Void)?
    var handleApprovalViewed: ((String) async -> Void)?
    var handleApprovalDecision: ((NativeApprovalNotificationBinding, String) async -> Void)?
    /// SPEC §19 多端审批：decision 为 nil = 只打开详情（点通知本身绝不当作批准）。
    var handleProposal: ((UUID, ProposalDecision?) async -> Void)?

    init(router: AppRouter) {
        self.router = router
        super.init()
    }

    // id 对应 UNNotificationService 里的 morning/evening
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let route = LocalProposalNotifier.route(userInfo: info, actionIdentifier: response.actionIdentifier) {
            if route.decision == nil {
                router.proposalFocusId = route.id
                router.openProposals = true
                #if os(macOS)
                if !TestHost.isActive { AppLifecycle.shared?.showMainWindow() }
                #endif
            }
            await handleProposal?(route.id, route.decision)
            return
        }
        if case let .decision(binding, decision) = NativeApprovalNotificationRoute.parse(userInfo: info, actionIdentifier: response.actionIdentifier) {
            // Persist/report the click alongside the decision, without waiting
            // for receipt network latency before handling the human choice.
            async let viewed: Void? = handleApprovalViewed?(binding.commandId)
            await handleApprovalDecision?(binding, decision)
            _ = await viewed
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let raw = info["bcExplicitReminder"] as? String {
            await handleReminderViewed?(raw)
            return // A reminder click never approves a command or starts timing.
        }
        if routeApproval(userInfo: info, actionIdentifier: response.actionIdentifier) {
            if let id = info["bcApprovalCommandId"] as? String { await handleApprovalViewed?(id) }
            return
        }
        switch response.notification.request.identifier {
        case "bc.reminder.morning":
            // 0.23 A：开始今天已退役——早通知改为打开执行界面、第一件「待开始」（不自动计时）
            router.selectedTab = .schedule
            router.primeNextStart = true
        case "bc.reminder.evening":
            // 0.38（#33）：晚通知直达日记页并进入分步收尾流程（明确的收尾入口）
            router.selectedTab = .journal
            router.journalRequest = .now
            router.wrapUpRequest = true
        default:
            break
        }
    }

    @discardableResult
    func routeApproval(userInfo: [AnyHashable: Any], actionIdentifier: String) -> Bool {
        guard let route = NativeApprovalNotificationRoute.parse(userInfo: userInfo, actionIdentifier: actionIdentifier) else { return false }
        switch route {
        case let .command(id):
            router.nativeApprovalPreviewRequest = nil
            router.nativeApprovalCommandId = id
        case .decision: return false // Only the async human-action handler submits a decision.
        case .displayTest:
            router.nativeApprovalCommandId = nil
            router.nativeApprovalPreviewRequest = UUID()
        }
        router.openNativeApprovals = true
        #if os(macOS)
        if !TestHost.isActive { AppLifecycle.shared?.showMainWindow() }
        #endif
        return true // Navigation only; never approves or executes.
    }

    // App 在前台时也把通知显出来（否则前台不弹）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
