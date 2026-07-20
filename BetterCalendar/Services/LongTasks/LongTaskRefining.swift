//
//  LongTaskRefining.swift
//  BetterCalendar
//
//  长期任务的「说一句」——**同时支持新增与修改现有项**（2026-07-20 Jason 要求：
//  「AI 调整不只是加新项目，也要能改现有项目」）。与排日程页「一框双模」对称（U7 同语义同组件）：
//  那边是 排今天/AI微调，这边是 加新的/改现有的——**同一个框，模型自己判断意图**。
//
//  红线：
//   - **只提议不落库**：产出是草稿（creates + updates），用户逐条过目、点「收下」才写入（代理而不代权）。
//   - **不删除**：删任务/删阶段属破坏性操作（U10 距离），只能在详情页手动做——模型永远不提议删。
//   - 阶段仍**无各自 DDL**（检查点无期限红线）；模型只能加阶段名。
//

import Foundation

/// 对现有长期任务的一处修改（字段 nil = 不改）。双 optional 语义：
/// `.some(nil)` = 显式清空该量（用户说「GRE 不设截止了」），`nil` = 不动。
struct LongTaskUpdate: Sendable, Identifiable {
    var id = UUID()
    /// 目标任务（按标题相似匹配现有在途项）。
    var targetTitle: String
    var newTitle: String?
    var deadline: Date??
    var cadenceMinutesPerWeek: Int??
    var totalMinutes: Int??
    /// 要追加的阶段名（按序）；模型不得提议删除阶段。
    var addCheckpoints: [String] = []

    /// 给用户看的一句人话摘要（草稿卡用）。
    var summary: String {
        var parts: [String] = []
        if let t = newTitle { parts.append("改名为「\(t)」") }
        if let d = deadline {
            parts.append(d.map { "截止改为 \($0.formatted(.dateTime.month().day()))" } ?? "取消截止")
        }
        if let c = cadenceMinutesPerWeek {
            parts.append(c.map { "每周改为约 \(ReviewSummaryText.hm($0))" } ?? "取消每周节奏")
        }
        if let t = totalMinutes {
            parts.append(t.map { "总量改为约 \(ReviewSummaryText.hm($0))" } ?? "取消总量")
        }
        if !addCheckpoints.isEmpty { parts.append("加阶段：" + addCheckpoints.joined(separator: " → ")) }
        return parts.isEmpty ? "（没有可识别的改动）" : parts.joined(separator: " · ")
    }
    /// 空修改（模型返回了但什么都没改）→ 不进草稿，免得用户点了个寂寞。
    var isEmpty: Bool {
        newTitle == nil && deadline == nil && cadenceMinutesPerWeek == nil
            && totalMinutes == nil && addCheckpoints.isEmpty
    }
}

/// 一次「说一句」的产物：新增 + 修改（两者可同时出现）。
struct LongTaskPlanEdit: Sendable {
    var creates: [ParsedLongTask] = []
    var updates: [LongTaskUpdate] = []
    var isEmpty: Bool { creates.isEmpty && updates.isEmpty }
}

/// 现有任务的摘要（喂给模型做匹配用；实现无关 DTO）。
struct LongTaskContext: Sendable {
    var title: String
    var deadline: Date?
    var cadenceMinutesPerWeek: Int?
    var totalMinutes: Int?
    var checkpoints: [String] = []
}

protocol LongTaskRefining {
    /// text = 用户说的一句话；existing = 现有在途任务（空数组=只可能新增）。
    func refine(text: String, existing: [LongTaskContext], now: Date) async throws -> LongTaskPlanEdit
}

// MARK: - 云端实现

struct ClaudeLongTaskRefiner: LongTaskRefining {
    let client: AnthropicClient

    func refine(text: String, existing: [LongTaskContext], now: Date) async throws -> LongTaskPlanEdit {
        let listing = existing.isEmpty ? "（还没有长期任务）" : existing.enumerated().map { i, t -> String in
            var parts = ["\(i): \(t.title)"]
            if let d = t.deadline { parts.append("DDL \(Self.ymd(d))") }
            if let c = t.cadenceMinutesPerWeek { parts.append("每周\(c)分钟") }
            if let m = t.totalMinutes { parts.append("共\(m)分钟") }
            if !t.checkpoints.isEmpty { parts.append("阶段：" + t.checkpoints.joined(separator: "→")) }
            return parts.joined(separator: " · ")
        }.joined(separator: "\n")

        let user = """
        今天是 \(Self.ymd(now))。用户现有的长期任务：
        \(listing)

        用户说：「\(text)」

        判断这句话是**新增**一件长期的事，还是**修改现有**的某一件（也可能两者都有）。
        - 修改：targetTitle 必须**原样抄**上面列表里的标题；只填要改的字段，不改的给 null。
          日期一律写 "YYYY-MM-DD"（只到天，别带时间）。
          清空某个设定（"不设截止了"）用 "clear"。加阶段放 addCheckpoints（只给名字、不给日期）。
        - 新增：整件事放 creates。
        - 都不像（比如在问问题）：两个数组都给空。
        绝不提议删除任何任务或阶段。
        """
        // 看门狗放宽到 20s（跑分：p95 6.8s / max 7.0s，10s 曾误杀一次 L3）
        let raw = try await LLMWatchdog.run(seconds: 20) {
            try await client.complete(system: "", user: user, maxTokens: 2000,
                                      jsonMode: true, jsonSchema: Self.schema,
                                      cachedSystemPrefix: Self.systemPrompt)
        }
        return Self.decode(raw, existing: existing)
    }

