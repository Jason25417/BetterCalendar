//
//  AgentChatView.swift
//  BetterCalendar
//
//  SPEC §19 A1：跟 BetterCalendar 智能体说话的对话页（两端主窗口的「智能体」页；Mac 另有同一视图的独立窗口）。
//  智能体在对话里提出的改动以卡片呈现，卡片状态与按钮都直接走 ProposalCenter（B3：与通知、设置里的审批记录同一份）。
//  W19：等你拍板的提案卡置顶在本页（ProposalCard，与对话气泡里同一张卡）；审批记录与预授权规则、
//  F1 晚间复盘的开关与时刻都在 设置 → 智能体 里。
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
    /// 从通知「查看详情」进来时要高亮的提案（router.proposalFocusId）。
    var focusId: UUID? = nil
    @State private var draft = ""
    @State private var visible = false
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            banners
            pinnedPending
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
        .navigationTitle("智能体")
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
        // W16：同一判定（IssueTriage）——短暂的 iCloud / 网络失败升级前不弹横幅（日志与 🐞 计数里照样有）
        if let error = chat.lastError, DevLog.shared.shouldShowInline(source: "智能体对话", message: error) {
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
        } else if let error = bridge?.lastError, DevLog.shared.shouldShowInline(source: "智能体桥接", message: error) {
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

    // MARK: 置顶：等你拍板的提案（W19，S-v2「待确认卡置顶在这里」）

    @ViewBuilder private var pinnedPending: some View {
        let pending = proposals.pending
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("等你拍板（\(pending.count)）", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(pending) { p in ProposalCard(center: proposals, proposal: p, highlighted: p.id == focusId) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
                // 小窗口也不把对话挤出屏幕：置顶区最多占一截，多了在里面滚
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
            .background(Color.secondary.opacity(0.05))
            .accessibilityIdentifier("bc.chat.pinnedPending")
            Divider()
        }
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
        if let p = card.proposal {
            ProposalCard(center: proposals, proposal: p, highlighted: p.id == focusId)   // W19：与顶部置顶卡同一张
        } else {
            Label("提案同步中…（会自动刷新）", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.3)))
        }
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
                Text("回复你刚说的话、你设了时间的复盘：会弹通知（静音时不弹）。智能体自己开口的消息：按 设置 →「审批记录与规则」→「智能体主动找你」里的打扰规则决定。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("通知") }
        }
        .formStyle(.grouped)
        .navigationTitle("晚间复盘")
    }

    private var timeOfDay: Date {
        Calendar.current.date(bySettingHour: reviewMinute / 60, minute: reviewMinute % 60, second: 0, of: .now) ?? .now
    }
    private func minutes(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 21) * 60 + (c.minute ?? 30)
    }
}
