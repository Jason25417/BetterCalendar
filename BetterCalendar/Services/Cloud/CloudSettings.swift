//
//  CloudSettings.swift
//  BetterCalendar
//
//  云端排程大脑的非敏感设置（模型、开关）。key 在 KeychainStore。
//

import Foundation

enum CloudSettings {
    private static let defaults = UserDefaults.standard

    /// 默认 Opus 4.8（最强）；想省钱可在设置里切 Sonnet / Haiku。
    static let availableModels = ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]

    static var model: String {
        get { defaults.string(forKey: "cloud.model") ?? "claude-opus-4-8" }
        set { defaults.set(newValue, forKey: "cloud.model") }
    }

    static var useCloud: Bool {
        get { defaults.object(forKey: "cloud.useCloud") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cloud.useCloud") }
    }
}
