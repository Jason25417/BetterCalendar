//
//  LLMPlanningEngine.swift
//  BetterCalendar
//
//  排程大脑（M1）：按「产品设计与行为逻辑 §3」给排序 + 温和 note，走 Anthropic API。
//  失败 → 回退本地 NaivePlanningEngine。
//

import Foundation

struct LLMPlanningEngine: PlanningEngine {
    let client: AnthropicClient
    let fallback: PlanningEngine

    private struct Wire: Decodable {
        let orderedIndexes: [Int]?
        let note: String?
        let poolSuggestions: [WirePoolSuggestion]?
    }
    private struct WirePoolSuggestion: Decodable {
        let poolIndex: Int
        let start: String
        let end: String
    }

    func arrange(_ blocks: [ScheduledBlock], now: Date) async throws -> PlanDecision {
        try await arrange(blocks, pool: [], now: now)
    }

    /// 带「在途」池的排程（M10-2）：池摘要进 prompt，LLM 可在空档给 0–2 个建议块（标来源）。
    func arrange(_ blocks: [ScheduledBlock], pool: [LongTaskBrief], now: Date) async throws -> PlanDecision {
        guard !blocks.isEmpty else { return try await fallback.arrange(blocks, now: now) }
        do {
            let listing = blocks.enumerated()
                .map { i, b in
                    let tags = "\(b.priority.rawValue)\(b.isFixed ? ",固定" : "")"
                    return "\(i): \(b.title) [\(tags)] \(Self.hm(b.start))–\(Self.hm(b.end))"
                }
                .joined(separator: "\n")
            let poolListing = pool.enumerated().map { i, t -> String in
                var parts = ["P\(i): \(t.title)"]
                if let d = t.deadline { parts.append("DDL \(Self.ymdhm(d))") }
                if let c = t.cadenceMinutesPerWeek { parts.append("每周约 \(c) 分钟") }
                return parts.joined(separator: " · ")
            }.joined(separator: "\n")
            let poolSection = pool.isEmpty ? "" : """

            「在途」长期事项池（用户跨日在做的事）：
            \(poolListing)
            若当日有空档且合适，可从池中挑 **0–2 件** 建议排入（DDL 近的优先、节奏欠账的优先；已在今日块里的同名事不要重复建议；不合适就不建议——宁缺毋滥）。
            """
            let user = """
            现在 \(Self.hm(now))。今日时间块（索引: 标题 [优先级] 起–止）：
            \(listing)
            \(poolSection)
            按行为策略排出推荐顺序，并写一句温和、前向的 note。
            只输出 JSON：{"orderedIndexes":[按推荐顺序的索引数组],"note":"一句话","poolSuggestions":[{"poolIndex":0,"start":"YYYY-MM-DD HH:mm","end":"YYYY-MM-DD HH:mm"}]}
            没有建议时 poolSuggestions 给 []。
            """
            let raw = try await client.complete(system: Self.systemPrompt, user: user, maxTokens: 4000,
                                                jsonMode: true, jsonSchema: Self.arrangeSchema)
            let json = JSONText.extractObject(raw)
            guard let data = json.data(using: .utf8) else { throw AnthropicError(message: "JSON 编码失败") }
            let wire = try JSONDecoder().decode(Wire.self, from: data)

            var seen = Set<Int>()
            var order: [Int] = []
            for i in (wire.orderedIndexes ?? []) where i >= 0 && i < blocks.count && !seen.contains(i) {
                seen.insert(i); order.append(i)
            }
            for i in blocks.indices where !seen.contains(i) { order.append(i) }  // 补齐遗漏

            var ordered = order.map { blocks[$0] }
            // 池建议块（≤2）：附在后面，标题记入 poolSuggestedTitles 供 UI 标来源
            var suggestedTitles: [String] = []
            for s in (wire.poolSuggestions ?? []).prefix(2)
            where s.poolIndex >= 0 && s.poolIndex < pool.count {
                guard let start = DateParsing.parse(s.start), let end = DateParsing.parse(s.end),
                      end > start else { continue }
                let t = pool[s.poolIndex]
                ordered.append(ScheduledBlock(title: t.title, start: start, end: end,
                                              deadline: t.deadline))
                suggestedTitles.append(t.title)
            }
            DevLog.shared.info("排程", "云端成功 · \(ordered.count) 块"
                               + (suggestedTitles.isEmpty ? "" : " · 在途建议 \(suggestedTitles.count)"))
            return PlanDecision(orderedBlocks: ordered, note: wire.note,
                                poolSuggestedTitles: suggestedTitles)
        } catch {
            DevLog.shared.warn("排程", "云端失败，回退本地：\(error.localizedDescription)")
            return try await fallback.arrange(blocks, now: now)
        }
    }

