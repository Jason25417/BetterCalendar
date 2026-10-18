//
//  ProposalCardControls.swift
//  BetterCalendar
//
//  W10：审批卡上的回应控件，「多端审批」面板的待确认卡与对话里的提案卡片共用（B3：同一份提案、同一套回应）。
//  - 三种回应：同意 / 拒绝 / 回一句（自然语言，提案停止等待、转给智能体）；
//  - 智能体填了备选方案：每个方案一张小卡 +「选这个」；
//  - 「以后同类…」：同意并生成预授权规则（做完告诉你 / 直接做）或拒绝并生成 deny 规则，可选范围；
//    越级 / 动你的东西 / 删除类不提供放行（PreauthPolicy 也会拦）；
//  - 越级提案顶部醒目横条：「越级：这会动你亲手放的位置或你的东西」+ 理由。
//

import SwiftUI

/// 越级提案的醒目横条（原则 8「审慎越级」）。
struct ProposalEscalationBanner: View {
    let reason: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("越级：这会动你亲手放的位置或你的东西", systemImage: "exclamationmark.shield.fill")
                .font(.subheadline.bold()).foregroundStyle(.orange)
            Text("智能体的理由：" + reason).font(.caption)
            Text("越级提案每次都要你亲自批准，预授权规则不会代你放行。").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("bc.proposal.escalation")
    }
}

struct ProposalCardControls: View {
    @Bindable var center: ProposalCenter
    let proposal: Proposal
    @State private var replying = false
    @State private var replyText = ""
    @State private var scope: PreauthScope = .kindOnBetterCalendar
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if proposal.hasAlternatives { optionCards } else { decisionRow }
            if replying { replyField }
        }
    }

    // MARK: 没有备选：同意 / 拒绝 / 回一句 / 以后同类

    private var decisionRow: some View {
        HStack(spacing: 8) {
            Button("同意") { Task { await center.decide(proposal.id, .approve) } }.buttonStyle(.borderedProminent)
            Button("拒绝", role: .destructive) { Task { await center.decide(proposal.id, .decline) } }.buttonStyle(.bordered)
            Button("回一句") { replying.toggle() }.buttonStyle(.bordered).accessibilityIdentifier("bc.proposal.reply")
            rememberMenu
        }
        .controlSize(.small)
    }

    @ViewBuilder private var rememberMenu: some View {
        if proposal.escalation == nil, center.rules != nil {
            Menu("以后同类…") {
                Picker("范围", selection: $scope) {
                    ForEach(PreauthScope.allCases) { Text($0.label).tag($0) }
                }
                if let why = center.cannotRemember(proposal, effect: .allowAndInform) {
                    Text("不能放行：\(why)")
                } else {
                    Button("同意，以后「\(proposal.action.ruleKindLabel)」都直接做，做完告诉你") {
                        Task { await center.decide(proposal.id, .approve, remember: (scope, .allowAndInform)) }
                    }
                    Button("同意，以后都直接做，不用告诉我") {
                        Task { await center.decide(proposal.id, .approve, remember: (scope, .allow)) }
                    }
                }
                Button("拒绝，以后这类都不要提", role: .destructive) {
                    Task { await center.decide(proposal.id, .decline, remember: (scope, .deny)) }
                }
            }
            .fixedSize()
            .accessibilityIdentifier("bc.proposal.remember")
        }
    }

    // MARK: 智能体填的备选方案

    private var optionCards: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(proposal.options) { o in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(o.index + 1). \(o.label)").font(.subheadline.bold())
                    ForEach(Array(o.changes.enumerated()), id: \.offset) { _, c in Text(Proposal.line(c)).font(.caption) }
                    Button("选这个") { Task { await center.decide(proposal.id, .approve, choice: o.index) } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .accessibilityIdentifier("bc.proposal.pick.\(o.index)")
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
            }
            HStack(spacing: 8) {
                Button("都不要", role: .destructive) { Task { await center.decide(proposal.id, .decline) } }.buttonStyle(.bordered)
                Button("回一句") { replying.toggle() }.buttonStyle(.bordered).accessibilityIdentifier("bc.proposal.reply")
            }
            .controlSize(.small)
        }
    }

    // MARK: 回一句

    private var replyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("比如「改成 9 点吧」", text: $replyText, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                    .onSubmit(sendReply)
                    .accessibilityIdentifier("bc.proposal.replyText")
                Button("发送", action: sendReply)
                    .disabled(sending || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("不批准也不拒绝：这份提案停止等待，你的话转给智能体，由它重新提。").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sendReply() {
        let text = replyText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sending else { return }
        sending = true
        Task {
            if await center.reply(proposal.id, text: text) { replyText = ""; replying = false }
            sending = false
        }
    }
}

/// 已有结论的提案上 W10 相关的一两行说明（你回的话 / 选了哪个方案 / 代你决定的规则）。
struct ProposalOutcomeNotes: View {
    let proposal: Proposal
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let reply = proposal.userReply {
                Text("你回了一句：「\(reply.text)」").font(.caption)
            }
            if proposal.hasAlternatives, proposal.chosenOption != nil {
                Text("你选了：\(proposal.chosen.index + 1). \(proposal.chosen.label)").font(.caption)
            }
            if let stamp = proposal.preauth {
                Text("由预授权规则代你决定（\(stamp.effect.label)）：\(stamp.ruleLabel)").font(.caption2).foregroundStyle(.secondary)
            }
            if let e = proposal.escalation { Text("越级理由：" + e).font(.caption2).foregroundStyle(.orange) }
        }
    }
}

/// 面板里的预授权规则列表：可查看、改效果、删除；随设置同步到你所有设备。
struct PreauthRulesSection: View {
    @Bindable var center: ProposalCenter

    var body: some View {
        if let store = center.rules {
            Section("预授权规则（以后同类…）") {
                Text("默认一律先问你。审批时选「以后同类…」会在这里加一条；越级、动你的东西、删除类永远不会被规则自动放行。规则随设置同步到你所有设备。")
                    .font(.caption).foregroundStyle(.secondary)
                if let e = store.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                if store.rules.isEmpty { Text("还没有规则").foregroundStyle(.secondary) }
                ForEach(store.rules) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(rule.origin.label)的「\(rule.kindLabel)」").font(.subheadline)
                        Text(rule.scope.label + " · 建于 " + rule.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Picker("效果", selection: Binding(get: { rule.effect }, set: { center.setRuleEffect(rule.id, $0) })) {
                                ForEach(PreauthEffect.allCases) { Text($0.label).tag($0) }
                            }
                            .fixedSize()
                            Spacer()
                            Button("删除", role: .destructive) { center.removeRule(rule.id) }.font(.caption)
                        }
                    }
                    .accessibilityIdentifier("bc.preauth.rule")
                }
            }
        }
    }
}
