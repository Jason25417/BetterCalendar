//
//  AppIntentRequest.swift
//  BetterCalendar
//
//  App Intents run outside the normal SwiftUI view flow. They write a small
//  pending request, then the app consumes it when it becomes active.
//

import Foundation

enum AppIntentRequest: String, Sendable {
    case arrangeToday
    case openSchedule
    case openToday
    case openJournal
    // startToday 已退役（0.23 A）：老快捷指令若还发它，rawValue 解析失败 → consume() 返回 nil，安全忽略
    case startFocus
    case completeCurrent
    case markDone      // 带 payload=任务标题：按标题标完成（Claude Code 完成信号入口）
    case review

    /// iOS 走 App Group defaults：Control Center 控件的 intent 在 **widget 扩展进程**里执行，
    /// 各进程的 UserDefaults.standard 互不相通——共享域才能把请求递给主 App。macOS 无控件，照旧 standard。
    nonisolated private static var store: UserDefaults {
        #if os(iOS)
        UserDefaults(suiteName: AppChannel.current.appGroupID) ?? .standard
        #else
        .standard
        #endif
    }

    nonisolated static func enqueue(_ request: AppIntentRequest, payload: String? = nil) {
        let key = "appIntent.pendingRequest"
        let payloadKey = "appIntent.pendingPayload"
        store.set(request.rawValue, forKey: key)
        if let payload, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.set(payload, forKey: payloadKey)
        } else {
            store.removeObject(forKey: payloadKey)
        }
    }

    nonisolated static func payload() -> String? {
        store.string(forKey: "appIntent.pendingPayload")
    }

    nonisolated static func consume() -> AppIntentRequest? {
        let key = "appIntent.pendingRequest"
        let payloadKey = "appIntent.pendingPayload"
        guard let raw = store.string(forKey: key),
              let request = AppIntentRequest(rawValue: raw) else {
            return nil
        }
        store.removeObject(forKey: key)
        store.removeObject(forKey: payloadKey)
        return request
    }
}
