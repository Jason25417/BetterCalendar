//
//  AgentHub.swift
//  BetterCalendar
//
//  W20「智能体适配器」：App 里所有发给智能体的事件都经这里，只送给**当前接通的那一个**实现（产品原则 9）：
//    · Claude Code：经 Mac 上的桥接目录（AgentBridge 写 events/*.json，调度器叫醒专用会话）。iOS 上没有这条通道。
//    · 内置智能体：进程内送达 BuiltinAgentRuntime。
//  没选中的实现没有任何通道：桥接停止同步与轮询、不写任何文件；内置智能体不收事件、不跑。不需要「拒收」。
//  选中的实现跑不了 → 它自己直说（对话 / 状态区），这里**绝不**自动换到另一个（原则 10）。
//
//  内置智能体额外负责桥接原来替 Claude Code 做的「发现事件」：本机说的话、本机发起的提案有了结论、晚间复盘时刻。
//

import Foundation
import Observation

/// Claude Code 这条通道（生产 = AgentBridge；测试 = 假实现）。
@MainActor protocol ClaudeCodeAgentChannel: AnyObject {
    func emit(kind: String, summary: String, payload: [String: Any])
    func activate()
    /// 切到别的实现（active = 现在接通的那个）：关掉这条通道。
    func deactivate(active: AgentKind)
}

extension AgentBridge: ClaudeCodeAgentChannel {
    /// W24：开 / 关通道时各写一次「当前智能体」状态标记（只给心跳看，不是通道），心跳才不会把「切到内置」误报成「App 没在运行」。
    func activate() { markActiveAgent(.claudeCode); start(); Task { await sync() } }
    func deactivate(active: AgentKind) { stop(); markActiveAgent(active) }
}

@MainActor @Observable final class AgentHub {
    let selection: AgentSelection
    let builtin: BuiltinAgentRuntime
    let memory: AgentSharedMemoryStore
    @ObservationIgnored private weak var claudeCode: (any ClaudeCodeAgentChannel)?
    private let defaults: UserDefaults
    private let now: () -> Date
    /// 本机设备类别（晚间复盘：Mac 先写，iPhone、iPad 依次错开等一等，见 dueEveningReview）。
    let deviceKind: ActivityDeviceKind
    /// 0.74.1：只有 Mac 代接别的设备没接上的话（W28 起按设备种类判断）。
    var isPhone: Bool { deviceKind != .mac }
    /// 测试可注入；生产读「关键时刻唤醒智能体」开关（与 Claude Code 同一个开关）。
    var eventsEnabled: () -> Bool = { AgentEventSettings.enabled }
    /// 晚间复盘的事实素材（做成了什么）。
    var eveningFacts: () -> [String: Any] = { [:] }

    var active: AgentKind { selection.kind }

    init(selection: AgentSelection, builtin: BuiltinAgentRuntime, memory: AgentSharedMemoryStore, claudeCode: (any ClaudeCodeAgentChannel)?,
         deviceKind: ActivityDeviceKind, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.selection = selection; self.builtin = builtin; self.memory = memory; self.claudeCode = claudeCode
        self.deviceKind = deviceKind; self.defaults = defaults; self.now = now
        builtin.isActive = { [weak selection] in selection?.kind == .builtin }
        selection.onChange = { [weak self] kind in self?.apply(kind) }
    }

    /// 启动时 / 切换后：只打开选中实现的通道，另一个关掉。
    func apply(_ kind: AgentKind) {
        switch kind {
        case .claudeCode:
            builtin.deactivate()
            claudeCode?.activate()
        case .builtin:
            claudeCode?.deactivate(active: .builtin)
            pump()
        }
    }

    // MARK: 关键时刻事件（App 发起：做完一件事 / 日历删块 / 哨兵）

    /// 送给当前智能体。受「关键时刻唤醒智能体」开关管（与 Claude Code 一致）；哨兵另有自己的开关，用 force。
    func emit(kind: String, summary: String, payload: [String: Any] = [:], force: Bool = false) {
        switch active {
        case .claudeCode:
            claudeCode?.emit(kind: kind, summary: summary, payload: payload)   // 桥接自己查开关 / 连接
        case .builtin:
            guard force || eventsEnabled() else { return }
            builtin.enqueue(AgentEvent(kind: kind, summary: summary, payload: payload, at: now()))
        }
    }

