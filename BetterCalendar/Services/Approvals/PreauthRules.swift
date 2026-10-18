//
//  PreauthRules.swift
//  BetterCalendar
//
//  SPEC §19 A3a（W10，第一版分层预授权）：「以后同类都允许」生成的规则 + 闸门的判定。
//  参照 coding agent 的权限分级：
//    - Claude Code：allow / ask / deny 规则按工具与范围匹配；审批时「这次允许 / 以后同类不再问」；deny 优先于 ask 优先于 allow。
//    - Codex：沙盒边界内可写，越界须申请提权、逐次批准。
//  映射到 BetterCalendar（原则 8「谁的东西谁做主」）：BetterCalendar 的东西 = 可写区（规则可以放行）；
//  你的东西 = 沙盒外（规则永远不能自动放行）；越级 = 申请提权（永远先问你）。
//  默认一律先问你（没有匹配的规则 = ask）。规则随设置多端同步（iCloud KV，见 SettingsSync）。
//

import Foundation
import Observation

/// 规则的效果。
nonisolated enum PreauthEffect: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 直接做（不再问，也不另发结果通知；面板「最近结果」照常可见、可撤销）
    case allow
    /// 直接做，做完发一条结果通知（可撤销）
    case allowAndInform
    /// 先问你（显式写下的 ask 规则优先于 allow，用来给某一类「钉死」要问）
    case ask
    /// 不做：这类提案自动拒绝（智能体在结果里看到「已拒绝」与依据的规则）
    case deny

    var id: String { rawValue }
    var label: String {
        switch self {
        case .allow: "直接做"
        case .allowAndInform: "做完告诉你"
        case .ask: "先问你"
        case .deny: "不做（自动拒绝）"
        }
    }
    var route: ProposalRoute {
        switch self {
        case .allow: .apply
        case .allowAndInform: .applyThenInform
        case .ask: .ask
        case .deny: .decline
        }
    }
    /// 是否会让提案不经你点按就被执行。
    var autoApplies: Bool { self == .allow || self == .allowAndInform }
}

/// 规则的范围。
nonisolated enum PreauthScope: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 这一类改动（不论动谁的东西；但动你的东西的提案永远不会被自动放行，见 PreauthPolicy）
    case kind
    /// 这一类改动 + 只在 BetterCalendar 自己的东西上
    case kindOnBetterCalendar

    var id: String { rawValue }
    var label: String {
        switch self {
        case .kind: "这一类改动"
        case .kindOnBetterCalendar: "这一类改动，且只动 BetterCalendar 自己的东西"
        }
    }
    func covers(_ action: ProposalAction) -> Bool {
        switch self {
        case .kind: true
        case .kindOnBetterCalendar: action.ownership == .betterCalendar
        }
    }
}

nonisolated struct PreauthRule: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var createdAt: Date
    var createdByDeviceId: String
    /// 只匹配这个发起者的提案（通常是智能体）。
    var origin: ProposalOrigin
    /// ProposalAction.ruleKind
    var ruleKind: String
    /// 建规则时那类改动的名字（给人看）。
    var kindLabel: String
    var scope: PreauthScope
    var effect: PreauthEffect
    /// 由哪份提案的审批引出（「以后同类…」）；nil = 在面板里直接建的。
    var sourceProposalId: UUID?

    /// 给人看的一句话：「BetterCalendar 智能体的「计时：暂停计时」（这一类改动）→ 做完告诉你」。
    var label: String { "\(origin.label)的「\(kindLabel)」（\(scope.label)）→ \(effect.label)" }

    func matches(_ p: Proposal) -> Bool {
        p.origin == origin && p.action.ruleKind == ruleKind && scope.covers(p.action)
    }
}

/// 闸门的判定：走哪条路 + 依据的规则（留底「来源 = 规则 id」）+ 为什么。
nonisolated struct ProposalGateVerdict: Equatable, Sendable {
    var route: ProposalRoute
    var rule: PreauthRule? = nil
    var note: String

    static func ask(_ note: String, rule: PreauthRule? = nil) -> ProposalGateVerdict { .init(route: .ask, rule: rule, note: note) }
}

