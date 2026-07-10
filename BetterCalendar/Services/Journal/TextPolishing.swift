//
//  TextPolishing.swift
//  BetterCalendar
//
//  日记润色（#23，2026-07-10 Jason 定评估路线）：错别字修正 + Markdown 规整 + 轻润色 +
//  **平直文本 → 结构化富文本**（Jason 补充：人造/真实日记常是平铺直叙，润色要能给出结构）。
//  ⚠️ 隐私边界（铁律）：**用户真日记正文绝不出云**——本文件当前只服务**算法试验台**
//  （固定合成样例文集），云端 vs 端侧对比出结论后再定生产形态（端侧直上 / 或再议知情例外）。
//  生产 UI 尚未接入；接入时必须 diff 预览 + 用户确认才替换（原则7：绝不自动改正文）。
//

import Foundation
import FoundationModels

protocol TextPolishing {
    /// 原文 → 润色后全文（只返回正文，无解释）。失败抛错（试验台要看到真实失败）。
    func polish(_ text: String) async throws -> String
}

/// 共用润色指令（两实现同一契约，对比才公平）。
enum PolishPrompt {
    static let instructions = """
    你是日记润色助手。把用户的日记润色成更易读的 Markdown，规则：
    1) 修正错别字与明显病句（口语可保留，意思绝不改变、内容绝不增删事实）；
    2) 规整 Markdown 格式（已有的标题/列表修好；杂乱符号清理）；
    3) **平铺直叙的长段落 → 结构化**：合理分段，需要时加小标题（##）或列表，让一天的记录有层次；
    4) 语气保持作者本人的（不套官腔、不加感叹）；篇幅与原文相当（±30%）。
    只输出润色后的正文，不要解释、不要围栏。
    """
}

/// 云端润色（试验台专用；生产未接）。
struct ClaudePolisher: TextPolishing {
    let client: AnthropicClient

    func polish(_ text: String) async throws -> String {
        try await LLMWatchdog.run(seconds: 30) {   // 润色长文比排程慢，看门狗放宽到 30s（仅试验台）
            try await client.complete(system: PolishPrompt.instructions, user: text,
                                      maxTokens: 4000, jsonMode: false, jsonSchema: nil)
        }
    }
}

/// 端侧 FM 润色（试验台专用；生产候选——若质量够，隐私上可直上）。
struct FMPolisher: TextPolishing {
    func polish(_ text: String) async throws -> String {
        switch SystemLanguageModel.default.availability {
        case .available: break
        default: throw AnthropicError(message: "端侧模型不可用")
        }
        let session = LanguageModelSession(instructions: PolishPrompt.instructions)
        let response = try await session.respond(to: text)
        return response.content
    }
}
