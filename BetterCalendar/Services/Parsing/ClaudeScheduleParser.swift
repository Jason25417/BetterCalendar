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

    func parse(_ text: String, referenceDate: Date, context: ParseContext) async throws -> ParsedPlan {
        do {
            // 长日程输出可观（20+ 块 + 长期任务），上限给足（曾因默认 2048 截断 → JSON 报废）
            let raw = try await client.complete(
                system: Self.systemPrompt(referenceDate: referenceDate, context: context),
                user: text, maxTokens: 6000)
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
                               + (decoded.loose ? " · 松散" : "") + " · \(CloudSettings.model)")
            return ParsedPlan(blocks: blocks, longTasks: longTasks, isLoose: decoded.loose)
        } catch {
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
        现在的真实时间：\(realNow)。**目标日：\(target)**——所有 blocks 一律排在目标日当天（唯一例外：睡前跨过午夜的块延到目标日次日凌晨，日期写次日）。"明早/上午/晚上"等都指目标日的时段，不是真实时间的次日。
        只输出一个 JSON 对象，不要任何解释、不要 markdown 代码围栏。格式：
        {"loose":false,"blocks":[{"title":"","start":"YYYY-MM-DD HH:mm","end":"YYYY-MM-DD HH:mm","isFixed":false,"isAnchor":false,"category":"","timingStyle":"light","priority":"normal","deadline":null}],"longTasks":[{"title":"","deadline":"YYYY-MM-DD HH:mm 或 null","cadenceMinutesPerWeek":null,"totalMinutes":null,"unitMinutes":null}]}
        规则：start/end 用 24 小时制本地时间；**isFixed 只给「与他人约定、时刻不可改」的事**（会议/上课/约诊/班车等）=true；**个人任务**（写作业/写代码/健身/读书/吃饭等）即使提到时间也 isFixed=false（它们时间可被自动 re-flow 调整，标 fixed 会导致排不动）；timingStyle ∈ pomodoro/light/none，默认 light；priority ∈ normal/important（要紧/紧急的事用 important）；deadline 为硬截止时间或 null。**跨过午夜的块（睡前/凌晨的事）start/end 日期用次日**，别写成目标日的 00:xx。**时间块默认互不重叠**；仅当用户明确表示可并行/同时进行（如"这几个任务可以并行""可以同时处理两三个"）时，才允许对应块时间重叠（并行块各自保留完整时长）。**并行块命名**：每块用**自己对应任务**的名字（可加「并行 · 」前缀，如「并行 · Watch Chatbot」），绝不要把所有并行任务名拼进每一个块的标题；并行块**不要因为并行而标 isFixed**（isFixed 仍只看会议类标准）。
        **松散意图 loose**：**仅当用户明确表达"想松散/放松/休息一下/随便过/不想被安排/今天摆烂"这类整段放松的意愿**时，把顶层 loose 设 true（这是解析用户明说的意愿，不是你替他判断该不该休息）；只是普通排程、或只提到某段小憩，loose 保持 false。loose=true 时仍可照常解析用户提到的块（他也许想松散地排几件）。
        **锚点块 isAnchor**：午饭/晚饭/早饭/通勤/午休/睡觉等作息必需事项设 isAnchor=true——照常排进日程占时间（其它事绕着它排），但它们不是"要完成的任务"。
        **留白与粒度**：**不要生成"小休息/休息"块**，两个工作块之间留出空隙即可（休息干什么无所谓、甚至继续工作）；把无需界定的碎片（拿快递、喝水）并入相邻块或省略；块的粒度 = 用户会"作为一件事去完成"的单位，别切太碎（但会议等固定块不要并进别的块）。
        **番茄钟**：timingStyle 默认 light（轻计时）；**只有**背书/写卷子/啃论文这类"容易劝退的高摩擦"任务才用 pomodoro，其余一律别用。
        **收工时间（软限制，非硬性）**：理想收工 = \(WorkHoursSettings.windDownText)。给没指定时间的事分配时段时，**尽量安排在收工时间之前**；只有当略超 5–10 分钟正好能把一件较大的事做完时才可略过。**用户明确说的晚间/睡前的事**（明说到某个晚点时刻，如"睡前读书到 24:00"）**不受此限**，照他说的排。
        **longTasks（长期事项）**：截止在目标日之后的远期任务（"下周五前交论文"）或多天持续的长线（"这学期学完 X""每周健身三次"）放 longTasks，**不放 blocks**——除非用户明确今天也要做一段（则两边都出：blocks 出今天这段，longTasks 出整件事）。cadenceMinutesPerWeek = 每周投入分钟数（"每天学 1 小时"≈420），没提就 null。没有长期事项时 longTasks 给 []。**总量**：说了"共9单元每单元40min"→ totalMinutes=360、unitMinutes=40；"共150小时"→ totalMinutes=9000、unitMinutes=null；没说就都 null。
        **委托长期任务（重要）**：若用户说"今天做X小时长期任务/安排学习时间/干哪个看你"这类**委托**，你要从下面〔长期任务池〕里挑合适的、按委托时长生成**具体的 blocks**（块名=池中该任务名，别写"长期任务"这种泛称），并把整件事也放 longTasks。〔长期任务池〕：\(poolSection)\(contextSection)
        """)
    }
}
