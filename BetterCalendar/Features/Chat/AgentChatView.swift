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

    /// W19b（P1 单射）：气泡里这张卡怎么长。
    /// 待确认的提案已置顶在页顶「等你拍板」——气泡里只留一行指路（点了滚到并高亮置顶卡），不再画第二张整卡；
    /// 有了结论（离开置顶区）→ 气泡显示结果卡；还没同步到 → 同步中。
    nonisolated enum Presentation: Equatable { case pointerToPinned, fullCard, syncing }
    func presentation(pinnedIds: Set<UUID>) -> Presentation {
        guard proposal != nil else { return .syncing }
        return pinnedIds.contains(id) ? .pointerToPinned : .fullCard
    }
}

struct AgentChatView: View {
    @Bindable var chat: AgentChatCenter
    @Bindable var proposals: ProposalCenter
    var bridge: AgentBridge? = nil
    /// W20：当前智能体（内置智能体的运行状态 / 跑不了的原因显示在这里；Claude Code 时才提示 Mac 桥接）。
    var hub: AgentHub? = nil
    /// 从通知「查看详情」进来时要高亮的提案（router.proposalFocusId）。
    var focusId: UUID? = nil
    @State private var draft = ""
    @State private var attachments: [ChatAttachment] = []   // W36
    @State private var composerStatus: String?
    @AppStorage(DeveloperSettings.key) private var developerOptions = DeveloperSettings.defaultValue   // W37：交付版信息披露（关 = 只留要你处理的）

