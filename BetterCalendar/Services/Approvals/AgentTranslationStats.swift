//
//  AgentTranslationStats.swift
//  BetterCalendar
//
//  SPEC §19.1「翻译官 + 参谋」的转译偏差观察（批次 6）：只统计，不改任何行为。
//  数据来源：
//    - 提案列表（ProposalCenter.proposals，经 iCloud 各端同一份）→ 批准 / 拒绝 / 过期 / 撤回 / 执行失败；
//    - 操作留底（OperationLedger，**本机**文件）→ 撤销（W1 的事件名 `undone` / `undo.failed`，先预留）
//      与「批准后被手动改掉」（预留事件名 `overridden`，当前无写入者）；
//    - 智能体消息（AgentMessageCenter.messages，各端同一份）→ 弹出 / 拦下 / 「好」/「静音」。
//  将来分层预授权闸门（A3a / §19.11）的依据就来自这里的比例。
//

import Foundation

/// 统计时间窗。「今天」按逻辑日（凌晨 4 点日界线）。
nonisolated enum AgentStatsWindow: String, CaseIterable, Identifiable, Sendable {
    case today, week, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: "今天"
        case .week: "7 天"
        case .all: "全部"
        }
    }

    /// 窗口起点（含）；nil = 不限。
    func start(now: Date) -> Date? {
        switch self {
        case .today: DayContext.logicalWindow(forLabel: DayContext.logicalStartOfDay(now)).start
        case .week: now.addingTimeInterval(-7 * 24 * 3600)
        case .all: nil
        }
    }
}

/// 一个比例：分子 / 分母；分母为 0 时没有比例（界面显示「—」，不显示 0%）。
nonisolated struct StatRatio: Equatable, Sendable {
    var count: Int
    var of: Int
    var fraction: Double? { of > 0 ? Double(count) / Double(of) : nil }
    var percentText: String { fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
    /// 「3/4（75%）」
    var text: String { of > 0 ? "\(count)/\(of)（\(percentText)）" : "—" }
}

nonisolated struct AgentTranslationStats: Equatable, Sendable {
    // 提案（来源 = 智能体，按创建时间落在窗内）
    var proposals = 0
    /// 仍待决定（含已同意但还没执行完的不算这里：那已有决定）
    var pending = 0
    /// 你同意了（含之后执行成功 / 失败 / 撤销的）
    var approved = 0
    var declined = 0
    var expired = 0
    var cancelled = 0
    /// 执行设备报告已应用
    var applied = 0
    /// 执行设备报告失败
    var failed = 0
    /// 已应用后被撤销（本机留底 `undone`）
    var undone = 0
    /// 撤销没成功（本机留底 `undo.failed`，例如版本已变）
    var undoFailed = 0
    /// 批准后被你手动改掉（预留 `overridden`，当前无写入者）
    var overridden = 0

    // 智能体主动消息（按创建时间落在窗内）
    var messages = 0
    var delivered = 0
    var suppressed = 0
    var acknowledged = 0
    var muted = 0

    /// 已有决定的提案（同意 / 拒绝 / 过期 / 撤回）——各比例的分母。
    var resolved: Int { approved + declined + expired + cancelled }
    var approvalRate: StatRatio { StatRatio(count: approved, of: resolved) }
    var declineRate: StatRatio { StatRatio(count: declined, of: resolved) }
    var expiryRate: StatRatio { StatRatio(count: expired, of: resolved) }
    /// 执行失败 / 已同意
    var failureRate: StatRatio { StatRatio(count: failed, of: approved) }
    /// 撤销 / 已应用
    var undoRate: StatRatio { StatRatio(count: undone, of: applied) }
    /// 被手动改掉 / 已应用
    var overrideRate: StatRatio { StatRatio(count: overridden, of: applied) }

    var deliveredRate: StatRatio { StatRatio(count: delivered, of: messages) }
    var suppressedRate: StatRatio { StatRatio(count: suppressed, of: messages) }
    /// 「好」/ 已弹出
    var acknowledgedRate: StatRatio { StatRatio(count: acknowledged, of: delivered) }
    /// 「静音」/ 已弹出
    var mutedRate: StatRatio { StatRatio(count: muted, of: delivered) }

    var isEmpty: Bool { proposals == 0 && messages == 0 }
}

nonisolated enum AgentTranslationStatsCalculator {
    /// W1 撤销上线后写入留底的事件名（先预留；无此事件时撤销数为 0）。
    static let undoneEvent = "undone"
    static let undoFailedEvent = "undo.failed"
    /// 预留：批准并应用后，你又手动改掉了这项改动。
    static let overriddenEvent = "overridden"

    static func compute(proposals: [Proposal], messages: [AgentMessage], ledger: [OperationRecord],
                        window: AgentStatsWindow, now: Date) -> AgentTranslationStats {
        let start = window.start(now: now)
        let inWindow = { (d: Date) in start.map { d >= $0 } ?? true }
        var s = AgentTranslationStats()

        let agentProposals = proposals.filter { $0.origin == .agent && inWindow($0.createdAt) }
        let ids = Set(agentProposals.map(\.id))
        // 留底按提案去重（同一提案多台设备 / 多次记录只算一次）。
        func flagged(_ event: String) -> Set<UUID> {
            Set(ledger.compactMap { r in r.event == event ? r.proposalId : nil }.filter(ids.contains))
        }
        let undoneIds = flagged(undoneEvent), undoFailedIds = flagged(undoFailedEvent), overriddenIds = flagged(overriddenEvent)

        for p in agentProposals {
            s.proposals += 1
            switch p.effectiveState(at: now) {
            case .pending: s.pending += 1
            case .approved: s.approved += 1
            case .applied: s.approved += 1; s.applied += 1
            case .failed: s.approved += 1; s.failed += 1
            case .declined: s.declined += 1
            case .expired: s.expired += 1
            case .cancelled: s.cancelled += 1
            }
        }
        // 撤销 / 手改只可能发生在已应用之后；按留底集合计数。
        // ⚠️ 上面的 switch 刻意穷举：W1 若给 ProposalState 新增状态（如 undone），合并时编译器会逼着在这里归类。
        s.undone = undoneIds.count
        s.undoFailed = undoFailedIds.subtracting(undoneIds).count
        s.overridden = overriddenIds.count
        // 撤销后若提案状态被改成别的（W1 可能新增），仍按「曾应用」计入分母，保证比例 ≤ 100%。
        s.applied = max(s.applied, s.undone + s.overridden)

        for m in messages where inWindow(m.createdAt) {
            s.messages += 1
            switch m.delivery {
            case .delivered: s.delivered += 1
            case .suppressed: s.suppressed += 1
            }
            switch m.reaction {
            case .acknowledged?: s.acknowledged += 1
            case .muted?: s.muted += 1
            case nil: break
            }
        }
        return s
    }
}
