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
        VStack(alignment: .leading, spacing: 6) {
            if let e = p.escalation, state == .pending { ProposalEscalationBanner(reason: e) }
            Text(p.title).font(.subheadline.bold())
            if state == .pending {
                if p.hasAlternatives {
                    Text("智能体给了 \(p.options.count) 个方案，挑一个：").font(.callout)
                    Text("理由：\(p.reason)").font(.caption)
                } else {
                    Text(p.notificationBody.components(separatedBy: "\n")
                        .filter { !$0.hasPrefix(Proposal.escalationHeadline) && !$0.hasPrefix(Proposal.adjustablePrefix) }
                        .joined(separator: "\n")).font(.caption)
                }
                Text("不处理到 \(p.expiresAt.formatted(date: .abbreviated, time: .shortened)) 就自动作废")
                    .font(.caption2).foregroundStyle(.secondary)
                ProposalCardControls(center: center, proposal: p)
            } else {
                Text(p.notificationBody).font(.caption)
                Text([state.label, p.resultNote].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(state == .failed ? .orange : .secondary)
                ProposalOutcomeNotes(proposal: p)
                undoRow
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(highlighted ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.3)))
        .id("\(p.id.uuidString)-\(center.replying.contains(p.id))")   // 展开「回一句」时换 id，逼外层重新量高
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
                    Button("撤销") { Task { await center.undo(p.id) } }.font(.caption).buttonStyle(.bordered)
                    if let hint = p.undoHint { Text(hint).font(.caption2).foregroundStyle(.secondary) }
                }
            } else if let reason = center.undoBlockedReason(p) {
                Text("不能撤销：\(reason)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
