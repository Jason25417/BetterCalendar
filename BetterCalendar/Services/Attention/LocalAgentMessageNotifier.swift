//
//  LocalAgentMessageNotifier.swift
//  BetterCalendar
//
//  SPEC §19 C2/C4：智能体消息的系统通知——一句话、指向下一步；按钮「好」/「静音 2 小时」（反应被记下）。
//  点通知本身只打开面板，不当作任何回应。
//

import Foundation
import UserNotifications

@MainActor final class LocalAgentMessageNotifier: AgentMessageNotifying {
    static let category = "BC_AGENT_MESSAGE"
    static let ackAction = "BC_AGENT_MESSAGE_ACK"
    static let muteAction = "BC_AGENT_MESSAGE_MUTE"
    static let notUsefulAction = "BC_AGENT_MESSAGE_NOT_USEFUL"   // W42
    /// W51：自动顺延回执（漂的是「没开始」的块）——按钮「我在做」= 撤回顺延 + 从原开始时间起计时。
    static let reflowCategory = "BC_AGENT_MESSAGE_REFLOW"
    static let doingAction = "BC_AGENT_MESSAGE_DOING"
    static let idPrefix = "bc.agentmsg."
    static let userInfoKey = "bcAgentMessageId"

    private let center: UNUserNotificationCenter
    /// W30 一处响（nil = 照旧每台都响）。
    private let reach: ReachOutlet?
    init(center: UNUserNotificationCenter = .current(), reach: ReachOutlet? = nil) { self.center = center; self.reach = reach }

    /// 与已有类别合并注册（setNotificationCategories 是整体替换）。
    static func registerCategories(center: UNUserNotificationCenter = .current()) async {
        let ack = UNNotificationAction(identifier: ackAction, title: "好", options: [])
        let mute = UNNotificationAction(identifier: muteAction, title: "静音 2 小时", options: [])
        let notUseful = UNNotificationAction(identifier: notUsefulAction, title: "没用", options: [])
        let messages = UNNotificationCategory(identifier: category, actions: [ack, notUseful, mute], intentIdentifiers: [], options: [])
        let doing = UNNotificationAction(identifier: doingAction, title: "我在做", options: [])
        let reflow = UNNotificationCategory(identifier: reflowCategory, actions: [doing, ack], intentIdentifiers: [], options: [])
        var categories = await center.notificationCategories()
        categories = categories.filter { $0.identifier != category && $0.identifier != reflowCategory }
        categories.insert(messages)
        categories.insert(reflow)
        center.setNotificationCategories(categories)
    }

    /// W51：通知上的「我在做」（返回消息 id）。
    static func doingRoute(userInfo: [AnyHashable: Any], actionIdentifier: String) -> UUID? {
        guard actionIdentifier == doingAction, let raw = userInfo[userInfoKey] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    /// 这条消息用哪个类别：自动顺延且漂的是「没开始」的块 → 带「我在做」。
    static func categoryFor(_ message: AgentMessage) -> String {
        PlanDriftRules.parseMessageRef(message.parentRef)?.kind == "notStarted" ? reflowCategory : category
    }

    static func route(userInfo: [AnyHashable: Any], actionIdentifier: String) -> (id: UUID, reaction: AgentMessage.Reaction?)? {
        guard let raw = userInfo[userInfoKey] as? String, let id = UUID(uuidString: raw) else { return nil }
        switch actionIdentifier {
        case ackAction: return (id, .acknowledged)
        case muteAction: return (id, .muted)
        case notUsefulAction: return (id, .notUseful)
        case UNNotificationDefaultActionIdentifier: return (id, nil)
        default: return nil
        }
    }

    func show(_ message: AgentMessage) async {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.categoryIdentifier = Self.categoryFor(message)
        content.threadIdentifier = "bc.agent"
        content.userInfo = [Self.userInfoKey: message.id.uuidString]
        let request = UNNotificationRequest(identifier: Self.idPrefix + message.id.uuidString, content: content, trigger: nil)
        do { try await center.add(reach?.route(request, kind: .agentMessage, reachID: "agentMessage:\(message.id.uuidString)") ?? request) }
        catch { DevLog.shared.error("智能体消息", "通知发送失败：\(error.localizedDescription)") }
    }

    func withdraw(_ id: UUID) async {
        center.removeDeliveredNotifications(withIdentifiers: [Self.idPrefix + id.uuidString])
    }
}

/// SPEC §19 C1：App 在关键时刻写事件唤醒智能体（实验，默认关——每个事件都消耗 Claude 订阅额度）。
nonisolated enum AgentEventSettings {
    static let key = "agentEvents.enabled"
    /// W8（Jason 2026-10-18）：默认开——只作用于从没设过的设备；手动关过的保留。
    static let defaultEnabled = true
    static func enabled(in d: UserDefaults) -> Bool { ExperimentDefaults.bool(key, default: defaultEnabled, in: d) }
    static var enabled: Bool {
        get { enabled(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 测试 host 用：不碰系统通知中心。
@MainActor final class SilentAgentMessageNotifier: AgentMessageNotifying {
    func show(_ message: AgentMessage) async {}
    func withdraw(_ id: UUID) async {}
}
