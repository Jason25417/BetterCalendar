//
//  SentinelEngine.swift
//  BetterCalendar
//
//  SPEC §19 C1 W14：哨兵调度器（Mac 上常驻，组装点创建；测试环境不启动循环）。
//  每一拍（默认 3 秒）：闸门（开关/桥接/打扰设置/每日花费上限）→ 只读收集（设备活动每拍读；计划与计时按 contextRefreshSeconds 刷新）
//  → 变化指纹 → 该判断时：摘要 → 判断器（按首选顺序 Jev → OpenAI → Claude，不可用或失败就换下一个，最后规则兜底；兜底一律可见）
//  → 概率过阈值才算「该叫醒」→ 防风暴 → 写 sentinel_wake 事件 → 决策日志一行 → 状态文件 runtime/sentinel.json（心跳读）。
//  防风暴（Jason 2026-10-18：决策模型可能几秒一判，别让智能体被反复叫醒、互相冲突）：
//    ① 智能体正在运行（或队列里还有事件）/ 离上次叫醒不到 minWakeGap / 到每小时上限 → 不写新叫醒，攒进「待发叫醒」，
//       条件满足时合并成**一次**叫醒发出（带全部理由）；② 待发里已有同一理由签名 → 只计数；
//    ③ 同一理由签名在冷却期内已叫醒过 → 不再叫醒；④ 调度器那边还会把队列里多个 sentinel_wake 并成一次运行。
//  它只叫醒智能体，从不直接通知 Jason。
//

#if os(macOS)
import Foundation
import Observation

nonisolated struct SentinelErrorNote: Equatable, Sendable {
    var at: Date
    var message: String
}

@MainActor @Observable final class SentinelEngine {
    // 依赖
    private let judges: [any SentinelJudge]
    private let fallback: any SentinelJudge
    let log: any SentinelDecisionLogging
    private let bridge: any SentinelBridgeAccess
    private let activity: any ActivityLog
    private let gather: (Date) async -> AgentContextInput
    private let defaults: UserDefaults
    /// 最近唤醒智能体的记录（调度器运行记录，来自桥接 runtime/runs.jsonl）。
    var recentAgentWakes: () -> [SentinelRecentWake] = { [] }
    /// 最近的主动通知（智能体消息中心）。
    var recentNotices: () -> [SentinelRecentNotice] = { [] }
    /// 打扰设置（与智能体主动通知共用一份：静音一处生效）。
    var attention: () -> AttentionSettings = { AttentionSettings.load() }
    /// 智能体忙不忙（默认读桥接：调度器 running 或队列里有事件）；测试可注入。
    var agentBusy: (() async -> Bool)?
    /// 测试注入时钟与时区。
    var now: () -> Date = Date.init
    var timeZone: TimeZone = .current
    var calendar: Calendar = .current

    var settings: SentinelSettings { didSet { settings.save(defaults) } }

    // 可观测状态（面板）
    private(set) var cadence = SentinelCadenceState()
    private(set) var lastTickAt: Date?
    private(set) var lastRunAt: Date?
    private(set) var gate: SentinelGate = .open
    private(set) var lastError: SentinelErrorNote?
    private(set) var consecutiveErrors = 0
    private(set) var lastStatusError: String?
    private(set) var activityError: String?
    /// 攒着待发的叫醒（合并后一次发出）。
    private(set) var pending: SentinelPendingWake?
    /// 最近 8 天的决策（启动时从日志读回）。
    private(set) var recent: [SentinelDecisionEntry] = []

    private var pendingDigest: SentinelDigest?
    private var pendingJudge: SentinelJudgeKind = .rule
    private var cachedContext: (at: Date, value: AgentContextInput)?
    private var evaluating = false
    private var loop: Task<Void, Never>?
    private var reportedFallback: String?
    private var reportedStop: String?
    private var lastStatusWrite: (at: Date, state: String)?

    init(judges: [any SentinelJudge], fallback: (any SentinelJudge)? = nil, log: any SentinelDecisionLogging,
         bridge: any SentinelBridgeAccess, activity: any ActivityLog, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init, gather: @escaping (Date) async -> AgentContextInput) {
        self.judges = judges; self.fallback = fallback ?? RuleSentinelJudge(); self.log = log; self.bridge = bridge; self.activity = activity
        self.defaults = defaults; self.gather = gather; self.now = now
        settings = SentinelSettings.load(defaults)
        recent = log.entries(since: now().addingTimeInterval(-8 * 86400))
        lastRunAt = recent.last { $0.trigger != .flush }?.at
        cadence.lastRunAt = lastRunAt
    }

