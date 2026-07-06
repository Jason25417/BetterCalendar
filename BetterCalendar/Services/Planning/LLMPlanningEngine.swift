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
            let raw = try await client.complete(system: Self.systemPrompt, user: user, maxTokens: 4000, jsonMode: true)
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
        let note: String?
    }

    /// 自愈 reflow：LLM 决定弹性块执行顺序（撞固定块智能重排），本地用 ReflowLayout 铺时间。失败回退本地。
    func reflow(_ blocks: [ScheduledBlock], from startTime: Date, now: Date) async throws -> PlanDecision {
        guard !blocks.isEmpty else { return try await fallback.reflow(blocks, from: startTime, now: now) }
        do {
            let listing = blocks.enumerated()
                .map { i, b in "\(i): \(b.title) [\(b.isFixed ? "固定" : "弹性")] 原 \(Self.hm(b.start))–\(Self.hm(b.end))" }
                .joined(separator: "\n")
            let user = """
            现在 \(Self.hm(startTime))。需要从现在起重排今天剩余。时间块（索引: 标题 [固定/弹性] 原起止）：
            \(listing)
            固定块时间不动；弹性块要在固定块开始前尽量塞"力所能及、来得及"的事避冲突。
            给出**弹性块**的推荐执行顺序（只列弹性块索引）+ 一句温和前向的 note。
            只输出 JSON：{"flexibleOrder":[弹性块索引...],"note":"一句话"}
            """
            let raw = try await client.complete(system: Self.reflowSystemPrompt, user: user, maxTokens: 4000, jsonMode: true)
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
            for (i, b) in blocks.enumerated() where !b.isFixed && !seen.contains(i) { flexible.append(b) }

            let laid = ReflowLayout.layOut(flexible: flexible, fixed: fixed, from: startTime)
            DevLog.shared.info("reflow", "云端成功 · \(laid.count) 块")
            return PlanDecision(orderedBlocks: laid, note: wire.note,
                                conflict: ReflowLayout.conflict(in: laid, now: now))
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

    static var reflowSystemPrompt: String { PromptConstitution.with("""
    你是「自愈排程大脑」。用户需要从现在起重排今天剩余（**不回顾、不算账**）。原则：
    1) **固定块（会议等）时间绝不动**；
    2) 撞固定块时，优先把"力所能及、固定块开始前来得及"的弹性块排到前面，智能重排顺序避免冲突；
    3) **收工时间（软限制）= \(WorkHoursSettings.windDownText)**：尽量别把弹性块排到收工时间之后（略超 5–10 分钟正好能多做完一件大事则可以）；排不进收工前的，**宁可今天不排（留给明天/以后）也别硬塞到深夜**。用户明确排在收工后的晚间块保持不动、别提前。
    4) 措辞给掌控感（"接下来这样就能收尾"），不施压（红线见宪法）。
    只输出 JSON：{"flexibleOrder":[弹性块索引...],"note":"一句温和前向的话"}
    """) }
}
