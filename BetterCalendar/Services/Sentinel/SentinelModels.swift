//
//  SentinelModels.swift
//  BetterCalendar
//
//  SPEC §19 C1 W14（Jason 2026-10-18 定；同日改：判断器优先用专门的决策模型 TypeSafe Jev / OpenAI Decisions，
//  Claude Haiku 与规则降为兜底；频率高了必须防风暴）：哨兵 = 一个快、便宜、类型安全的判断调用，高频看数据源，
//  每次只判断一件事——「此刻值不值得叫醒 BetterCalendar 智能体」。它**从不直接通知 Jason**，只写唤醒事件；
//  智能体醒来自己决定做什么，任何通知仍走 AttentionPolicy。
//  本文件：判断结果、设置、决策日志条目、成本估算（与服务商无关的 DTO）。
//  哨兵只在 Mac 上跑（桥接目录、设备活动都在 Mac）。
//

import Foundation

nonisolated enum SentinelUrgency: String, Codable, Sendable, CaseIterable {
    case low, normal, high
    var label: String { switch self { case .low: "低"; case .normal: "一般"; case .high: "高" } }
}

/// 哨兵给出的判断（结构化输出的 schema 与它一一对应）。
nonisolated struct SentinelVerdict: Codable, Equatable, Sendable {
    var wake: Bool
    /// 一句白话中文：为什么（不）叫醒。不点名具体 App / 网站（会出现在面板与日志里）。
    var reason: String
    var urgency: SentinelUrgency
    /// 信号标识（见 SentinelSignal），排序去重后参与「理由签名」。
    var signals: [String]
    /// 决策模型给的「该叫醒」概率（0–1）；wake 由引擎按阈值（设置）决定。LLM / 规则为 nil。
    var probability: Double? = nil
    /// 决策模型选的理由类别（SentinelSignal 的 rawValue）。
    var category: String? = nil
}

/// 信号标识（固定词表，结构化输出用 enum 约束；英文 id 方便日后统计误报/漏报）。
nonisolated enum SentinelSignal: String, CaseIterable, Sendable {
    case plannedStartPassed = "planned_start_passed"     // 计划块开始时间已过，没见开始迹象
    case timerOverPlan = "timer_over_plan"               // 计时远超计划
    case deadlineNearNoProgress = "deadline_near_no_progress"   // 截止临近、没见推进
    case longIdleDaytime = "long_idle_daytime"           // 白天长时间无操作、原因不明
    case untrackedContextSwitch = "untracked_context_switch"    // 切到了别的事，像是开始了没记的事
    case seemsFinished = "seems_finished"                // 看起来做完了一件事
    case other

    var label: String {
        switch self {
        case .plannedStartPassed: "计划的开始时间已过"
        case .timerOverPlan: "计时超出计划较多"
        case .deadlineNearNoProgress: "截止临近"
        case .longIdleDaytime: "白天长时间没有操作"
        case .untrackedContextSwitch: "像是开始了没记的事"
        case .seemsFinished: "像是做完了一件事"
        case .other: "其他"
        }
    }

    /// 给决策模型的类别说明（Choice 问题的 criteria / choices 描述）。
    var criterion: String {
        switch self {
        case .plannedStartPassed: "A planned block's start time has passed and there is no sign Jason started it."
        case .timerOverPlan: "A running timer is far past the planned end of its block."
        case .deadlineNearNoProgress: "A deadline is approaching and there is no recent progress on it."
        case .longIdleDaytime: "Long unexplained idle or away time during the day."
        case .untrackedContextSwitch: "Device activity suggests Jason started something new that is not tracked."
        case .seemsFinished: "Jason seems to have just finished something."
        case .other: "None of the above, or nothing notable."
        }
    }
}

