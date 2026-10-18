//
//  LocalAgentChatNotifier.swift
//  BetterCalendar
//
//  SPEC §19 A1：智能体对话回复的系统通知。通知上可以直接「回复」一句（无感：说一句 = 操作）；
//  点通知本身只打开对话页。是否弹出由 AgentChatNotifyPolicy 在 Mac 导入时决定一次，各端照办。
//

import Foundation
import UserNotifications

@MainActor final class LocalAgentChatNotifier: AgentChatNotifying {
    static let category = "BC_AGENT_CHAT"
    static let replyAction = "BC_AGENT_CHAT_REPLY"
    static let idPrefix = "bc.agentchat."
    static let userInfoKey = "bcAgentChatId"

    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    /// 与已有类别合并注册（setNotificationCategories 是整体替换）。
    static func registerCategories(center: UNUserNotificationCenter = .current()) async {
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "回复", options: [],
                                                  textInputButtonTitle: "发送", textInputPlaceholder: "跟智能体说一句")
        let chat = UNNotificationCategory(identifier: category, actions: [reply], intentIdentifiers: [], options: [])
        var categories = await center.notificationCategories()
        categories = categories.filter { $0.identifier != category }
        categories.insert(chat)
        center.setNotificationCategories(categories)
    }

    /// 通知点击路由：text 非 nil = 在通知上回复了一句；nil = 只打开对话页。
    nonisolated static func route(userInfo: [AnyHashable: Any], actionIdentifier: String, typedText: String?) -> (id: UUID, text: String?)? {
        guard let raw = userInfo[userInfoKey] as? String, let id = UUID(uuidString: raw) else { return nil }
        switch actionIdentifier {
        case replyAction:
            let text = typedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (id, text.isEmpty ? nil : text)
        case UNNotificationDefaultActionIdentifier: return (id, nil)
        default: return nil
        }
    }

    func show(_ message: AgentChatMessage) async {
        let content = UNMutableNotificationContent()
        content.title = message.kind == .eveningReview ? "今天做成了什么" : "BetterCalendar 智能体"
        content.body = String(message.text.prefix(400))
        content.categoryIdentifier = Self.category
        content.threadIdentifier = "bc.agent.chat"
        content.userInfo = [Self.userInfoKey: message.id.uuidString]
        do { try await center.add(UNNotificationRequest(identifier: Self.idPrefix + message.id.uuidString, content: content, trigger: nil)) }
        catch { DevLog.shared.error("智能体对话", "通知发送失败：\(error.localizedDescription)") }
    }

    func withdraw(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids.map { Self.idPrefix + $0.uuidString })
    }
}
