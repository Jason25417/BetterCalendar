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
//  W11：方案带可调参数时，卡片上出滑块 / 时间选择器（ProposalTuner）：你调的值套回动作、经 App 同一套校验，
//  「改动前 → 改动后」实时重算；不合法当场写明原因、不能批准（不悄悄夹到范围里）。带参数的提案不出「以后同类…」
//  （预授权规则本来就不放行带参数的提案；要设规则，在同类不带参数的提案上设）。
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

    @ViewBuilder private var decisionRow: some View {
        let primary = proposal.options[0]
        if !primary.parameters.isEmpty {
            // W11：先调数值（实时预览），批准按钮在调节区里（不合法时不能点）。
            ProposalTuner(center: center, proposal: proposal, option: primary, approveTitle: "同意")
        }
        HStack(spacing: 8) {
            if primary.parameters.isEmpty {
                Button("同意") { Task { await center.decide(proposal.id, .approve) } }.buttonStyle(.borderedProminent)
            }
            Button("拒绝", role: .destructive) { Task { await center.decide(proposal.id, .decline) } }.buttonStyle(.bordered)
            Button("回一句") { replying.toggle() }.buttonStyle(.bordered).accessibilityIdentifier("bc.proposal.reply")
            rememberMenu
        }
        .controlSize(.small)
    }

    @ViewBuilder private var rememberMenu: some View {
        if proposal.escalation == nil, !proposal.hasParameters, center.rules != nil {
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
                    if o.parameters.isEmpty {
                        Button("选这个") { Task { await center.decide(proposal.id, .approve, choice: o.index) } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .accessibilityIdentifier("bc.proposal.pick.\(o.index)")
                    } else {
                        ProposalTuner(center: center, proposal: proposal, option: o, approveTitle: "选这个")   // W11：参数作用于这个方案
                    }
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

/// W11：一个方案上的可调参数——滑块 / 时间选择器 + 依据真实数据实时重算的「改动前 → 改动后」+ 批准按钮。
/// 智能体给的范围只是滑块/选择器的边界提示；合法性由 ProposalCenter.checkTuning（同一套 prepare）判定，批准时再查一次。
struct ProposalTuner: View {
    @Bindable var center: ProposalCenter
    let proposal: Proposal
    let option: ProposalOption
    let approveTitle: String
    @State private var values: [String: ProposalParameterValue] = [:]
    @State private var check: Check = .checking

    enum Check: Equatable {
        case checking
        case ok([ProposalChange])
        case invalid(String)
    }

    private var current: [String: ProposalParameterValue] {
        var all: [String: ProposalParameterValue] = [:]
        for p in option.parameters { all[p.id] = values[p.id] ?? p.defaultValue }
        return all
    }
    private var changed: Bool { option.parameters.contains { ProposalParameterRules.isChanged($0, values[$0.id]) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(option.parameters) { p in row(p) }
            switch check {
            case .checking: EmptyView()
            case let .ok(changes) where changed:
                VStack(alignment: .leading, spacing: 2) {
                    Text("按你调的，会这样改：").font(.caption.bold())
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, c in Text(Proposal.line(c)).font(.caption) }
                }
                .accessibilityIdentifier("bc.proposal.tuned.preview")
            case .ok: EmptyView()
            case let .invalid(reason):
                Label("这个数值不行：\(reason)", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("bc.proposal.tuned.invalid")
            }
            Button(approveTitle) {
                let picked = current
                Task { await center.decide(proposal.id, .approve, choice: proposal.hasAlternatives ? option.index : nil, values: picked) }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled({ if case .invalid = check { true } else { false } }())
            .accessibilityIdentifier("bc.proposal.tuned.approve.\(option.index)")
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .task(id: values) {
            // 拖滑块时稍等一下再算（被下一次改动取消 = 只算最后那个值）。
            if !values.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            do {
                let checked = try await center.checkTuning(proposal, option: option.index, values: current)
                guard !Task.isCancelled else { return }
                check = .ok(checked.changes ?? option.changes)
            } catch {
                guard !Task.isCancelled else { return }
                check = .invalid(error.localizedDescription)
            }
        }
    }

    @ViewBuilder private func row(_ p: ProposalParameter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch p.kind {
            case .number, .duration:
                let lo = p.min?.number ?? 0, hi = p.max?.number ?? 1
                HStack {
                    Text(p.label).font(.subheadline)
                    Slider(value: Binding(get: { (values[p.id] ?? p.defaultValue)?.number ?? lo },
                                          set: { values[p.id] = .number($0) }),
                           in: lo...max(hi, lo + 1e-9), step: p.step ?? 1)
                    Text((values[p.id] ?? p.defaultValue).map { ProposalParameterRules.format($0, p) } ?? "")
                        .font(.subheadline.monospacedDigit())
                }
            case .timeOfDay, .dateTime:
                let binding = Binding(get: { (values[p.id] ?? p.defaultValue)?.date ?? .now },
                                      set: { values[p.id] = .date($0) })
                let parts: DatePickerComponents = p.kind == .timeOfDay ? [.hourAndMinute] : [.date, .hourAndMinute]
                if let lo = p.min?.date, let hi = p.max?.date {
                    DatePicker(p.label, selection: binding, in: lo...hi, displayedComponents: parts)
                } else if let lo = p.min?.date {
                    DatePicker(p.label, selection: binding, in: lo..., displayedComponents: parts)
                } else if let hi = p.max?.date {
                    DatePicker(p.label, selection: binding, in: ...hi, displayedComponents: parts)
                } else {
                    DatePicker(p.label, selection: binding, displayedComponents: parts)
                }
            }
            if let d = p.defaultValue {
                HStack(spacing: 6) {
                    Text("智能体给的：\(ProposalParameterRules.format(d, p))").font(.caption2).foregroundStyle(.secondary)
                    if ProposalParameterRules.isChanged(p, values[p.id]) {
                        Button("用回这个") { values[p.id] = nil }.font(.caption2).buttonStyle(.borderless)
                    }
                }
            }
        }
        .accessibilityIdentifier("bc.proposal.param.\(p.id)")
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
