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
    }

    func arrange(_ blocks: [ScheduledBlock], now: Date) async throws -> PlanDecision {
        guard !blocks.isEmpty else { return try await fallback.arrange(blocks, now: now) }
        do {
            let listing = blocks.enumerated()
                .map { i, b in "\(i): \(b.title) [\(b.priority.rawValue)] \(Self.hm(b.start))–\(Self.hm(b.end))" }
                .joined(separator: "\n")
            let user = """
            现在 \(Self.hm(now))。今日时间块（索引: 标题 [优先级] 起–止）：
            \(listing)
            按行为策略排出推荐顺序，并写一句温和、前向的 note。
            只输出 JSON：{"orderedIndexes":[按推荐顺序的索引数组],"note":"一句话"}
            """
            let raw = try await client.complete(system: Self.systemPrompt, user: user, maxTokens: 1024)
            let json = JSONText.extractObject(raw)
            guard let data = json.data(using: .utf8) else { throw AnthropicError(message: "JSON 编码失败") }
            let wire = try JSONDecoder().decode(Wire.self, from: data)

            var seen = Set<Int>()
            var order: [Int] = []
            for i in (wire.orderedIndexes ?? []) where i >= 0 && i < blocks.count && !seen.contains(i) {
                seen.insert(i); order.append(i)
            }
            for i in blocks.indices where !seen.contains(i) { order.append(i) }  // 补齐遗漏

            let ordered = order.map { blocks[$0] }
            DevLog.shared.info("排程", "云端成功 · \(ordered.count) 块")
            return PlanDecision(orderedBlocks: ordered, note: wire.note)
        } catch {
            DevLog.shared.warn("排程", "云端失败，回退本地：\(error.localizedDescription)")
            return try await fallback.arrange(blocks, now: now)
        }
    }

    static func hm(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static let systemPrompt = """
    你是 BetterCalendar 的「排程大脑」。情感目标 = 掌控感 + 成就感，不是纪律。原则：
    1) 要紧事(important)优先靠前(eat-the-frog)；
    2) 措辞中性/正向、前向（给下一步），禁用"失败/落后/又没做到"；
    3) 温和、不施压。
    根据用户今日时间块给出推荐顺序与一句温和的 note。只输出 JSON。
    """
}