    private struct ReflowWire: Decodable {
        let flexibleOrder: [Int]?
        let deferred: [Int]?    // 0.23 B：候补通道——模型第一次拥有「今天不排」的表达能力
        let note: String?
    }

    /// 自愈 reflow（0.23 B 起 V2）：LLM 决定弹性块执行顺序 + 候补取舍（deferred 通道），
    /// 本地 ReflowLayoutV2 铺时间并**硬执法收工线**（不信任模型：LLM 没让路的本地也截；
    /// LLM 让路的 ★/晚间块本地否决）。失败回退本地（本地同样执法，约束不随降级消失）。
    func reflow(_ blocks: [ScheduledBlock], from startTime: Date, now: Date) async throws -> PlanDecision {
        guard !blocks.isEmpty else { return try await fallback.reflow(blocks, from: startTime, now: now) }
        do {
            let windDown = WorkHoursSettings.effectiveWindDown(from: startTime)
            let listing = blocks.enumerated()
                .map { i, b in
                    var marks = ""
                    if b.priority == .important { marks += "[★]" }
                    if let g = b.parallelGroup {
                        marks += "[并行:\(g.replacingOccurrences(of: ScheduledBlock.parallelPrefix, with: ""))]"
                    }
                    if !b.isFixed && b.start >= windDown { marks += "[晚间]" }
                    return "\(i): \(b.title) [\(b.isFixed ? "固定" : "弹性")]\(marks) 原 \(Self.hm(b.start))–\(Self.hm(b.end))"
                }
                .joined(separator: "\n")
            let user = """
            现在 \(Self.hm(startTime))。需要从现在起重排今天剩余。时间块（索引: 标题 [固定/弹性][标记] 原起止）：
            \(listing)
            给出弹性块的执行顺序 flexibleOrder + 放不进收工线的候补 deferred（两者不重复、合起来覆盖全部弹性块）+ 一句 note。
            """
            let raw = try await client.complete(system: Self.reflowSystemPrompt(windDownText: Self.hm(windDown)),
                                                user: user, maxTokens: 4000,
                                                jsonMode: true, jsonSchema: Self.reflowSchema)
            let json = JSONText.extractObject(raw)
            guard let data = json.data(using: .utf8) else { throw AnthropicError(message: "JSON 编码失败") }
            let wire = try JSONDecoder().decode(ReflowWire.self, from: data)

            let fixed = blocks.filter { $0.isFixed }
            var seen = Set<Int>()
            var flexible: [ScheduledBlock] = []
            for i in (wire.flexibleOrder ?? [])
            where i >= 0 && i < blocks.count && !blocks[i].isFixed && !seen.contains(i) {
                seen.insert(i); flexible.append(blocks[i])
            }
            // LLM 点名候补的（合法索引、非固定、没在顺序里出现过）→ 记 id；本地执法可否决（★/晚间）
            let llmDeferredIDs = Set((wire.deferred ?? [])
                .filter { $0 >= 0 && $0 < blocks.count && !blocks[$0].isFixed && !seen.contains($0) }
                .map { blocks[$0].id })
            // 两边都没点到的弹性块补进排队尾（同旧语义：漏了不丢）
            for (i, b) in blocks.enumerated()
            where !b.isFixed && !seen.contains(i) && !llmDeferredIDs.contains(b.id) { flexible.append(b) }

            let laid = ReflowLayoutV2.layOut(
                flexible: flexible + blocks.filter { llmDeferredIDs.contains($0.id) },
                fixed: fixed, from: startTime,
                windDown: windDown, graceMinutes: WorkHoursSettings.graceMinutes,
                llmDeferred: llmDeferredIDs)
            DevLog.shared.info("reflow", "云端成功 · 排定 \(laid.scheduled.count) 块"
                               + (laid.deferred.isEmpty ? "" : " · 候补 \(laid.deferred.count) 块"))
            return PlanDecision(orderedBlocks: laid.scheduled, note: wire.note, deferred: laid.deferred)
        } catch {
            DevLog.shared.warn("reflow", "云端失败，回退本地：\(error.localizedDescription)")
            return try await fallback.reflow(blocks, from: startTime, now: now)
        }
    }

