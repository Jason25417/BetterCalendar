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
    case startToday
    case startFocus
    case completeCurrent
    case review

    nonisolated static func enqueue(_ request: AppIntentRequest, payload: String? = nil) {
        let key = "appIntent.pendingRequest"
        let payloadKey = "appIntent.pendingPayload"
        UserDefaults.standard.set(request.rawValue, forKey: key)
        if let payload, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.set(payload, forKey: payloadKey)
        } else {
            UserDefaults.standard.removeObject(forKey: payloadKey)
        }
    }

    nonisolated static func payload() -> String? {
        let payloadKey = "appIntent.pendingPayload"
        return UserDefaults.standard.string(forKey: payloadKey)
    }

    nonisolated static func consume() -> AppIntentRequest? {
        let key = "appIntent.pendingRequest"
        let payloadKey = "appIntent.pendingPayload"
        guard let raw = UserDefaults.standard.string(forKey: key),
              let request = AppIntentRequest(rawValue: raw) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: payloadKey)
        return request
    }
}