    // MARK: 内置智能体自己发现的事件

    // MARK: 谁来回你这句话（W35，Jason 2026-10-22）
    // 0.74.1（Jason 2026-10-24「我们没必要等 Mac」）：哪台说的哪台马上回——内置智能体只调云端模型，不需要 Mac。
    // Mac 只兜底：别的设备说的话过了 handoffGrace 还没人接（比如说完 App 就被系统收回了），Mac 代接并写明。
    // 先到先得：接手前在 iCloud 上条件写「已转交」回执（AgentChatCenter.claimForAgent），两台设备不会都回。

    /// 说话的设备没接上、Mac 代接前等的时间（说话的那台正常几秒内就认领了）。
    static let handoffGrace: TimeInterval = 20
    /// 生产：Mac 看到别的设备刚说的话，过这么久再查一次（组装点注入）；测试不注入，手动 `await pumpMessages()`。
    var scheduleHandoffCheck: (TimeInterval) -> Void = { _ in }

    /// 你在本机说了一句（已存进 iCloud）：本机马上认领、自己回。
    func userMessageStored(_ m: AgentChatMessage) {
        guard active == .builtin, m.author == .user, m.deviceId == builtin.tools.chat.deviceId else { return }
        Task { [weak self] in await self?.take(m, fallback: false) }
    }

    /// 等着接手的你的消息：本机说的马上接（App 重开后补上）；别的设备说的，只由 Mac 在等满 handoffGrace 还没人接时代接。
    func pumpMessages() async {
        guard active == .builtin else { return }
        let chat = builtin.tools.chat
        var nextCheck: TimeInterval?
        for m in chat.pendingForwards() {
            if m.deviceId == chat.deviceId {
                await take(m, fallback: false)
            } else if !isPhone {
                let wait = Self.handoffGrace - now().timeIntervalSince(m.createdAt)
                if wait > 0 { nextCheck = min(nextCheck ?? wait, wait); continue }
                await take(m, fallback: true)
            }
        }
        if let nextCheck { scheduleHandoffCheck(nextCheck) }
    }

    private var enqueuedMessages: Set<UUID> = []
    private var claiming: Set<UUID> = []

    private func take(_ m: AgentChatMessage, fallback: Bool) async {
        guard !enqueuedMessages.contains(m.id), claiming.insert(m.id).inserted else { return }
        defer { claiming.remove(m.id) }
        let chat = builtin.tools.chat
        let note: String? = fallback ? "\(m.deviceLabel) 没接上（等了 \(Int(Self.handoffGrace)) 秒），由 \(chat.deviceLabel) 回复" : nil
        guard await chat.claimForAgent(m.id, note: note) == true else { return }
        if fallback { DevLog.shared.warn("内置智能体", "\(m.deviceLabel) 没在 \(Int(Self.handoffGrace)) 秒内接手你在那台说的话，改由本机代回") }
        enqueueUserMessage(m, handledNote: note)
    }

