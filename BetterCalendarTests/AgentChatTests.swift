import Foundation
import Testing
@testable import BetterCalendar

/// SPEC §19 A1 / F1：跟智能体说话（两台设备经 iCloud 中转 = 共用内存中转）、Mac 桥接转交/导入、
/// 对话卡片与提案状态同源（B3）、通知规则、离线可见、晚间复盘事件开关。
@MainActor @Suite struct AgentChatTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    func at(_ h: Int, _ m: Int = 0, day: Int = 17) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }

    @MainActor final class Bell: AgentChatNotifying {
        var shown: [UUID] = [], withdrawn: [UUID] = []
        func show(_ message: AgentChatMessage) async { shown.append(message.id) }
        func withdraw(_ ids: [UUID]) async { withdrawn.append(contentsOf: ids) }
    }

    final class Clock { var now: Date; init(_ d: Date) { now = d } }

    /// 这组测试的基线：主动通知总开关关、频率上限开（W8 起两者的出厂默认相反，这里显式写死，测的是规则本身）。
    nonisolated static var attentionOff: AttentionSettings { var s = AttentionSettings(); s.enabled = false; s.capsOn = true; return s }

    func defaults() -> UserDefaults { UserDefaults(suiteName: "bc-chat-" + UUID().uuidString)! }

    func device(_ name: String, _ transport: InMemoryAgentChatTransport, _ bell: Bell, _ clock: Clock,
                settings: AttentionSettings = Self.attentionOff, defaults d: UserDefaults? = nil) -> AgentChatCenter {
        let c = AgentChatCenter(transport: transport, notifier: bell, ledger: MemoryOperationLedger(), deviceId: name,
                                deviceLabel: name, defaults: d ?? defaults(), now: { clock.now })
        c.attention = { settings }
        return c
    }

    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-chat-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func proposalCenter() -> ProposalCenter {
        ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(), notifier: SilentProposalNotifier(),
                       ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac")
    }

    func events(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("events"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    // MARK: 消息往返

    @Test func messageRoundTripsBetweenPhoneAndMac() async throws {
        let cloud = InMemoryAgentChatTransport(), clock = Clock(at(14))
        let phoneBell = Bell(), macBell = Bell()
        let phone = device("iphone", cloud, phoneBell, clock), mac = device("mac", cloud, macBell, clock)

        let said = try #require(await phone.send("  接下来做什么？ "))
        #expect(said.text == "接下来做什么？" && said.author == .user)
        #expect(phone.status(of: said) == .waitingForMac(overdue: false))

        await mac.refresh()
        #expect(mac.pendingForwards().map(\.id) == [said.id])
        await mac.markForwarded(said.id)
        #expect(mac.pendingForwards().isEmpty)

        clock.now = at(14, 1)
        await phone.refresh()
        #expect(phone.status(of: try #require(phone.messages.first)) == .withAgent(overdue: false))

        let reply = try #require(await mac.receiveAgent(AgentChatReplyDraft(id: UUID(), text: "先做 N1 表格吧，大概 20 分钟。", replyTo: said.id)))
        #expect(reply.author == .agent && reply.delivery == .delivered)   // 回应型：总开关关着也弹
        await phone.refresh()
        #expect(phone.status(of: said) == .replied)
        #expect(phoneBell.shown == [reply.id] && phone.unreadCount == 1)
        await phone.refresh()
        #expect(phoneBell.shown.count == 1)                                  // 不重复弹
        await phone.setViewing(true)
        #expect(phone.unreadCount == 0 && phoneBell.withdrawn.contains(reply.id))
        // 同 id 再导入一次：幂等
        _ = await mac.receiveAgent(AgentChatReplyDraft(id: reply.id, text: "x", replyTo: said.id))
        #expect(mac.messages.filter { $0.author == .agent }.count == 1)
    }

    @Test func viewingDeviceDoesNotPopNotification() async throws {
        let cloud = InMemoryAgentChatTransport(), clock = Clock(at(14)), bell = Bell()
        let phone = device("iphone", cloud, bell, clock), mac = device("mac", cloud, Bell(), clock)
        await phone.setViewing(true)
        let said = try #require(await phone.send("在吗"))
        _ = await mac.receiveAgent(AgentChatReplyDraft(id: UUID(), text: "在。", replyTo: said.id))
        await phone.refresh()
        #expect(bell.shown.isEmpty && phone.unreadCount == 0)
    }

    // MARK: 离线 / 失败可见

    @Test func failedSendStaysInOutboxVisibleAndRetries() async throws {
        let cloud = InMemoryAgentChatTransport(), clock = Clock(at(9)), d = defaults()
        await cloud.setFailNextPosts(1)
        let phone = device("iphone", cloud, Bell(), clock, defaults: d)
        #expect(await phone.send("把写代码挪到下午") == nil)
        let pending = try #require(phone.outbox.first)
        if case .failed = phone.status(of: pending) {} else { Issue.record("应显示失败") }
        #expect(phone.lastError != nil && phone.timeline.count == 1)
        // 重启 App：发件箱还在
        let restarted = device("iphone", cloud, Bell(), clock, defaults: d)
        #expect(restarted.outbox.map(\.id) == [pending.id])
        #expect(await restarted.retry(pending.id) != nil)
        #expect(restarted.outbox.isEmpty && restarted.messages.map(\.id) == [pending.id])
        #expect(restarted.status(of: restarted.messages[0]) == .waitingForMac(overdue: false))
    }

    /// W31 自测：没登录 iCloud 的设备上 CloudKit 写入永远不回——不能一直「发送中…」。
    nonisolated struct HangingTransport: AgentChatTransport {
        func post(_ message: AgentChatMessage) async throws {
            // 模拟不响应取消的卡死写入（真 CloudKit 无账号时的表现）
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { c.resume() }
            }
        }
        func fetchRecent() async throws -> [AgentChatMessage] { [] }
        func save(_ message: AgentChatMessage) async throws {}
    }

    @Test func hangingSendTimesOutVisiblyInsteadOfSendingForever() async throws {
        let clock = Clock(at(9))
        let phone = AgentChatCenter(transport: HangingTransport(), notifier: Bell(), ledger: MemoryOperationLedger(),
                                    deviceId: "iphone", deviceLabel: "iphone", defaults: defaults(), now: { clock.now })
        phone.attention = { Self.attentionOff }
        phone.sendTimeout = 0.2
        #expect(await phone.send("没登录 iCloud 时说一句") == nil)
        let pending = try #require(phone.outbox.first)
        if case .failed = phone.status(of: pending) {} else { Issue.record("超时后应显示没发出去，而不是一直发送中") }
        #expect(phone.lastError != nil)
    }

    @Test func statusEscalatesWhenMacOrAgentIsSilent() async throws {
        let cloud = InMemoryAgentChatTransport(), clock = Clock(at(10))
        let phone = device("iphone", cloud, Bell(), clock), mac = device("mac", cloud, Bell(), clock)
        let a = try #require(await phone.send("a"))
        clock.now = at(10, 3)
        #expect(phone.status(of: a) == .waitingForMac(overdue: true) && phone.status(of: a).isProblem)
        clock.now = at(16, 1)
        #expect(phone.status(of: a) == .expired)
        await mac.refresh()
        #expect(mac.pendingForwards().isEmpty)                    // 过时的不再转交
        let b = try #require(await phone.send("b"))
        await mac.refresh(); await mac.markForwarded(b.id)
        clock.now = at(16, 12)
        await phone.refresh()
        #expect(phone.status(of: phone.messages.first { $0.id == b.id }!) == .withAgent(overdue: true))
    }

    // MARK: 通知规则

    @Test func notifyPolicySeparatesSolicitedFromProactive() {
        var s = AttentionSettings()
        s.enabled = false             // 总开关关（W8 起默认开，这里显式关）
        s.capsOn = true
        let reply = AgentChatReplyDraft(id: UUID(), text: "t", replyTo: UUID())
        let review = AgentChatReplyDraft(id: UUID(), text: "t", kind: .eveningReview)
        let proactive = AgentChatReplyDraft(id: UUID(), text: "t")
        #expect(AgentChatNotifyPolicy.evaluate(reply, settings: s, at: at(23, 30), recentProactive: []) == .allow)   // 安静时段也回
        #expect(AgentChatNotifyPolicy.evaluate(review, settings: s, at: at(21, 30), recentProactive: []) == .allow)
        #expect(AgentChatNotifyPolicy.evaluate(proactive, settings: s, at: at(14), recentProactive: []) != .allow)
        s.enabled = true
        #expect(AgentChatNotifyPolicy.evaluate(proactive, settings: s, at: at(14), recentProactive: []) == .allow)
        #expect(AgentChatNotifyPolicy.evaluate(proactive, settings: s, at: at(14), recentProactive: [at(13, 30), at(13, 50)]) != .allow)
        s.mutedUntil = at(15)
        #expect(AgentChatNotifyPolicy.evaluate(reply, settings: s, at: at(14), recentProactive: []) != .allow)        // 静音始终有效
    }

    @Test func proactiveChatMessageIsKeptButSilentWhenAttentionOff() async throws {
        let cloud = InMemoryAgentChatTransport(), clock = Clock(at(14)), bell = Bell()
        let mac = device("mac", cloud, Bell(), clock), phone = device("iphone", cloud, bell, clock)
        let m = try #require(await mac.receiveAgent(AgentChatReplyDraft(id: UUID(), text: "要不要先看一眼 N1？")))
        #expect(m.delivery == .suppressed && m.suppressReason?.contains("未开启") == true)
        await phone.refresh()
        #expect(bell.shown.isEmpty && phone.messages.contains { $0.id == m.id } && phone.unreadCount == 1)
    }

    @Test func notificationRouteAndToneLint() {
        let id = UUID()
        let info: [AnyHashable: Any] = [LocalAgentChatNotifier.userInfoKey: id.uuidString]
        #expect(LocalAgentChatNotifier.route(userInfo: info, actionIdentifier: LocalAgentChatNotifier.replyAction, typedText: " 好 ")?.text == "好")
        #expect(LocalAgentChatNotifier.route(userInfo: info, actionIdentifier: LocalAgentChatNotifier.replyAction, typedText: "  ")?.text == nil)
        #expect(LocalAgentChatNotifier.route(userInfo: info, actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", typedText: nil)?.id == id)
        #expect(LocalAgentChatNotifier.route(userInfo: [:], actionIdentifier: LocalAgentChatNotifier.replyAction, typedText: "x") == nil)
        #expect(AgentChatToneLint.flags("今天写完了 N1，还读了 30 页书").isEmpty)
        #expect(AgentChatToneLint.flags("有两件事拖延了") == ["拖延"])
    }

    // MARK: 桥接文件契约

    /// reply_jason（智能体工作区 mcp/bc-bridge-server.mjs）2026-10-18 实际写出的文件：两边契约一致。
    static let mcpReplyFile = #"""
{"schemaVersion": 1, "id": "DFD34408-101A-4794-BE77-14E5C8F3CE6B", "createdAt": "2026-10-18T06:08:34.003Z", "text": "先做 N1 吧", "kind": "chat", "replyTo": "5FCC2D9D-62D6-4C96-8A18-1B7A0FA02336", "proposalIds": ["5FCC2D9D-62D6-4C96-8A18-1B7A0FA02336"], "parentEventId": null}
"""#

    @Test func parsesRealMcpReplyFile() throws {
        let d = try AgentBridgeIO.chatReplyDraft(from: Data(Self.mcpReplyFile.utf8))
        #expect(d.id.uuidString == "DFD34408-101A-4794-BE77-14E5C8F3CE6B" && d.text == "先做 N1 吧" && d.kind == .chat)
        #expect(d.replyTo?.uuidString == "5FCC2D9D-62D6-4C96-8A18-1B7A0FA02336" && d.proposalIds.count == 1 && d.parentRef == nil)
    }

    @Test func parsesAndValidatesReplyFiles() throws {
        let pid = UUID(), rid = UUID(), id = UUID()
        let good = #"{"schemaVersion":1,"id":"\#(id)","text":"好的，已提了一个改动。","replyTo":"\#(rid)","proposalIds":["\#(pid)"],"parentEventId":"user_message-1"}"#
        let d = try AgentBridgeIO.chatReplyDraft(from: Data(good.utf8))
        #expect(d.id == id && d.replyTo == rid && d.proposalIds == [pid] && d.kind == .chat && d.parentRef == "user_message-1")
        let review = try AgentBridgeIO.chatReplyDraft(from: Data(#"{"schemaVersion":1,"id":"\#(UUID())","text":"今天写完了 N1。","kind":"eveningReview","replyTo":null}"#.utf8))
        #expect(review.kind == .eveningReview && review.replyTo == nil)
        let bad = [
            #"{"schemaVersion":1,"id":"\#(UUID())","text":"  "}"#,
            #"{"schemaVersion":1,"id":"\#(UUID())","text":"x","kind":"lecture"}"#,
            #"{"schemaVersion":1,"id":"\#(UUID())","text":"x","replyTo":"not-a-uuid"}"#,
            #"{"schemaVersion":1,"id":"\#(UUID())","text":"x","proposalIds":["a"]}"#,
            #"{"schemaVersion":2,"id":"\#(UUID())","text":"x"}"#,
        ]
        for b in bad { #expect(throws: AgentBridgeError.self) { _ = try AgentBridgeIO.chatReplyDraft(from: Data(b.utf8)) } }
    }

    @Test func bridgeForwardsUserMessageOnceImportsReplyAndCardMatchesProposal() async throws {
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        try io.prepare()
        let cloud = InMemoryAgentChatTransport(), clock = Clock(at(15))
        let phone = device("iphone", cloud, Bell(), clock), mac = device("mac", cloud, Bell(), clock)
        let center = proposalCenter()
        let bridge = AgentBridge(center: center, defaults: defaults()) { ["schemaVersion": 1, "synthetic": true] }
        bridge.eventsEnabled = { false }   // 「关键时刻唤醒」关着也要转交你的话
        bridge.chat = mac

        let said = try #require(await phone.send("N1 那个我想弄一下"))
        await bridge.sync(io: io)
        let written = try events(root)
        #expect(written.count == 1 && written[0].lastPathComponent.contains("user_message"))
        let event = try JSONSerialization.jsonObject(with: Data(contentsOf: written[0])) as! [String: Any]
        let payload = event["payload"] as! [String: Any]
        #expect(event["kind"] as? String == "user_message" && payload["messageId"] as? String == said.id.uuidString)
        #expect(payload["text"] as? String == "N1 那个我想弄一下" && payload["device"] as? String == "iphone")
        await bridge.sync(io: io)
        #expect(try events(root).count == 1)                         // 只转交一次
        await phone.refresh()
        #expect(phone.status(of: said) == .withAgent(overdue: false))

        // 智能体：先提案、再回复带卡片（reply_jason 写 chat/<id>.json）
        clock.now = at(15, 1)
        try io.writeAtomic(Data(AgentBridgeTests.realAgentProposal.utf8), to: "proposals/p.json")
        let pid = "5FCC2D9D-62D6-4C96-8A18-1B7A0FA02336", rid = UUID()
        try io.writeAtomic(Data(#"{"schemaVersion":1,"id":"\#(rid)","text":"提了一个改动，你看一下。","replyTo":"\#(said.id)","proposalIds":["\#(pid)"]}"#.utf8),
                           to: "chat/\(rid).json")
        try io.writeAtomic(Data(#"{"schemaVersion":1,"id":"\#(UUID())","text":"x","kind":"lecture"}"#.utf8), to: "chat/bad.json")
        await bridge.sync(io: io)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent("chat/imported/\(rid).json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("chat/rejected/bad.json").path))
        #expect(bridge.lastError?.contains("bad.json") == true)

        await phone.refresh()
        let reply = try #require(phone.messages.first { $0.id == rid })
        #expect(phone.status(of: said) == .replied)
        // B3：卡片 = 同一份提案；在面板/通知里同意后，卡片立刻是同一个结果
        var card = try #require(AgentChatCard.resolve(reply.proposalIds, in: center.proposals).first)
        #expect(card.proposal?.state == .pending)
        await center.decide(card.id, .approve)
        card = try #require(AgentChatCard.resolve(reply.proposalIds, in: center.proposals).first)
        #expect(card.proposal == center.proposals.first { $0.id == card.id } && card.proposal?.state == .applied)
        #expect(AgentChatCard.resolve([UUID()], in: center.proposals).first?.proposal == nil)   // 还没同步到：显示「同步中」

        // read_chat 的历史文件：带卡片上提案的最新状态
        await bridge.sync(io: io)
        let history = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("chat/history.json"))) as! [String: Any]
        let rows = try #require(history["messages"] as? [[String: Any]])
        #expect(rows.count == 2 && rows.first?["author"] as? String == "user")
        let cards = try #require(rows.last?["proposals"] as? [[String: Any]])
        #expect(cards.first?["state"] as? String == "applied")
    }

    // MARK: F1 晚间复盘

    @Test func eveningReviewDueOncePerDayWithinWindow() {
        let m = 21 * 60 + 30
        #expect(EveningReviewSettings.dueDayKey(enabled: false, minute: m, lastDayKey: nil, now: at(22)) == nil)   // 默认关
        #expect(EveningReviewSettings.dueDayKey(enabled: true, minute: m, lastDayKey: nil, now: at(21, 29)) == nil)
        let key = EveningReviewSettings.dueDayKey(enabled: true, minute: m, lastDayKey: nil, now: at(21, 30))
        #expect(key == DayContext.dayKey(at(21, 30)))
        #expect(EveningReviewSettings.dueDayKey(enabled: true, minute: m, lastDayKey: key, now: at(22)) == nil)    // 一天一次
        #expect(EveningReviewSettings.dueDayKey(enabled: true, minute: m, lastDayKey: nil, now: at(0, 31, day: 18)) == nil)   // 超过 3 小时不补
        // 0:30 的复盘属于前一个逻辑日的晚上
        let late = EveningReviewSettings.dueDayKey(enabled: true, minute: 30, lastDayKey: nil, now: at(0, 40, day: 18))
        #expect(late == DayContext.dayKey(at(22)))
        #expect(EveningReviewSettings.dueDayKey(enabled: true, minute: 30, lastDayKey: nil, now: at(22)) == nil)
    }

    @Test func bridgeWritesEveningReviewEventOnlyWhenEnabled() async throws {
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        try io.prepare()
        let cloud = InMemoryAgentChatTransport(), clock = Clock(at(21, 40)), d = defaults()
        let mac = device("mac", cloud, Bell(), clock)
        let facts = AgentChatBridgeStep.eveningFacts(done: [(title: "写 N1", start: at(9), end: at(10, 30))])
        var reports: [String] = []
        func run() async throws {
            try await AgentChatBridgeStep.run(io: io, chat: mac, proposals: [], defaults: d, eveningFacts: { facts },
                                              now: clock.now, report: { what, _ in reports.append(what) })
        }
        d.set(false, forKey: EveningReviewSettings.enabledKey)       // 手动关过（W8：从没设过才默认开）
        try await run()
        #expect(try events(root).isEmpty)                            // 关着：不写事件、不耗额度
        d.set(true, forKey: EveningReviewSettings.enabledKey)
        try await run(); try await run()
        let written = try events(root)
        #expect(written.count == 1 && written[0].lastPathComponent.contains("evening_review"))
        let event = try JSONSerialization.jsonObject(with: Data(contentsOf: written[0])) as! [String: Any]
        let payload = event["payload"] as! [String: Any]
        #expect(payload["configuredTime"] as? String == "21:30" && payload["logicalDay"] as? String == DayContext.dayKey(at(21, 40)))
        let done = payload["doneToday"] as! [[String: Any]]
        #expect(done.first?["title"] as? String == "写 N1" && done.first?["minutes"] as? Int == 90)
        #expect(reports.isEmpty)

        // 智能体写复盘 → 你补一句：补充带着「接的是复盘」转交
        let rid = UUID()
        try io.writeAtomic(Data(#"{"schemaVersion":1,"id":"\#(rid)","text":"今天写完了 N1 的第一版，用了一个半小时。","kind":"eveningReview"}"#.utf8), to: "chat/\(rid).json")
        try await run()
        #expect(mac.messages.first?.kind == .eveningReview && mac.messages.first?.delivery == .delivered)
        clock.now = at(21, 50)
        _ = try #require(await mac.send("还顺手把书房收拾了"))
        try await run()
        let forward = try events(root).first { $0.lastPathComponent.contains("user_message") }
        let fe = try JSONSerialization.jsonObject(with: Data(contentsOf: try #require(forward))) as! [String: Any]
        let inReply = (fe["payload"] as! [String: Any])["inReplyTo"] as! [String: Any]
        #expect(inReply["kind"] as? String == "eveningReview" && inReply["id"] as? String == rid.uuidString)
    }
}