nonisolated enum SentinelJudgeKind: String, Codable, Sendable, CaseIterable {
    /// TypeSafe Jev（OpenRouter Decisions，首选）；OpenAI Decisions（gpt-6-luna，可选）；Claude Haiku（结构化输出，兜底）；规则（最后兜底）。
    case jev, openai, claude, rule
    var label: String {
        switch self {
        case .jev: "TypeSafe Jev（OpenRouter）"
        case .openai: "OpenAI Decisions（gpt-6-luna）"
        case .claude: "Claude Haiku 4.5（兜底）"
        case .rule: "规则兜底"
        }
    }
    /// 决策模型：按 token 输入计费极便宜、亚秒级 → 可以高频判断；LLM / 规则走慢节奏。
    var isDecisionModel: Bool { self == .jev || self == .openai }
}

/// 什么触发了这次判断。
nonisolated enum SentinelTrigger: String, Codable, Sendable {
    case change    // 设备活动 / 计划 / 计时有变化（防抖后）
    case idle      // 一段时间没变化的例行检查
    case manual    // 面板「立即判断一次」
    case flush     // 不是判断：把攒着的叫醒（合并后）发出去
}

/// 一次调用的用量（token）与成本（服务商报了就用报的，否则按价目估算）。
nonisolated struct SentinelUsage: Codable, Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var costUsd: Double = 0
}

/// 价目（每百万 token，美元；2026-10 核对）。只是估算，账单以服务商后台为准；规则兜底 = 0。
nonisolated enum SentinelPricing {
    /// Claude Haiku 4.5：输入 $1 / 输出 $5 / 缓存写 $1.25 / 缓存读 $0.10。
    static func claude(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        (Double(input) * 1.0 + Double(output) * 5.0 + Double(cacheWrite) * 1.25 + Double(cacheRead) * 0.10) / 1_000_000
    }
    /// TypeSafe Jev（OpenRouter）：只按输入计费 $0.042，输出免费（响应里 usage.cost 有实际值时以它为准）。
    static func jev(input: Int) -> Double { Double(input) * 0.042 / 1_000_000 }
    /// OpenAI Decisions（gpt-6-luna）：只按输入计费 $0.10，输出/缓存不收费。
    static func openAIDecisions(input: Int) -> Double { Double(input) * 0.10 / 1_000_000 }
}

/// 判断器的一次产出。
nonisolated struct SentinelJudgment: Sendable {
    var verdict: SentinelVerdict
    var judge: SentinelJudgeKind
    var model: String? = nil
    var usage: SentinelUsage? = nil
}

/// 这次判断最后落成了什么。
nonisolated enum SentinelOutcome: String, Codable, Sendable {
    case woke                  // 写了 sentinel_wake 事件（直接叫醒，或 flush 把攒着的合并发出）
    case noWake                // 判断不叫醒（含概率没过阈值）
    case held                  // 判断要叫醒，但智能体正在运行 / 离上次叫醒太近 / 到每小时上限 → 并进待发的叫醒，之后合并发一次
    case merged                // 和待发叫醒里的某条理由签名相同 → 只计数，不新增理由
    case suppressedDuplicate   // 同一理由签名在冷却期内已叫醒过 → 不再叫醒
    case expired               // 待发的叫醒等太久没发出去（情况多半已变）→ 丢弃
    case wakeFailed            // 要叫醒，但写事件失败（错误见 error）
    case dismissedByYou        // W42：同一件事你今天点过「没用」→ 当天不再叫醒

    var label: String {
        switch self {
        case .woke: "已叫醒智能体"
        case .noWake: "不叫醒"
        case .held: "智能体忙 / 刚叫醒过，先攒着"
        case .merged: "和攒着的理由相同，已合并"
        case .suppressedDuplicate: "同一理由刚叫醒过，已拦下"
        case .expired: "攒着的叫醒等太久，已丢弃"
        case .wakeFailed: "叫醒失败"
        case .dismissedByYou: "你今天点过「没用」，不再叫醒"
        }
    }
}