    private func enqueueUserMessage(_ m: AgentChatMessage, handledNote: String? = nil) {
        guard enqueuedMessages.insert(m.id).inserted else { return }
        let chat = builtin.tools.chat
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = ["messageId": m.id.uuidString, "text": m.text, "device": m.deviceLabel, "saidAt": iso.string(from: m.createdAt)]
        if let handledNote { payload["handledBy"] = handledNote }
        if let files = m.attachments, !files.isEmpty { payload["attachments"] = ChatAttachmentStore.agentPayload(files) }   // W36
        if let rid = m.replyTo, let prior = chat.messages.first(where: { $0.id == rid }) {
            payload["inReplyTo"] = ["id": rid.uuidString, "kind": prior.kind.rawValue, "text": String(prior.text.prefix(200))]
        }
        // 0.75：主动提醒现在也在对话页里——你看到提醒后接着说的话，带上那条提醒（比上一条对话还新、6 小时内）
        let lastAgentChat = chat.messages.last { $0.author == .agent && $0.createdAt < m.createdAt }?.createdAt ?? .distantPast
        if let notice = builtin.tools.messages?.messages
            .filter({ $0.createdAt < m.createdAt && $0.createdAt > lastAgentChat && m.createdAt.timeIntervalSince($0.createdAt) < 6 * 3600 })
            .max(by: { $0.createdAt < $1.createdAt }) {
            payload["afterNotice"] = ["id": notice.id.uuidString, "title": notice.title, "body": String(notice.body.prefix(200)), "sentAt": iso.string(from: notice.createdAt)]
        }
        var summary = "Jason 在对话里说：\(m.text.prefix(80))" + ((m.attachments?.isEmpty ?? true) ? "" : "（附 \(m.attachments!.count) 个图片 / 文件）")
        if let pid = m.inReplyToProposal {
            let proposals = builtin.tools.proposals.proposals
            payload["inReplyToProposal"] = AgentChatBridgeStep.proposalReplyContext(pid, proposals: proposals, now: now())
            summary = "Jason 对提案「\(proposals.first { $0.id == pid }?.title ?? "")」回了一句：\(m.text.prefix(80))"
        }
        // 你主动找它：不受「关键时刻唤醒」开关限制（同桥接）。
        builtin.enqueue(AgentEvent(kind: "user_message", summary: summary, payload: payload, at: now()))
    }

    /// 回前台 / 定时 / 刷新后：补上本机还没接手的你的消息、本机提案的结论、晚间复盘。只在内置智能体接通时做。
    func pump() {
        guard active == .builtin else { return }
        Task { [weak self] in await self?.pumpMessages() }
        proposalsRefreshed()
        if let day = dueEveningReview() {
            var payload = eveningFacts()
            let minute = EveningReviewSettings.minute(defaults)
            payload["logicalDay"] = day
            payload["configuredTime"] = String(format: "%02d:%02d", minute / 60, minute % 60)
            defaults.set(day, forKey: EveningReviewSettings.lastDayKey)
            builtin.enqueue(AgentEvent(kind: "evening_review", summary: "晚间复盘时间到：在对话里写「今天做成了什么」", payload: payload, at: now()))
        }
    }

    static let resolvedKey = "agent.builtin.resolvedEmitted"

    /// 本机发起的、内置智能体提的提案有了结论（2 小时内）→ proposal_resolved（每份一次）。你回了一句的不发（那句话本身会唤醒它）。
    func proposalsRefreshed() {
        guard active == .builtin, eventsEnabled() else { return }
        let center = builtin.tools.proposals
        var done = Set(defaults.stringArray(forKey: Self.resolvedKey) ?? [])
        let t = now()
        var changed = false
        for p in center.proposals where p.origin == .agent && AgentKind.of(p.agentKey) == .builtin
            && p.originDeviceId == center.deviceId && !done.contains(p.id.uuidString) {
            let state = p.effectiveState(at: t)
            if state == .replied { done.insert(p.id.uuidString); changed = true; continue }
            guard state.isClosed else { continue }
            done.insert(p.id.uuidString); changed = true
            guard t.timeIntervalSince(p.appliedAt ?? p.decidedAt ?? p.expiresAt) < 7200 else { continue }
            builtin.enqueue(AgentEvent(kind: "proposal_resolved", summary: "提案「\(p.title)」：\(state.label)",
                                       payload: ["proposalId": p.id.uuidString, "state": state.rawValue], at: t))
        }
        if changed { defaults.set(Array(done.suffix(300)), forKey: Self.resolvedKey) }
    }

    /// 晚间复盘该不该发（一天一次）。几台设备都开着内置智能体时按类别错开：Mac 到点就发；iPhone 晚 3 分钟；iPad 晚 6 分钟——
    /// 且对话里还没有今天的复盘才发（W28：以前只有 Mac + iPhone；iPad 若也晚 3 分钟，没开 Mac 时 iPhone 和 iPad 会同时各发一条）。
    /// iCloud 同步有延迟，极少数情况下仍可能两条——可见、不丢。同类别两台（如两台 iPhone）仍是同一时刻，见报告的待定项。
    static func eveningGrace(_ kind: ActivityDeviceKind) -> TimeInterval {
        switch kind { case .mac: 0; case .iphone: 180; case .ipad: 360 }
    }

