//
//  Proposal.swift
//  BetterCalendar
//
//  SPEC §19 B 组：多端审批（Duo 式）的核心数据。
//  一份「提案」= 某个发起者（你 / 智能体 / 系统）想做的一项改动；需要同意时，各端看到的是同一份提案，
//  首个有效决定生效，其余端只显示最新结果。与旧 StateBridge 审批（NativeApproval*，已冻结）完全解耦。
//

import Foundation

/// 谁发起的（SPEC §19 A5：来源记录是将来预授权闸门的依据）。
nonisolated enum ProposalOrigin: String, Codable, Sendable, CaseIterable {
    case user, agent, system
    var label: String {
        switch self {
        case .user: "你"
        case .agent: "BetterCalendar 智能体"
        case .system: "BetterCalendar"
        }
    }
}

nonisolated enum ProposalState: String, Codable, Sendable {
    /// 等你决定
    case pending
    /// 已同意，等执行设备接手
    case approved
    case declined
    case expired
    /// 发起者撤回
    case cancelled
    /// 执行设备报告已应用
    case applied
    /// 执行设备报告失败（不自动重试，不复活）
    case failed

    var label: String {
        switch self {
        case .pending: "待你确认"
        case .approved: "已同意，等待执行"
        case .declined: "已拒绝"
        case .expired: "已过期，不会执行"
        case .cancelled: "已撤回"
        case .applied: "已完成"
        case .failed: "执行失败"
        }
    }
    /// 已有最终结论、不会再变的状态。
    var isClosed: Bool { ![.pending, .approved].contains(self) }
}

nonisolated enum ProposalDecision: String, Codable, Sendable {
    case approve, decline
    var resultingState: ProposalState { self == .approve ? .approved : .declined }
}

/// 给人看的一行改动：「字段：原来 → 改成」。before 为 nil = 新增。
nonisolated struct ProposalChange: Codable, Equatable, Sendable {
    var field: String
    var before: String?
    var after: String?
}

/// 机器执行的内容。新增种类时在这里加 case，并在 ProposalExecuting 实现里处理；
/// 未识别的种类一律执行失败，绝不猜测。
nonisolated enum ProposalAction: Codable, Equatable, Sendable {
    /// 联调用的空改动：批准后只记录「已应用」，不碰任何真实数据。
    case experimentNoop(note: String)

    var kindLabel: String {
        switch self {
        case .experimentNoop: "测试改动（不改真实数据）"
        }
    }
}

nonisolated struct Proposal: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var expiresAt: Date
    var origin: ProposalOrigin
    /// 发起者的具体名字，如「BetterCalendar 智能体」「Claude（替 Jason 测试）」。
    var originLabel: String
    var originDeviceId: String
    /// 上下级：这份提案由哪个更早的操作/提案引出（nil = 直接发起）。
    var parentId: UUID?
    /// 指定执行设备；nil = 由做出同意决定的那台设备执行。
    var targetDeviceId: String?
    /// 通知标题：一句话说明是什么事。
    var title: String
    var changes: [ProposalChange]
    /// 一句话理由（SPEC §19 A3 / 原则 7 补充：讲得出依据）。
    var reason: String
    var action: ProposalAction
    var experiment: Bool
    var state: ProposalState
    var decidedAt: Date?
    var decidedByDeviceId: String?
    var appliedAt: Date?
    var resultNote: String?

    /// 以此刻判断的有效状态：未决定且已过截止时间 = 已过期（不复活，不执行）。
    func effectiveState(at now: Date) -> ProposalState {
        state == .pending && now >= expiresAt ? .expired : state
    }

    /// 本机是否负责执行这份已同意的提案。
    func isExecutor(_ deviceId: String) -> Bool {
        (targetDeviceId ?? decidedByDeviceId) == deviceId
    }

    /// 通知正文：改动前后 + 理由，局外操作也看得懂（Duo 式）。
    var notificationBody: String {
        var lines = changes.map { c -> String in
            switch (c.before, c.after) {
            case let (b?, a?): "\(c.field)：\(b) → \(a)"
            case let (nil, a?): "\(c.field)：新增「\(a)」"
            case let (b?, nil): "\(c.field)：删除「\(b)」"
            case (nil, nil): c.field
            }
        }
        if !reason.isEmpty { lines.append("理由：" + reason) }
        lines.append("发起：" + originLabel)
        return lines.joined(separator: "\n")
    }
}

/// 发起时只填这些；身份、时间、状态由 ProposalCenter 统一盖章。
nonisolated struct ProposalDraft: Sendable {
    var origin: ProposalOrigin
    var originLabel: String
    var parentId: UUID? = nil
    var targetDeviceId: String? = nil
    var title: String
    var changes: [ProposalChange]
    var reason: String
    var action: ProposalAction
    var experiment: Bool
    var lifetime: TimeInterval = 24 * 3600
}
