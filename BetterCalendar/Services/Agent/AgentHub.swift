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
    /// 平台（晚间复盘：iPhone 等 Mac 先写，见 dueEveningReview）。
    let isPhone: Bool
    /// 测试可注入；生产读「关键时刻唤醒智能体」开关（与 Claude Code 同一个开关）。
    var eventsEnabled: () -> Bool = { AgentEventSettings.enabled }
    /// 晚间复盘的事实素材（做成了什么）。
    var eveningFacts: () -> [String: Any] = { [:] }

    var active: AgentKind { selection.kind }

    init(selection: AgentSelection, builtin: BuiltinAgentRuntime, memory: AgentSharedMemoryStore, claudeCode: (any ClaudeCodeAgentChannel)?,
         isPhone: Bool, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.selection = selection; self.builtin = builtin; self.memory = memory; self.claudeCode = claudeCode
        self.isPhone = isPhone; self.defaults = defaults; self.now = now
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
    // iPhone / iPad 上说的话交给 Mac 的内置智能体跑（Mac 不会被系统收回后台时间）；说完等 handoffGrace，
    // Mac 还没接手 = 说话的那台自己跑，并在那句话下面写明「Mac 没在线，由 iPhone 回复」。
    // 先到先得：接手前在 iCloud 上条件写「已转交」回执（AgentChatCenter.claimForAgent），两台设备不会都回。

    /// iPhone 说完等 Mac 接手的时间（Mac 开着时，推送 + 认领通常几秒内完成）。
    static let handoffGrace: TimeInterval = 20
    /// 生产：iPhone 说完一句后，过 handoffGrace 再查一次（组装点注入）；测试不注入，手动 `await pumpMessages()`。
    var scheduleHandoffCheck: (TimeInterval) -> Void = { _ in }

    /// 你在本机说了一句（已存进 iCloud）。Mac：马上认领接手；iPhone：先等 Mac。
    func userMessageStored(_ m: AgentChatMessage) {
        guard active == .builtin, m.author == .user, m.deviceId == builtin.tools.chat.deviceId else { return }
        if isPhone { scheduleHandoffCheck(Self.handoffGrace) } else { Task { [weak self] in await self?.take(m, fallback: false) } }
    }

    /// 等着接手的你的消息：Mac 接所有设备说的（先到先得）；iPhone 只接自己说的、且等满 handoffGrace 还没人接的。
    func pumpMessages() async {
        guard active == .builtin else { return }
        let chat = builtin.tools.chat
        for m in chat.pendingForwards() {
            if isPhone {
                guard m.deviceId == chat.deviceId, now().timeIntervalSince(m.createdAt) >= Self.handoffGrace else { continue }
                await take(m, fallback: true)
            } else {
                await take(m, fallback: false)
            }
        }
    }

    private var enqueuedMessages: Set<UUID> = []
    private var claiming: Set<UUID> = []

    private func take(_ m: AgentChatMessage, fallback: Bool) async {
        guard !enqueuedMessages.contains(m.id), claiming.insert(m.id).inserted else { return }
        defer { claiming.remove(m.id) }
        let chat = builtin.tools.chat
        let note: String? = fallback ? "Mac 没在线（等了 \(Int(Self.handoffGrace)) 秒没接手），由 \(chat.deviceLabel) 回复"
            : m.deviceId != chat.deviceId ? "由 \(chat.deviceLabel) 接手" : nil
        guard await chat.claimForAgent(m.id, note: note) == true else { return }
        if fallback { DevLog.shared.warn("内置智能体", "Mac 没在 \(Int(Self.handoffGrace)) 秒内接手你在 \(m.deviceLabel) 说的话，改由本机回复") }
        enqueueUserMessage(m, handledNote: note)
    }

    private func enqueueUserMessage(_ m: AgentChatMessage, handledNote: String? = nil) {
        guard enqueuedMessages.insert(m.id).inserted else { return }
        let chat = builtin.tools.chat
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = ["messageId": m.id.uuidString, "text": m.text, "device": m.deviceLabel, "saidAt": iso.string(from: m.createdAt)]
        if let handledNote { payload["handledBy"] = handledNote }
        if let rid = m.replyTo, let prior = chat.messages.first(where: { $0.id == rid }) {
            payload["inReplyTo"] = ["id": rid.uuidString, "kind": prior.kind.rawValue, "text": String(prior.text.prefix(200))]
        }
        var summary = "Jason 在对话里说：\(m.text.prefix(80))"
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

    /// 晚间复盘该不该发（一天一次）。两台设备都开着内置智能体时：Mac 到点就发；iPhone 晚 3 分钟、且对话里还没有今天的复盘才发
    /// （iCloud 同步有延迟，极少数情况下仍可能两条——可见、不丢）。
    static let phoneEveningGrace: TimeInterval = 180

    func dueEveningReview() -> String? {
        let t = isPhone ? now().addingTimeInterval(-Self.phoneEveningGrace) : now()
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

// MARK: - 哨兵（Mac）的通道

#if os(macOS)
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
#endif