    /// 解码（纯函数、可单测）：脏数据一律丢弃，宁缺勿脏。
    static func decode(_ raw: String, existing: [LongTaskContext]) -> LongTaskPlanEdit {
        let json = JSONText.extractObject(raw)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return LongTaskPlanEdit()
        }
        var edit = LongTaskPlanEdit()

        for c in (obj["creates"] as? [[String: Any]]) ?? [] {
            guard let title = (c["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            let cps = ((c["checkpoints"] as? [Any]) ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            edit.creates.append(ParsedLongTask(title: title,
                                               deadline: DateParsing.parseDeadline(c["deadline"] as? String),
                                               cadenceMinutesPerWeek: intOf(c["cadenceMinutesPerWeek"]),
                                               totalMinutes: intOf(c["totalMinutes"]),
                                               unitMinutes: intOf(c["unitMinutes"]),
                                               checkpoints: cps))
        }

        for u in (obj["updates"] as? [[String: Any]]) ?? [] {
            guard let target = (u["targetTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty,
                  // 目标必须**真的存在**（防模型幻觉出一个不存在的任务去改）
                  existing.contains(where: { TitleMatch.similarity($0.title, target) >= 0.6 }) else { continue }
            var up = LongTaskUpdate(targetTitle: target)
            if let t = (u["newTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                up.newTitle = t
            }
            up.deadline = dateField(u["deadline"])
            up.cadenceMinutesPerWeek = intField(u["cadenceMinutesPerWeek"])
            up.totalMinutes = intField(u["totalMinutes"])
            up.addCheckpoints = ((u["addCheckpoints"] as? [Any]) ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !up.isEmpty { edit.updates.append(up) }
        }
        return edit
    }

    // "clear" → .some(nil)（显式清空）；null/缺失 → nil（不改）；有值 → .some(值)
    private static func dateField(_ v: Any?) -> Date?? {
        guard let s = v as? String else { return nil }
        if s.lowercased() == "clear" { return .some(nil) }
        // 截止语义：纯日期落当天 23:59（跑分 L1 实锤修复）
        return DateParsing.parseDeadline(s).map { .some($0) }
    }
    private static func intField(_ v: Any?) -> Int?? {
        if let s = v as? String {
            if s.lowercased() == "clear" { return .some(nil) }
            return Int(s).map { .some($0) }
        }
        if let i = v as? Int { return .some(i) }
        return nil
    }
    private static func intOf(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap(Int.init) }

    private static func ymd(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static let systemPrompt = """
    你是长期任务助手。把用户的一句话变成「新增」或「对现有任务的修改」。只输出 JSON，不要解释。
    绝不提议删除任务或阶段；阶段只给名字、绝不给各自的日期。
    """

    private static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["creates", "updates"],
        "properties": [
            "creates": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["title", "deadline", "cadenceMinutesPerWeek", "totalMinutes",
                                 "unitMinutes", "checkpoints"],
                    "properties": [
                        "title": ["type": "string"],
                        "deadline": ["type": ["string", "null"]],
                        "cadenceMinutesPerWeek": ["type": ["integer", "null"]],
                        "totalMinutes": ["type": ["integer", "null"]],
                        "unitMinutes": ["type": ["integer", "null"]],
                        "checkpoints": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
            ],
            "updates": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["targetTitle", "newTitle", "deadline", "cadenceMinutesPerWeek",
                                 "totalMinutes", "addCheckpoints"],
                    "properties": [
                        "targetTitle": ["type": "string"],
                        "newTitle": ["type": ["string", "null"]],
                        "deadline": ["type": ["string", "null"]],
                        "cadenceMinutesPerWeek": ["type": ["string", "integer", "null"]],
                        "totalMinutes": ["type": ["string", "integer", "null"]],
                        "addCheckpoints": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
            ],
        ],
    ]
}
