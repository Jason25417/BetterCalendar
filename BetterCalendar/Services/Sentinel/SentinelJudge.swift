//
//  SentinelJudge.swift
//  BetterCalendar
//
//  SPEC §19 C1 W14：哨兵的判断器（摘要 → 判断）。协议与服务商无关。
//  Jason 2026-10-18 改：首选专门的决策模型——TypeSafe Jev（OpenRouter Decisions 端点）/ OpenAI Decisions（gpt-6-luna），
//  只回答「该不该叫醒」的概率、理由类别与紧急程度（不生成文字，亚秒级、按输入计费极便宜）；引擎按阈值决定叫不叫醒。
//  Jason 同日在会话里明确同意：哨兵可以把含设备活动（App 名、网站域名）的摘要发给 OpenRouter 与 OpenAI 做判断。
//    - JevSentinelJudge：POST https://openrouter.ai/api/alpha/decisions，questions 是对象（noul / choice / score），state = 摘要原文。
//    - OpenAIDecisionsSentinelJudge：POST https://api.openai.com/v1/decisions，questions 是数组（predicate / choice / score），input = 摘要原文。
//    - ClaudeSentinelJudge：Claude Haiku 4.5，结构化输出（output_config.format + JSON schema），**不用 prefill**；
//      稳定的指令段放 cachedSystemPrefix（客户端支持 cache_control）。⚠️ Haiku 4.5 最小可缓存前缀 4096 token，
//      这段指令不到，实际不会命中缓存（无害；决策日志的 cacheRead 可实证）。
//    - RuleSentinelJudge：没有 key / 云端关 / 调用失败时的朴素规则兜底（用摘要里算好的事实）。兜底一律可见（DevLog + 面板）。
//

#if os(macOS)
import Foundation

@MainActor protocol SentinelJudge {
    var kind: SentinelJudgeKind { get }
    /// nil = 可用；否则 = 不可用的原因（白话，面板与日志显示）。
    func unavailableReason() -> String?
    func judge(_ digest: SentinelDigest) async throws -> SentinelJudgment
}

struct ClaudeSentinelJudge: SentinelJudge {
    /// Jason 2026-10-18 指定的哨兵模型（Haiku 4.5 快照 id；支持结构化输出、接受 thinking disabled）。
    static let model = "claude-haiku-4-5-20251001"
    static let keychainAccount = LLMProvider.anthropic.keychainAccount   // "anthropic-api-key"
    static let maxTokens = 400

    let kind = SentinelJudgeKind.claude
    var client: AnthropicClient
    /// 云端是否允许（关了云端或设成「只用端侧」= 隐私承诺，哨兵也不上云）。
    var cloudAllowed: () -> Bool

    init(apiKey: @escaping () -> String? = { KeychainStore.loadAPIKey(account: ClaudeSentinelJudge.keychainAccount) },
         cloudAllowed: @escaping () -> Bool = { CloudSettings.useCloud && !CloudSettings.onDeviceOnly },
         transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) {
        var c = AnthropicClient(provider: { .anthropic }, apiKey: apiKey, model: { ClaudeSentinelJudge.model }, useCloud: { true })
        if let transport { c.transport = transport }
        client = c
        self.cloudAllowed = cloudAllowed
    }

    func unavailableReason() -> String? {
        guard cloudAllowed() else { return "云端已关闭或设成了「只使用端侧」，哨兵不上云" }
        guard let key = client.apiKey(), !key.isEmpty else { return "没有 Anthropic API key（设置页填写）" }
        return nil
    }

    func judge(_ digest: SentinelDigest) async throws -> SentinelJudgment {
        let c = try await client.completeWithUsage(system: "", user: digest.text, maxTokens: Self.maxTokens,
                                                    jsonSchema: Self.schema, cachedSystemPrefix: Self.instructions)
        let verdict = try Self.parse(c.text)
        let cost = SentinelPricing.claude(input: c.inputTokens, output: c.outputTokens, cacheRead: c.cacheReadTokens, cacheWrite: c.cacheWriteTokens)
        return SentinelJudgment(verdict: verdict, judge: .claude, model: Self.model,
                                usage: SentinelUsage(inputTokens: c.inputTokens, outputTokens: c.outputTokens,
                                                     cacheReadTokens: c.cacheReadTokens, cacheWriteTokens: c.cacheWriteTokens, costUsd: cost))
    }

