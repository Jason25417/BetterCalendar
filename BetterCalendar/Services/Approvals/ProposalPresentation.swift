//
//  ProposalPresentation.swift
//  BetterCalendar
//
//  W34（Jason 2026-10-21）：审批卡怎么说的纯规则（可单测；ProposalCard / 批量卡 / 压缩条共用同一份口径）。
//  · 每样信息只出现一次：一句「做什么」（headline）+ 改动前 → 后 + 一行后果（进回收站 / 可撤销 / 撤销限制）；
//    越级点名行不在正文里，只在红色小盾牌的小窗里；
//  · 有效期默认不显示（注意力守恒、不施压）；临近作废才在盾牌旁加闹钟小图标，小窗里写还剩多久；到期只作废。
//

import Foundation

nonisolated enum ProposalPresentation {
    /// 卡片标题那一句（低风险自动通过的回执带「已自动通过：」）。
    static func headline(_ p: Proposal) -> String {
        (p.preauth?.ruleId == PreauthPolicy.lowRiskRuleId ? "已自动通过：" : "") + p.cardHeadline
    }

    /// 正文：改动前 → 后（不含越级点名、不含后果行）。
    static func changeLines(_ changes: [ProposalChange]) -> [String] {
        changes.filter { !$0.isEscalationSubject && !$0.isConsequence }.map(Proposal.line)
    }

    /// 后果合成一行（「进回收站，30 天内可恢复 · 可一键撤销」）。
    static func consequenceLine(_ changes: [ProposalChange]) -> String? {
        let parts = changes.filter(\.isConsequence).map(\.field)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 越级小窗里点名「动的是你的什么」。
    static func escalationSubjects(_ changes: [ProposalChange]) -> [String] {
        changes.filter(\.isEscalationSubject).map { String($0.field.dropFirst(ProposalChange.escalationMarker.count)) }
    }

    // MARK: 有效期（默认不显示；临近作废才出闹钟）

    /// 临近作废的提示窗：最后 25% 的有效期，且不超过 60 分钟（15 分钟的提案 = 最后 3–4 分钟；7 天的 = 最后 1 小时）。
    static func nearExpiryWindow(_ p: Proposal) -> TimeInterval {
        min(3600, max(0, p.expiresAt.timeIntervalSince(p.createdAt)) * 0.25)
    }

    static func isNearExpiry(_ p: Proposal, at now: Date) -> Bool {
        guard p.effectiveState(at: now) == .pending else { return false }
        let left = p.expiresAt.timeIntervalSince(now)
        return left > 0 && left <= nearExpiryWindow(p)
    }

    /// 「还有 12 分钟作废」（不到 1 分钟 =「马上作废」）。
    static func timeLeft(_ p: Proposal, at now: Date) -> String {
        let minutes = Int((p.expiresAt.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 1 { return "马上就作废了（到期只作废，不会默认同意）" }
        let span = minutes >= 120 ? "\(minutes / 60) 小时" : "\(minutes) 分钟"
        return "还有 \(span)作废（到期只作废，不会默认同意）"
    }

    /// 「详情」里的有效期一行（完整、但默认折起）。
    static func expiryDetail(_ p: Proposal) -> String {
        "有效期至 \(p.expiresAt.formatted(date: .abbreviated, time: .shortened))；到期只作废，不会默认同意"
    }

    // MARK: 压缩条（W34：一条消息下已处理的卡收起后，每份一行「做什么 + 状态」）

    static func compactStatus(_ p: Proposal, at now: Date) -> String {
        if p.undoneAt != nil { return "已撤销" }
        if p.preauth?.ruleId == PreauthPolicy.lowRiskRuleId, p.state == .applied { return "已自动通过" }
        switch p.effectiveState(at: now) {
        case .applied: return "已批准"
        case .approved: return "已批准，执行中"
        case .declined: return "已拒绝"
        case .expired: return "已作废"
        case .cancelled: return "已撤回"
        case .failed: return "执行失败"
        case .replied: return "你回了一句"
        case .pending: return "待你确认"
        }
    }
}

