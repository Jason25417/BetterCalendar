//
//  SentinelCadence.swift
//  BetterCalendar
//
//  SPEC §19 C1 W14：哨兵什么时候调用模型（纯函数，单测注入时钟）。
//    - 变化驱动：设备活动 / 计划 / 计时的指纹变了 → 防抖（安静 debounce 秒，连续变化最多等 maxDebounce 秒），且距上次判断 ≥ minInterval；
//      节奏随判断器变：决策模型（Jev / OpenAI）快到秒级，Claude / 规则兜底慢（见 SentinelSettings.pacing）；
//    - 没变化：每 idleInterval 做一次例行判断；
//    - 闸门：总开关、桥接没连、「允许智能体主动通知你」关、静音、安静时段（复用 AttentionPolicy 设置）→ 跳过；
//      稳定性上限（**不是产品规则**，防烧钱）：今天估算花费 ≥ dailyBudget → 停止调用，可见。
//    - 防风暴（Jason 2026-10-18）：每小时叫醒上限、两次叫醒的最短间隔、智能体正在运行 → 不停判断，只把叫醒攒着合并（见引擎）；
//      同一理由签名在冷却期内已叫醒过 → 不再叫醒。
//

#if os(macOS)
import Foundation

nonisolated struct SentinelCadenceState: Equatable, Sendable {
    var lastFingerprint: String?
    /// 最近一次看到变化的时刻。
    var lastChangeAt: Date?
    /// 自上次判断以来第一次看到变化的时刻（nil = 没有待判断的变化）。
    var pendingSince: Date?
    var lastRunAt: Date?
}

nonisolated enum SentinelCadenceDecision: Equatable, Sendable {
    case run(SentinelTrigger)
    case wait
}

/// 闸门结果：为什么这一拍不调用。stop = 稳定性上限（醒目显示）；skip = 正常跳过（安静时段等）。
nonisolated enum SentinelGate: Equatable, Sendable {
    case open
    case disabled(String)
    case skip(String)
    case stop(String)

    var reason: String? {
        switch self {
        case .open: nil
        case let .disabled(r), let .skip(r), let .stop(r): r
        }
    }
}

nonisolated enum SentinelCadence {
    /// 记下这一拍看到的指纹；变了就标记待判断。
    static func observe(_ s: inout SentinelCadenceState, fingerprint: String, now: Date) {
        guard fingerprint != s.lastFingerprint else { return }
        s.lastFingerprint = fingerprint
        s.lastChangeAt = now
        if s.pendingSince == nil { s.pendingSince = now }
    }

    static func decide(_ s: SentinelCadenceState, settings: SentinelSettings, judge: SentinelJudgeKind, now: Date) -> SentinelCadenceDecision {
        let pace = settings.pacing(for: judge)
        let sinceRun = s.lastRunAt.map { now.timeIntervalSince($0) } ?? .infinity
        if let pending = s.pendingSince {
            guard sinceRun >= pace.minInterval else { return .wait }
            let quiet = now.timeIntervalSince(s.lastChangeAt ?? pending)
            if quiet >= pace.debounce || now.timeIntervalSince(pending) >= pace.maxDebounce { return .run(.change) }
            return .wait
        }
        return sinceRun >= settings.idleIntervalSeconds ? .run(.idle) : .wait
    }

    /// 判断完成：清掉待判断的变化。
    static func ran(_ s: inout SentinelCadenceState, at now: Date) {
        s.lastRunAt = now
        s.pendingSince = nil
    }

    static func gate(settings: SentinelSettings, attention: AttentionSettings, bridgeConnected: Bool, now: Date,
                     costTodayUsd: Double, calendar: Calendar = .current) -> SentinelGate {
        guard settings.enabled else { return .disabled("哨兵已关") }
        guard bridgeConnected else { return .skip("桥接目录未连接（设置 → 审批记录与规则里选 bridge 文件夹）") }
        guard attention.enabled else { return .skip("「允许智能体主动通知你」已关") }
        if let until = attention.mutedUntil, now < until { return .skip("静音中（到 \(until.formatted(date: .omitted, time: .shortened))）") }
        if AttentionPolicy.inQuietHours(attention, at: now, calendar: calendar) {
            return .skip("安静时段（\(attention.quietStartHour):00–\(attention.quietEndHour):00）")
        }
        if costTodayUsd >= settings.dailyBudgetUsd {
            return .stop(String(format: "今天估算花费 $%.3f 已到上限 $%.2f（稳定性上限），今天不再调用", costTodayUsd, settings.dailyBudgetUsd))
        }
        return .open
    }

    /// 理由签名：理由类别 / 信号集合 + 情况键（计划块、计时、已算出的事实；不含分钟数与设备活动）。
    /// 正常切换 App 不改变签名；情况真的变了（块挪了、开始计时了、新的事实）才算新理由。
    static func signature(_ v: SentinelVerdict, situationKey: String) -> String {
        let reasons = (v.category.map { [$0] } ?? []) + v.signals
        let key = Array(Set(reasons)).sorted().joined(separator: ",") + "|" + situationKey
        return String(SentinelDigestBuilder.sha256(Data(key.utf8)).prefix(16))
    }

    /// 同一签名在冷却期内已经叫醒过（直接叫醒或合并发出）→ 重复。
    static func isDuplicate(signature: String, wakes: [SentinelDecisionEntry], now: Date, cooldownMinutes: Double) -> Bool {
        wakes.contains { $0.outcome == .woke && now.timeIntervalSince($0.at) < cooldownMinutes * 60
            && ($0.signature == signature || ($0.mergedSignatures ?? []).contains(signature)) }
    }

    /// 现在能不能发叫醒（不能 = 攒着）；返回不能的原因。
    static func holdReason(agentBusy: Bool, lastWakeAt: Date?, wakesLastHour: Int, settings: SentinelSettings, now: Date) -> String? {
        if agentBusy { return "智能体正在处理别的事" }
        if let last = lastWakeAt, now.timeIntervalSince(last) < settings.minWakeGapSeconds {
            return "距上次叫醒不到 \(Int(settings.minWakeGapSeconds / 60)) 分钟"
        }
        if wakesLastHour >= settings.maxWakesPerHour {
            return "最近 1 小时已叫醒 \(wakesLastHour) 次（稳定性上限 \(settings.maxWakesPerHour) 次）"
        }
        return nil
    }
}
#endif