    /// 结构化输出 schema：每个 object additionalProperties:false + 全部 required；signals 用固定词表约束。
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "wake": ["type": "boolean"],
            "reason": ["type": "string"],
            "urgency": ["type": "string", "enum": SentinelUrgency.allCases.map(\.rawValue)],
            "signals": ["type": "array", "items": ["type": "string", "enum": SentinelSignal.allCases.map(\.rawValue)]],
        ] as [String: Any],
        "required": ["wake", "reason", "urgency", "signals"],
        "additionalProperties": false,
    ]

    /// 解析并收紧（结构化输出下是直通；仍防御空理由 / 未知信号 / 过长）。
    static func parse(_ text: String) throws -> SentinelVerdict {
        guard let data = JSONText.extractObject(text).data(using: .utf8),
              var v = try? JSONDecoder().decode(SentinelVerdict.self, from: data) else {
            throw AnthropicError(message: "哨兵回复不是合法的判断 JSON：\(text.prefix(200))")
        }
        v.reason = v.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.reason.isEmpty { v.reason = v.wake ? "（模型没给理由）" : "没有需要智能体此刻处理的事" }
        if v.reason.count > 120 { v.reason = String(v.reason.prefix(120)) + "…" }
        let known = Set(SentinelSignal.allCases.map(\.rawValue))
        v.signals = Array(Set(v.signals.map { known.contains($0) ? $0 : SentinelSignal.other.rawValue })).sorted()
        return v
    }

    /// 稳定指令段（字节级不变，放缓存前缀）。判断准则来自 SPEC §19 C 组与 Jason 2026-10-18 的哨兵决定。
    static let instructions = """
    你是 BetterCalendar 的「哨兵」。BetterCalendar 是 Jason 的日程 App；它有一个「BetterCalendar 智能体」（参谋），每叫醒一次都要花不少额度。
    你每隔几分钟看一眼下面这份摘要，只回答一个问题：**此刻值不值得叫醒智能体**。你不能直接通知 Jason，也不替智能体做决定；叫醒后由智能体自己判断要不要说话（它也可能什么都不做）。

    什么时候叫醒（wake=true）——此刻很可能有值得智能体注意的事：
    - 计划块的开始时间已过一会儿，却没有开始迹象（没在计时、没有实际记录、设备活动也不像在做它）；
    - 计时远远超过了计划；
    - 截止临近，却没见推进；
    - 白天长时间没有操作，且原因不明（不是计划里的休息/外出/固定安排）；
    - 设备活动显示 Jason 切到了别的事，像是开始了一件没记的事；
    - 看起来 Jason 刚做完了一件事（例如计划块对应的活动结束、长时间专注后离开）。

    什么时候不叫醒：
    - 拿不准就不叫醒（宁可漏一次，也不要打扰）。
    - 同一个理由刚叫醒过（见「最近叫醒过智能体」），而此后没有新变化 → 不叫醒。不要连续两次为同一个理由叫醒，除非情况变了。
    - 智能体刚因为别的事被叫醒过、或刚给 Jason 发过通知、或他选了「静音」→ 更要克制。
    - 一切按计划进行、或只是正常的切换与浏览 → 不叫醒。
    - 固定安排（课、会）不需要你提醒开始。

    输出要求：
    - reason：一句白话中文（不超过 60 字），说清为什么（不）叫醒。不要点名具体的 App 或网站（用「编程工具」「视频网站」这类类别说法），不评判、不说「落后 / 拖延 / 失败」。
    - urgency：low / normal / high。只有时间很紧（例如几十分钟内截止、固定安排马上开始却在做别的）才用 high；不叫醒时用 low。
    - signals：从固定词表里选（可多个，不叫醒时可以为空）：planned_start_passed（计划开始已过没见开始）、timer_over_plan（计时超计划）、deadline_near_no_progress（截止临近没推进）、long_idle_daytime（白天长时间没操作）、untracked_context_switch（像是开始了没记的事）、seems_finished（像是做完了一件事）、other。
    - 只输出 JSON。
    """
}

