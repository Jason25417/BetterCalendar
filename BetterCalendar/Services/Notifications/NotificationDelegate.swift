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
    var handleApprovalDecision: ((NativeApprovalNotificationBinding, String) async -> Void)?

    init(router: AppRouter) {
        self.router = router
        super.init()
    }

    // id 对应 UNNotificationService 里的 morning/evening
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if case let .decision(binding, decision) = NativeApprovalNotificationRoute.parse(userInfo: info, actionIdentifier: response.actionIdentifier) {
            await handleApprovalDecision?(binding, decision)
            return
        }
        if routeApproval(userInfo: info, actionIdentifier: response.actionIdentifier) { return }
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
