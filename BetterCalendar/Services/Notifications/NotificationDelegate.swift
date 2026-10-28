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
    /// SPEC §19 多端审批：.open = 只打开详情（点通知本身绝不当作批准）；W10 起还有回一句 / 选方案 / 撤销（规则自动做完的结果）。
    var handleProposal: ((UUID, LocalProposalNotifier.Response) async -> Void)?
    /// SPEC §19 C4：智能体消息的反应；reaction 为 nil = 只打开面板。
    var handleAgentMessage: ((UUID, AgentMessage.Reaction?) async -> Void)?
    /// W51：自动顺延通知上的「我在做」（消息 id）。
    var handleReflowDoing: ((UUID) async -> Void)?
    /// W52：哨兵问句通知上的回答（消息 id，yes = 在做 / 停了）。
    var handleSentinelAnswer: ((UUID, Bool) async -> Void)?
    /// SPEC §19 A1：智能体对话通知；text 非 nil = 在通知上直接回复了一句，nil = 只打开对话。
    var handleAgentChat: ((UUID, String?) async -> Void)?
    /// W30 一处响：你在本机点了某条通知 = 处理了 → 其他设备上的那份收起（提案有自己的收起机制，不走这里）。
    var reach: ReachOutlet?

    init(router: AppRouter) {
        self.router = router
        super.init()
    }

    // id 对应 UNNotificationService 里的 morning/evening
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let id = info[ReachOutlet.idKey] as? String, let raw = info[ReachOutlet.kindKey] as? String,
           ReachKind(rawValue: raw)?.usesHandledBoard == true {
            await reach?.markHandled([id])
        }
        if let route = LocalAgentChatNotifier.route(userInfo: info, actionIdentifier: response.actionIdentifier,
                                                    typedText: (response as? UNTextInputNotificationResponse)?.userText) {
            FeatureUsage.used(route.text == nil ? .notificationChatOpen : .notificationChatReply)   // W21
            if route.text == nil {
                router.openChat()
                #if os(macOS)
                if !TestHost.isActive { AppLifecycle.shared?.showMainWindow() }
                #endif
            }
            await handleAgentChat?(route.id, route.text)
            return
        }
        if let id = LocalAgentMessageNotifier.doingRoute(userInfo: info, actionIdentifier: response.actionIdentifier) {
            await handleReflowDoing?(id)
            return
        }
        if let route = LocalAgentMessageNotifier.askRoute(userInfo: info, actionIdentifier: response.actionIdentifier) {
            await handleSentinelAnswer?(route.id, route.yes)
            return
        }
        if let route = LocalAgentMessageNotifier.route(userInfo: info, actionIdentifier: response.actionIdentifier) {
            FeatureUsage.used(route.reaction == nil ? .notificationMessageOpen : .notificationMessageReact, route.reaction?.rawValue)   // W21
            if route.reaction == nil {
                router.openProposals = true
                #if os(macOS)
                if !TestHost.isActive { AppLifecycle.shared?.showMainWindow() }
                #endif
            }
            await handleAgentMessage?(route.id, route.reaction)
            return
        }
        if let route = LocalProposalNotifier.response(userInfo: info, actionIdentifier: response.actionIdentifier,
                                                      typedText: (response as? UNTextInputNotificationResponse)?.userText) {
            FeatureUsage.used(Self.usageFeature(route.response))   // W21
            if route.response == .open {
                router.proposalFocusId = route.id
                router.openProposals = true
                #if os(macOS)
                if !TestHost.isActive { AppLifecycle.shared?.showMainWindow() }
                #endif
            }
            await handleProposal?(route.id, route.response)
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
            FeatureUsage.used(.notificationMorning)   // W21
            // 0.23 A：开始今天已退役——早通知改为打开执行界面、第一件「待开始」（不自动计时）
            router.selectedTab = .schedule
            router.primeNextStart = true
        case "bc.reminder.evening":
            FeatureUsage.used(.notificationEvening)   // W21
            // 0.38（#33）：晚通知直达日记页并进入分步收尾流程（明确的收尾入口）
            router.selectedTab = .journal
            router.journalRequest = .now
            router.wrapUpRequest = true
        default:
            break
        }
    }

    /// W21：提案通知上的回应 → 功能（批准 / 选方案都算批准）。
    static func usageFeature(_ r: LocalProposalNotifier.Response) -> FeatureID {
        switch r {
        case .open: .notificationProposalOpen
        case let .decide(d, _): d == .approve ? .notificationProposalApprove : .notificationProposalDecline
        case .reply: .notificationProposalReply
        case .undo: .notificationProposalUndo
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
        // SPEC §19 B5 去重：同一提案本机已有通知时，不再展示云端代发的那条。
        let info = notification.request.content.userInfo
        if LocalProposalNotifier.isRemoteAlert(info), let id = LocalProposalNotifier.proposalId(from: info),
           await LocalProposalNotifier().hasLocalNotification(for: id) {
            return []
        }
        // W30 一处响：本机这一份是安静的（在场设备在别处）→ App 在前台也只放进通知中心，不弹横幅不出声
        if notification.request.content.interruptionLevel == .passive { return [.list] }
        return [.banner, .sound]
    }
}