/// 决策模型共用的三个问题（Jev 与 OpenAI 同一套语义，便于对比误报 / 漏报）。
nonisolated enum SentinelDecisionQuestions {
    static let wakeInstructions = """
    You are the sentinel of BetterCalendar, Jason's scheduling app. Waking its agent is expensive. \
    Based on the state (a compact Chinese digest of Jason's plan, timer, deadlines, device activity, recent wakes and notifications), \
    is it worth waking the agent RIGHT NOW? Wake only when something likely needs its attention now. \
    If unsure, do not wake. Do not wake again for the same reason as a recent wake unless the situation clearly changed. \
    Fixed events (classes, meetings) need no start reminder. Normal app switching and browsing is not a reason.
    """
    static let wakeTrue = "Something likely needs the agent's attention now: a planned block is overdue to start with no sign of starting, a timer is far past plan, a deadline is near with no progress, unexplained long idle in daytime, Jason seems to have started something untracked, or seems to have just finished something."
    static let wakeFalse = "Nothing needs the agent now: things are on track, the situation is unclear, it was already handled by a recent wake, or Jason is resting, away by plan, muted, or in a fixed event."
    static let categoryInstructions = "Which single reason best describes why the agent might be needed now? Choose 'other' if none applies."
    static let urgencyInstructions = "How time-critical is it for the agent to look now?"
    static let urgencyLevels: [(label: String, description: String)] = [
        ("low", "Can wait; nothing time-critical."),
        ("normal", "Worth a look soon."),
        ("high", "Very time-critical, e.g. a deadline within tens of minutes or a fixed event about to start while doing something else."),
    ]

    /// 0…2 的 score（概率加权的等级下标）→ 紧急程度。
    static func urgency(score: Double?) -> SentinelUrgency {
        guard let score else { return .low }
        return score < 0.67 ? .low : score < 1.5 ? .normal : .high
    }

    /// 决策模型没有文字理由：用类别与概率拼一句白话（不点名 App / 网站）。
    static func reason(category: SentinelSignal, probability: Double) -> String {
        let pct = Int((probability * 100).rounded())
        return category == .other ? "决策模型判断该叫醒的把握 \(pct)%" : "\(category.label)（把握 \(pct)%）"
    }

    static func verdict(probability: Double, category raw: String?, urgencyScore: Double?) -> SentinelVerdict {
        let category = raw.flatMap(SentinelSignal.init(rawValue:)) ?? .other
        // wake 由引擎按阈值定；这里先按 0.5 填一个参考值，日志里以 probability 为准。
        return SentinelVerdict(wake: probability >= 0.5, reason: reason(category: category, probability: probability),
                               urgency: urgency(score: urgencyScore), signals: category == .other ? [] : [category.rawValue],
                               probability: min(1, max(0, probability)), category: category.rawValue)
    }
}

/// 决策模型的 HTTP 调用（可注入 transport；失败带状态码与正文片段，可见）。
nonisolated enum SentinelHTTP {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let live: Transport = { req in try await URLSession.shared.data(for: req) }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func postJSON(_ url: URL, key: String, body: [String: Any], timeout: TimeInterval, transport: Transport,
                         service: String) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            let hint = status == 401 ? "（key 无效）" : status == 402 ? "（余额不足）" : status == 429 ? "（请求太频繁）" : ""
            throw Failure(message: "\(service) 返回 HTTP \(status)\(hint)：\(snippet)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "\(service) 回复不是 JSON 对象")
        }
        return object
    }

    /// 没有报用量时按字节粗估 token（中文约 1.5 字节/token 偏保守取 2）。
    static func estimateTokens(_ text: String) -> Int { max(1, text.utf8.count / 2) }
}

/// TypeSafe Jev（OpenRouter Decisions，首选）。
struct JevSentinelJudge: SentinelJudge {
    static let endpoint = URL(string: "https://openrouter.ai/api/alpha/decisions")!
    static let model = "typesafe/jev-1.14"
    static let keychainAccount = "openrouter-api-key"
    let kind = SentinelJudgeKind.jev
    var apiKey: () -> String?
    var transport: SentinelHTTP.Transport
    var timeout: TimeInterval = 10

