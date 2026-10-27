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
        (p.preauth?.ruleId == PreauthPolicy.lowRiskRuleId ? "已自动通过：" : p.preauth?.ruleId == PreauthPolicy.autoReflowRuleId ? "已自动顺延：" : "")
            + p.cardHeadline
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
        if p.preauth?.ruleId == PreauthPolicy.autoReflowRuleId, p.state == .applied { return "已自动顺延" }
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

// MARK: - W34 批量卡（App 侧合卡；智能体照旧一件事一份提案）

/// 能合成一批的「同类」。排一天 / 计时 / 测试改动本身就是一份完整的事，不合。
nonisolated enum ProposalFamily: String, Sendable {
    case delete, create, edit, complete, move

    var verb: String {
        switch self {
        case .delete: "删除"
        case .create: "新增"
        case .edit: "修改"
        case .complete: "标完成"
        case .move: "挪动"
        }
    }

    static func of(_ a: ProposalAction) -> ProposalFamily? {
        if a.isUndoOnly { return nil }
        switch a {
        case .blockDelete, .yourEventDelete, .yourReminderDelete, .itemDelete, .checkpointDelete: return .delete
        case .itemCreate, .blockCreate, .reminder, .alarm, .checkpointCreate, .journalAppend: return .create
        case .itemEdit, .blockEdit, .yourEventEdit, .journalEdit: return .edit
        case .itemSetDone: return .complete
        case let .yourReminderEdit(e): return e.title == nil && e.due == nil && e.done != nil ? .complete : .edit
        case .moveBlock, .moveBlocks: return .move
        default: return nil
        }
    }
}

/// 一张卡：一份提案，或同一次行动里的同类一批。
nonisolated struct ProposalGroup: Identifiable, Equatable, Sendable {
    let proposals: [Proposal]
    let family: ProposalFamily?
    var id: UUID { proposals[0].id }
    var isBatch: Bool { proposals.count > 1 }
    var title: String { "\(family?.verb ?? "处理") \(proposals.count) 项" }
}

nonisolated enum ProposalBatching {
    /// 同一次行动：同一发起者、相邻两份相隔不超过这么久（智能体一轮里逐份提交，通常几秒内）。
    static let window: TimeInterval = 120

    /// 能进批量卡：智能体发起、没有备选 / 可调参数（那些要你逐份挑 / 调）、属于某一同类。
    static func batchable(_ p: Proposal) -> ProposalFamily? {
        guard p.origin == .agent, !p.experiment, !p.hasAlternatives, !p.hasParameters else { return nil }
        return ProposalFamily.of(p.action)
    }

    /// 分组（不看状态：已处理的一批照样认得出，用于「整批撤销」）。组内按提交先后；组的次序 = 输入里第一次出现的次序。
    static func groups(_ input: [Proposal]) -> [ProposalGroup] {
        var groupOf: [UUID: Int] = [:]
        var members: [[Proposal]] = []
        var families: [ProposalFamily?] = []
        var open: [String: Int] = [:]   // 发起者 + 同类 → 还能接上的那一组
        for p in input.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
            guard let family = batchable(p) else {
                groupOf[p.id] = members.count; members.append([p]); families.append(nil); continue
            }
            let key = "\(p.originLabel)|\(p.agentKey ?? "")|\(family.rawValue)"
            if let g = open[key], let last = members[g].last, p.createdAt.timeIntervalSince(last.createdAt) <= window {
                members[g].append(p); groupOf[p.id] = g
            } else {
                open[key] = members.count; groupOf[p.id] = members.count; members.append([p]); families.append(family)
            }
        }
        var seen = Set<Int>(), out: [ProposalGroup] = []
        for p in input {
            guard let g = groupOf[p.id], seen.insert(g).inserted else { continue }
            out.append(ProposalGroup(proposals: members[g], family: families[g]))
        }
        return out
    }
}
