//
//  CloudSettings.swift
//  BetterCalendar
//
//  云端排程大脑的非敏感设置（模型、开关）。key 在 KeychainStore。
//

import Foundation

/// 云端服务商：Anthropic(Claude 原生 /v1/messages) 或 硅基流动(OpenAI 兼容 /v1/chat/completions)。
enum LLMProvider: String, CaseIterable, Sendable {
    case anthropic, siliconflow
    var label: String { self == .anthropic ? "Anthropic（Claude）" : "硅基流动（OpenAI 兼容）" }
    var keychainAccount: String { self == .anthropic ? "anthropic-api-key" : "siliconflow-api-key" }
}

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

    /// 当前服务商（默认 Anthropic）。
    static var provider: LLMProvider {
        get { LLMProvider(rawValue: defaults.string(forKey: "cloud.provider") ?? "") ?? .anthropic }
        set { defaults.set(newValue.rawValue, forKey: "cloud.provider") }
    }

    /// 硅基流动模型 ID（自己填）。默认给一个**几乎必然存在**的小 Instruct（先测通连接），
    /// 再自行换成想要的 <200B MoE Instruct（排日程是结构化抽取、别用 Thinking 变体=慢且浪费）。
    static var siliconflowModel: String {
        get { defaults.string(forKey: "cloud.sfModel") ?? "Qwen/Qwen2.5-7B-Instruct" }
        set { defaults.set(newValue, forKey: "cloud.sfModel") }
    }

    /// 当前生效模型 ID（据 provider）。
    static var activeModel: String { provider == .anthropic ? model : siliconflowModel }
}