    init(apiKey: @escaping () -> String? = { KeychainStore.loadAPIKey(account: JevSentinelJudge.keychainAccount) },
         transport: @escaping SentinelHTTP.Transport = SentinelHTTP.live) {
        self.apiKey = apiKey; self.transport = transport
    }

    func unavailableReason() -> String? {
        guard let key = apiKey(), !key.isEmpty else { return "没有 OpenRouter API key（多端审批面板 → 哨兵里填写）" }
        return nil
    }

    static func body(_ digest: SentinelDigest) -> [String: Any] {
        let Q = SentinelDecisionQuestions.self
        var categories: [String: String] = [:]
        for s in SentinelSignal.allCases { categories[s.rawValue] = s.criterion }
        return [
            "model": model,
            "questions": [
                "wake": ["type": "noul", "instructions": Q.wakeInstructions, "criteria": ["true": Q.wakeTrue, "false": Q.wakeFalse]],
                "category": ["type": "choice", "instructions": Q.categoryInstructions, "criteria": categories],
                "urgency": ["type": "score", "instructions": Q.urgencyInstructions, "criteria": Q.urgencyLevels.map { "\($0.label): \($0.description)" }],
            ] as [String: Any],
            "state": digest.text,
        ]
    }

    func judge(_ digest: SentinelDigest) async throws -> SentinelJudgment {
        guard let key = apiKey(), !key.isEmpty else { throw SentinelHTTP.Failure(message: "没有 OpenRouter API key") }
        let o = try await SentinelHTTP.postJSON(Self.endpoint, key: key, body: Self.body(digest), timeout: timeout,
                                                transport: transport, service: "OpenRouter（Jev）")
        return try Self.parse(o, digest: digest)
    }

    static func parse(_ o: [String: Any], digest: SentinelDigest) throws -> SentinelJudgment {
        guard let answers = o["answers"] as? [String: Any],
              let wake = answers["wake"] as? [String: Any], let p = (wake["noul"] as? NSNumber)?.doubleValue else {
            throw SentinelHTTP.Failure(message: "Jev 回复里没有 answers.wake.noul：\(String(describing: o).prefix(200))")
        }
        let category = (answers["category"] as? [String: Any])?["choice"] as? String
        let score = ((answers["urgency"] as? [String: Any])?["score"] as? NSNumber)?.doubleValue
        let usage = o["usage"] as? [String: Any]
        let input = (usage?["input_tokens"] as? NSNumber)?.intValue ?? SentinelHTTP.estimateTokens(digest.text)
        let cost = (usage?["cost"] as? NSNumber)?.doubleValue ?? SentinelPricing.jev(input: input)
        return SentinelJudgment(verdict: SentinelDecisionQuestions.verdict(probability: p, category: category, urgencyScore: score),
                                judge: .jev, model: o["model"] as? String ?? model,
                                usage: SentinelUsage(inputTokens: input, outputTokens: (usage?["output_tokens"] as? NSNumber)?.intValue ?? 0, costUsd: cost))
    }
}

/// OpenAI Decisions（gpt-6-luna，可选）。
struct OpenAIDecisionsSentinelJudge: SentinelJudge {
    static let endpoint = URL(string: "https://api.openai.com/v1/decisions")!
    static let model = "gpt-6-luna"
    static let keychainAccount = "openai-api-key"
    let kind = SentinelJudgeKind.openai
    var apiKey: () -> String?
    var transport: SentinelHTTP.Transport
    var timeout: TimeInterval = 10

    init(apiKey: @escaping () -> String? = { KeychainStore.loadAPIKey(account: OpenAIDecisionsSentinelJudge.keychainAccount) },
         transport: @escaping SentinelHTTP.Transport = SentinelHTTP.live) {
        self.apiKey = apiKey; self.transport = transport
    }

    func unavailableReason() -> String? {
        guard let key = apiKey(), !key.isEmpty else { return "没有 OpenAI API key（多端审批面板 → 哨兵里填写）" }
        return nil
    }

