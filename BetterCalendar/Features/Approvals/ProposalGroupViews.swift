//
//  ProposalGroupViews.swift
//  BetterCalendar
//
//  W34（Jason 2026-10-21）：
//  · 批量卡——同一次行动里的同类待批提案（ProposalBatching）合成一张「删除 6 项」：每项一个勾选框（默认全勾），
//    「同意（N 项）」= 勾上的同意、没勾的拒绝；每项可展开成它自己的完整卡（单独回一句 / 单独批）。
//  · 已处理的卡收起——一条消息下面有结论的卡全收进一个小箭头：点开是压缩条（做什么 + 状态），再点某一条才展开完整卡；
//    同一批里能撤销的有两份以上时给「撤销这一批」。
//  待确认列表（智能体页顶部 / 设置页）与对话气泡共用这里的组件（P1：同一份提案只有一种长相）。
//

import SwiftUI

/// 待确认列表：一份一张卡，同一次行动的同类合成一张批量卡。anchor = 每份提案在滚动容器里的 id（指路滚动用）。
struct PendingProposalStack: View {
    @Bindable var center: ProposalCenter
    let pending: [Proposal]
    var highlighted: (UUID) -> Bool = { _ in false }
    var anchor: (UUID) -> String = { $0.uuidString }

    var body: some View {
        ForEach(ProposalBatching.groups(pending)) { g in
            if g.isBatch {
                ProposalBatchCard(center: center, group: g, highlighted: highlighted, anchor: anchor)
            } else {
                ProposalCard(center: center, proposal: g.proposals[0], highlighted: highlighted(g.id)).id(anchor(g.id))
            }
        }
    }
}

struct ProposalBatchCard: View {
    @Bindable var center: ProposalCenter
    let group: ProposalGroup
    var highlighted: (UUID) -> Bool = { _ in false }
    var anchor: (UUID) -> String = { $0.uuidString }
    @State private var unchecked: Set<UUID> = []
    @State private var expanded: Set<UUID> = []

    private var checked: [UUID] { group.proposals.map(\.id).filter { !unchecked.contains($0) } }

    var body: some View {
        let ps = group.proposals
        let consequences = ps.map { ProposalPresentation.consequenceLine($0.chosen.changes) }
        let sharedAll = Set(consequences).count == 1   // 后果都一样 → 只在列表下面说一次
        let allEscalated = ps.allSatisfy { $0.escalation != nil }   // 都越级 → 标题旁一个盾牌就够，行里不重复
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ProposalBatchBadges(group: group)
                Text(group.title).font(.subheadline.bold())
            }
            ForEach(ps) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button { toggle(p.id) } label: {
                            Image(systemName: unchecked.contains(p.id) ? "square" : "checkmark.square.fill")
                                .foregroundStyle(unchecked.contains(p.id) ? Color.secondary : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(unchecked.contains(p.id) ? "不同意这项" : "同意这项")
                        .accessibilityIdentifier("bc.proposal.batch.check")
                        if p.escalation != nil, !allEscalated {
                            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red).font(.caption)
                        }
                        Text(p.cardHeadline).font(.callout)
                            .strikethrough(unchecked.contains(p.id), color: .secondary)
                            .foregroundStyle(unchecked.contains(p.id) ? .secondary : .primary)
                        Spacer(minLength: 4)
                        Button { expand(p.id) } label: {
                            Image(systemName: expanded.contains(p.id) ? "chevron.down" : "chevron.right").font(.caption)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("展开这项")
                    }
                    if !sharedAll, let c = ProposalPresentation.consequenceLine(p.chosen.changes) {
                        Text(c).font(.caption2).foregroundStyle(.secondary).padding(.leading, 22)
                    }
                    if expanded.contains(p.id) {
                        ProposalCard(center: center, proposal: p, highlighted: highlighted(p.id)).padding(.leading, 22)
                    }
                }
                .id(anchor(p.id))
            }
            if sharedAll, let c = consequences[0] { Text(c).font(.caption2).foregroundStyle(.secondary) }
            ProposalReason(reason: Self.reasons(ps))
            if ps.contains(where: { center.deciding.contains($0.id) }) {
                Label("提交中…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button("同意（\(checked.count) 项）") {
                        FeatureUsage.used(.proposalApprove)
                        let yes = checked, no = ps.map(\.id).filter { unchecked.contains($0) }
                        Task { await center.decideBatch(approve: yes, decline: no) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(checked.isEmpty)
                    .accessibilityIdentifier("bc.proposal.batch.approve")
                    Button("全部拒绝", role: .destructive) {
                        FeatureUsage.used(.proposalDecline)
                        Task { await center.decideBatch(approve: [], decline: ps.map(\.id)) }
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .onAppear { FeatureUsage.seen(.proposalCard) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ps.contains { highlighted($0.id) } ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.3)))
        .accessibilityIdentifier("bc.proposal.batch")
    }

    private func toggle(_ id: UUID) { if unchecked.contains(id) { unchecked.remove(id) } else { unchecked.insert(id) } }
    private func expand(_ id: UUID) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }

    /// 理由去重（同一次行动的理由多半一样）。
    static func reasons(_ ps: [Proposal]) -> String {
        var seen = Set<String>()
        return ps.map(\.reason).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
    }
}