/// 纯函数判定（可单测）。
nonisolated enum PreauthPolicy {
    /// 永远不能被规则自动放行的提案（有值 = 原因）：越级 / 动你的东西 / 删除类。
    static func protectionReason(_ p: Proposal) -> String? {
        let actions = p.options.map(\.action)
        if p.escalation != nil { return "越级提案（动你亲手放的位置或你的东西）每次都要你亲自批准" }
        if actions.contains(where: { $0.ownership == .yours }) { return "动你的东西的改动每次都要你亲自批准" }
        if actions.contains(where: \.isDestructive) { return "删除类改动每次都要你亲自批准" }
        return nil
    }

    /// 能不能从这份提案生成「以后同类都允许」的规则（nil = 可以；有值 = 不能的原因）。
    static func cannotRemember(_ p: Proposal, effect: PreauthEffect) -> String? {
        if effect.autoApplies, let why = protectionReason(p) { return why }
        return nil
    }

    /// 判定顺序（同 Claude Code）：deny ＞ ask ＞ allow；没有匹配 = 先问你。
    /// 越级提案一律先问你（连 deny 也不自动拒绝：越级是智能体审慎判断「确有必要」，要你亲眼看到）；
    /// 有备选方案的一律先问你（智能体在等你挑）。
    static func evaluate(_ p: Proposal, rules: [PreauthRule]) -> ProposalGateVerdict {
        let hits = rules.filter { $0.matches(p) }
        // 有规则命中但仍先问你时，判定里带上那条规则（留底讲得出「为什么规则没生效」）。
        if p.escalation != nil { return .ask("越级提案永远先问你", rule: hits.first) }
        if p.hasAlternatives { return .ask("有 \(p.options.count) 个方案，等你挑", rule: hits.first) }
        if let deny = hits.first(where: { $0.effect == .deny }) {
            return ProposalGateVerdict(route: .decline, rule: deny, note: "按规则自动拒绝：\(deny.label)")
        }
        if let ask = hits.first(where: { $0.effect == .ask }) { return .ask("按规则先问你：\(ask.label)", rule: ask) }
        // 两条放行规则同时命中（范围不同）时取更谨慎的「做完告诉你」。
        guard let allow = hits.first(where: { $0.effect == .allowAndInform }) ?? hits.first(where: { $0.effect == .allow }) else {
            return .ask("没有匹配的预授权规则（默认先问你）")
        }
        if let why = protectionReason(p) { return .ask("规则「\(allow.label)」不能放行这份提案：\(why)", rule: allow) }
        return ProposalGateVerdict(route: allow.effect.route, rule: allow, note: "按规则\(allow.effect.label)：\(allow.label)")
    }
}

/// 规则列表（真相 = UserDefaults 里的一份 JSON，随 SettingsSync 同步到你所有设备）。
@MainActor @Observable final class PreauthRuleStore {
    static let key = "approvals.preauthRules.v1"
    private(set) var rules: [PreauthRule] = []
    private(set) var lastError: String?
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        reload()
    }

    /// 读本地（另一台设备改了规则、SettingsSync 落到本地后也调这里）。读坏了不覆盖原数据，一律按「先问你」处理并可见。
    func reload() {
        guard let data = defaults.data(forKey: Self.key) else { rules = []; return }
        do {
            rules = try JSONDecoder().decode([PreauthRule].self, from: data)
            lastError = nil
        } catch {
            rules = []
            lastError = "预授权规则读不出来（已一律按「先问你」处理，原数据未改）：\(error.localizedDescription)"
            DevLog.shared.error("预授权规则", lastError!)
        }
    }

    /// 新增；同一发起者 + 同一类 + 同一范围已有规则时改成新的效果（不重复堆规则）。
    @discardableResult
    func upsert(origin: ProposalOrigin, action: ProposalAction, scope: PreauthScope, effect: PreauthEffect,
                deviceId: String, sourceProposalId: UUID?) -> PreauthRule {
        if let i = rules.firstIndex(where: { $0.origin == origin && $0.ruleKind == action.ruleKind && $0.scope == scope }) {
            rules[i].effect = effect
            rules[i].sourceProposalId = sourceProposalId ?? rules[i].sourceProposalId
            persist()
            return rules[i]
        }
        let rule = PreauthRule(id: UUID(), createdAt: now(), createdByDeviceId: deviceId, origin: origin,
                               ruleKind: action.ruleKind, kindLabel: action.ruleKindLabel, scope: scope, effect: effect,
                               sourceProposalId: sourceProposalId)
        rules.append(rule)
        persist()
        return rule
    }

    func setEffect(_ id: UUID, _ effect: PreauthEffect) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].effect = effect
        persist()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do {
            if rules.isEmpty { defaults.removeObject(forKey: Self.key) }
            else { defaults.set(try JSONEncoder().encode(rules), forKey: Self.key) }   // Data = plist 类型，可进 iCloud KV
            lastError = nil
        } catch {
            lastError = "预授权规则保存失败：\(error.localizedDescription)"
            DevLog.shared.error("预授权规则", lastError!)
        }
    }
}

/// 生产闸门：按规则判定（规则列表随设置同步）。
@MainActor struct PreauthRuleGate: ProposalGate {
    let store: PreauthRuleStore
    func verdict(for proposal: Proposal) -> ProposalGateVerdict { PreauthPolicy.evaluate(proposal, rules: store.rules) }
}
