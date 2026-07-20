//
//  ClaudeScheduleParser.swift
//  BetterCalendar
//
//  云端解析（M1）：自然语言 → 结构化 PlanBlock[]，走 Anthropic API。
//  对冲全败/未配 key/离线 → fallback（FailedScheduleParser 干净抛错；上层链再试端侧 FM 兜底）。
//  prompt 已静态化（#21④，0.29.0）：静态规则段=缓存前缀（字节稳定），动态值全在【今日上下文】段。
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
            // 并行组（0.22）：同组同名 parallel 值 → labels "parallel:<组名>"（reflow 同组绑定）
            let parallel = (b["parallel"] as? String)?.trimmingCharacters(in: .whitespaces)
            // 锚点不计时（2026-07-11 Jason 定）：prompt 已说死，这里再兜底——模型抽风给锚点配番茄也拉回 none
            //（锚点本就不进执行列表，此处是界面一致性+双保险）
            let isAnchor = b["isAnchor"] as? Bool ?? false
            blocks.append(ParsedBlock(
                title: title, start: start, end: end,
                durationMinutes: Int(end.timeIntervalSince(start) / 60),
                isFixed: b["isFixed"] as? Bool ?? false,
                isAnchor: isAnchor,
                category: b["category"] as? String ?? "",
                timingStyle: isAnchor ? TimingStyle.none
                    : TimingStyle(rawValue: b["timingStyle"] as? String ?? "light") ?? .light,
                priority: BlockPriority(rawValue: b["priority"] as? String ?? "normal") ?? .normal,
                deadline: DateParsing.parse(b["deadline"] as? String),
                labels: (parallel?.isEmpty == false) ? [ScheduledBlock.parallelPrefix + parallel!] : []))
        }
        var longTasks: [ParsedLongTask] = []
        for t in (obj["longTasks"] as? [[String: Any]]) ?? [] {
            guard let title = t["title"] as? String, !title.isEmpty else { dropped += 1; continue }
            let cadence = (t["cadenceMinutesPerWeek"] as? Int)
                ?? (t["cadenceMinutesPerWeek"] as? String).flatMap(Int.init)
            func intOf(_ k: String) -> Int? { (t[k] as? Int) ?? (t[k] as? String).flatMap(Int.init) }
            // 阶段（#40 批3）：字符串数组，去空去空白；模型抽风给非字符串则整体忽略（宁缺勿脏）
            let cps = ((t["checkpoints"] as? [Any]) ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            longTasks.append(ParsedLongTask(title: title,
                                            deadline: DateParsing.parseDeadline(t["deadline"] as? String),
                                            cadenceMinutesPerWeek: cadence,
                                            totalMinutes: intOf("totalMinutes"),
                                            unitMinutes: intOf("unitMinutes"),
                                            checkpoints: cps))
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

    /// 并发对冲请求数（2026-07-09 Jason）：主请求 + (N-1) 备胎并行发同一模型；单发 89% → 3 发 ~99.9%。
    /// token 便宜（Haiku）、时间取最快，失败率断崖下降。内部参数，不进设置（原则6）。
    static let parseHedgeCount = 3

    func parse(_ text: String, referenceDate: Date, context: ParseContext) async throws -> ParsedPlan {
        let system = Self.dynamicContext(referenceDate: referenceDate, context: context)
        // 并发对冲（选 i）：**主请求流式**（喂 liveDraft 冒块，保留现体验）+ 备胎非流式并行；
        // 谁先返回**有效**（解码非空/松散）用谁、取消其余。全败 → 回退本地。
        let winner: ParsedPlan? = await withTaskGroup(of: ParsedPlan?.self) { group in
            for i in 0..<max(1, Self.parseHedgeCount) {
                let streaming = (i == 0)
                // 看门狗（链 v3，2026-07-13 Jason 定）：解析单路放宽到 30s——总时限/端侧接管由
                // chain 的 20s 优先窗+30s 总限管；10s 曾误杀慢而好的云答（实测最慢成功 40s）。
                group.addTask {
                    (try? await LLMWatchdog.run(seconds: 30) { await self.oneParse(system: system, text: text, streaming: streaming) }) ?? nil
                }
            }
            for await r in group where r != nil {
                group.cancelAll()   // 已有有效结果 → 取消其余对冲请求（省 token/算力）
                return r
            }
            return nil
        }
        liveDraft?.clear()   // 无论谁赢，最终结果即将替换草稿，收掉流式暂显
        if let winner {
            DevLog.shared.info("解析", "云端成功 · \(winner.blocks.count) 块"
                               + (winner.longTasks.isEmpty ? "" : " · \(winner.longTasks.count) 在途")
                               + (winner.isLoose ? " · 松散" : "")
                               + " · \(CloudSettings.activeModel)×\(Self.parseHedgeCount)")
            return winner
        }
        DevLog.shared.warn("解析", "云端对冲全部失败/空，回退本地")
        return try await fallback.parse(text, referenceDate: referenceDate, context: context)
    }

    /// 单次解析请求（对冲的一路）：streaming=主路（喂 liveDraft）；返回 nil = 本路失败/空（不抛，交给对冲汇总）。
    private func oneParse(system: String, text: String, streaming: Bool) async -> ParsedPlan? {
        do {
            let raw: String
            // 长日程输出可观（20+ 块），上限给足 10000（6000 见过截断）
            if streaming, let live = liveDraft {
                var lastCount = 0
                var scannedLength = 0
                raw = try await client.completeStreaming(
                    system: system, user: text, maxTokens: 10000, jsonSchema: Self.parseSchema,
                    cachedSystemPrefix: Self.staticSystemPrompt) { partial in
                    let newPart = partial.dropFirst(scannedLength)
                    scannedLength = partial.count
                    guard newPart.contains("}") else { return }
                    let blocks = Self.liveBlocks(fromPartial: partial)
                    if blocks.count != lastCount {
                        lastCount = blocks.count
                        live.streaming = blocks   // #42：流式期不排序——排序会让新块插中间、下方全跳；最终草稿自会重排
                    }
                }
            } else {
                raw = try await client.complete(
                    system: system, user: text, maxTokens: 10000, jsonMode: true, jsonSchema: Self.parseSchema,
                    cachedSystemPrefix: Self.staticSystemPrompt)
            }
            guard let decoded = Self.decodePlan(JSONText.extractObject(raw)) else { return nil }
            // 纯松散意图可无块无长期事项，仍算有效
            guard !decoded.blocks.isEmpty || !decoded.longTasks.isEmpty || decoded.loose else { return nil }
            return ParsedPlan(blocks: decoded.blocks, longTasks: decoded.longTasks, isLoose: decoded.loose)
        } catch {
            return nil   // 本路失败（网络/取消/解码）——对冲里其它路可能成功
        }
    }

    /// 静态指令段（#21④ prompt 静态化，0.29.0）：**字节级稳定的缓存前缀**——任何动态值
    /// （现在时刻/目标日/最早起排/收工线/池/busy/到期提醒）都不得写进这里，全部走 dynamicContext。
    /// 内容与拆分前逐句对应，动态处改为指向【今日上下文】；行为回归由试验台 P 组护航。
    static let staticSystemPrompt: String = PromptConstitution.with("""
    你把用户用自然语言描述的一天，转成结构化日程。
    现在真实时间与**目标日**见下方【今日上下文】——所有块排在目标日当天；"明早/上午/晚上"都指目标日的时段。**睡前跨过午夜的块延到次日凌晨、日期写次日**（别写成目标日 00:xx）。晚间语境里的「12点/12点半」指**午夜**（次日 00:00/00:30），不是中午——如「晚上10点到12点半写论文」=目标日 22:00 到次日 00:30；用户给了起止时刻就**照写**，别自行截短或平均切分。用户话里的「明天/明早/明晚」**同样指目标日本身**（排哪天已由目标日决定；凌晨排「明天」尤其如此=睡醒后的那一天）——绝不因「明天」二字把日期再 +1。
    目标日可能是"逻辑上的今天"（凌晨 0–4 点仍属前一晚，目标日=日历昨天是正常的）：**即使目标日的多数时段已过去，也照常解析全部任务并排出（blocks 绝不因"时间已过"而返回空）**——用户现在（凌晨）要做的事从当前时刻排起、日期写真实的今天。
    只输出一个 JSON 对象，不要解释、不要 markdown 围栏：
    {"loose":false,"blocks":[{"title":"","start":"YYYY-MM-DD HH:mm","end":"YYYY-MM-DD HH:mm","isFixed":false,"isAnchor":false,"category":"","timingStyle":"light","priority":"normal","deadline":null}],"longTasks":[{"title":"","deadline":null,"cadenceMinutesPerWeek":null,"totalMinutes":null,"unitMinutes":null,"checkpoints":[]}]}
    start/end 用 24 小时制本地时间。

    【块规则】
    - isFixed：**只有"与他人约定、时刻不可改"的事**（会议/上课/约诊/班车）=true；个人任务（写作业/写代码/健身/读书/吃饭）即使说了时间也 false（否则 re-flow 调不动）。
    - **不漏**：用户提到的每件要做的事都出一个块（或 longTasks），逐一保留、数量对得上；真排不下宁可排到收工后，也别省略。
    - 默认**互不重叠**；仅当用户明说可并行/同时（"这几个可并行"）才让对应块**重叠在同一时段**（start/end 大幅重合，不是前后相接）。并行块**各自成块、一个不少、不合并**；标题用**各自任务**的名（可加"并行·"前缀，别把多个名拼进一个标题）；并行不改 isFixed。并行的块给**同一个 parallel 组名**（如 "P1"；第二组用 "P2"）；不并行的块 parallel=null——这个组名让重排时同组保持同时段。
    - isAnchor：午/晚/早饭、通勤、午休、睡觉等作息=true（照排占时间，但不是"要完成的任务"）；**锚点一律 timingStyle="none"**（作息不计时、不进执行）。
    - **用餐默认补排（「不漏也不多」的唯一例外）**：用户安排的时间范围与午餐（约 11:30–13:30）或晚餐（约 17:30–19:30）时段**有交集**、而用户没提对应那顿饭时，默认插入该顿锚点块——标题就叫「午饭」/「晚饭」，30–60 分钟，isAnchor=true、isFixed=false、timingStyle="none"，放在不与其他块冲突的合理时刻。用户明说不吃/不用安排、或该时段已被排满/占用时不加；只补午/晚两顿，早饭夜宵不补。
    - timingStyle ∈ pomodoro/light/none，默认 light；**只有**背书/写卷子/啃论文这类"高摩擦易劝退"才 pomodoro。priority ∈ normal/important（要紧/紧急用 important）。deadline 为硬截止或 null。
    - 粒度：**不要生成"小休息"块**（两块之间留空隙即可）；拿快递/喝水这类碎片并入相邻块或省略；别切太碎（固定块不并进别的块）。
    - 收工时间（软限制）见【今日上下文】：没指定时间的事尽量排在收工前；只有略超 5–10 分钟正好做完一件大事才可越界。用户明说的晚间/睡前块不受限。

    【松散 / 长期】
    - loose：**仅当用户明说"想松散/放松/休息一下/摆烂"这类整段放松意愿**时设 true（解析他明说的意愿，不替他判断）；普通排程或只提某段小憩=false。loose=true 仍照常解析块。
    - longTasks：截止在目标日之后的远期任务（"下周五交论文"）或多天长线（"这学期学完 X""每周健身三次"）放 longTasks、**不放 blocks**——除非用户明说今天也做一段（则两边都出）。cadenceMinutesPerWeek=每周投入分钟（"每天 1h"≈420），没提就 null；说了总量（"共9单元每40min"→total=360,unit=40；"共150小时"→total=9000,unit=null）就填，否则 null。没有长期事项 longTasks 给 []。**title=干净短名**（2-8 字，如"AI 学习""通识课作业"）——数量/单元/时长这些元数据**只进对应字段、绝不复读进标题**（错例："要进行 AI 学习，总共有 21 讲，每一讲要 40 分钟"整句当标题；对："AI 学习"+total=840+unit=40）。checkpoints=用户**明确列出的阶段名**（"分三个阶段：读文献、写初稿、改"→["读文献","写初稿","改"]；"先看完第1章再第2章"→["第 1 章","第 2 章"]），按用户给的顺序、原话为准不自创不扩写；**只给名字**，绝不给各自的日期；没提阶段就给 []。
    - 委托：用户说"今天做X小时长期任务/干哪个看你"这类委托，从【今日上下文】的〔池〕按时长挑合适的生成**具体 blocks**（块名=池中任务名；该任务若标了"下一阶段"，块名写"任务名 · 阶段名"），并把整件事也放 longTasks。
    """)

    /// 动态上下文段（每次请求都变，跟在静态前缀后面的第二个 system 块）。
    static func dynamicContext(referenceDate: Date, context: ParseContext = ParseContext()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd EEEE"
        let target = df.string(from: referenceDate)
        // 0.30.2 P1 回归修复：静态化后「次日」要模型跨段推（目标日在此、跨午夜规则在静态段）——
        // Haiku P1 从基线掉到 2/10、错法全是差一天 → 把次日日期**直接算好喂给它**，不留推理缝。
        let nextDay = df.string(from: referenceDate.addingTimeInterval(24 * 3600))
        df.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let realNow = df.string(from: .now)
        // 今天排程从「现在+5 分」起（Jason 2026-07-10）：给启动缓冲、且排出的一天永远「从现在起可行」，不生成已落后于钟表的计划。
        let isToday = Calendar.current.isDateInToday(referenceDate)
        df.dateFormat = "HH:mm"
        let earliest5 = df.string(from: Date.now.addingTimeInterval(300))
        let poolSection = context.pool.isEmpty ? "（空）" : context.pool.map { t -> String in
            var parts = [t.title]
            if let d = t.deadline { parts.append("DDL " + { let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: d) }()) }
            if let c = t.cadenceMinutesPerWeek { parts.append("每周约\(c)分钟") }
            if let cp = t.nextCheckpoint { parts.append("下一阶段：\(cp)") }   // #40 批3
            return "「" + parts.joined(separator: "·") + "」"
        }.joined(separator: "、")
        var contextSection = ""
        if !context.busy.isEmpty {
            let tf = DateFormatter()
            tf.locale = Locale(identifier: "en_US_POSIX")
            tf.dateFormat = "HH:mm"
            // L1 脱敏（2026-07-10 拍板）：只传时段不传标题——避开时段不需要知道是什么事；
            // 重要性/优先级由解析产出的结构化字段承载，不靠云端看见日历内容。
            let lines = context.busy.prefix(15)
                .map { "- \(tf.string(from: $0.start))–\(tf.string(from: $0.end))（已占用）" }
                .joined(separator: "\n")
            contextSection += "\n目标日已被占用的时段（新块避开；仅用户明确要求时才与其重叠）：\n" + lines
        }
        if !context.dueReminders.isEmpty {
            let lines = context.dueReminders.prefix(10).map { "- \($0)" }.joined(separator: "\n")
            contextSection += "\n目标日**到期的提醒事项**（用户可能想安排它们；用户没提且排不下就别硬塞）：\n" + lines
        }
        return """
        【今日上下文】
        现在真实时间：\(realNow)。**目标日：\(target)**——所有块的日期写 \(String(target.prefix(10)))。
        **睡前跨过午夜的块：日期写次日 \(String(nextDay.prefix(10)))**（如「到凌晨1点」= \(String(nextDay.prefix(10))) 01:00，绝不写成 \(String(target.prefix(10))) 01:00）。
        \((isToday && !context.isBackfill) ? "**排今天时：没给具体时间的弹性块，最早从 \(earliest5)（现在+5 分、留启动缓冲）起排，不要排在此刻或更早**；用户明确给了时间的块按用户说的（哪怕已过去也照写）。" : "")
        \(context.isBackfill ? "**补记过去做的事：只记录用户提到的，不默认补排用餐锚点。**" : "")
        收工时间（软限制）= \(WorkHoursSettings.windDownText)。
        〔池〕：\(poolSection)\(contextSection)
        """
    }

    /// 完整 system prompt（静态+动态拼接）——试验台展示「实际发送的 prompt」用；真实请求走两块 system。
    static func systemPrompt(referenceDate: Date, context: ParseContext = ParseContext()) -> String {
        staticSystemPrompt + "\n\n" + dynamicContext(referenceDate: referenceDate, context: context)
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
                    "required": ["title", "start", "end", "isFixed", "isAnchor", "category", "timingStyle", "priority", "deadline", "parallel"],
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
                        "parallel": ["type": ["string", "null"]],
                    ],
                ],
            ],
            "longTasks": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["title", "deadline", "cadenceMinutesPerWeek", "totalMinutes", "unitMinutes",
                                 "checkpoints"],
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
        ],
    ]
}
