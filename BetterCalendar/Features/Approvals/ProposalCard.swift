//
//  ProposalCard.swift
//  BetterCalendar
//
//  W19（P1 双射）：一张提案卡只有一种长相——「智能体」页顶部的待确认卡、对话气泡里的卡、
//  设置 →「审批记录与规则」里的待确认卡都是这一个组件；回应控件仍是 ProposalCardControls（通知上的按钮是它的系统版）。
//  W34（Jason 2026-10-21）：每样信息只出现一次——
//    [红色小盾牌（越级）][闹钟（临近作废）] 一句「做什么」/ 改动前 → 后 / 一行后果 / 理由 ▸ / 回应控件 / 详情 ▸。
//    盾牌、闹钟：Mac 悬停出提示、点一下出小窗；iPhone 点一下出小窗。有效期默认不显示（在「详情」里），到期只作废。
//  有结论：结论 + 结果说明（降级 / 失败照写，P4）+ 你回的话 + 能撤销就给「撤销」。
//

import SwiftUI

struct ProposalCard: View {
    @Bindable var center: ProposalCenter
    let proposal: Proposal
    var highlighted = false

    var body: some View {
        let p = proposal
        let state = p.effectiveState(at: .now)
        let autoPassed = p.preauth?.ruleId == PreauthPolicy.lowRiskRuleId
        let changes = p.chosen.changes
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ProposalBadges(proposal: p)
                Text(ProposalPresentation.headline(p)).font(.subheadline.bold())
            }
            if state == .pending {
                if p.hasAlternatives {
                    Text("智能体给了 \(p.options.count) 个方案，挑一个：").font(.callout)
                } else {
                    changeLines(changes)
                }
                ProposalReason(reason: p.reason)
                if center.deciding.contains(p.id) {
                    Label("提交中…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProposalCardControls(center: center, proposal: p)
                        .onAppear { FeatureUsage.seen(.proposalCard) }
                }
            } else {
                if p.hasAlternatives, p.chosenOption != nil { Text("你选了【\(p.chosen.index + 1). \(p.chosen.label)】").font(.caption) }
                changeLines(changes)
                if !p.tuningSummary.isEmpty { Text(p.tuningSummary.joined(separator: "\n")).font(.caption) }
                ProposalReason(reason: p.reason)
                statusLine(p, state: state, autoPassed: autoPassed)
                if let reply = p.userReply { Text("你回了一句：「\(reply.text)」").font(.caption) }
                undoRow
            }
            ProposalDetails(proposal: p, state: state)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(highlighted ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.3)))
        .id("\(p.id.uuidString)-\(center.replying.contains(p.id))")   // 展开「回一句」时换 id，逼外层重新量高
    }

    /// W34：改动前 → 后 + 一行后果；越级点名只在盾牌小窗里。
    @ViewBuilder private func changeLines(_ changes: [ProposalChange]) -> some View {
        let lines = ProposalPresentation.changeLines(changes)
        if !lines.isEmpty { Text(lines.joined(separator: "\n")).font(.caption) }
        if let c = ProposalPresentation.consequenceLine(changes) { Text(c).font(.caption2).foregroundStyle(.secondary) }
    }

    /// 结论一行：失败 / 过期等原因照常可见；已完成时结果说明只是复述改动 → 收进「详情」，
    /// 但带「注意：」的（替身 / 降级 / 稍后同步）直接显示（P4 不暗减）。
    @ViewBuilder private func statusLine(_ p: Proposal, state: ProposalState, autoPassed: Bool) -> some View {
        let note = p.resultNote ?? ""
        if state == .applied {
            let deviation = note.contains(ProposalExecutionOutcome.deviationMarker)
            if deviation { Text(note).font(.caption).foregroundStyle(.orange) }
            else if !autoPassed { Text(state.label).font(.caption).foregroundStyle(.secondary) }
        } else {
            Text([state.label, p.resultNote].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(state == .failed ? .orange : .secondary)
        }
    }

    /// SPEC §19 A3 后半：已执行的真改动可撤销（撤销 = 一条来源为「你」的操作，写进操作留底）。
    @ViewBuilder private var undoRow: some View {
        let p = proposal
        if let at = p.undoneAt {
            Text("已撤销 \(at.formatted(date: .omitted, time: .shortened))" + (p.undoNote.map { " · \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        } else if p.state == .applied, p.action.touchesRealData {
            if center.canUndo(p) {
                HStack(spacing: 8) {
                    Button("撤销") {
                        FeatureUsage.used(.proposalUndo)
                        Task { await center.undo(p.id) }
                    }.font(.caption).buttonStyle(.bordered)
                    .onAppear { FeatureUsage.seen(.proposalUndo) }
                    if let hint = p.undoHint { Text(hint).font(.caption2).foregroundStyle(.secondary) }
                }
            } else if let reason = center.undoBlockedReason(p) {
                Text("不能撤销：\(reason)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// W32e：调试 / 追溯信息（发起者、规则 id、提案 id、执行设备、完整结果说明、越级理由、撤销说明）收进「详情」——完整、但默认折起。
struct ProposalDetails: View {
    let proposal: Proposal
    let state: ProposalState
    var body: some View {
        let p = proposal
        DisclosureGroup("详情") {
            VStack(alignment: .leading, spacing: 2) {
                Text("发起：" + p.originLabel + (p.agentKey.map { "（\(AgentKind.of($0).shortLabel)）" } ?? ""))
                Text("种类：\(p.executedAction.kindLabel)（\(p.executedAction.kind)）")
                if let e = p.escalation { Text("越级理由：" + e).foregroundStyle(.red) }
                if state == .pending || state == .expired { Text(ProposalPresentation.expiryDetail(p)) }
                if let stamp = p.preauth {
                    Text("由\(stamp.ruleId == PreauthPolicy.lowRiskRuleId ? "「低风险改动自动通过」" : "预授权规则")代你决定（\(stamp.effect.label)）：\(stamp.ruleLabel) · 规则 \(stamp.ruleId.uuidString.prefix(8))")
                }
                if let note = p.resultNote, state == .applied { Text("结果：" + note) }
                if let at = p.decidedAt { Text("决定于 \(at.formatted(date: .abbreviated, time: .standard))" + (p.decidedByDeviceId.map { " · 设备 \($0.prefix(12))" } ?? "")) }
                if let r = p.undoUnavailableReason { Text("撤销：" + r) }
                Text("提案 \(p.id.uuidString)").textSelection(.enabled)
                if let ref = p.parentRef ?? p.parentId?.uuidString { Text("由 \(ref) 引出").textSelection(.enabled) }
            }
            .font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption2)
        .accessibilityIdentifier("bc.proposal.details")
    }
}

/// W34：理由默认收起（点开才看全文）。
struct ProposalReason: View {
    let reason: String
    var body: some View {
        if !reason.isEmpty {
            DisclosureGroup("理由") {
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .font(.caption)
            .accessibilityIdentifier("bc.proposal.reason")
        }
    }
}

/// W34：标题前的小图标——红色小盾牌 = 越级；闹钟 = 临近作废（待确认时才有）。
/// Mac：悬停出系统提示，点一下出小窗；iPhone：点一下出小窗。
struct ProposalBadges: View {
    let proposal: Proposal
    var body: some View {
        HStack(spacing: 4) {
            if let e = proposal.escalation {
                ProposalBadge(systemImage: "exclamationmark.shield.fill", tint: .red, identifier: "bc.proposal.escalation",
                              title: "越级：这会动你亲手放的位置或你的东西",
                              lines: ProposalPresentation.escalationSubjects(proposal.chosen.changes) + ["智能体的理由：" + e],
                              footnote: "越级提案每次都要你亲自批准，预授权规则不会代你放行。")
            }
            if proposal.effectiveState(at: .now) == .pending {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    if ProposalPresentation.isNearExpiry(proposal, at: ctx.date) {
                        ProposalBadge(systemImage: "alarm.fill", tint: .orange, identifier: "bc.proposal.nearExpiry",
                                      title: ProposalPresentation.timeLeft(proposal, at: ctx.date), lines: [], footnote: nil)
                    }
                }
                .fixedSize()
            }
        }
    }
}

struct ProposalBadge: View {
    let systemImage: String
    let tint: Color
    let identifier: String
    let title: String
    let lines: [String]
    let footnote: String?
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: systemImage).foregroundStyle(tint).font(.subheadline)
        }
        .buttonStyle(.plain)
        .help(([title] + lines).joined(separator: "\n"))
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold()).foregroundStyle(tint)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(l).font(.callout) }
                if let footnote { Text(footnote).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(12)
            .frame(maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .presentationCompactAdaptation(.popover)
        }
    }
}