    // MARK: 判断器选择

    /// 按首选排好的判断器（首选在前，其余按 Jev → OpenAI → Claude）。
    var orderedJudges: [any SentinelJudge] {
        let rank: [SentinelJudgeKind] = [.jev, .openai, .claude]
        return judges.sorted { a, b in
            if (a.kind == settings.preferredJudge) != (b.kind == settings.preferredJudge) { return a.kind == settings.preferredJudge }
            return (rank.firstIndex(of: a.kind) ?? 9) < (rank.firstIndex(of: b.kind) ?? 9)
        }
    }

    private var availableJudges: [any SentinelJudge] { orderedJudges.filter { $0.unavailableReason() == nil } }

    /// 现在会用哪个判断器（都不可用 = 规则兜底）。
    var judgeInUse: SentinelJudgeKind { availableJudges.first?.kind ?? .rule }

    /// 没用上首选的原因（面板 / 状态文件显示；用的就是首选时为 nil）。
    var primaryUnavailableReason: String? {
        guard judgeInUse != settings.preferredJudge else { return nil }
        if let preferred = judges.first(where: { $0.kind == settings.preferredJudge }) {
            return "\(preferred.kind.label)不可用：\(preferred.unavailableReason() ?? "未知原因")"
        }
        return "没有配置\(settings.preferredJudge.label)"
    }

    // MARK: 统计（面板 / 状态文件）

    private var todayStart: Date { DayContext.logicalStartOfDay(now()) }
    var today: [SentinelDecisionEntry] { recent.filter { $0.at >= todayStart } }
    /// 真正调用了判断器的那些（不含合并发出 / 过期丢弃这类记账行）。
    var judgmentsToday: [SentinelDecisionEntry] { today.filter { $0.trigger != .flush && $0.outcome != .expired } }
    var wakesToday: [SentinelDecisionEntry] { today.filter { $0.outcome == .woke } }
    var costTodayUsd: Double { today.reduce(0) { $0 + $1.costUsd } }
    var cost7dUsd: Double { recent.filter { $0.at >= now().addingTimeInterval(-7 * 86400) }.reduce(0) { $0 + $1.costUsd } }
    var wakesLastHour: Int { recent.filter { $0.outcome == .woke && now().timeIntervalSince($0.at) < 3600 }.count }
    var lastWake: SentinelDecisionEntry? { recent.last { $0.outcome == .woke } }
    var lastEntry: SentinelDecisionEntry? { recent.last }

    // MARK: 运行