    @State private var visible = false
    /// 从气泡「在顶部等你拍板」点过来要闪一下的置顶卡（短暂高亮后清空）。
    @State private var flashPinnedId: UUID?
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appTheme) private var theme

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
        .background(theme.bg.ignoresSafeArea())   // W31 自测：四页里只有这页是纯白——补上同款微暖页底（P1 同一概念同一长相）
        .navigationTitle("智能体")
        .task {
            FeatureUsage.seen(.agentPage)
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
        if let hub, hub.active == .builtin {
            if let p = hub.builtin.problem {
                banner("\(p.message)。你可以：\(p.hint)", systemImage: "exclamationmark.triangle.fill") { hub.builtin.clearProblem() }
            } else if hub.builtin.isRunning {
                Label("内置智能体正在想…", systemImage: "ellipsis.bubble").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
        #if os(macOS)
        if hub?.active == .builtin {
            EmptyView()   // W20：内置智能体在本机进程里接手，不需要 Mac 桥接
        } else if let bridge, !bridge.connected {
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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            // W34：同一次行动的同类合成一张批量卡
                            PendingProposalStack(center: proposals, pending: pending,
                                                 highlighted: { $0 == focusId || $0 == flashPinnedId }, anchor: Self.pinnedAnchor)
                        }
                        .padding(.horizontal, 16).padding(.bottom, 8)
                    }
                    // 小窗口也不把对话挤出屏幕：置顶区最多占一截，多了在里面滚
                    .frame(maxHeight: 340)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: flashPinnedId) { _, id in
                        if let id { withAnimation { proxy.scrollTo(Self.pinnedAnchor(id), anchor: .top) } }
                    }
                }
            }
            .background(Color.secondary.opacity(0.05))
            .accessibilityIdentifier("bc.chat.pinnedPending")
            .task(id: flashPinnedId) {
                guard flashPinnedId != nil else { return }
                try? await Task.sleep(for: .seconds(1.6))
                if !Task.isCancelled { withAnimation { flashPinnedId = nil } }
            }
            Divider()
        }
    }

    private static func pinnedAnchor(_ id: UUID) -> String { "pinned-" + id.uuidString }

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
                ForEach(m.attachments ?? []) { a in ChatAttachmentView(attachment: a) }   // W36
                if !m.text.isEmpty {
                    Text(m.text)
                        .textSelection(.enabled)
                        .padding(10).background(theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                }
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
                let pinnedIds = Set(proposals.pending.map(\.id))   // 与置顶区同一份判定
                let cards = AgentChatCard.resolve(m.proposalIds, in: proposals.proposals)
                // W34：待确认的一批只留一行指路；已有结论的全部收进一个小箭头（压缩条 → 完整卡）
                let waiting = cards.compactMap { $0.presentation(pinnedIds: pinnedIds) == .pointerToPinned ? $0.proposal : nil }
                ForEach(ProposalBatching.groups(waiting)) { g in pinnedPointer(g) }
                ForEach(cards.filter { $0.presentation(pinnedIds: pinnedIds) == .syncing }) { card in proposalCard(card, pinnedIds: pinnedIds) }
                let resolved = cards.compactMap { $0.presentation(pinnedIds: pinnedIds) == .fullCard ? $0.proposal : nil }
                if !resolved.isEmpty { ResolvedProposalsGroup(center: proposals, proposals: resolved, focusId: focusId) }
                HStack(spacing: 6) {
                    Text(m.createdAt.formatted(date: .omitted, time: .shortened))
                    if developerOptions, m.delivery == .suppressed, let why = m.suppressReason { Text("· 没弹通知：\(why)") }
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
            Text("\(m.createdAt.formatted(date: .omitted, time: .shortened)) · \(chat.label(for: status))"
                 + (chat.handlerNote(m).flatMap { developerOptions || $0.contains("没在线") ? " · \($0)" : nil } ?? ""))   // W35：Mac 没在线时写明；平常由谁接手只给开发者看
                .font(.caption2).foregroundStyle(status.isProblem ? .orange : .secondary)
                .multilineTextAlignment(.trailing)
            if case .failed = status {
                Button("重试") { FeatureUsage.used(.agentChatRetry); Task { await chat.retry(m.id) } }.font(.caption)
                Button("删掉", role: .destructive) { chat.discard(m.id) }.font(.caption)
            }
        }
    }

    /// W19b：待确认时整卡只在顶部出现一次（P1）；气泡里一行指路（W34：一批只一行），点了滚过去并闪一下。
    private func pinnedPointer(_ g: ProposalGroup) -> some View {
        Button { flashPinnedId = g.id } label: {
            Label("「\(g.isBatch ? g.title : g.proposals[0].cardHeadline)」在顶部等你拍板", systemImage: "arrow.up.circle")
                .font(.caption).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("bc.chat.pinnedPointer")
    }

    @ViewBuilder private func proposalCard(_ card: AgentChatCard, pinnedIds: Set<UUID>) -> some View {
        switch card.presentation(pinnedIds: pinnedIds) {
        case .pointerToPinned:
            Button { flashPinnedId = card.id } label: {
                Label("「\(card.proposal?.cardHeadline ?? "这份提案")」在顶部等你拍板", systemImage: "arrow.up.circle")
                    .font(.caption).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("bc.chat.pinnedPointer")
        case .fullCard:
            if let p = card.proposal {
                ProposalCard(center: proposals, proposal: p, highlighted: p.id == focusId)   // 有结论：结果卡（与设置里同一张）
            }
        case .syncing:
            Label("提案同步中…（会自动刷新）", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.3)))
        }
    }

    // MARK: 输入

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
        if let s = composerStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
        ChatAttachmentStrip(attachments: $attachments)
        HStack(alignment: .bottom, spacing: 8) {
            TextField("跟智能体说一句", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit(send)
                .accessibilityIdentifier("bc.chat.input")
                // W21：打了字 = 开了头；清空没发 = 没做完（发出去 = 做完，见 send）
                .onChange(of: draft) { old, new in
                    let wasEmpty = old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let isEmpty = new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if wasEmpty, !isEmpty { FeatureUsage.begin(.agentChatSend) }
                    if !wasEmpty, isEmpty { FeatureUsage.abandonIfOpen(.agentChatSend) }
                }
            ChatComposerTools(text: $draft, attachments: $attachments, status: $composerStatus)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("bc.chat.send")
        }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func send() {
        let text = draft, files = attachments
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        FeatureUsage.complete(.agentChatSend, "智能体页")
        draft = ""; attachments = []; composerStatus = nil   // complete 已关掉开头，清空不会记成没做完
        Task { await chat.send(text, attachments: files) }
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