    static func hm(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func ymdhm(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static let systemPrompt = PromptConstitution.with("""
    你是「排程大脑」。原则：
    1) 要紧事(important)优先靠前(eat-the-frog)；
    2) **固定块（标"固定"，如会议）保持原时间，不要建议挪动**；
    3) 温和、不施压（措辞红线见宪法）。
    根据用户今日时间块给出推荐顺序与一句温和的 note。只输出 JSON。
    """)

    /// 0.23 B（V2，自试验台毕业）：deferred 通道 + 收工线硬约束。试验台留有 v1 冻结快照可对比。
    static func reflowSystemPrompt(windDownText: String) -> String { PromptConstitution.with("""
    你是「自愈排程大脑」。用户需要从现在起重排今天剩余（**不回顾、不算账**）。原则：
    1) **固定块（会议等）时间绝不动**；标了 [晚间] 的块是用户自己排在收工后的，保持原时间、不提前不挪动。
    2) **收工线（硬约束）= \(windDownText)**（宽限 \(WorkHoursSettings.graceMinutes) 分钟）：按你给的顺序从现在起依次铺开，整块放不进 收工线+宽限 的弹性块，放进 deferred（= 候补：今天不排时间、温和地留在清单里可随时手动开始，**不是失败不是删除**）。
    3) **[★] 要紧事绝不放 deferred**——超线也照排，它的去留由用户决定，不由你。
    4) 排序智能：短平快的事可以排在大块之前塞进空隙，让收工线内完成的件数更多；撞固定块的顺延由本地铺排处理，你只管顺序与取舍。
    5) [并行:组名] 的块会被本地绑定为同一时段，视作一个槽考虑。
    6) 措辞给掌控感（"接下来这样就能收尾"），不施压（红线见宪法）。
    只输出 JSON：{"flexibleOrder":[要排的弹性块索引，按执行顺序],"deferred":[进候补的弹性块索引],"note":"一句温和前向的话"}
    """) }

    // MARK: 结构化输出 schema（`output_config.format`）—— 对齐 Wire / ReflowWire

    static let arrangeSchema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["orderedIndexes", "note", "poolSuggestions"],
        "properties": [
            "orderedIndexes": ["type": "array", "items": ["type": "integer"]],
            "note": ["type": "string"],
            "poolSuggestions": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["poolIndex", "start", "end"],
                    "properties": [
                        "poolIndex": ["type": "integer"],
                        "start": ["type": "string"],
                        "end": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]

    static let reflowSchema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["flexibleOrder", "deferred", "note"],
        "properties": [
            "flexibleOrder": ["type": "array", "items": ["type": "integer"]],
            "deferred": ["type": "array", "items": ["type": "integer"]],
            "note": ["type": "string"],
        ],
    ]
}