    func dueEveningReview() -> String? {
        let t = now().addingTimeInterval(-Self.eveningGrace(deviceKind))
        guard let day = EveningReviewSettings.dueDayKey(enabled: EveningReviewSettings.enabled(defaults), minute: EveningReviewSettings.minute(defaults),
                                                        lastDayKey: defaults.string(forKey: EveningReviewSettings.lastDayKey), now: t) else { return nil }
        let chat = builtin.tools.chat
        let already = chat.messages.contains { $0.kind == .eveningReview && DayContext.dayKey($0.createdAt) == day }
        if already { defaults.set(day, forKey: EveningReviewSettings.lastDayKey); return nil }
        return day
    }

    // MARK: 定时（只在内置智能体接通、App 活着时；没接通 = 不轮询）

    private var ticker: Task<Void, Never>?

    func startTicking(every seconds: Double = 60) {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                if self.active == .builtin { await self.builtin.tools.chat.refresh(); self.pump() }
            }
        }
    }
}

// MARK: - 哨兵的通道（W42 起 Mac 与 iPhone 都有哨兵）

/// 哨兵只认「一个桥接目录」。Claude Code 接通时 = 真桥接目录；内置智能体接通时 = App 沙盒里的一个私有目录，
/// 哨兵写进去的 sentinel_wake 事件被立刻取走、在进程内送给内置智能体（摘要原文一起带上）。都没接通 = 不连接（哨兵跳过）。
@MainActor final class AgentSentinelChannel: SentinelBridgeAccess {
    private let hub: AgentHub
    private weak var bridge: AgentBridge?
    let localRoot: URL

    init(hub: AgentHub, bridge: AgentBridge?, localRoot: URL) {
        self.hub = hub; self.bridge = bridge; self.localRoot = localRoot
    }

    var isConnected: Bool {
        switch hub.active {
        case .claudeCode: bridge?.connected ?? false
        case .builtin: true
        }
    }

    func withBridge(refreshContext: Bool, _ body: (AgentBridgeIO) throws -> Void) async throws {
        switch hub.active {
        case .claudeCode:
            guard let bridge else { throw AgentBridgeError.invalid("桥接目录未连接") }
            try await bridge.performInFolder(refreshContext: refreshContext, body)
        case .builtin:
            let io = AgentBridgeIO(root: localRoot)
            try io.prepare()
            try FileManager.default.createDirectory(at: localRoot.appendingPathComponent("runtime"), withIntermediateDirectories: true)
            // 「智能体忙不忙」由哨兵读 runtime/status.json：内置智能体正在跑 = running。
            let state = hub.builtin.isRunning ? "running" : "idle"
            try io.writeAtomic(SafeJSON.data(withJSONObject: ["schemaVersion": 1, "state": state]), to: "runtime/status.json")
            try body(io)
            try deliverWakes(io)
        }
    }

    /// 取走哨兵刚写的叫醒事件 → 进程内送达（摘要原文放进 payload.digestText）。
    func deliverWakes(_ io: AgentBridgeIO) throws {
        let fm = FileManager.default
        let dir = localRoot.appendingPathComponent("events")
        for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            defer { try? fm.removeItem(at: file) }
            guard let o = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let kind = o["kind"] as? String else { continue }
            var payload = (o["payload"] as? [String: Any]) ?? [:]
            if let ref = payload["digestRef"] as? String,
               let d = try? JSONSerialization.jsonObject(with: Data(contentsOf: localRoot.appendingPathComponent(ref))) as? [String: Any] {
                payload["digestText"] = d["text"]
                payload["digestNote"] = "摘要原文含 App / 网站名：只供你理解情况，永远不要写进回复、通知、提案理由、复盘或共享记忆"
            }
            payload["digestRef"] = nil
            hub.emit(kind: kind, summary: (o["summary"] as? String) ?? kind, payload: payload, force: true)
        }
    }
}