/// 批量卡标题前的小图标：任一项越级 → 盾牌（小窗里逐项点名）；任一项临近作废 → 闹钟（按最早作废的那份）。
struct ProposalBatchBadges: View {
    let group: ProposalGroup
    var body: some View {
        let escalated = group.proposals.filter { $0.escalation != nil }
        HStack(spacing: 4) {
            if !escalated.isEmpty {
                ProposalBadge(systemImage: "exclamationmark.shield.fill", tint: .red, identifier: "bc.proposal.escalation",
                              title: "越级：这一批里有 \(escalated.count) 项会动你的东西",
                              lines: escalated.flatMap { ProposalPresentation.escalationSubjects($0.chosen.changes) }
                                  + Array(Set(escalated.compactMap(\.escalation))).sorted().map { "智能体的理由：" + $0 },
                              footnote: "越级提案每次都要你亲自批准，预授权规则不会代你放行。")
            }
            if let soonest = group.proposals.min(by: { $0.expiresAt < $1.expiresAt }) {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    if ProposalPresentation.isNearExpiry(soonest, at: ctx.date) {
                        ProposalBadge(systemImage: "alarm.fill", tint: .orange, identifier: "bc.proposal.nearExpiry",
                                      title: ProposalPresentation.timeLeft(soonest, at: ctx.date), lines: [], footnote: nil)
                    }
                }
                .fixedSize()
            }
        }
    }
}

/// 一条消息下面已有结论的卡：默认收起成一个小箭头。
struct ResolvedProposalsGroup: View {
    @Bindable var center: ProposalCenter
    let proposals: [Proposal]
    var focusId: UUID? = nil
    @State private var open: Bool
    @State private var openCards: Set<UUID>
    @State private var undoingBatch: UUID?

    /// 从通知「查看详情」点进来的那份（focusId）在这一组里 → 直接展开到它的完整卡。
    init(center: ProposalCenter, proposals: [Proposal], focusId: UUID? = nil) {
        self.center = center; self.proposals = proposals; self.focusId = focusId
        let focused = focusId.flatMap { id in proposals.contains { $0.id == id } ? id : nil }
        _open = State(initialValue: focused != nil)
        _openCards = State(initialValue: focused.map { [$0] } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("已处理 \(proposals.count) 项").font(.caption.weight(.medium))
                    Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bc.chat.resolvedToggle")
            if open {
                ForEach(ProposalBatching.groups(proposals)) { g in
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(g.proposals) { p in
                            if openCards.contains(p.id) {
                                // 展开 = 压缩条换成完整卡（标题不重复）；右上角小箭头收回
                                ProposalCard(center: center, proposal: p, highlighted: p.id == focusId)
                                    .overlay(alignment: .topTrailing) {
                                        Button { openCards.remove(p.id) } label: {
                                            Image(systemName: "chevron.up").font(.caption2).padding(10).contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                        .accessibilityLabel("收起")
                                    }
                            } else {
                                Button { openCards.insert(p.id) } label: { row(p) }.buttonStyle(.plain)
                            }
                        }
                        batchUndo(g)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    /// 压缩条：做什么 + 状态。
    private func row(_ p: Proposal) -> some View {
        let status = center.deciding.contains(p.id) ? "提交中…" : ProposalPresentation.compactStatus(p, at: .now)
        return HStack(spacing: 6) {
            if p.escalation != nil { Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red).font(.caption2) }
            Text(p.cardHeadline).font(.caption).lineLimit(1)
            Spacer(minLength: 6)
            Text(status).font(.caption2).foregroundStyle(p.effectiveState(at: .now) == .failed ? .orange : .secondary)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .contentShape(Rectangle())
        .accessibilityIdentifier("bc.chat.resolvedRow")
    }

    @ViewBuilder private func batchUndo(_ g: ProposalGroup) -> some View {
        let undoable = g.proposals.filter { center.canUndo($0) }
        if g.isBatch, undoable.count >= 2 {
            Button(undoingBatch == g.id ? "撤销中…" : "撤销这一批（\(undoable.count) 项）") {
                FeatureUsage.used(.proposalUndo)
                undoingBatch = g.id
                Task { await center.undoBatch(undoable.map(\.id)); undoingBatch = nil }
            }
            .font(.caption).buttonStyle(.bordered).controlSize(.small)
            .disabled(undoingBatch != nil)
            .accessibilityIdentifier("bc.chat.batchUndo")
        }
    }

    /// 「批准 3 · 拒绝 1」
    private var summary: String {
        var counts: [(String, Int)] = []
        for p in proposals {
            let s = ProposalPresentation.compactStatus(p, at: .now)
            if let i = counts.firstIndex(where: { $0.0 == s }) { counts[i].1 += 1 } else { counts.append((s, 1)) }
        }
        return counts.map { counts.count == 1 && proposals.count == 1 ? $0.0 : "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}
