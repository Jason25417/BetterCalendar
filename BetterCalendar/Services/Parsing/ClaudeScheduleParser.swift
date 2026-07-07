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
    var liveDraft: LiveDraft?   // 云端流式（0.20.1）：边生成边把完整块冒进草稿区（同端侧 FM 那条管子）；nil=非流式

    /// 宽容解码（0.15.2）：JSONSerialization 手工取值——字段类型不合/多余字段/单块损坏都不废全包，
    /// 坏块跳过并计数。严格 Codable 曾因 LLM 一个字段类型漂移整包报废 → 回退本地桩产垃圾草稿。
    static func decodePlan(_ json: String) -> (blocks: [ParsedBlock], longTasks: [ParsedLongTask], loose: Bool, dropped: Int)? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var dropped = 0
        let loose = (obj["loose"] as? Bool) ?? ((obj["loose"] as? String).map { $0 == "true" } ?? false)
        var blocks: [ParsedBlock] = []
        for b in (obj["blocks"] as? [[String: Any]]) ?? [] {
            guard let title = b["title"] as? String,
                  let start = DateParsing.parse(b["start"] as? String),
                  let end = DateParsing.parse(b["end"] as? String) else { dropped += 1; continue }
            blocks.append(ParsedBlock(
                title: title, start: start, end: end,
                durationMinutes: Int(end.timeIntervalSince(start) / 60),
                isFixed: b["isFixed"] as? Bool ?? false,
                isAnchor: b["isAnchor"] as? Bool ?? false,
                category: b["category"] as? String ?? "",
                timingStyle: TimingStyle(rawValue: b["timingStyle"] as? String ?? "light") ?? .light,
                priority: BlockPriority(rawValue: b["priority"] as? String ?? "normal") ?? .normal,
                deadline: DateParsing.parse(b["deadline"] as? String)))
        }
        var longTasks: [ParsedLongTask] = []
        for t in (obj["longTasks"] as? [[String: Any]]) ?? [] {
            guard let title = t["title"] as? String, !title.isEmpty else { dropped += 1; continue }
            let cadence = (t["cadenceMinutesPerWeek"] as? Int)
                ?? (t["cadenceMinutesPerWeek"] as? String).flatMap(Int.init)
            func intOf(_ k: String) -> Int? { (t[k] as? Int) ?? (t[k] as? String).flatMap(Int.init) }
            longTasks.append(ParsedLongTask(title: title,
                                            deadline: DateParsing.parse(t["deadline"] as? String),
                                            cadenceMinutesPerWeek: cadence,
                                            totalMinutes: intOf("totalMinutes"),
                                            unitMinutes: intOf("unitMinutes")))
        }
        return (blocks, longTasks, loose, dropped)
    }

    func parse(_ text: String, referenceDate: Date) async throws -> ParsedPlan {
        try await parse(text, referenceDate: referenceDate, context: ParseContext())
    }

    /// 流式部分文本 → 已完整闭合的块（喂 LiveDraft 边生成边显示）。纯函数、可单测。
    static func liveBlocks(fromPartial partial: String) -> [ScheduledBlock] {
        let objects = JSONText.completeArrayObjects(in: partial, arrayKey: "\"blocks\"")
        guard !objects.isEmpty else { return [] }
        // 拼回 {"blocks":[…]} 复用宽容解码（单块损坏跳过、字段漂移不废全包）
        guard let decoded = Self.decodePlan("{\"blocks\":[\(objects.joined(separator: ","))]}") else { return [] }
        return decoded.blocks.compactMap { pb in
            guard let s = pb.start, let e = pb.end else { return nil }
            return ScheduledBlock(title: pb.title, start: s, end: e, isFixed: pb.isFixed,
                                  isAnchor: pb.isAnchor, timingStyle: pb.timingStyle,
                                  priority: pb.priority, deadline: pb.deadline)
        }
    }

    func parse(_ text: String, referenceDate: Date, context: ParseContext) async throws -> ParsedPlan {
        do {
            // 长日程输出可观（20+ 块 + 长期任务），上限给足（2048→6000→10000：6000 仍见截断，2026-07-07 日志实锤；
            // 若加了预算还截断=模型在循环复读，看「云端原文」截断样本的尾 500 字即知）
            let system = Self.systemPrompt(referenceDate: referenceDate, context: context)
            let raw: String
            if let live = liveDraft {
                // 云端流式：SSE 边收边把已闭合的块冒进草稿区（0.20.1，同端侧 FM 的体验）
                var lastCount = 0
                raw = try await client.completeStreaming(
                    system: system, user: text, maxTokens: 10000, jsonSchema: Self.parseSchema) { partial in
                    guard partial.hasSuffix("}") || partial.last == "," else { return }   // 只在可能新闭合时重扫
                    let blocks = Self.liveBlocks(fromPartial: partial)
                    if blocks.count != lastCount {
                        lastCount = blocks.count
                        live.streaming = blocks.sorted { $0.start < $1.start }
                    }
                }
                live.clear()   // 最终结果即将替换草稿，收掉流式暂显
            } else {
                raw = try await client.complete(
                    system: system, user: text, maxTokens: 10000, jsonMode: true, jsonSchema: Self.parseSchema)
            }
            let json = JSONText.extractObject(raw)
            guard let decoded = Self.decodePlan(json) else {
                DevLog.shared.warn("解析", "JSON 解码失败，原文前 300 字：\(String(raw.prefix(300)))")
                throw AnthropicError(message: "JSON 解码失败")
            }
            if decoded.dropped > 0 {
                DevLog.shared.warn("解析", "跳过 \(decoded.dropped) 个损坏条目（其余正常解析）")
            }
            let blocks = decoded.blocks
            let longTasks = decoded.longTasks
            // 纯松散意图（"明天松散一下"）可无块无长期事项 → 不回退，照样把松散标志带上来
            guard !blocks.isEmpty || !longTasks.isEmpty || decoded.loose else {
                DevLog.shared.warn("解析", "云端返回 0 块，回退本地")
                return try await fallback.parse(text, referenceDate: referenceDate, context: context)
            }
            DevLog.shared.info("解析", "云端成功 · \(blocks.count) 块"
                               + (longTasks.isEmpty ? "" : " · \(longTasks.count) 在途")
                               + (decoded.loose ? " · 松散" : "") + " · \(CloudSettings.activeModel)")
            return ParsedPlan(blocks: blocks, longTasks: longTasks, isLoose: decoded.loose)
        } catch {
            liveDraft?.clear()   // 失败也别留流式残影
            DevLog.shared.warn("解析", "云端失败，回退本地：\(error.localizedDescription)")
            return try await fallback.parse(text, referenceDate: referenceDate, context: context)
        }
    }

    static func systemPrompt(referenceDate: Date, context: ParseContext = ParseContext()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd EEEE"
        let target = df.string(from: referenceDate)
        df.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let realNow = df.string(from: .now)
        let poolSection = context.pool.isEmpty ? "（空）" : context.pool.map { t -> String in
            var parts = [t.title]
            if let d = t.deadline { parts.append("DDL " + { let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d) }()) }
            if let c = t.cadenceMinutesPerWeek { parts.append("每周约\(c)分钟") }
            return "「" + parts.joined(separator: "·") + "」"
        }.joined(separator: "、")
        var contextSection = ""
        if !context.busy.isEmpty {
            let tf = DateFormatter()
            tf.locale = Locale(identifier: "en_US_POSIX")
            tf.dateFormat = "HH:mm"
            let lines = context.busy.prefix(15)
                .map { "- \($0.title) \(tf.string(from: $0.start))–\(tf.string(from: $0.end))" }
                .joined(separator: "\n")
            contextSection += "\n目标日日历里**已有的安排**（时段已被占用，新块避开；仅用户明确要求时才与其重叠）：\n" + lines
        }
        if !context.dueReminders.isEmpty {
            let lines = context.dueReminders.prefix(10).map { "- \($0)" }.joined(separator: "\n")
            contextSection += "\n目标日**到期的提醒事项**（用户可能想安排它们；用户没提且排不下就别硬塞）：\n" + lines
        }
        return PromptConstitution.with("""
        你把用户用自然语言描述的一天，转成结构化日程。
        现在真实时间：\(realNow)。**目标日：\(target)**——所有块排在目标日当天；"明早/上午/晚上"都指目标日的时段。**睡前跨过午夜的块延到次日凌晨、日期写次日**（别写成目标日 00:xx）。
        目标日可能是"逻辑上的今天"（凌晨 0–4 点仍属前一晚，目标日=日历昨天是正常的）：**即使目标日的多数时段已过去，也照常解析全部任务并排出（blocks 绝不因"时间已过"而返回空）**——用户现在（凌晨）要做的事从当前时刻排起、日期写真实的今天。
        只输出一个 JSON 对象，不要解释、不要 markdown 围栏：
        {"loose":false,"blocks":[{"title":"","start":"YYYY-MM-DD HH:mm","end":"YYYY-MM-DD HH:mm","isFixed":false,"isAnchor":false,"category":"","timingStyle":"light","priority":"normal","deadline":null}],"longTasks":[{"title":"","deadline":null,"cadenceMinutesPerWeek":null,"totalMinutes":null,"unitMinutes":null}]}
        start/end 用 24 小时制本地时间。

        【块规则】
        - isFixed：**只有"与他人约定、时刻不可改"的事**（会议/上课/约诊/班车）=true；个人任务（写作业/写代码/健身/读书/吃饭）即使说了时间也 false（否则 re-flow 调不动）。
        - **不漏**：用户提到的每件要做的事都出一个块（或 longTasks），逐一保留、数量对得上；真排不下宁可排到收工后，也别省略。
        - 默认**互不重叠**；仅当用户明说可并行/同时（"这几个可并行"）才让对应块**重叠在同一时段**（start/end 大幅重合，不是前后相接）。并行块**各自成块、一个不少、不合并**；标题用**各自任务**的名（可加"并行·"前缀，别把多个名拼进一个标题）；并行不改 isFixed。
        - isAnchor：午/晚/早饭、通勤、午休、睡觉等作息=true（照排占时间，但不是"要完成的任务"）。
        - timingStyle ∈ pomodoro/light/none，默认 light；**只有**背书/写卷子/啃论文这类"高摩擦易劝退"才 pomodoro。priority ∈ normal/important（要紧/紧急用 important）。deadline 为硬截止或 null。
        - 粒度：**不要生成"小休息"块**（两块之间留空隙即可）；拿快递/喝水这类碎片并入相邻块或省略；别切太碎（固定块不并进别的块）。
        - 收工时间（软限制）= \(WorkHoursSettings.windDownText)：没指定时间的事尽量排在收工前；只有略超 5–10 分钟正好做完一件大事才可越界。用户明说的晚间/睡前块不受限。

        【松散 / 长期】
        - loose：**仅当用户明说"想松散/放松/休息一下/摆烂"这类整段放松意愿**时设 true（解析他明说的意愿，不替他判断）；普通排程或只提某段小憩=false。loose=true 仍照常解析块。
        - longTasks：截止在目标日之后的远期任务（"下周五交论文"）或多天长线（"这学期学完 X""每周健身三次"）放 longTasks、**不放 blocks**——除非用户明说今天也做一段（则两边都出）。cadenceMinutesPerWeek=每周投入分钟（"每天 1h"≈420），没提就 null；说了总量（"共9单元每40min"→total=360,unit=40；"共150小时"→total=9000,unit=null）就填，否则 null。没有长期事项 longTasks 给 []。
        - 委托：用户说"今天做X小时长期任务/干哪个看你"这类委托，从〔池〕按时长挑合适的生成**具体 blocks**（块名=池中任务名），并把整件事也放 longTasks。〔池〕：\(poolSection)\(contextSection)
        """)
    }

    /// 结构化输出 schema（`output_config.format`）—— 对齐 `decodePlan` 读的字段。
    /// 可空字段用 `["string","null"]` 类型联合；所有字段列入 required（结构化输出要求），Swift 侧仍容错。
    static let parseSchema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["loose", "blocks", "longTasks"],
        "properties": [
            "loose": ["type": "boolean"],
            "blocks": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["title", "start", "end", "isFixed", "isAnchor", "category", "timingStyle", "priority", "deadline"],
                    "properties": [
                        "title": ["type": "string"],
                        "start": ["type": "string"],
                        "end": ["type": "string"],
                        "isFixed": ["type": "boolean"],
                        "isAnchor": ["type": "boolean"],
                        "category": ["type": "string"],
                        "timingStyle": ["type": "string", "enum": ["pomodoro", "light", "none"]],
                        "priority": ["type": "string", "enum": ["normal", "important"]],
                        "deadline": ["type": ["string", "null"]],
                    ],
                ],
            ],
            "longTasks": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["title", "deadline", "cadenceMinutesPerWeek", "totalMinutes", "unitMinutes"],
                    "properties": [
                        "title": ["type": "string"],
                        "deadline": ["type": ["string", "null"]],
                        "cadenceMinutesPerWeek": ["type": ["integer", "null"]],
                        "totalMinutes": ["type": ["integer", "null"]],
                        "unitMinutes": ["type": ["integer", "null"]],
                    ],
                ],
            ],
        ],
    ]
}