/// 决策日志的一行（JSONL）。Jason 用它测误报/漏报、删减数据源。
/// 只记摘要的哈希与大小，不记摘要原文（原文含 App/网站名；只有叫醒时才写进桥接目录给智能体读）。
nonisolated struct SentinelDecisionEntry: Codable, Equatable, Sendable, Identifiable {
    var schemaVersion = 1
    var id = UUID()
    var at: Date
    var trigger: SentinelTrigger
    var judge: SentinelJudgeKind
    var model: String?
    /// 用了规则兜底的原因（没有 key / 调用失败…）；用 Claude 时为 nil。
    var fallbackReason: String?
    var digestHash: String
    var digestBytes: Int
    var verdict: SentinelVerdict
    var outcome: SentinelOutcome
    var latencyMs: Int
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var costUsd: Double
    var error: String?
    var eventId: String?
    /// 理由签名（类别 + 关键信号 + 对应事实的哈希）：同一签名冷却期内不再叫醒。
    var signature: String?
    /// flush：合并发出的那几次判断的 id 与理由签名（签名参与冷却期去重）。
    var mergedDecisionIds: [UUID]? = nil
    var mergedSignatures: [String]? = nil
    /// held / merged：当时为什么没发（智能体忙 / 离上次叫醒太近 / 每小时上限）。
    var holdReason: String? = nil
}