    /// 常驻循环（测试环境不要启动）。
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(max(1, self.settings.tickSeconds)))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// 一拍：闸门 → 收集 → 指纹 → 该判断就判断 → 试着发出攒着的叫醒 → 写状态。
    func tick() async {
        guard !evaluating else { return }
        evaluating = true; defer { evaluating = false }
        let t = now()
        lastTickAt = t
        gate = currentGate(at: t)
        reportStop()
        if case .open = gate {
            let (ctx, events) = await collect(at: t, forceContext: false)
            SentinelCadence.observe(&cadence, fingerprint: SentinelDigestBuilder.changeFingerprint(context: ctx, activity: events, now: t), now: t)
            if case let .run(trigger) = SentinelCadence.decide(cadence, settings: settings, judge: judgeInUse, now: t) {
                await evaluate(trigger: trigger, at: t, context: ctx, events: events)
            }
        }
        await flushPending(at: t)
        await writeStatus(at: t)
    }

    /// 面板「立即判断一次」：不等节拍，但闸门照旧（关了 / 安静时段 / 花费上限都不调用）。
    func runNow() async {
        guard !evaluating else { return }
        evaluating = true; defer { evaluating = false }
        let t = now()
        lastTickAt = t
        gate = currentGate(at: t)
        reportStop()
        if case .open = gate {
            let (ctx, events) = await collect(at: t, forceContext: true)
            SentinelCadence.observe(&cadence, fingerprint: SentinelDigestBuilder.changeFingerprint(context: ctx, activity: events, now: t), now: t)
            await evaluate(trigger: .manual, at: t, context: ctx, events: events)
        }
        await flushPending(at: t)
        await writeStatus(at: t)
    }

    private func currentGate(at t: Date) -> SentinelGate {
        SentinelCadence.gate(settings: settings, attention: attention(), bridgeConnected: bridge.isConnected, now: t,
                             costTodayUsd: costTodayUsd, calendar: calendar)
    }

    private func isAgentBusy() async -> Bool {
        if let agentBusy { return await agentBusy() }
        return await bridge.agentBusy()
    }

    private func collect(at t: Date, forceContext: Bool) async -> (AgentContextInput, [ActivityEvent]) {
        // 计划 / 待办 / 日历读取较重：按 contextRefreshSeconds 缓存；设备活动每拍读（增量变化靠它）。
        let ctx: AgentContextInput
        if !forceContext, let c = cachedContext, t.timeIntervalSince(c.at) < settings.contextRefreshSeconds, t >= c.at {
            ctx = c.value
        } else {
            ctx = await gather(t)
            cachedContext = (t, ctx)
        }
        // 多读 2 小时：知道窗口开始时前台是谁（汇总只算窗口内）。
        let window = DateInterval(start: t.addingTimeInterval(-settings.activityWindowMinutes * 60 - 7200), end: t)
        do {
            let events = try await activity.events(in: window)
            if activityError != nil { DevLog.shared.info("哨兵", "设备活动已恢复读取") }
            activityError = nil
            return (ctx, events)
        } catch {
            let message = "读取设备活动失败：\(error.localizedDescription)"
            if activityError != message { DevLog.shared.warn("哨兵", message + "（这一轮只看计划与计时）") }
            activityError = message
            return (ctx, [])
        }
    }

    private func evaluate(trigger: SentinelTrigger, at t: Date, context: AgentContextInput, events: [ActivityEvent]) async {
        let own = recent.filter { $0.outcome == .woke }.map { SentinelRecentWake(at: $0.at, kind: "sentinel_wake", summary: $0.verdict.reason) }
        let input = SentinelDigestInput(now: t, context: context, activity: events, activityWindowMinutes: settings.activityWindowMinutes,
                                        recentWakes: own + recentAgentWakes().filter { $0.kind != SentinelBridgeFiles.wakeKind },
                                        recentNotices: recentNotices(), attention: attention(), timeZone: timeZone)
        let digest = SentinelDigestBuilder.build(input)

        // 判断器链：首选 → 其余可用的 → 规则。每一级失败都记下来（可见）。
        let clock = ContinuousClock(), started = clock.now
        var judgment: SentinelJudgment?
        var errors: [String] = []
        for judge in availableJudges {
            do { judgment = try await judge.judge(digest); break } catch {
                errors.append("\(judge.kind.label)：\(error.localizedDescription.prefix(200))")
            }
        }
        var fallbackReason: String? = nil
        if judgment == nil {
            judgment = await ruleJudgment(digest)
            fallbackReason = errors.isEmpty ? (primaryUnavailableReason ?? "没有可用的判断器") : "调用失败：" + errors.joined(separator: "；")
        } else if let used = judgment?.judge, used != settings.preferredJudge {
            fallbackReason = errors.isEmpty ? primaryUnavailableReason : "调用失败，改用\(used.label)：" + errors.joined(separator: "；")
        }
        var j = judgment!
        let latencyMs = Int((clock.now - started) / .milliseconds(1))
        reportFallback(fallbackReason)
        if errors.isEmpty {
            consecutiveErrors = 0
        } else {
            consecutiveErrors += 1
            lastError = SentinelErrorNote(at: t, message: "判断器调用失败（已换下一个 / 兜底）：" + errors.joined(separator: "；"))
            DevLog.shared.warn("哨兵", lastError!.message)
        }
        // 决策模型：概率过阈值才算该叫醒。
        if let p = j.verdict.probability { j.verdict.wake = p >= settings.wakeThreshold }

        let id = UUID()
        var outcome = SentinelOutcome.noWake
        var eventId: String? = nil
        var wakeError: String? = nil
        var holdReason: String? = nil
        let signature = SentinelCadence.signature(j.verdict, situationKey: digest.situationKey)
        if j.verdict.wake {
            if SentinelCadence.isDuplicate(signature: signature, wakes: recent, now: t, cooldownMinutes: settings.signatureCooldownMinutes) {
                outcome = .suppressedDuplicate
            } else if var p = pending, p.signatures.contains(signature) {
                p.mergedCount += 1
                pending = p
                outcome = .merged
            } else if let hold = SentinelCadence.holdReason(agentBusy: await isAgentBusy(), lastWakeAt: lastWake?.at, wakesLastHour: wakesLastHour,
                                                            settings: settings, now: t) {
                var p = pending ?? SentinelPendingWake(firstAt: t)
                p.reasons.append(.init(at: t, reason: j.verdict.reason, urgency: j.verdict.urgency, signals: j.verdict.signals,
                                       signature: signature, probability: j.verdict.probability, decisionId: id))
                p.holdReason = hold
                pending = p
                pendingDigest = digest
                pendingJudge = j.judge
                holdReason = hold
                outcome = .held
            } else {
                do {
                    eventId = try await writeWake(verdict: j.verdict, digest: digest, trigger: trigger, judge: j.judge, decisionId: id, at: t)
                    outcome = .woke
                    DevLog.shared.info("哨兵", "已叫醒智能体（\(j.verdict.urgency.label)）：\(j.verdict.reason)")
                } catch {
                    outcome = .wakeFailed
                    wakeError = "写唤醒事件失败：\(error.localizedDescription)"
                    lastError = SentinelErrorNote(at: t, message: wakeError!)
                    DevLog.shared.error("哨兵", wakeError!)
                }
            }
        }
        let u = j.usage
        var entry = SentinelDecisionEntry(id: id, at: t, trigger: trigger, judge: j.judge, model: j.model,
                                          fallbackReason: fallbackReason, digestHash: digest.hash, digestBytes: digest.bytes,
                                          verdict: j.verdict, outcome: outcome, latencyMs: latencyMs,
                                          inputTokens: u?.inputTokens, outputTokens: u?.outputTokens,
                                          cacheReadTokens: u?.cacheReadTokens, cacheWriteTokens: u?.cacheWriteTokens,
                                          costUsd: u?.costUsd ?? 0, error: (errors + [wakeError].compactMap { $0 }).joined(separator: "；").nilIfEmpty,
                                          eventId: eventId, signature: signature)
        entry.holdReason = holdReason
        record(entry, at: t)
        SentinelCadence.ran(&cadence, at: t)
        lastRunAt = t
    }

    /// 攒着的叫醒：条件满足时合并成一次发出；等太久就丢弃（记一笔）。闸门关着（安静时段 / 关了）不发。
    private func flushPending(at t: Date) async {
        guard var p = pending else { return }
        if t.timeIntervalSince(p.lastAt) > settings.pendingMaxAgeMinutes * 60 {
            let entry = flushEntry(p, at: t, outcome: .expired, eventId: nil, error: nil)
            pending = nil; pendingDigest = nil
            record(entry, at: t)
            DevLog.shared.info("哨兵", "攒着的 \(p.reasons.count) 条叫醒理由等了太久（最后一条在 \(p.lastAt.formatted(date: .omitted, time: .shortened))），情况多半已变，丢弃")
            return
        }
        guard case .open = gate else { return }
        if let hold = SentinelCadence.holdReason(agentBusy: await isAgentBusy(), lastWakeAt: lastWake?.at, wakesLastHour: wakesLastHour,
                                                 settings: settings, now: t) {
            p.holdReason = hold
            pending = p
            return
        }
        let verdict = mergedVerdict(p)
        let id = UUID()
        do {
            let digest = pendingDigest ?? SentinelDigest(text: "（摘要不可用）", hash: String(repeating: "0", count: 64), bytes: 0, facts: SentinelFacts())
            let eventId = try await writeWake(verdict: verdict, digest: digest, trigger: .flush, judge: pendingJudge, decisionId: id, at: t,
                                              merged: p.reasons)
            var entry = flushEntry(p, at: t, outcome: .woke, eventId: eventId, error: nil)
            entry.id = id
            pending = nil; pendingDigest = nil
            record(entry, at: t)
            DevLog.shared.info("哨兵", "已叫醒智能体（合并 \(p.reasons.count) 条理由，另有 \(p.mergedCount) 次同理由）：\(verdict.reason)")
        } catch {
            let message = "发出攒着的叫醒失败：\(error.localizedDescription)"
            lastError = SentinelErrorNote(at: t, message: message)
            DevLog.shared.error("哨兵", message)
            p.holdReason = message
            pending = p
        }
    }

    /// 合并后的判断：紧急程度取最高；理由取最紧急的那条（同级取最新）；信号取并集。
    private func mergedVerdict(_ p: SentinelPendingWake) -> SentinelVerdict {
        let order: [SentinelUrgency] = [.low, .normal, .high]
        let top = p.reasons.max { a, b in
            let ia = order.firstIndex(of: a.urgency) ?? 0, ib = order.firstIndex(of: b.urgency) ?? 0
            return ia != ib ? ia < ib : a.at < b.at
        }
        let reason = (top?.reason ?? "哨兵攒下的叫醒") + (p.reasons.count > 1 ? "（另有 \(p.reasons.count - 1) 条理由）" : "")
        return SentinelVerdict(wake: true, reason: reason, urgency: p.urgency, signals: p.signals,
                               probability: p.reasons.compactMap(\.probability).max())
    }

    private func flushEntry(_ p: SentinelPendingWake, at t: Date, outcome: SentinelOutcome, eventId: String?, error: String?) -> SentinelDecisionEntry {
        let digest = pendingDigest
        var e = SentinelDecisionEntry(at: t, trigger: .flush, judge: pendingJudge, model: nil, fallbackReason: nil,
                                      digestHash: digest?.hash ?? String(repeating: "0", count: 64), digestBytes: digest?.bytes ?? 0,
                                      verdict: mergedVerdict(p), outcome: outcome, latencyMs: 0,
                                      inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil,
                                      costUsd: 0, error: error, eventId: eventId, signature: nil)
        e.mergedDecisionIds = p.reasons.map(\.decisionId)
        e.mergedSignatures = Array(p.signatures).sorted()
        e.holdReason = p.holdReason
        return e
    }

    private func writeWake(verdict: SentinelVerdict, digest: SentinelDigest, trigger: SentinelTrigger, judge: SentinelJudgeKind,
                           decisionId: UUID, at t: Date, merged: [SentinelPendingWake.Reason] = []) async throws -> String {
        var written: String?
        try await bridge.withBridge(refreshContext: true) { io in
            written = try SentinelBridgeFiles.writeWake(io: io, verdict: verdict, digestText: digest.text, digestHash: digest.hash,
                                                        digestBytes: digest.bytes, trigger: trigger, judge: judge, decisionId: decisionId,
                                                        now: t, merged: merged)
        }
        guard let written else { throw AgentBridgeError.invalid("唤醒事件没有写出") }
        return written
    }

    private func record(_ entry: SentinelDecisionEntry, at t: Date) {
        do { try log.append(entry) } catch {
            lastError = SentinelErrorNote(at: t, message: "决策日志写入失败：\(error.localizedDescription)")
            DevLog.shared.error("哨兵", lastError!.message)
        }
        recent.append(entry)
        let cut = t.addingTimeInterval(-8 * 86400)
        recent.removeAll { $0.at < cut }
    }

    /// 规则兜底（它本身不抛错；万一抛了也给一个「不叫醒」，不让一拍崩掉）。
    private func ruleJudgment(_ digest: SentinelDigest) async -> SentinelJudgment {
        (try? await fallback.judge(digest))
            ?? SentinelJudgment(verdict: .init(wake: false, reason: "规则兜底出错，这一轮不叫醒", urgency: .low, signals: []), judge: .rule)
    }

    private func reportFallback(_ reason: String?) {
        guard reason != reportedFallback else { return }
        if let reason { DevLog.shared.warn("哨兵", "没用上首选判断器：\(reason)") }
        else if reportedFallback != nil { DevLog.shared.info("哨兵", "已恢复用\(settings.preferredJudge.label)判断") }
        reportedFallback = reason
    }

    private func reportStop() {
        if case let .stop(reason) = gate {
            if reportedStop != reason { DevLog.shared.error("哨兵", reason) }
            reportedStop = reason
        } else {
            reportedStop = nil
        }
    }

    // MARK: 状态文件（心跳读）

    var stateLabel: String {
        switch gate {
        case .disabled: "disabled"
        case .skip: "skipped"
        case .stop: "stopped"
        case .open: consecutiveErrors > 0 ? "error" : "ok"
        }
    }

    func statusObject(at t: Date) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let opt: (Date?) -> Any = { $0.map { iso.string(from: $0) } ?? NSNull() }
        let a = attention()
        let today = self.today
        let judged = judgmentsToday
        return [
            "schemaVersion": 1, "writtenAt": iso.string(from: t), "app": "BetterCalendar",
            "enabled": settings.enabled, "state": stateLabel, "gateReason": gate.reason ?? NSNull(),
            "lastTickAt": opt(lastTickAt), "lastRunAt": opt(lastRunAt),
            "judge": judgeInUse.rawValue, "preferredJudge": settings.preferredJudge.rawValue, "wakeThreshold": settings.wakeThreshold,
            "fallbackReason": primaryUnavailableReason ?? lastEntry?.fallbackReason ?? NSNull(),
            "lastError": lastError.map { ["at": iso.string(from: $0.at), "message": $0.message] as [String: Any] } ?? NSNull(),
            "consecutiveErrors": consecutiveErrors, "activityError": activityError ?? NSNull(),
            "today": ["calls": judged.count, "byJudge": Dictionary(grouping: judged, by: \.judge.rawValue).mapValues(\.count),
                      "wakes": wakesToday.count, "held": today.filter { $0.outcome == .held }.count,
                      "merged": today.filter { $0.outcome == .merged }.count,
                      "suppressedDuplicate": today.filter { $0.outcome == .suppressedDuplicate }.count,
                      "expired": today.filter { $0.outcome == .expired }.count,
                      "costUsd": (costTodayUsd * 10000).rounded() / 10000, "fallbacks": judged.filter { $0.fallbackReason != nil }.count,
                      "errors": today.filter { $0.error != nil }.count] as [String: Any],
            "cost7dUsd": (cost7dUsd * 10000).rounded() / 10000,
            "pending": pending.map { p -> [String: Any] in
                ["since": iso.string(from: p.firstAt), "reasons": p.reasons.count, "mergedCount": p.mergedCount, "holdReason": p.holdReason ?? NSNull()]
            } ?? NSNull(),
            "caps": ["maxWakesPerHour": settings.maxWakesPerHour, "dailyBudgetUsd": settings.dailyBudgetUsd, "wakesLastHour": wakesLastHour,
                     "minWakeGapSeconds": settings.minWakeGapSeconds, "note": "稳定性上限（不是产品规则）"] as [String: Any],
            "cadence": ["tickSeconds": settings.tickSeconds, "minIntervalSeconds": settings.pacing(for: judgeInUse).minInterval,
                        "idleIntervalSeconds": settings.idleIntervalSeconds, "debounceSeconds": settings.pacing(for: judgeInUse).debounce] as [String: Any],
            "attention": ["enabled": a.enabled, "quietStartHour": a.quietStartHour, "quietEndHour": a.quietEndHour,
                          "mutedUntil": opt(a.mutedUntil)] as [String: Any],
            "decisionLog": log.location,
        ]
    }

    private func writeStatus(at t: Date) async {
        guard bridge.isConnected else { return }
        // 节拍可能只有 3 秒：状态文件最多 15 秒写一次（状态变了立即写），心跳只需要知道「最近还活着」。
        if let last = lastStatusWrite, last.state == stateLabel, t.timeIntervalSince(last.at) < 15, t >= last.at { return }
        lastStatusWrite = (t, stateLabel)
        nonisolated(unsafe) let status = statusObject(at: t)
        do {
            try await bridge.withBridge(refreshContext: false) { io in try SentinelBridgeFiles.writeStatus(io: io, status) }
            if lastStatusError != nil { DevLog.shared.info("哨兵", "状态文件已恢复写入") }
            lastStatusError = nil
        } catch {
            let message = "写哨兵状态文件失败：\(error.localizedDescription)"
            if lastStatusError != message { DevLog.shared.error("哨兵", message) }
            lastStatusError = message
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
