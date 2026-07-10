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

    /// ⚠️ 列表内模型都**支持结构化输出**（`output_config.format`）——排程/微调走它强制直出 JSON。
    /// 已下线的 `claude-sonnet-4-6` 不支持结构化输出（也不支持 prefill），故移除并在 getter 里自动迁移。
    static let availableModels = ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"]

    // 默认 Haiku 4.5（2026-07-09 试验台 10 轮定：解析 89%/微调+防呆 100%/reflowV2 98%，全面胜 Sonnet
    // 且快 40–50%、最便宜；Opus 结构化输出灾难=解码失败率极高，不作默认）。已选过模型的老用户不受影响。
    static let defaultModel = "claude-haiku-4-5"
    static var model: String {
        get {
            let stored = defaults.string(forKey: "cloud.model") ?? defaultModel
            if stored == "claude-sonnet-4-6" { return "claude-sonnet-5" }   // 4.6 不支持结构化输出 → 迁到 5
            return availableModels.contains(stored) ? stored : defaultModel
        }
        set { defaults.set(newValue, forKey: "cloud.model") }
    }

    static var useCloud: Bool {
        get { defaults.object(forKey: "cloud.useCloud") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cloud.useCloud") }
    }

    /// 开发期：把云端**原始返回**（stop_reason + 前 2000 字）记进 DevLog，排查「成功返回但解析 0 块 / 截断」。
    /// 默认开；上架前关或删。
    static var logRawResponses: Bool {
        get { defaults.object(forKey: "cloud.logRaw") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cloud.logRaw") }
    }

    /// **只使用端侧**（2026-07-11 Jason 定，原「优先端侧」语义升级）：开=解析/AI 调整/排序全部只在
    /// 设备上运行（Apple Foundation Models + 本地排序），**文字绝不出云**——选它的唯一理由是绝对隐私，
    /// 云端兜底会让这个承诺不成立，所以失败=干净失败、绝不静默回云。
    /// 关（默认）=云端 Haiku 优先（表现明显更优），云端失败时端侧 FM 自动兜底。
    /// 端云并行赛跑（0.26.19 #13）随本语义退役：并行=文字必然发云，与「端侧=隐私」矛盾。
    /// 沿用旧键 cloud.onDeviceParser（老用户开着的直接获得新语义，changelog 已说明）。
    static var onDeviceOnly: Bool {
        get { defaults.object(forKey: "cloud.onDeviceParser") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "cloud.onDeviceParser") }
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
