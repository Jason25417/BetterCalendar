import Foundation
import Testing
import UserNotifications
@testable import BetterCalendar

/// SPEC §19 W10：审批升级——自然语言回一句（第三种回应）、智能体自填的备选方案、分层预授权规则（A3a 第一版）、
/// 审慎越级标记、判断类数字改由智能体判断（代码只守有效性边界）。
/// 两台「设备」共用内存中转；对话共用内存中转；时钟注入；UserDefaults 用独立 suite。
@MainActor @Suite struct W10ApprovalUXTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_792_000_000) }

    /// 记下审批通知与结果通知（含 W10 的结果通知）。
    @MainActor final class Bell: ProposalNotifying {
        var shown: Set<UUID> = [], results: Set<UUID> = [], resultShows = 0
        func show(_ proposal: Proposal) async { shown.insert(proposal.id) }
        func withdraw(_ id: UUID) async { shown.remove(id) }
        func shownIds() async -> Set<UUID> { shown }
        func showResult(_ proposal: Proposal) async { if results.insert(proposal.id).inserted { resultShows += 1 } }
        func withdrawResult(_ id: UUID) async { results.remove(id) }
        func shownResultIds() async -> Set<UUID> { results }
    }

    @MainActor final class SpyExecutor: ProposalExecuting {
        var escalations: [String?] = []
        var performed: [ProposalAction] = []
        var fail = false
        func prepare(_ action: ProposalAction) async throws -> PreparedProposalAction { PreparedProposalAction(action: action, changes: nil) }
        func prepare(_ action: ProposalAction, escalation: String?) async throws -> PreparedProposalAction {
            escalations.append(escalation)
            return try await prepare(action)
        }
        func perform(_ action: ProposalAction) async throws -> ProposalExecutionOutcome {
            if fail { throw ProposalExecutionError.unavailable("模拟执行失败") }
            performed.append(action)
            return ProposalExecutionOutcome(note: "已应用", undo: ProposalUndoInfo(action: .experimentNoop(note: "undo")))
        }
    }

    struct Pair {
        let mac: ProposalCenter, phone: ProposalCenter
        let macBell: Bell, phoneBell: Bell
        let ledger: MemoryOperationLedger
        let rules: PreauthRuleStore
        let executor: SpyExecutor
        let macChat: AgentChatCenter, phoneChat: AgentChatCenter
        let clock: Clock
    }

    func suite() -> UserDefaults { UserDefaults(suiteName: "bc-w10-" + UUID().uuidString)! }

    func pair(withRules: Bool = true) -> Pair {
        let clock = Clock()
        let transport = InMemoryProposalTransport(), ledger = MemoryOperationLedger()
        let rules = PreauthRuleStore(defaults: suite(), now: { clock.now })   // 两端共用一份 = 已随设置同步
        let executor = SpyExecutor()
        let macBell = Bell(), phoneBell = Bell()
        let gate: any ProposalGate = withRules ? PreauthRuleGate(store: rules) : AskAlwaysGate()
        let mac = ProposalCenter(transport: transport, gate: gate, rules: withRules ? rules : nil, executor: executor, notifier: macBell,
                                 ledger: ledger, deviceId: "mac", deviceLabel: "Mac", informDefaults: suite(), now: { clock.now })
        let phone = ProposalCenter(transport: transport, gate: gate, rules: withRules ? rules : nil, executor: executor, notifier: phoneBell,
                                   ledger: ledger, deviceId: "phone", deviceLabel: "iPhone", informDefaults: suite(), now: { clock.now })
        let chatCloud = InMemoryAgentChatTransport()
        let macChat = AgentChatCenter(transport: chatCloud, notifier: SilentAgentChatNotifier(), ledger: ledger, deviceId: "mac",
                                      deviceLabel: "Mac", defaults: suite(), now: { clock.now })
        let phoneChat = AgentChatCenter(transport: chatCloud, notifier: SilentAgentChatNotifier(), ledger: ledger, deviceId: "phone",
                                        deviceLabel: "iPhone", defaults: suite(), now: { clock.now })
        mac.forwardReply = { p, text in await macChat.send(text, inReplyToProposal: p.id) != nil }
        phone.forwardReply = { p, text in await phoneChat.send(text, inReplyToProposal: p.id) != nil }
        return Pair(mac: mac, phone: phone, macBell: macBell, phoneBell: phoneBell, ledger: ledger, rules: rules,
                    executor: executor, macChat: macChat, phoneChat: phoneChat, clock: clock)
    }

    func draft(_ action: ProposalAction = .experimentNoop(note: "联调"), title: String = "把「整理笔记」挪到 15:00",
               escalation: String? = nil, alternatives: [ProposalAlternative] = [], target: String? = "mac") -> ProposalDraft {
        ProposalDraft(origin: .agent, originLabel: "BetterCalendar 智能体", targetDeviceId: target, title: title,
                      changes: [ProposalChange(field: "开始时间", before: "14:00", after: "15:00")], reason: "午饭晚了",
                      action: action, experiment: true, lifetime: 3600, escalation: escalation, alternatives: alternatives)
    }

    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-w10-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: 1. 第三种回应：回一句话

    @Test func replyStopsWaitingDoesNotExecuteAndReachesTheAgentWithProposalId() async throws {
        let p = pair()
        let proposal = try #require(await p.mac.submit(draft()))
        await p.phone.refresh()
        #expect(p.phoneBell.shown == [proposal.id])
        #expect(await p.phone.reply(proposal.id, text: "  改成 9 点吧 "))
        let replied = try #require(p.phone.proposals.first { $0.id == proposal.id })
        #expect(replied.state == .replied && replied.state.isClosed && replied.userReply?.text == "改成 9 点吧")
        #expect(replied.userReply?.deviceId == "phone" && replied.state.label.contains("你回了一句"))
        #expect(p.phoneBell.shown.isEmpty)                      // 停止等待：通知收起
        await p.mac.refresh()
        #expect(p.macBell.shown.isEmpty && p.executor.performed.isEmpty)   // 不执行
        // 迟到的批准不生效（首个回应生效）
        guard case .alreadyClosed? = await p.mac.decide(proposal.id, .approve) else { Issue.record("回一句之后的批准不应生效"); return }
        #expect(p.executor.performed.isEmpty)
        #expect(p.ledger.values.contains { $0.event == "replied" && $0.proposalId == proposal.id && $0.actor == .user })
        // 这句话进了对话，带着提案 id
        await p.macChat.refresh()
        let said = try #require(p.macChat.pendingForwards().first)
        #expect(said.text == "改成 9 点吧" && said.inReplyToProposal == proposal.id && said.author == .user)
        // 不算拒绝：统计里单独计「回了一句」
        let stats = AgentTranslationStatsCalculator.compute(proposals: p.mac.proposals, messages: [], ledger: p.ledger.values,
                                                            window: .all, now: p.clock.now)
        #expect(stats.replied == 1 && stats.declined == 0 && stats.replyRate.count == 1)
    }

    @Test func macBridgeWritesUserMessageWithInReplyToProposalAndResultShowsReply() async throws {
        let p = pair()
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        try io.prepare()
        let proposal = try #require(await p.mac.submit(draft(title: "挪笔记")))
        #expect(await p.phone.reply(proposal.id, text: "改成 9 点吧"))
        await p.mac.refresh()
        try await AgentChatBridgeStep.run(io: io, chat: p.macChat, proposals: p.mac.proposals, defaults: suite(),
                                          eveningFacts: { [:] }, now: p.clock.now, report: { _, _ in })
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("events"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("user_message") }
        let event = try JSONSerialization.jsonObject(with: Data(contentsOf: try #require(files.first))) as! [String: Any]
        let payload = event["payload"] as! [String: Any]
        let ref = try #require(payload["inReplyToProposal"] as? [String: Any])
        #expect(ref["id"] as? String == proposal.id.uuidString && ref["state"] as? String == "replied" && ref["title"] as? String == "挪笔记")
        #expect((event["summary"] as? String)?.contains("对提案「挪笔记」回了一句") == true)
        // read_proposals 看得到这句回复
        let replied = try #require(p.mac.proposals.first { $0.id == proposal.id })
        try io.writeResult(replied, at: p.clock.now)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results/\(proposal.id.uuidString).json"))) as! [String: Any]
        #expect(result["state"] as? String == "replied" && (result["userReply"] as? [String: Any])?["text"] as? String == "改成 9 点吧")
        // 对话历史里这条消息也标着回的是哪个提案
        let history = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("chat/history.json"))) as! [String: Any]
        let rows = history["messages"] as! [[String: Any]]
        #expect(rows.contains { $0["inReplyToProposal"] as? String == proposal.id.uuidString })
    }

    @Test func lateReplyAfterApprovalStillForwardsAndMissingChatIsVisible() async throws {
        let p = pair()
        let proposal = try #require(await p.mac.submit(draft()))
        await p.mac.decide(proposal.id, .approve)
        #expect(p.mac.proposals.first { $0.id == proposal.id }?.state == .applied)
        #expect(await p.phone.reply(proposal.id, text: "其实想改成 9 点"))      // 照常转交智能体
        #expect(p.phone.proposals.first { $0.id == proposal.id }?.state == .applied)   // 不改已完成的结果
        #expect(p.ledger.values.contains { $0.event == "lost" && $0.detail.contains("照常转给智能体") })
        // 没接对话的设备：失败可见
        let lonely = pair(withRules: false)
        lonely.mac.forwardReply = nil
        let q = try #require(await lonely.mac.submit(draft()))
        #expect(await lonely.mac.reply(q.id, text: "改一下") == false)
        #expect(lonely.mac.lastError?.contains("没有接入对话") == true)
        #expect(await lonely.mac.reply(q.id, text: "   ") == false)   // 空话不算回应
    }

    @Test func notificationParsesReplyPickAndUndo() {
        let id = UUID()
        let info: [AnyHashable: Any] = [LocalProposalNotifier.userInfoKey: id.uuidString]
        #expect(LocalProposalNotifier.response(userInfo: info, actionIdentifier: LocalProposalNotifier.replyAction, typedText: " 改成 9 点 ")?.response == .reply("改成 9 点"))
        #expect(LocalProposalNotifier.response(userInfo: info, actionIdentifier: LocalProposalNotifier.replyAction, typedText: "  ")?.response == .open)
        #expect(LocalProposalNotifier.response(userInfo: info, actionIdentifier: LocalProposalNotifier.pickPrefix + "2", typedText: nil)?.response
                == .decide(.approve, choice: 2))
        #expect(LocalProposalNotifier.response(userInfo: info, actionIdentifier: UNNotificationDefaultActionIdentifier, typedText: nil)?.response == .open)
        #expect(LocalProposalNotifier.response(userInfo: info, actionIdentifier: LocalProposalNotifier.pickPrefix + "x", typedText: nil) == nil)
        // 旧入口只认批准/拒绝/打开（选方案、回一句不会被误当成批准主方案）
        #expect(LocalProposalNotifier.route(userInfo: info, actionIdentifier: LocalProposalNotifier.pickPrefix + "1") == nil)
        #expect(LocalProposalNotifier.route(userInfo: info, actionIdentifier: LocalProposalNotifier.approveAction)?.decision == .approve)
        let result: [AnyHashable: Any] = [LocalProposalNotifier.resultUserInfoKey: id.uuidString]
        #expect(LocalProposalNotifier.response(userInfo: result, actionIdentifier: LocalProposalNotifier.undoAction, typedText: nil)?.response == .undo)
        #expect(LocalProposalNotifier.response(userInfo: result, actionIdentifier: LocalProposalNotifier.approveAction, typedText: nil) == nil)
    }

    // MARK: 2. 智能体自己填的备选方案

    func proposalValue(alternatives: Int, escalation: String? = nil) -> Proposal {
        let at = Date(timeIntervalSince1970: 1_792_000_000)
        var p = Proposal(id: UUID(), createdAt: at, expiresAt: at.addingTimeInterval(3600), origin: .agent, originLabel: "BetterCalendar 智能体",
                         originDeviceId: "mac", parentId: nil, targetDeviceId: nil, title: "挪笔记",
                         changes: [ProposalChange(field: "开始", before: "14:00", after: "15:00")], reason: "午饭晚了",
                         action: .experimentNoop(note: "a"), experiment: true, state: .pending)
        p.primaryLabel = "15 点"
        p.alternatives = (0..<alternatives).map { i in
            ProposalAlternative(label: "\(16 + i) 点", action: .experimentNoop(note: "alt\(i)"),
                                changes: [ProposalChange(field: "开始", before: "14:00", after: "\(16 + i):00")])
        }
        if alternatives == 0 { p.alternatives = nil }
        p.escalation = escalation
        return p
    }

    @Test func notificationListsOptionButtonsOrSendsYouToDetailsWhenTheyDoNotFit() {
        let two = proposalValue(alternatives: 1)
        let cat = LocalProposalNotifier.optionsCategory(for: two)
        #expect(cat.identifier == LocalProposalNotifier.optionsCategoryPrefix + two.id.uuidString)
        #expect(cat.actions.map(\.identifier) == [LocalProposalNotifier.pickPrefix + "0", LocalProposalNotifier.pickPrefix + "1",
                                                   LocalProposalNotifier.replyAction, LocalProposalNotifier.declineAction])
        #expect(cat.actions.first?.title == "1. 15 点" && cat.actions[1].title == "2. 16 点")
        #expect(LocalProposalNotifier.request(for: two).content.categoryIdentifier == cat.identifier)
        #expect(two.notificationBody.contains("【1. 15 点】") && two.notificationBody.contains("【2. 16 点】"))
        let four = proposalValue(alternatives: 3)
        #expect(!LocalProposalNotifier.optionsFit(four))
        #expect(LocalProposalNotifier.optionsCategory(for: four).actions.map(\.identifier)
                == [LocalProposalNotifier.openAction, LocalProposalNotifier.replyAction, LocalProposalNotifier.declineAction])
        #expect(LocalProposalNotifier.request(for: four).content.body.contains("有 4 个方案：打开详情挑一个"))
        #expect(LocalProposalNotifier.request(for: proposalValue(alternatives: 0)).content.categoryIdentifier == LocalProposalNotifier.category)
    }

    @Test func choosingAnAlternativeExecutesOnlyThatOneAndRecordsTheChoice() async throws {
        let p = pair()
        let alts = [ProposalAlternative(label: "16 点", action: .experimentNoop(note: "alt-16"), changes: [ProposalChange(field: "开始", before: "14:00", after: "16:00")]),
                    ProposalAlternative(label: "17 点", action: .experimentNoop(note: "alt-17"), changes: [ProposalChange(field: "开始", before: "14:00", after: "17:00")])]
        let proposal = try #require(await p.mac.submit(draft(alternatives: alts)))
        #expect(proposal.state == .pending && proposal.options.count == 3)   // 带备选的永远等你挑（即使有规则）
        await p.phone.refresh()
        await p.phone.decide(proposal.id, .approve, choice: 2)
        await p.mac.refresh()
        let done = try #require(p.mac.proposals.first { $0.id == proposal.id })
        #expect(done.state == .applied && done.chosenOption == 2 && done.chosen.label == "17 点")
        #expect(p.executor.performed == [.experimentNoop(note: "alt-17")])   // 只执行选中的那个
        #expect(done.notificationBody.contains("选了【3. 17 点】") && done.notificationBody.contains("14:00 → 17:00"))
        #expect(!done.notificationBody.contains("16:00"))
        #expect(p.ledger.values.contains { $0.event == "decided" && $0.detail.contains("选了【3. 17 点】") })
        // 结果文件：kind/changes = 选中的，另附全部方案
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        try io.prepare(); try io.writeResult(done, at: p.clock.now)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results/\(proposal.id.uuidString).json"))) as! [String: Any]
        #expect(result["chosenOption"] as? Int == 2 && (result["options"] as? [[String: Any]])?.count == 3)
        #expect(((result["changes"] as? [[String: Any]])?.first?["after"] as? String) == "17:00")
        // 选一个不存在的方案：不生效
        let other = try #require(await p.mac.submit(draft(alternatives: alts)))
        #expect(await p.mac.decide(other.id, .approve, choice: 5) == nil)
        #expect(p.mac.proposals.first { $0.id == other.id }?.state == .pending && p.mac.lastError?.contains("没有第 6 个方案") == true)
        // 没选（旧入口「批准」）= 主方案
        await p.mac.decide(other.id, .approve)
        #expect(p.mac.proposals.first { $0.id == other.id }?.chosenOption == 0 && p.executor.performed.last == .experimentNoop(note: "联调"))
    }

    @Test func alternativesAreValidatedLikeTheMainOne() async throws {
        let p = pair()
        let same = ProposalAlternative(label: "一样的", action: .experimentNoop(note: "联调"))
        #expect(await p.mac.submit(draft(alternatives: [same])) == nil)
        #expect(p.mac.lastError?.contains("完全一样") == true)
        let many = (0..<4).map { ProposalAlternative(label: "方案\($0)", action: .experimentNoop(note: "n\($0)")) }
        #expect(await p.mac.submit(draft(alternatives: many)) == nil)
        #expect(p.mac.lastError?.contains("最多 3 个") == true)
        #expect(await p.mac.submit(draft(alternatives: [ProposalAlternative(label: "  ", action: .experimentNoop(note: "z"))])) == nil)
        #expect(p.mac.lastError?.contains("要有名字") == true)
        #expect(p.mac.proposals.isEmpty)
    }

    @Test func bridgeParsesAlternativesAndEscalationStrictly() throws {
        func file(_ extra: [String: Any]) throws -> Data {
            var o: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString, "title": "t", "reason": "r",
                                    "action": ["kind": "itemCreate", "title": "买牛奶"]]
            for (k, v) in extra { o[k] = v }
            return try JSONSerialization.data(withJSONObject: o)
        }
        let ok = try AgentBridgeIO.draft(from: file(["primaryLabel": "买牛奶", "escalation": "  你亲手放的块和新会冲突 ",
                                                     "alternatives": [["label": "买豆浆", "action": ["kind": "itemCreate", "title": "买豆浆"]]]]))
        #expect(ok.alternatives.count == 1 && ok.alternatives[0].label == "买豆浆" && ok.primaryLabel == "买牛奶")
        #expect(ok.escalation == "你亲手放的块和新会冲突" && !ok.experiment)
        if case let .itemCreate(_, title, _, _) = ok.alternatives[0].action { #expect(title == "买豆浆") } else { Issue.record("应为 itemCreate") }
        let bad: [[String: Any]] = [
            ["escalation": ""],
            ["escalation": 3],
            ["alternatives": [["label": "x", "action": ["kind": "nope"]]]],
            ["alternatives": [["action": ["kind": "itemCreate", "title": "x"]]]],                                     // 缺名字
            ["alternatives": [["label": "x", "action": ["kind": "itemCreate", "title": "x"], "extra": 1]]],
            ["alternatives": [["label": "x", "action": ["kind": "itemDiscard", "itemId": UUID().uuidString]]]],      // 撤销专用
            ["alternatives": Array(repeating: ["label": "x", "action": ["kind": "itemCreate", "title": "x"]], count: 4)],
            ["alternatives": [["label": "测试", "action": ["kind": "experimentNoop"]]]],                              // 测试改动缺 changes
        ]
        for extra in bad { #expect(throws: (any Error).self) { try AgentBridgeIO.draft(from: file(extra)) } }
    }

    // MARK: 3. 分层预授权规则（A3a）

    func rule(_ kind: String, _ effect: PreauthEffect, scope: PreauthScope = .kind, origin: ProposalOrigin = .agent) -> PreauthRule {
        PreauthRule(id: UUID(), createdAt: .init(timeIntervalSince1970: 0), createdByDeviceId: "phone", origin: origin, ruleKind: kind,
                    kindLabel: kind, scope: scope, effect: effect, sourceProposalId: nil)
    }

    func value(_ action: ProposalAction, escalation: String? = nil, origin: ProposalOrigin = .agent) -> Proposal {
        var p = proposalValue(alternatives: 0, escalation: escalation)
        p.action = action; p.origin = origin
        return p
    }

    @Test func policyMatchesKindAndScopeWithDenyOverAskOverAllowAndDefaultsToAsk() {
        let create = value(.itemCreate(id: UUID(), title: "t", note: nil))
        #expect(PreauthPolicy.evaluate(create, rules: []).route == .ask)                                         // 默认先问你
        let allow = rule("itemCreate", .allow)
        let allowed = PreauthPolicy.evaluate(create, rules: [allow])
        #expect(allowed.route == .apply && allowed.rule == allow && allowed.note.contains("直接做"))
        #expect(PreauthPolicy.evaluate(create, rules: [rule("itemCreate", .allowAndInform), allow]).route == .applyThenInform)  // 更谨慎的优先
        #expect(PreauthPolicy.evaluate(create, rules: [allow, rule("itemCreate", .ask)]).route == .ask)          // ask ＞ allow
        #expect(PreauthPolicy.evaluate(create, rules: [allow, rule("itemCreate", .ask), rule("itemCreate", .deny)]).route == .decline)   // deny 最先
        #expect(PreauthPolicy.evaluate(create, rules: [rule("itemCreate", .allow, scope: .kindOnBetterCalendar)]).route == .apply)
        #expect(PreauthPolicy.evaluate(create, rules: [rule("itemCreate", .allow, origin: .system)]).route == .ask)   // 发起者不同不匹配
        // 「这一类」比 kind 细：暂停计时的规则不放行结束计时
        let pause = value(.timer(command: .pause, blockId: nil, title: nil, expectedRevision: nil))
        let stop = value(.timer(command: .stop, blockId: nil, title: nil, expectedRevision: nil))
        #expect(PreauthPolicy.evaluate(pause, rules: [rule("timer.pause", .allow)]).route == .apply)
        #expect(PreauthPolicy.evaluate(stop, rules: [rule("timer.pause", .allow)]).route == .ask)
        #expect(value(.itemSetDone(id: UUID(), done: false, expectedRevision: nil)).action.ruleKind == "itemSetDone.undone")
    }

    @Test func escalationUserOwnedAndDeletionAreNeverAutoAllowed() {
        // 越级：连 deny 也不自动拒绝，一律先问你
        let escalated = value(.itemCreate(id: UUID(), title: "t", note: nil), escalation: "确有必要")
        for effect in PreauthEffect.allCases {
            #expect(PreauthPolicy.evaluate(escalated, rules: [rule("itemCreate", effect)]).route == .ask)
        }
        #expect(PreauthPolicy.protectionReason(escalated)?.contains("越级") == true)
        // 删除类：放行规则被降成先问，deny 照样生效
        let discard = value(.itemDiscard(id: UUID(), expectedRevision: nil))
        let verdict = PreauthPolicy.evaluate(discard, rules: [rule("itemDiscard", .allow)])
        #expect(verdict.route == .ask && verdict.note.contains("删除类") && verdict.rule != nil)
        #expect(PreauthPolicy.evaluate(discard, rules: [rule("itemDiscard", .deny)]).route == .decline)
        #expect(PreauthPolicy.cannotRemember(discard, effect: .allow) != nil && PreauthPolicy.cannotRemember(discard, effect: .deny) == nil)
        #expect(ProposalAction.reminderCancel(id: UUID(), expectedRevision: nil).isDestructive && ProposalAction.alarmCancel(id: UUID()).isDestructive)
        // 动你的东西：现有种类全部只动 BetterCalendar 自己的东西；「只在 BetterCalendar 的东西上」范围据此匹配
        #expect(ProposalAction.moveBlock(id: UUID(), start: .now, end: nil, expectedRevision: nil).ownership == .betterCalendar)
        #expect(PreauthScope.kindOnBetterCalendar.covers(.itemCreate(id: UUID(), title: "t", note: nil)))
        // 带备选方案：等你挑
        var withAlts = proposalValue(alternatives: 1)
        withAlts.origin = .agent
        #expect(PreauthPolicy.evaluate(withAlts, rules: [rule("experimentNoop", .allow)]).route == .ask)
    }

    @Test func rememberedRuleAutoAppliesNextOneInformsWithUndoAndLedgerCarriesRuleId() async throws {
        let p = pair()
        let first = try #require(await p.mac.submit(draft()))
        #expect(first.state == .pending)
        await p.phone.refresh()
        await p.phone.decide(first.id, .approve, remember: (.kindOnBetterCalendar, .allowAndInform))
        let rule = try #require(p.rules.rules.first)
        #expect(rule.ruleKind == "experimentNoop" && rule.effect == .allowAndInform && rule.sourceProposalId == first.id)
        #expect(p.ledger.values.contains { $0.event == "rule.added" && $0.ruleId == rule.id && $0.actor == .user })
        // 下一份同类：建出来就是已同意，Mac 直接执行，不弹审批通知
        let second = try #require(await p.mac.submit(draft(title: "第二份")))
        #expect(second.state == .applied && second.preauth?.ruleId == rule.id && second.preauth?.effect == .allowAndInform)
        #expect(p.macBell.shown.isEmpty)
        let decided = try #require(p.ledger.values.first { $0.event == "decided" && $0.proposalId == second.id })
        #expect(decided.actor == .system && decided.ruleId == rule.id && decided.detail.contains("做完告诉你"))
        #expect(p.ledger.values.first { $0.event == "applied" && $0.proposalId == second.id }?.ruleId == rule.id)   // 来源 = 规则 id
        // 做完告诉你：各端一条结果通知，可撤销；重复刷新不重弹
        #expect(p.macBell.results == [second.id])
        await p.phone.refresh(); await p.phone.refresh()
        #expect(p.phoneBell.results == [second.id] && p.phoneBell.resultShows == 1)
        let result = LocalProposalNotifier.resultRequest(for: try #require(p.mac.proposals.first { $0.id == second.id }))
        #expect(result.content.categoryIdentifier == LocalProposalNotifier.resultCategory && result.content.body.contains("依据规则"))
        #expect(await p.phone.undo(second.id))
        await p.phone.refresh(); await p.mac.refresh()
        #expect(p.phoneBell.results.isEmpty && p.macBell.results.isEmpty)   // 撤销后收起
        // 越级的同类提案：照样先问你，并留底讲得出为什么
        let escalated = try #require(await p.mac.submit(draft(title: "越级", escalation: "这块是你亲手拖的，但 9 点有硬性会议")))
        #expect(escalated.state == .pending && escalated.preauth == nil && p.macBell.shown.contains(escalated.id))
        #expect(p.ledger.values.contains { $0.event == "gate.ask" && $0.proposalId == escalated.id })
        // 越级提案不能「以后同类都允许」
        #expect(p.mac.remember(escalated, scope: .kind, effect: .allow) == nil && p.mac.lastError?.contains("越级") == true)
        #expect(p.rules.rules.count == 1)
    }

    @Test func allowRunsQuietlyDenyDeclinesAndAutoFailureIsAlwaysVisible() async throws {
        let p = pair()
        let r = p.rules.upsert(origin: .agent, action: .experimentNoop(note: "x"), scope: .kind, effect: .allow, deviceId: "phone", sourceProposalId: nil)
        let quiet = try #require(await p.mac.submit(draft()))
        #expect(quiet.state == .applied && p.macBell.results.isEmpty && p.macBell.shown.isEmpty)   // 直接做：不另发结果通知
        p.mac.setRuleEffect(r.id, .deny)
        #expect(p.ledger.values.contains { $0.event == "rule.changed" && $0.ruleId == r.id })
        let denied = try #require(await p.mac.submit(draft(title: "被拒")))
        #expect(denied.state == .declined && denied.preauth?.effect == .deny && p.executor.performed.count == 1)
        // 放行规则下自动执行失败：不论哪种放行都通知你
        p.mac.setRuleEffect(r.id, .allow)
        p.executor.fail = true
        let broken = try #require(await p.mac.submit(draft(title: "会失败")))
        #expect(broken.state == .failed && p.macBell.results.contains(broken.id))
        #expect(LocalProposalNotifier.resultRequest(for: broken).content.title.contains("没成功"))
        #expect(p.ledger.values.contains { $0.event == "informed" && $0.proposalId == broken.id })
        // 删除规则后回到默认先问你
        p.mac.removeRule(r.id)
        #expect(await p.mac.submit(draft(title: "又问了"))?.state == .pending)
        #expect(p.ledger.values.contains { $0.event == "rule.removed" && $0.ruleId == r.id })
    }

    @Test func rulesPersistAsPlistDataSyncAcrossDevicesAndCorruptDataFallsBackToAsk() throws {
        #expect(SettingsSync.syncedKeys.contains(PreauthRuleStore.key))   // 随设置多端同步
        let d = suite()
        let phone = PreauthRuleStore(defaults: d)
        let action = ProposalAction.timer(command: .pause, blockId: nil, title: nil, expectedRevision: nil)
        let a = phone.upsert(origin: .agent, action: action, scope: .kind, effect: .allow, deviceId: "phone", sourceProposalId: nil)
        let again = phone.upsert(origin: .agent, action: action, scope: .kind, effect: .allowAndInform, deviceId: "phone", sourceProposalId: nil)
        #expect(phone.rules.count == 1 && again.id == a.id && again.effect == .allowAndInform)   // 同类同范围不重复堆
        #expect(d.object(forKey: PreauthRuleStore.key) is Data)                                    // plist 类型，可进 iCloud KV
        #expect(a.kindLabel == "计时：暂停计时" && a.label.contains("做完告诉你") == false && again.label.contains("做完告诉你"))
        // 「另一台设备」：同步落到本地后 reload 读到同一份
        let mac = PreauthRuleStore(defaults: d)
        #expect(mac.rules == phone.rules)
        phone.remove(a.id)
        mac.reload()
        #expect(mac.rules.isEmpty && d.object(forKey: PreauthRuleStore.key) == nil)
        // 读坏了：一律先问你、错误可见、原数据不动
        d.set(Data("not json".utf8), forKey: PreauthRuleStore.key)
        let broken = PreauthRuleStore(defaults: d)
        #expect(broken.rules.isEmpty && broken.lastError?.contains("先问你") == true)
        #expect(d.data(forKey: PreauthRuleStore.key) == Data("not json".utf8))
    }

    @Test func oldProposalRecordsWithoutW10FieldsStillDecode() throws {
        let p = proposalValue(alternatives: 0)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        for key in ["escalation", "primaryLabel", "alternatives", "chosenOption", "userReply", "preauth"] { object[key] = nil }
        let decoded = try JSONDecoder().decode(Proposal.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.escalation == nil && decoded.alternatives == nil && decoded.options.count == 1 && decoded.executedAction == p.action)
        let old = #"{"id":"\#(UUID())","at":"2026-10-18T10:00:00Z","actor":"agent","actorLabel":"a","deviceId":"mac","event":"submitted","detail":"x"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(OperationRecord.self, from: Data(old.utf8)).ruleId == nil)
    }

    // MARK: 4. 审慎越级

    @Test func escalationIsShownProminentlyForcesAskAndReachesTheValidationSeam() async throws {
        let p = pair()
        let e = try #require(await p.mac.submit(draft(escalation: "  这块是你亲手拖的，但它和你刚说的面试冲突  ")))
        #expect(e.escalation == "这块是你亲手拖的，但它和你刚说的面试冲突")
        #expect(e.notificationBody.hasPrefix(Proposal.escalationHeadline + "：这块是你亲手拖的"))
        #expect(LocalProposalNotifier.request(for: e).content.title.hasPrefix("【越级】"))
        #expect(p.executor.escalations.last == "这块是你亲手拖的，但它和你刚说的面试冲突")   // W9 挪块校验能拿到越级理由
        #expect(await p.mac.submit(draft(escalation: "   ")) == nil && p.mac.lastError?.contains("必须写明理由") == true)
        let root = try tempRoot(), io = AgentBridgeIO(root: root)
        try io.prepare(); try io.writeResult(e, at: p.clock.now)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results/\(e.id.uuidString).json"))) as! [String: Any]
        #expect(result["escalation"] as? String == e.escalation)
    }
}

// MARK: - 5. 判断类数字改由智能体判断：真实数据上的边界（复用 W1 的两台设备 + 内存数据）

extension ProposalActionTests {
    @Test func longBackdateIsAllowedAndTheCardSaysHowFarBack() async throws {
        let r = try rig()
        let c = r.clock   // 10:00
        let p = try #require(await r.mac.submit(draft(.timer(command: .start, blockId: nil, title: "写论文", expectedRevision: nil,
                                                             startAt: at(6, 50, c)))))
        #expect(p.changes.contains { $0.field.hasPrefix("回溯 3 小时 10 分钟") })
        #expect(ProposalTimerRules.backdateText(3600) == "回溯 1 小时" && ProposalTimerRules.backdateText(25 * 60) == "回溯 25 分钟")
        // 物理一致性照守：不在未来、在今天、不与已记下的重叠
        r.mac.clearError()
        _ = await r.mac.submit(draft(.timer(command: .start, blockId: nil, title: "写论文", expectedRevision: nil, startAt: at(10, 30, c))))
        #expect(r.mac.lastError?.contains("在未来") == true)
    }

    @Test func moveBlocksHasNoProductCapOnlyAWideTechnicalOne() async throws {
        let r = try rig()
        let c = r.clock
        let blocks = (0..<12).map { i in ScheduledBlock(title: "块\(i)", start: at(11, 0, c).addingTimeInterval(Double(i) * 1800),
                                                        end: at(11, 30, c).addingTimeInterval(Double(i) * 1800)) }
        try r.plans.replacePlanned(blocks, on: Calendar.current.startOfDay(for: c.now))
        let moves = blocks.map { ProposalBlockMove(id: $0.id, start: $0.start.addingTimeInterval(6.5 * 3600), end: nil, expectedRevision: nil) }
        let p = try await approve(r, .moveBlocks(moves: moves, isUndo: false))
        #expect(p.state == .applied && p.changes.count == 13)   // 12 块 + 一行说明：以前「最多 10 块」会拒收
        let many = (0...PlanMoveRules.maxGroup).map { _ in PlanMoveRules.Move(id: UUID(), start: c.now, end: nil) }
        #expect(throws: (any Error).self) {
            try PlanMoveRules.validateGroup(many, in: .init(blocks: [], now: c.now, dayWindow: DayContext.logicalWindow(forLabel: DayContext.logicalStartOfDay(c.now))))
        }
    }
}

extension W8ReminderTests {
    @Test func farFutureReminderAndAlarmAreAcceptedButAtLeastOneMinuteStillHolds() async throws {
        let r = rig(), c = r.clock
        let far = c.now.addingTimeInterval(90 * 86_400)   // 以前「30 天以内」会拒收
        let alarm = try #require(await r.mac.submit(draft(.alarm(id: UUID(), title: "交年度报告", fireAt: far, deviceId: "phone"))))
        #expect(alarm.state == .pending && alarm.notificationBody.contains(ProposalReminderRules.when(far)))
        r.mac.clearError()
        _ = await r.mac.submit(draft(.reminder(id: UUID(), title: "t", body: nil, fireAt: c.now.addingTimeInterval(30), deviceId: nil)))
        #expect(r.mac.lastError?.contains("至少 1 分钟以后") == true)
    }
}