    static func body(_ digest: SentinelDigest) -> [String: Any] {
        let Q = SentinelDecisionQuestions.self
        return [
            "model": model,
            "input": digest.text,
            "questions": [
                ["type": "predicate", "name": "wake", "instructions": Q.wakeInstructions + " True means: " + Q.wakeTrue],
                ["type": "choice", "name": "category", "instructions": Q.categoryInstructions,
                 "choices": SentinelSignal.allCases.map { ["value": $0.rawValue, "description": $0.criterion] }],
                ["type": "score", "name": "urgency", "instructions": Q.urgencyInstructions,
                 "levels": Q.urgencyLevels.map { ["label": $0.label, "description": $0.description] }],
            ] as [[String: Any]],
        ]
    }

    func judge(_ digest: SentinelDigest) async throws -> SentinelJudgment {
        guard let key = apiKey(), !key.isEmpty else { throw SentinelHTTP.Failure(message: "没有 OpenAI API key") }
        let o = try await SentinelHTTP.postJSON(Self.endpoint, key: key, body: Self.body(digest), timeout: timeout,
                                                transport: transport, service: "OpenAI Decisions")
        return try Self.parse(o, digest: digest)
    }

    static func parse(_ o: [String: Any], digest: SentinelDigest) throws -> SentinelJudgment {
        let answers = (o["answers"] as? [[String: Any]]) ?? []
        func answer(_ name: String) -> [String: Any]? { answers.first { $0["name"] as? String == name } }
        if let refusal = answers.first(where: { $0["type"] as? String == "refusal" }) {
            throw SentinelHTTP.Failure(message: "OpenAI Decisions 拒答：\(String(describing: refusal).prefix(200))")
        }
        guard let p = (answer("wake")?["probability"] as? NSNumber)?.doubleValue else {
            throw SentinelHTTP.Failure(message: "OpenAI Decisions 回复里没有 wake 的 probability：\(String(describing: o).prefix(200))")
        }
        let usage = o["usage"] as? [String: Any]
        let input = (usage?["input_tokens"] as? NSNumber)?.intValue ?? SentinelHTTP.estimateTokens(digest.text)
        return SentinelJudgment(verdict: SentinelDecisionQuestions.verdict(probability: p, category: answer("category")?["choice"] as? String,
                                                                           urgencyScore: (answer("urgency")?["score"] as? NSNumber)?.doubleValue),
                                judge: .openai, model: o["model"] as? String ?? model,
                                usage: SentinelUsage(inputTokens: input, costUsd: SentinelPricing.openAIDecisions(input: input)))
    }
}

/// 规则兜底：只用摘要里算好的事实，朴素、保守。
struct RuleSentinelJudge: SentinelJudge {
    let kind = SentinelJudgeKind.rule
    /// 白天长时间离开电脑多少分钟算「长」。
    var longIdleMinutes = 90

    func unavailableReason() -> String? { nil }

    func judge(_ digest: SentinelDigest) async throws -> SentinelJudgment {
        let f = digest.facts
        let verdict: SentinelVerdict
        if let d = f.deadlineSoon {
            verdict = .init(wake: true, reason: "「\(d.title)」\(d.minutesLeft) 分钟后截止，最近没见推进", urgency: d.minutesLeft <= 60 ? .high : .normal,
                            signals: [SentinelSignal.deadlineNearNoProgress.rawValue])
        } else if let l = f.overdueStart {
            verdict = .init(wake: true, reason: "「\(l.title)」开始时间已过 \(l.minutesLate) 分钟，还没见开始", urgency: .normal,
                            signals: [SentinelSignal.plannedStartPassed.rawValue])
        } else if let o = f.timerOverrun, o.minutesOver >= 30 {
            verdict = .init(wake: true, reason: "「\(o.title)」的计时超过计划 \(o.minutesOver) 分钟", urgency: .low,
                            signals: [SentinelSignal.timerOverPlan.rawValue])
        } else if let idle = f.idleMinutes, idle >= longIdleMinutes, !f.timerRunning {
            verdict = .init(wake: true, reason: "已经 \(idle) 分钟没有操作电脑", urgency: .low, signals: [SentinelSignal.longIdleDaytime.rawValue])
        } else {
            verdict = .init(wake: false, reason: "规则判断：此刻没有需要智能体处理的信号", urgency: .low, signals: [])
        }
        return SentinelJudgment(verdict: verdict, judge: .rule)
    }
}
#endif
