//
//  ClaudeScheduleParser.swift
//  BetterCalendar
//
//  云端解析（M1）：自然语言 → 结构化 PlanBlock[]，走 Anthropic API。
//  失败/未配 key/离线 → 回退本地 StubScheduleParser。
//

import Foundation

struct ClaudeScheduleParser: ScheduleParsing {
    let client: AnthropicClient
    let fallback: ScheduleParsing

    private struct WirePlan: Decodable { let blocks: [WireBlock] }
    private struct WireBlock: Decodable {
        let title: String
        let start: String
        let end: String
        let isFixed: Bool?
        let category: String?
        let timingStyle: String?
        let priority: String?
        let deadline: String?
    }

    func parse(_ text: String, referenceDate: Date) async throws -> ParsedPlan {
        do {
            let raw = try await client.complete(
                system: Self.systemPrompt(referenceDate: referenceDate), user: text)
            let json = JSONText.extractObject(raw)
            guard let data = json.data(using: .utf8) else { throw AnthropicError(message: "JSON 编码失败") }
            let wire = try JSONDecoder().decode(WirePlan.self, from: data)
            let blocks: [ParsedBlock] = wire.blocks.compactMap { b in
                guard let s = DateParsing.parse(b.start), let e = DateParsing.parse(b.end) else { return nil }
                return ParsedBlock(
                    title: b.title,
                    start: s,
                    end: e,
                    durationMinutes: Int(e.timeIntervalSince(s) / 60),
                    isFixed: b.isFixed ?? false,
                    category: b.category ?? "",
                    timingStyle: TimingStyle(rawValue: b.timingStyle ?? "light") ?? .light,
                    priority: BlockPriority(rawValue: b.priority ?? "normal") ?? .normal,
                    deadline: DateParsing.parse(b.deadline))
            }
            guard !blocks.isEmpty else {
                DevLog.shared.warn("解析", "云端返回 0 块，回退本地")
                return try await fallback.parse(text, referenceDate: referenceDate)
            }
            DevLog.shared.info("解析", "云端成功 · \(blocks.count) 块 · \(CloudSettings.model)")
            return ParsedPlan(blocks: blocks)
        } catch {
            DevLog.shared.warn("解析", "云端失败，回退本地：\(error.localizedDescription)")
            return try await fallback.parse(text, referenceDate: referenceDate)
        }
    }

    static func systemPrompt(referenceDate: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let now = df.string(from: referenceDate)
        return """
        你把用户用自然语言描述的一天，转成结构化日程。当前时间：\(now)。
        只输出一个 JSON 对象，不要任何解释、不要 markdown 代码围栏。格式：
        {"blocks":[{"title":"","start":"YYYY-MM-DD HH:mm","end":"YYYY-MM-DD HH:mm","isFixed":false,"category":"","timingStyle":"light","priority":"normal","deadline":null}]}
        规则：start/end 用 24 小时制本地时间；isFixed=在固定时刻发生（如会议）；timingStyle ∈ pomodoro/light/none，默认 light；priority ∈ normal/important（要紧/紧急的事用 important）；deadline 为硬截止时间或 null。相对时间（如"明早"）按当前时间推算。
        """
    }
}
