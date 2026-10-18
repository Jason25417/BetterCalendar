//
//  AgentChatView.swift
//  BetterCalendar
//
//  SPEC §19 A1：跟 BetterCalendar 智能体说话的对话页（iPhone = 「智能体」标签页；Mac = 独立窗口）。
//  智能体在对话里提出的改动以卡片呈现，卡片状态与按钮都直接走 ProposalCenter（B3：与通知、多端审批面板同一份）。
//  F1 晚间复盘的开关与时刻在右上角「对话设置」里（默认关）。
//

import SwiftUI

/// 对话里的一张提案卡片：只认 id，内容与状态读 ProposalCenter 的同一份提案。
nonisolated struct AgentChatCard: Identifiable, Equatable {
    let id: UUID
    let proposal: Proposal?

    static func resolve(_ ids: [UUID], in proposals: [Proposal]) -> [AgentChatCard] {
        ids.map { id in AgentChatCard(id: id, proposal: proposals.first { $0.id == id }) }
    }
}

struct AgentChatView: View {
    @Bindable var chat: AgentChatCenter
    @Bindable var proposals: ProposalCenter
    var bridge: AgentBridge? = nil
    @State private var draft = ""
    @State private var showSettings = false
    @State private var visible = false
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            banners
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.timeline.isEmpty { emptyHint }
                        ForEach(chat.timeline) { m in bubble(m).id(m.id) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .onChange(of: chat.timeline.last?.id) { _, last in
                    if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
                .onAppear { if let last = chat.timeline.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
            Divider()
            inputBar
        }
        .navigationTitle("BetterCalendar 智能体")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Label("对话设置", systemImage: "gearshape") }
                    .accessibilityIdentifier("bc.chat.settings")
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { AgentChatSettingsView() }
            #if os(macOS)
                .frame(minWidth: 380, minHeight: 300)
            #endif
        }
        .task {
            visible = true
            await chat.setViewing(scenePhase == .active)
            await chat.refresh()
            await proposals.refresh()
        }
        .task {
            // 对话页开着时每 10 秒兜底刷新一次（推送丢失也能看到回复）；离开页面随视图取消。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await chat.refresh()
            }
        }
        .onDisappear { visible = false; Task { await chat.setViewing(false) } }
        .onChange(of: scenePhase) { _, phase in
            let on = visible && phase == .active
            Task { await chat.setViewing(on) }
        }
    }

    // MARK: 横幅（失败 / 离线可见）

    @ViewBuilder private var banners: some View {
        if let error = chat.lastError {
            banner(error, systemImage: "exclamationmark.triangle.fill") { chat.clearError() }
        }
        #if os(macOS)
        if let bridge, !bridge.connected {
            HStack {
                Label("这台 Mac 还没连接智能体 bridge 文件夹，消息不会转交给智能体", systemImage: "link.badge.plus").font(.callout)
                Spacer()
                Button("选择 bridge 文件夹") { bridge.chooseFolder() }
            }
            .padding(10).background(Color.orange.opacity(0.12))
        } else if let error = bridge?.lastError {
            banner(error, systemImage: "exclamationmark.triangle") { }
        }
        #endif
    }

    private func banner(_ text: String, systemImage: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Label(text, systemImage: systemImage).font(.callout).foregroundStyle(.orange)
            Spacer()
            Button("知道了", action: dismiss).font(.callout)
        }
        .padding(10).background(Color.orange.opacity(0.12))
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("随口说一句就行").font(.headline)
            Text("比如「接下来做什么」「把这个挪到明天」「我有点累」。智能体跑在你的 Mac 上：Mac 开着、BetterCalendar 连着 bridge 文件夹时才会回复。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }

    // MARK: 气泡

    @ViewBuilder private func bubble(_ m: AgentChatMessage) -> some View {
        if m.author == .user {
            VStack(alignment: .trailing, spacing: 4) {
                if let pid = m.inReplyToProposal {   // W10：这句话是在回某个提案
                    Label("回提案「\(proposals.proposals.first { $0.id == pid }?.title ?? "…")」", systemImage: "arrowshape.turn.up.left")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(m.text)
                    .textSelection(.enabled)
                    .padding(10).background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                userStatus(m)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if m.kind == .eveningReview {
                    Label("晚间复盘", systemImage: "moon.stars").font(.caption).foregroundStyle(.secondary)
                }
                Text(m.text)
                    .textSelection(.enabled)
                    .padding(10).background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                ForEach(AgentChatCard.resolve(m.proposalIds, in: proposals.proposals)) { card in proposalCard(card) }
                HStack(spacing: 6) {
                    Text(m.createdAt.formatted(date: .omitted, time: .shortened))
                    if m.delivery == .suppressed, let why = m.suppressReason { Text("· 没弹通知：\(why)") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)
        }
    }

    @ViewBuilder private func userStatus(_ m: AgentChatMessage) -> some View {
        let status = chat.status(of: m)
        HStack(spacing: 8) {
            Text("\(m.createdAt.formatted(date: .omitted, time: .shortened)) · \(status.label)")
                .font(.caption2).foregroundStyle(status.isProblem ? .orange : .secondary)
                .multilineTextAlignment(.trailing)
            if case .failed = status {
                Button("重试") { Task { await chat.retry(m.id) } }.font(.caption)
                Button("删掉", role: .destructive) { chat.discard(m.id) }.font(.caption)
            }
        }
    }

    @ViewBuilder private func proposalCard(_ card: AgentChatCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = card.proposal {
                let state = p.effectiveState(at: .now)
                if let e = p.escalation, state == .pending { ProposalEscalationBanner(reason: e) }
                Text(p.title).font(.subheadline.bold())
                if state == .pending {
                    if p.hasAlternatives { Text("理由：\(p.reason)").font(.caption) }
                    else { Text(p.notificationBody.components(separatedBy: "\n").filter { !$0.hasPrefix(Proposal.escalationHeadline) && !$0.hasPrefix(Proposal.adjustablePrefix) }.joined(separator: "\n")).font(.caption) }
                    ProposalCardControls(center: proposals, proposal: p)   // W10：与面板、通知同一套回应
                } else {
                    Text(p.notificationBody).font(.caption)
                    Text([state.label, p.resultNote].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(state == .failed ? .orange : .secondary)
                    ProposalOutcomeNotes(proposal: p)
                }
            } else {
                Label("提案同步中…（如果一直不出现，到「多端审批」里刷新）", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.3)))
    }

    // MARK: 输入

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("跟智能体说一句", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit(send)
                .accessibilityIdentifier("bc.chat.input")
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("bc.chat.send")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await chat.send(text) }
    }
}

/// 对话设置：F1 晚间复盘（默认关）。设置随 iCloud 同步，由接着 bridge 的 Mac 到点触发。
struct AgentChatSettingsView: View {
    @AppStorage(EveningReviewSettings.enabledKey) private var reviewOn = EveningReviewSettings.defaultEnabled   // W8：从没设过 = 开
    @AppStorage(EveningReviewSettings.minuteKey) private var reviewMinute = EveningReviewSettings.defaultMinute
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle("晚上在对话里复盘", isOn: $reviewOn)
                DatePicker("时间", selection: Binding(get: { timeOfDay }, set: { reviewMinute = minutes(of: $0) }),
                           displayedComponents: .hourAndMinute)
                    .disabled(!reviewOn)
            } header: { Text("晚间复盘（实验）") } footer: {
                Text("到点后智能体在这里写「今天做成了什么」，只说做成的事；你可以回一句补充。需要 Mac 开着并连接智能体 bridge 文件夹；每次复盘会消耗一次 Claude 订阅额度。错过时间 3 小时内会补上，之后当天不再发。")
            }
            Section {
                Text("回复你刚说的话、你设了时间的复盘：会弹通知（静音时不弹）。智能体自己开口的消息：按「多端审批 → 智能体主动找你」里的打扰规则决定。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("通知") }
        }
        .formStyle(.grouped)
        .navigationTitle("对话设置")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }

    private var timeOfDay: Date {
        Calendar.current.date(bySettingHour: reviewMinute / 60, minute: reviewMinute % 60, second: 0, of: .now) ?? .now
    }
    private func minutes(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 21) * 60 + (c.minute ?? 30)
    }
}
