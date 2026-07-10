//
//  ClaudePlanRefiner.swift
//  BetterCalendar
//
//  自然语言微调（云端车道）：把当前块清单 + 用户指令发给 Claude，返回调整后的块清单。
//  失败/空 → **抛错**（0.29.0 起）：「保持原样」的决定上收到 FoundationModelsPlanRefiner 链
//  （云端失败要先给端侧 FM 兜底的机会，这里吞掉错误链就断了）。试验台直接用本类=失败如实计败。
//

import Foundation

struct ClaudePlanRefiner: PlanRefining {
    let client: AnthropicClient

    private struct OutBlock: Encodable {
        let title: String; let start: String; let end: String
        let isFixed: Bool; let timingStyle: String; let priority: String
    }
    private struct Wire: Decodable { let blocks: [WireBlock] }
    private struct WireBlock: Decodable {
        let title: String; let start: String; let end: String
        let isFixed: Bool?; let timingStyle: String?; let priority: String?
    }

    func refine(_ blocks: [ScheduledBlock], command: String,
                originalRequest: String, now: Date) async throws -> [ScheduledBlock] {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !blocks.isEmpty else { return blocks }
        do {
            let out = blocks.map {
                OutBlock(title: $0.title, start: Self.fmt($0.start), end: Self.fmt($0.end),
                         isFixed: $0.isFixed, timingStyle: $0.timingStyle.rawValue, priority: $0.priority.rawValue)
            }
            let listing = String(data: try JSONEncoder().encode(["blocks": out]), encoding: .utf8) ?? "{}"
            let req = originalRequest.trimmingCharacters(in: .whitespacesAndNewlines)
            let reqSection = req.isEmpty ? "" : """
            用户最初的排程需求（这些约束仍然有效，调整时不要违背）：
            \(req)

            """
            let user = """
            \(reqSection)当前日程：\(listing)
            用户调整指令：\(cmd)
            按指令修改对应块（时间/标题/固定/计时风格/优先级），未提到的块保持不变，且不违背最初需求里的约束（如娱乐时长下限、结束时间等）。
            只输出 JSON：{"blocks":[{"title":"","start":"YYYY-MM-DD HH:mm","end":"YYYY-MM-DD HH:mm","isFixed":false,"timingStyle":"light","priority":"normal"}]}
            """
            // 4000 见过截断（2026-07-07 17:16 日志）：微调返回完整清单、块多时不够 → 提到 8000
            let client = self.client
            // 看门狗 10s（p95 定值，2026-07-10）：超时抛错 → 上层链先试 FM 兜底再定原样
            // 缓存（#21④）：本 prompt 全静态 → 整段作缓存前缀（cache_control），user 消息承载全部动态
            let raw = try await LLMWatchdog.run {
                try await client.complete(system: "", user: user, maxTokens: 8000,
                                          jsonMode: true, jsonSchema: Self.outputSchema,
                                          cachedSystemPrefix: Self.systemPrompt)
            }
            let json = JSONText.extractObject(raw)
            guard let data = json.data(using: .utf8) else { throw AnthropicError(message: "JSON 编码失败") }
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            let result: [ScheduledBlock] = wire.blocks.compactMap { b in
                guard let s = DateParsing.parse(b.start), let e = DateParsing.parse(b.end) else { return nil }
                return ScheduledBlock(title: b.title, start: s, end: e,
                                      isFixed: b.isFixed ?? false,
                                      timingStyle: TimingStyle(rawValue: b.timingStyle ?? "light") ?? .light,
                                      priority: BlockPriority(rawValue: b.priority ?? "normal") ?? .normal)
            }
            guard !result.isEmpty else {
                DevLog.shared.warn("微调", "云端返回空")
                throw AnthropicError(message: "微调返回空结果")
            }
            DevLog.shared.info("微调", "云端成功 · \(result.count) 块")
            return result
        } catch {
            DevLog.shared.warn("微调", "云端失败：\(error.localizedDescription)")
            throw error
        }
    }

    static func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static let systemPrompt = PromptConstitution.with("你在调整一个已排好的一天日程。依据用户的中文调整指令修改对应的块，未提到的块保持不变。只输出 JSON，不要解释、不要 markdown 围栏。")

    /// 结构化输出 schema（`output_config.format`）：约束模型直出这个形状的 JSON。
    /// 对齐 `WireBlock`；所有字段列入 required（结构化输出要求），Swift 侧仍按缺省容错。
    static let outputSchema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["blocks"],
        "properties": [
            "blocks": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["title", "start", "end", "isFixed", "timingStyle", "priority"],
                    "properties": [
                        "title": ["type": "string"],
                        "start": ["type": "string"],
                        "end": ["type": "string"],
                        "isFixed": ["type": "boolean"],
                        "timingStyle": ["type": "string", "enum": ["pomodoro", "light", "none"]],
                        "priority": ["type": "string", "enum": ["normal", "important"]],
                    ],
                ],
            ],
        ],
    ]
}
