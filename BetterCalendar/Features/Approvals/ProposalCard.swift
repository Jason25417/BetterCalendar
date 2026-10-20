//
//  ProposalCard.swift
//  BetterCalendar
//
//  W19（P1 双射）：一张提案卡只有一种长相——「智能体」页顶部的待确认卡、对话气泡里的卡、
//  设置 →「审批记录与规则」里的待确认卡都是这一个组件；回应控件仍是 ProposalCardControls（通知上的按钮是它的系统版）。
//  待确认：越级横条 + 标题 + 改动前→后（或备选方案）+ 有效期 + 回应控件。
//  有结论：结论 + 结果说明（降级 / 失败照写，P4）+ 你回的话 / 代你决定的规则 + 能撤销就给「撤销」。
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
        VStack(alignment: .leading, spacing: 6) {
            if let e = p.escalation, state == .pending {
                ProposalEscalationBanner(reason: e, subjects: p.chosen.changes.filter(\.isEscalationSubject)
                    .map { String($0.field.dropFirst(ProposalChange.escalationMarker.count)) })
            }
            // W32d：低风险自动通过的回执 =「已自动通过：…」+ 改动 + 撤销
            Text(autoPassed ? "已自动通过：" + p.title : p.title).font(.subheadline.bold())
            if state == .pending {
                if p.hasAlternatives {
                    Text("智能体给了 \(p.options.count) 个方案，挑一个：").font(.callout)
                } else {
                    changeLines(p, hideSubjects: p.escalation != nil)
                }
                reasonLine(p)
                Text("不处理到 \(p.expiresAt.formatted(date: .abbreviated, time: .shortened)) 就自动作废")
                    .font(.caption2).foregroundStyle(.secondary)
                ProposalCardControls(center: center, proposal: p)
                    .onAppear { FeatureUsage.seen(.proposalCard) }
            } else {
                if p.hasAlternatives, p.chosenOption != nil { Text("你选了【\(p.chosen.index + 1). \(p.chosen.label)】").font(.caption) }
                changeLines(p, hideSubjects: false)
                if !p.tuningSummary.isEmpty { Text(p.tuningSummary.joined(separator: "\n")).font(.caption) }
                reasonLine(p)
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

    /// W32e：卡片 = 改动本身（改动前 → 改动后），每条只出现一次。
    @ViewBuilder private func changeLines(_ p: Proposal, hideSubjects: Bool) -> some View {
        let lines = p.chosen.changes.filter { !(hideSubjects && $0.isEscalationSubject) }.map(Proposal.line)
        if !lines.isEmpty { Text(lines.joined(separator: "\n")).font(.caption) }
    }

    @ViewBuilder private func reasonLine(_ p: Proposal) -> some View {
        if !p.reason.isEmpty { Text("理由：" + p.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
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
                if let e = p.escalation, state != .pending { Text("越级理由：" + e).foregroundStyle(.orange) }
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