/// 哨兵设置（Mac 本机；默认值 = 实验期起步值，面板可调）。
/// 整份存 UserDefaults 的 Data（plist 安全）；缺的键按默认值补（加字段不丢旧设置）。
nonisolated struct SentinelSettings: Codable, Equatable, Sendable {
    /// 总开关（实验期默认开，Jason 2026-10-18）。
    var enabled = true
    /// 你选的判断器（Jev / OpenAI / Claude / 规则）；原则 10：只用这一个，不可用或失败 = 哨兵暂停并直说，不换替身。
    var preferredJudge = SentinelJudgeKind.jev
    /// 决策模型的「该叫醒」概率阈值。漏叫一次的代价小（下一拍/例行检查/心跳还会看），
    /// 误叫一次要花 Claude Code 额度、还可能多一条通知 → 偏保守，起步 0.85；按决策日志里的概率分布再调。
    var wakeThreshold = 0.75   // 2026-10-19 按 Jev 实测校准：一天 340 次判断最高 0.81，0.85 等于永不叫醒（Jason 定 75%）
    /// 调度节拍：每隔多少秒看一眼（只读本地数据，不调用模型）。
    var tickSeconds: Double = 3
    /// 决策模型：两次判断的最短间隔 / 防抖（变化后安静多久才判断）/ 连续变化时最多等多久。
    var minIntervalSeconds: Double = 3
    var debounceSeconds: Double = 2
    var maxDebounceSeconds: Double = 15
    /// Claude / 规则兜底时的慢节奏（Claude 每次约 $0.003，不能 3 秒一次）。
    var llmMinIntervalSeconds: Double = 120
    var llmDebounceSeconds: Double = 45
    var llmMaxDebounceSeconds: Double = 300
    /// 一直没变化时，多久做一次例行判断。
    var idleIntervalSeconds: Double = 600
    /// 计划 / 待办 / 日历这类较重的读取多久刷新一次（设备活动每拍增量读）。
    var contextRefreshSeconds: Double = 15
    /// 给模型看最近多少分钟的设备活动。
    var activityWindowMinutes: Double = 30
    /// 防风暴：两次叫醒之间至少隔多久（期间的叫醒判断合并成一次，之后发）。
    var minWakeGapSeconds: Double = 300
    /// 防风暴：同一理由签名的冷却期。
    var signatureCooldownMinutes: Double = 30
    /// 攒着的叫醒最多等多久（过了 = 情况多半已变，丢弃并记一笔）。
    var pendingMaxAgeMinutes: Double = 20
    /// 稳定性上限（**不是产品规则**，防失控/防烧钱用）：每小时最多叫醒几次智能体。
    var maxWakesPerHour = 6
    /// 稳定性上限（**不是产品规则**）：每天估算花费上限（美元）。到了今天不再调用、面板与心跳可见。
    var dailyBudgetUsd: Double = 1.0

    static let key = "sentinel.settings.v1"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SentinelSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        enabled = v(.enabled, d.enabled)
        preferredJudge = v(.preferredJudge, d.preferredJudge)
        wakeThreshold = v(.wakeThreshold, d.wakeThreshold)
        tickSeconds = v(.tickSeconds, d.tickSeconds)
        minIntervalSeconds = v(.minIntervalSeconds, d.minIntervalSeconds)
        debounceSeconds = v(.debounceSeconds, d.debounceSeconds)
        maxDebounceSeconds = v(.maxDebounceSeconds, d.maxDebounceSeconds)
        llmMinIntervalSeconds = v(.llmMinIntervalSeconds, d.llmMinIntervalSeconds)
        llmDebounceSeconds = v(.llmDebounceSeconds, d.llmDebounceSeconds)
        llmMaxDebounceSeconds = v(.llmMaxDebounceSeconds, d.llmMaxDebounceSeconds)
        idleIntervalSeconds = v(.idleIntervalSeconds, d.idleIntervalSeconds)
        contextRefreshSeconds = v(.contextRefreshSeconds, d.contextRefreshSeconds)
        activityWindowMinutes = v(.activityWindowMinutes, d.activityWindowMinutes)
        minWakeGapSeconds = v(.minWakeGapSeconds, d.minWakeGapSeconds)
        signatureCooldownMinutes = v(.signatureCooldownMinutes, d.signatureCooldownMinutes)
        pendingMaxAgeMinutes = v(.pendingMaxAgeMinutes, d.pendingMaxAgeMinutes)
        maxWakesPerHour = v(.maxWakesPerHour, d.maxWakesPerHour)
        dailyBudgetUsd = v(.dailyBudgetUsd, d.dailyBudgetUsd)
    }

    /// 某个判断器用的节奏（决策模型快、LLM/规则慢）。
    func pacing(for judge: SentinelJudgeKind) -> (minInterval: Double, debounce: Double, maxDebounce: Double) {
        judge.isDecisionModel ? (minIntervalSeconds, debounceSeconds, maxDebounceSeconds)
            : (llmMinIntervalSeconds, llmDebounceSeconds, llmMaxDebounceSeconds)
    }

    static func load(_ defaults: UserDefaults) -> SentinelSettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return s
    }
    func save(_ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// 攒着待发的叫醒（智能体正在运行 / 离上次叫醒太近 / 到每小时上限时，新的「该叫醒」并进来，之后合并发一次）。
nonisolated struct SentinelPendingWake: Equatable, Sendable {
    struct Reason: Equatable, Sendable {
        var at: Date
        var reason: String
        var urgency: SentinelUrgency
        var signals: [String]
        var signature: String
        var probability: Double?
        var decisionId: UUID
        /// W42：反馈键（随叫醒事件交给智能体，记在发出的消息上）。
        var feedbackKey: String? = nil
    }
    var firstAt: Date
    var reasons: [Reason] = []
    /// 同签名被合并的次数（不新增理由行）。
    var mergedCount = 0
    /// 为什么还没发（最近一次）。
    var holdReason: String?

    var lastAt: Date { reasons.last?.at ?? firstAt }
    var signatures: Set<String> { Set(reasons.map(\.signature)) }
    var signals: [String] { Array(Set(reasons.flatMap(\.signals))).sorted() }
    var urgency: SentinelUrgency {
        reasons.contains { $0.urgency == .high } ? .high : reasons.contains { $0.urgency == .normal } ? .normal : .low
    }
}

/// 最近一次唤醒智能体（任何来源：做完一件事、对话、哨兵…），给哨兵看，避免为同一件事反复叫醒。
nonisolated struct SentinelRecentWake: Equatable, Sendable {
    var at: Date
    var kind: String
    var summary: String
}

/// 最近一条给 Jason 的主动通知（智能体 notify_jason 的结果）。
nonisolated struct SentinelRecentNotice: Equatable, Sendable {
    var at: Date
    var title: String
    var delivered: Bool
    var suppressReason: String?
    var reaction: String?
    /// W42：这条是哨兵叫醒后发的——叫醒的信号与反馈键（「没用」校准、跨设备去重用）。
    var wakeSignals: [String] = []
    var wakeSignature: String? = nil
}
