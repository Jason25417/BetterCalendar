import Foundation
import Testing
@testable import BetterCalendar

/// W20：智能体适配器 + App 内置智能体（DeepSeek）。全部用假模型 / 假 HTTP，绝不真调 API。
@MainActor @Suite struct W20BuiltinAgentTests {
    // MARK: 夹具

    final class Clock { var now: Date; init(_ d: Date) { now = d } }

    /// 周日 15:00 UTC = 低谷时段（价格按 1 倍算）。
    static let sunday = ISO8601DateFormatter().date(from: "2026-10-18T15:00:00Z")!

    @MainActor final class FakeModel: BuiltinAgentModel {
        var script: [DeepSeekCompletion] = []
        /// 脚本用完后一直返回这个（nil = 返回「说完了」）。
        var repeating: DeepSeekCompletion?
        var delay: Duration?
        var error: Error?
        private(set) var requests: [[DeepSeekMessage]] = []
        private(set) var toolsSeen: [Data] = []

        func complete(model: String, messages: [DeepSeekMessage], tools: Data) async throws -> DeepSeekCompletion {
            requests.append(messages); toolsSeen.append(tools)
            if let delay { try await Task.sleep(for: delay) }
            if let error { throw error }
            if !script.isEmpty { return script.removeFirst() }
            return repeating ?? FakeModel.done()
        }

        static func call(_ name: String, _ args: [String: Any], id: String = UUID().uuidString,
                         usage: DeepSeekUsage = .init(cacheHitTokens: 0, cacheMissTokens: 1000, completionTokens: 100)) -> DeepSeekCompletion {
            let a = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            return DeepSeekCompletion(message: DeepSeekMessage(role: "assistant", content: nil,
                                                               toolCalls: [DeepSeekToolCall(id: id, function: .init(name: name, arguments: a))]),
                                      finishReason: "tool_calls", usage: usage, model: "deepseek-flash")
        }
        static func done(_ text: String? = nil) -> DeepSeekCompletion {
            DeepSeekCompletion(message: DeepSeekMessage(role: "assistant", content: text), finishReason: "stop",
                               usage: .init(cacheHitTokens: 0, cacheMissTokens: 1000, completionTokens: 50), model: "deepseek-flash")
        }
    }

    @MainActor final class FakeClaudeCode: ClaudeCodeAgentChannel {
        var emitted: [String] = []
        var active = true
        func emit(kind: String, summary: String, payload: [String: Any]) { emitted.append(kind) }
        func activate() { active = true }
        var deactivatedFor: [AgentKind] = []
        func deactivate(active: AgentKind) { self.active = false; deactivatedFor.append(active) }
    }

    struct Env {
        let defaults: UserDefaults
        let clock: Clock
        let chat: AgentChatCenter
        let center: ProposalCenter
        let messages: AgentMessageCenter
        let memory: AgentSharedMemoryStore
        let tools: BuiltinAgentToolbox
        let model: FakeModel
        let runtime: BuiltinAgentRuntime
        let selection: AgentSelection
        let claude: FakeClaudeCode
        let hub: AgentHub
    }

    func env(rules: PreauthRuleStore? = nil, isPhone: Bool = false, now: Date = W20BuiltinAgentTests.sunday) -> Env {
        let d = UserDefaults(suiteName: "bc-w20-" + UUID().uuidString)!
        let clock = Clock(now)
        let chat = AgentChatCenter(transport: InMemoryAgentChatTransport(), notifier: SilentAgentChatNotifier(), ledger: MemoryOperationLedger(),
                                   deviceId: "mac", deviceLabel: "Mac", defaults: d, now: { clock.now })
        var off = AttentionSettings(); off.enabled = false; off.capsOn = true
        chat.attention = { off }
        let center: ProposalCenter
        if let rules {
            center = ProposalCenter(transport: InMemoryProposalTransport(), gate: PreauthRuleGate(store: rules), rules: rules,
                                    executor: ExperimentOnlyExecutor(), notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(),
                                    deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        } else {
            center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(), notifier: SilentProposalNotifier(),
                                    ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        }
        let messages = AgentMessageCenter(transport: InMemoryAgentMessageTransport(), notifier: SilentAgentMessageNotifier(),
                                          ledger: MemoryOperationLedger(), deviceId: "mac", defaults: d, now: { clock.now })
        let memory = AgentSharedMemoryStore(defaults: d, now: { clock.now })
        let tools = BuiltinAgentToolbox(proposals: center, chat: chat, messages: messages, memory: memory, deviceLabel: "Mac",
                                        now: { clock.now }, context: { ["today": ["blocks": []], "schemaVersion": 1] })
        let model = FakeModel()
        let runtime = BuiltinAgentRuntime(model: model, tools: tools, usage: BuiltinAgentUsageStore(defaults: d, now: { clock.now }),
                                          defaults: d, now: { clock.now }, promptLoader: { "PROMPT" })
        runtime.autoStart = false; runtime.debounce = 0
        let selection = AgentSelection(defaults: d)
        let claude = FakeClaudeCode()
        let hub = AgentHub(selection: selection, builtin: runtime, memory: memory, claudeCode: claude, isPhone: isPhone, defaults: d, now: { clock.now })
        hub.eventsEnabled = { true }
        return Env(defaults: d, clock: clock, chat: chat, center: center, messages: messages, memory: memory, tools: tools,
                   model: model, runtime: runtime, selection: selection, claude: claude, hub: hub)
    }

    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-w20-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func object(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: 适配器开关：没选中的实现没有任何通道

    @Test func defaultIsClaudeCodeAndBuiltinGetsNoChannel() async throws {
        let e = env()
        #expect(e.selection.kind == .claudeCode)   // 日用版默认 = 现在的行为
        e.hub.emit(kind: "block_finished", summary: "做完了")
        #expect(e.claude.emitted == ["block_finished"])
        #expect(e.runtime.queuedCount == 0)
        // 你说的话：Claude Code 时由 Mac 桥接转交，内置智能体不接手
        let m = try #require(await e.chat.send("接下来做什么"))
        e.hub.userMessageStored(m)
        e.hub.pump()
        #expect(e.runtime.queuedCount == 0)
        // 直接塞给内置智能体也没用：没接通 = 没通道
        e.runtime.isActive = { e.selection.kind == .builtin }
        e.runtime.enqueue(AgentEvent(kind: "user_message", summary: "x", at: e.clock.now))
        #expect(e.runtime.queuedCount == 0)
        await e.runtime.run([AgentEvent(kind: "user_message", summary: "x", at: e.clock.now)])
        #expect(e.model.requests.isEmpty)
    }

    @Test func switchingToBuiltinClosesClaudeCodeChannel() async throws {
        let e = env()
        e.selection.select(.builtin)
        #expect(e.claude.active == false)
        #expect(e.claude.deactivatedFor == [.builtin])   // W24：告诉通道「现在接通的是内置」（桥接据此写状态标记给心跳）
        e.hub.emit(kind: "block_finished", summary: "做完了")
        #expect(e.claude.emitted.isEmpty)
        #expect(e.runtime.queuedCount == 1)
        // 切回 Claude Code：排着的事件属于内置通道，丢掉；之后事件只给 Claude Code
        e.selection.select(.claudeCode)
        #expect(e.claude.active && e.runtime.queuedCount == 0)
        e.hub.emit(kind: "block_finished", summary: "又做完一件")
        #expect(e.claude.emitted == ["block_finished"] && e.runtime.queuedCount == 0)
        #expect(e.defaults.string(forKey: AgentSelectionSettings.key) == "claudeCode")
    }

    @Test func inactiveBridgeWritesNothing() async throws {
        let root = try tempRoot()
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(), notifier: SilentProposalNotifier(),
                                    ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac")
        let bridge = AgentBridge(center: center, defaults: UserDefaults(suiteName: "bc-w20b-" + UUID().uuidString)!) { ["schemaVersion": 1] }
        bridge.isActive = { false }
        await bridge.sync(io: AgentBridgeIO(root: root))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("context.json").path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true)
        await #expect(throws: AgentBridgeError.self) { try await bridge.performInFolder(refreshContext: false) { _ in } }
        bridge.isActive = { true }
        await bridge.sync(io: AgentBridgeIO(root: root))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("context.json").path))
    }

    // MARK: 工具 → ProposalCenter（与桥接同一套校验）

    @Test func proposeChangeGoesThroughProposalCenter() async throws {
        let e = env()
        e.selection.select(.builtin)
        e.model.script = [
            FakeModel.call("propose_change", ["title": "测试", "reason": "联调", "lifetimeMinutes": 30,
                                              "action": ["kind": "experimentNoop", "note": "w20"],
                                              "changes": [["field": "测试字段", "before": "旧", "after": "新"]]]),
            FakeModel.done(),
        ]
        await e.runtime.run([AgentEvent(kind: "block_finished", summary: "做完了", at: e.clock.now)])
        let p = try #require(e.center.proposals.first)
        #expect(p.origin == .agent && p.agentKey == "builtin" && p.originLabel == "BetterCalendar 内置智能体")
        #expect(p.state == .pending && p.expiresAt.timeIntervalSince(p.createdAt) == 1800)
        #expect(p.parentRef?.hasPrefix("block_finished-") == true)
        // 模型拿到的工具结果：已提交，带 id
        let toolMsg = try #require(e.model.requests.last?.last)
        #expect(toolMsg.role == "tool" && object(toolMsg.content ?? "")["ok"] as? Bool == true)
        #expect(e.runtime.problem == nil)
    }

    @Test func proposeChangeRejectsWithSameValidationAsBridge() async throws {
        let e = env()
        let args: [String: Any] = ["title": "挪", "reason": "r", "action": ["kind": "moveBlock", "blockId": UUID().uuidString,
                                                                          "start": "2026-10-18T15:00:00Z", "color": "red"]]
        let ledger = BuiltinAgentRunLedger()
        let out = object(await e.tools.call("propose_change", arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self),
                                            eventId: nil, ledger: ledger))
        // 桥接对同一份提案文件的拒绝原因
        let file = try BuiltinAgentToolbox.proposalFile(args, id: UUID(), eventId: nil)
        var bridgeWhy = ""
        do { _ = try AgentBridgeIO.draft(from: JSONSerialization.data(withJSONObject: file)) } catch { bridgeWhy = error.localizedDescription }
        #expect(!bridgeWhy.isEmpty && out["ok"] as? Bool == false && out["error"] as? String == bridgeWhy)
        #expect(e.center.proposals.isEmpty)
        // 不认识的种类同样拒收；App 侧 prepare 不通过（本设备只接受测试改动）→ rejected 带原因
        let real = object(await e.tools.call("propose_change", arguments: #"{"title":"加待办","reason":"r","action":{"kind":"itemCreate","title":"交表"}}"#,
                                             eventId: nil, ledger: ledger))
        #expect(real["ok"] as? Bool == false && (real["rejected"] as? String)?.contains("只接受测试改动") == true)
        // 顶层多一个参数也拒收
        let extra = object(await e.tools.call("propose_change", arguments: #"{"title":"t","reason":"r","sneaky":1}"#, eventId: nil, ledger: ledger))
        #expect((extra["error"] as? String)?.contains("sneaky") == true)
    }

    @Test func parameterTargetIndexBecomesBlockId() throws {
        let pid = UUID()
        let action: [String: Any] = ["kind": "blockCreate", "day": "2026-10-19",
                                     "blocks": [["title": "a", "start": "2026-10-19T09:00:00-04:00", "durationMinutes": 60],
                                                ["title": "b", "start": "2026-10-19T11:00:00-04:00", "durationMinutes": 60]]]
        let out = try BuiltinAgentToolbox.resolveTargets([["id": "p", "target": 1]], action: action, proposalId: pid, path: "parameters") as? [[String: Any]]
        #expect(out?.first?["target"] as? String == AgentBridgeIO.derivedBlockID(pid, 1).uuidString)
        #expect(throws: AgentBridgeError.self) { _ = try BuiltinAgentToolbox.resolveTargets([["target": 5]], action: action, proposalId: pid, path: "p") }
    }

    @Test func replyAndNotifyUseBridgeValidation() async throws {
        let e = env()
        let ledger = BuiltinAgentRunLedger()
        let said = try #require(await e.chat.send("在吗"))
        let ok = object(await e.tools.call("reply_jason", arguments: #"{"text":"在","replyTo":"\#(said.id.uuidString)"}"#, eventId: "ev-1", ledger: ledger))
        #expect(ok["ok"] as? Bool == true && ledger.repliedTo == [said.id])
        let reply = try #require(e.chat.messages.last)
        #expect(reply.author == .agent && reply.replyTo == said.id && reply.parentRef == "ev-1")
        let tooLong = object(await e.tools.call("reply_jason", arguments: #"{"text":"\#(String(repeating: "长", count: 1001))"}"#, eventId: nil, ledger: ledger))
        #expect((tooLong["error"] as? String)?.contains("1000") == true)
        let n = object(await e.tools.call("notify_jason", arguments: #"{"title":"休息","body":"起来走走","reason":"连续两小时"}"#, eventId: nil, ledger: ledger))
        #expect(n["ok"] as? Bool == true && e.messages.messages.first?.originLabel == "BetterCalendar 内置智能体")
        let bad = object(await e.tools.call("notify_jason", arguments: #"{"title":"x","body":"y"}"#, eventId: nil, ledger: ledger))
        #expect((bad["error"] as? String)?.contains("理由") == true)
    }

    // MARK: 循环：步数上限、超时

    @Test func loopStopsAtTurnLimit() async throws {
        let e = env()
        e.selection.select(.builtin)
        e.runtime.maxTurns = 3
        e.model.repeating = FakeModel.call("read_chat", [:])
        await e.runtime.run([AgentEvent(kind: "block_finished", summary: "x", at: e.clock.now)])
        #expect(e.model.requests.count == 3)
        #expect(e.runtime.problem == .turnLimit(3))
        #expect(e.runtime.lastRun?.turns == 3)
    }

    @Test func loopStopsOnTimeout() async throws {
        let e = env()
        e.selection.select(.builtin)
        e.runtime.runTimeout = 0.2
        e.model.delay = .seconds(60)   // 不靠墙钟断言（全量并行时主线程很忙）：没超时就会拿到「说完了」而不是超时问题
        await e.runtime.run([AgentEvent(kind: "block_finished", summary: "x", at: e.clock.now)])
        #expect(e.runtime.problem == .timeout(1))
        #expect(e.runtime.lastRun?.problem?.contains("秒") == true)
    }

    // MARK: 失败可见、不降级

    @Test func noKeyIsSaidPlainlyInChatWithoutFallback() async throws {
        let e = env()
        e.selection.select(.builtin)
        let client = DeepSeekClient(apiKey: { nil }, transport: { _ in Issue.record("没有 key 不该发请求"); throw URLError(.badURL) })
        let runtime = BuiltinAgentRuntime(model: client, tools: e.tools, usage: BuiltinAgentUsageStore(defaults: e.defaults, now: { e.clock.now }),
                                          defaults: e.defaults, now: { e.clock.now }, promptLoader: { "PROMPT" })
        runtime.isActive = { true }; runtime.autoStart = false
        let said = try #require(await e.chat.send("明天上午排两小时写论文"))
        await runtime.run([AgentEvent(kind: "user_message", summary: "s", payload: ["messageId": said.id.uuidString, "text": said.text], at: e.clock.now)])
        guard case let .model(err)? = runtime.problem else { Issue.record("应有问题"); return }
        #expect(err.kind == .noKey && err.hint.contains("设置 → 智能体"))
        let reply = try #require(e.chat.messages.last { $0.author == .agent })
        #expect(reply.replyTo == said.id && reply.text.contains("没能回复") && reply.text.contains("API key"))
        #expect(e.chat.status(of: said) == .replied)          // 不让他看着「正在想」干等
        #expect(e.claude.emitted.isEmpty)                      // 没有悄悄转给 Claude Code
        #expect(e.selection.kind == .builtin)                  // 也没有自动切换
        #expect(e.center.proposals.isEmpty)
    }

    @Test func httpErrorsSayWhatBrokeAndWhatToDo() async throws {
        let paid = DeepSeekClient.httpError(status: 402, data: Data(#"{"error":{"message":"Insufficient Balance"}}"#.utf8))
        #expect(paid.kind == .insufficientBalance && paid.hint.contains("充值"))
        let bad = DeepSeekClient.httpError(status: 401, data: Data(#"{"error":{"message":"Authentication Fails"}}"#.utf8))
        #expect(bad.kind == .unauthorized && bad.message.contains("Authentication Fails"))
        let client = DeepSeekClient(apiKey: { "k" }, transport: { req in
            (Data(#"{"error":{"message":"busy"}}"#.utf8), HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: DeepSeekError.self) { _ = try await client.complete(model: "deepseek-flash", messages: [.user("hi")], tools: Data("[]".utf8)) }
    }

    @Test func modelPlainTextIsDeliveredWhenNoReplyToolWasCalled() async throws {
        let e = env()
        e.selection.select(.builtin)
        let said = try #require(await e.chat.send("你好"))
        e.model.script = [FakeModel.done("你好，今天想先做哪件？")]
        await e.runtime.run([AgentEvent(kind: "user_message", summary: "s", payload: ["messageId": said.id.uuidString], at: e.clock.now)])
        let reply = try #require(e.chat.messages.last { $0.author == .agent })
        #expect(reply.text == "你好，今天想先做哪件？" && reply.replyTo == said.id)
        #expect(e.runtime.problem == nil)
    }

    // MARK: 预授权规则：各实现共用同一套（Jason 2026-10-19 改定）

    @Test func preauthRulesAreSharedAcrossImplementations() async throws {
        let rulesDefaults = UserDefaults(suiteName: "bc-w20r-" + UUID().uuidString)!
        let rules = PreauthRuleStore(defaults: rulesDefaults)
        // 规则来自 Claude Code 时代（经桥接、无 agentKey 的提案「以后同类都允许」）
        rules.upsert(origin: .agent, action: .experimentNoop(note: ""), scope: .kind, effect: .allow, deviceId: "mac", sourceProposalId: nil)
        let e = env(rules: rules)
        e.selection.select(.builtin)
        let ledger = BuiltinAgentRunLedger()
        let out = object(await e.tools.call("propose_change",
            arguments: #"{"title":"测试","reason":"r","action":{"kind":"experimentNoop"},"changes":[{"field":"f","before":"a","after":"b"}]}"#,
            eventId: nil, ledger: ledger))
        #expect(out["ok"] as? Bool == true)
        let p = try #require(e.center.proposals.first)
        #expect(p.preauth?.effect == .allow)               // 同一套规则对内置智能体同样生效
        #expect(p.agentKey == "builtin")                   // 但留得下是哪种实现提的
        #expect(AgentKind.of(p.agentKey) == .builtin && AgentKind.of(nil) == .claudeCode)
        #expect(e.center.ledger.records().contains { $0.event == "submitted" && $0.actorLabel == "BetterCalendar 内置智能体" })
    }

    // MARK: 共享记忆

    @Test func sharedMemoryIsReadOnTakeoverAndSyncsThroughBridge() async throws {
        let e = env()
        e.selection.select(.builtin)
        let ledger = BuiltinAgentRunLedger()
        let ok = object(await e.tools.call("update_shared_memory", arguments: #"{"text":"- 2026-10-18 Jason 喜欢提前 15 分钟提醒"}"#, eventId: nil, ledger: ledger))
        #expect(ok["ok"] as? Bool == true)
        // 同一份设置（= iCloud 同步到另一台设备）读得到
        let other = AgentSharedMemoryStore(defaults: e.defaults)
        #expect(other.memory?.text.contains("提前 15 分钟") == true && other.memory?.updatedBy.contains("内置智能体") == true)
        // 接手时读：每轮的系统提示里带全文
        await e.runtime.run([AgentEvent(kind: "block_finished", summary: "x", at: e.clock.now)])
        let system = try #require(e.model.requests.first?.first)
        #expect(system.role == "system" && system.content?.contains("提前 15 分钟") == true && system.content?.hasPrefix("PROMPT") == true)
        // 超上限：拒绝、不截断
        let big = object(await e.tools.call("update_shared_memory", arguments: #"{"text":"\#(String(repeating: "字", count: 6001))"}"#, eventId: nil, ledger: ledger))
        #expect(big["ok"] as? Bool == false && e.memory.memory?.text.count ?? 0 < 100)

        // Claude Code 一侧：桥接写只读快照、导入它的整份改写
        let root = try tempRoot()
        let bridge = AgentBridge(center: e.center, defaults: UserDefaults(suiteName: "bc-w20m-" + UUID().uuidString)!) { ["schemaVersion": 1] }
        bridge.sharedMemory = e.memory
        await bridge.sync(io: AgentBridgeIO(root: root))
        let md = try String(contentsOf: root.appendingPathComponent("shared-memory.md"), encoding: .utf8)
        #expect(md.contains("提前 15 分钟"))
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "text": "- 他周三下午有组会"]).write(to: root.appendingPathComponent("shared-memory.update.json"))
        await bridge.sync(io: AgentBridgeIO(root: root))
        #expect(e.memory.memory?.text == "- 他周三下午有组会" && e.memory.memory?.updatedBy.contains("Claude Code") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("shared-memory.update.json").path))
        #expect(try String(contentsOf: root.appendingPathComponent("shared-memory.md"), encoding: .utf8).contains("周三下午"))
        // 坏的改写 → 拒绝并写原因，原记忆不动
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "text": String(repeating: "x", count: 7000)]).write(to: root.appendingPathComponent("shared-memory.update.json"))
        await bridge.sync(io: AgentBridgeIO(root: root))
        #expect(e.memory.memory?.text == "- 他周三下午有组会")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("shared-memory.rejected.reason.txt").path))
    }

    // MARK: 成本与预算

    @Test func costFollowsPublishedPricesWithPeakHours() throws {
        let u = DeepSeekUsage(cacheHitTokens: 1_000_000, cacheMissTokens: 1_000_000, completionTokens: 1_000_000)
        let offPeak = try #require(DeepSeekPricing.cost(u, model: "deepseek-flash", at: Self.sunday))
        #expect(abs(offPeak - (0.003 + 0.15 + 0.6)) < 1e-9)
        let mondayPeak = ISO8601DateFormatter().date(from: "2026-10-19T02:30:00Z")!
        #expect(DeepSeekPricing.isPeak(mondayPeak) && !DeepSeekPricing.isPeak(Self.sunday))
        #expect(abs((DeepSeekPricing.cost(u, model: "deepseek-flash", at: mondayPeak) ?? 0) - 2 * offPeak) < 1e-9)
        #expect(DeepSeekPricing.cost(u, model: "gpt-whatever", at: Self.sunday) == nil)
    }

    @Test func usageIsCountedAndBudgetStops() async throws {
        let e = env()
        e.selection.select(.builtin)
        e.defaults.set(0.001, forKey: BuiltinAgentSettings.budgetKey)
        // 第一次调用：1 万未命中 + 1 千输出 = 0.0015 + 0.0006 = $0.0021 > 预算 → 第二次调用前停下
        e.model.repeating = FakeModel.call("read_chat", [:], usage: .init(cacheHitTokens: 0, cacheMissTokens: 10_000, completionTokens: 1000))
        await e.runtime.run([AgentEvent(kind: "block_finished", summary: "x", at: e.clock.now)])
        #expect(e.model.requests.count == 1)
        guard case let .budgetReached(spent, budget)? = e.runtime.problem else { Issue.record("应碰到预算"); return }
        #expect(abs(spent - 0.0021) < 1e-9 && budget == 0.001)
        let today = e.runtime.usage.today
        #expect(today.calls == 1 && today.runs == 1 && today.cacheMissTokens == 10_000 && today.completionTokens == 1000)
        // 已经用完：下一轮一次都不调
        await e.runtime.run([AgentEvent(kind: "block_finished", summary: "y", at: e.clock.now)])
        #expect(e.model.requests.count == 1)
        #expect(e.runtime.problem?.hint.contains("预算") == true)
        // 不认识的模型：不瞎估，直说
        e.defaults.set(5.0, forKey: BuiltinAgentSettings.budgetKey)
        #expect(BuiltinAgentSettings.model(e.defaults) == "deepseek-flash")
    }

    @Test func noBudgetByDefaultKeepsRunning() async throws {
        // Jason 10-19：试验阶段不设预算——没设过就没有上限，花得再多也照常调用（用量照常记账）
        let e = env()
        e.selection.select(.builtin)
        #expect(BuiltinAgentSettings.budget(e.defaults) == nil)
        e.model.repeating = FakeModel.call("read_chat", [:], usage: .init(cacheHitTokens: 0, cacheMissTokens: 10_000_000, completionTokens: 1000))
        await e.runtime.run([AgentEvent(kind: "block_finished", summary: "x", at: e.clock.now)])
        await e.runtime.run([AgentEvent(kind: "block_finished", summary: "y", at: e.clock.now)])
        #expect(e.model.requests.count > 2)
        if case .budgetReached? = e.runtime.problem { Issue.record("不设预算时不该因预算停") }
        #expect(e.runtime.usage.today.costUSD > 1)
        e.defaults.set(0, forKey: BuiltinAgentSettings.budgetKey)   // 设 0 = 回到不设
        #expect(BuiltinAgentSettings.budget(e.defaults) == nil)
    }

    // MARK: 请求形状（DeepSeek / OpenAI 兼容工具调用，无预填）

    @Test func requestShapeIsOpenAICompatibleToolsWithoutPrefill() async throws {
        let tools = try BuiltinAgentToolbox.loadDefinitions()   // 资源文件随 App 打包，名字与实现一一对应
        let list = try #require(try JSONSerialization.jsonObject(with: tools) as? [[String: Any]])
        #expect(Set(list.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }) == BuiltinAgentToolbox.toolNames)
        for t in list {
            #expect(t["type"] as? String == "function")
            let params = try #require((t["function"] as? [String: Any])?["parameters"] as? [String: Any])
            #expect(params["type"] as? String == "object" && params["additionalProperties"] as? Bool == false)
        }
        var captured: URLRequest?
        let reply = #"{"model":"deepseek-flash","choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"read_context","arguments":"{}"}}]}}],"usage":{"prompt_tokens":120,"prompt_cache_hit_tokens":100,"prompt_cache_miss_tokens":20,"completion_tokens":7}}"#
        let box = RequestBox()
        let client = DeepSeekClient(apiKey: { "sk-test" }, transport: { req in
            await box.set(req)
            return (Data(reply.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let history: [DeepSeekMessage] = [.system("S"), .user("U"),
            DeepSeekMessage(role: "assistant", content: nil, toolCalls: [DeepSeekToolCall(id: "c0", function: .init(name: "read_chat", arguments: "{}"))]),
            .tool("c0", "{}")]
        let out = try await client.complete(model: "deepseek-flash", messages: history, tools: tools)
        captured = await box.request
        let req = try #require(captured)
        #expect(req.url?.absoluteString == "https://api.deepseek.com/chat/completions")   // 不是 /beta
        #expect(req.httpMethod == "POST" && req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "deepseek-flash" && body["tool_choice"] as? String == "auto" && body["stream"] as? Bool == false)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((body["tools"] as? [Any])?.count == BuiltinAgentToolbox.toolNames.count)
        let msgs = try #require(body["messages"] as? [[String: Any]])
        #expect(msgs.last?["role"] as? String == "tool" && msgs.last?["tool_call_id"] as? String == "c0")
        #expect(msgs.allSatisfy { $0["prefix"] == nil && $0["reasoning_content"] == nil })   // 无预填
        #expect(((msgs[2]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String == "read_chat")
        #expect(msgs[2].keys.contains("content"))   // assistant 带工具调用时 content = null（照样有这个键）
        // 解析：工具调用 + 用量
        #expect(out.message.toolCalls?.first?.function.name == "read_context")
        #expect(out.usage == DeepSeekUsage(cacheHitTokens: 100, cacheMissTokens: 20, completionTokens: 7))
        #expect(DeepSeekClient.keychainAccount == "deepseek-api-key")
    }

    actor RequestBox { var request: URLRequest?; func set(_ r: URLRequest) { request = r } }

    @Test func promptResourceIsBundledAndCoversDuties() throws {
        let p = try BuiltinAgentRuntime.loadPrompt()
        for duty in ["翻译官", "提交 ≠ 执行", "做不到就直说", "只向前", "App / 网站名", "escalation", "排一天", "reply_jason", "update_shared_memory"] {
            #expect(p.contains(duty), "提示词缺「\(duty)」")
        }
    }

    // MARK: 事件（进程内送达）

    @Test func ownUserMessagesAreHandledHereOthersAreNot() async throws {
        let e = env()
        e.selection.select(.builtin)
        let mine = try #require(await e.chat.send("挪到明天"))
        e.hub.userMessageStored(mine)
        #expect(e.runtime.queuedCount == 1)
        e.hub.pump()   // 同一条不重复排
        #expect(e.runtime.queuedCount == 1)
        var other = mine; other.id = UUID(); other.deviceId = "iphone"
        e.hub.userMessageStored(other)   // 别的设备说的由那台设备处理
        #expect(e.runtime.queuedCount == 1)
        e.model.script = [FakeModel.call("reply_jason", ["text": "好，我来排", "replyTo": mine.id.uuidString]), FakeModel.done()]
        await e.runtime.processPending()
        #expect(e.chat.status(of: mine) == .replied)
        let firstUser = try #require(e.model.requests.first?[1].content)
        #expect(firstUser.contains("user_message") && firstUser.contains(mine.id.uuidString))
    }

    @Test func sentinelBurstsCoalesceIntoOneRun() async throws {
        let e = env()
        e.selection.select(.builtin)
        e.hub.emit(kind: "sentinel_wake", summary: "a", payload: ["reason": "计划开始已过"], force: true)
        e.hub.emit(kind: "sentinel_wake", summary: "b", payload: ["reason": "像是做完了"], force: true)
        e.hub.emit(kind: "block_finished", summary: "做完了")
        #expect(e.runtime.queuedCount == 2)
        await e.runtime.processPending()
        #expect(e.model.requests.count == 1)   // 一阵连发只叫醒一次
        let text = try #require(e.model.requests.first?[1].content)
        #expect(text.contains("计划开始已过") && text.contains("像是做完了") && text.contains("block_finished"))
    }

    @Test func eveningReviewAndResolvedProposalsAreEmittedOnce() async throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let evening = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 21, minute: 40))!
        let e = env(now: evening)
        e.selection.select(.builtin)
        e.defaults.set(true, forKey: EveningReviewSettings.enabledKey)
        e.hub.pump()
        #expect(e.runtime.queuedCount == 1)
        e.hub.pump()
        #expect(e.runtime.queuedCount == 1)   // 一天一次
        await e.runtime.processPending()
        #expect(e.model.requests.first?[1].content?.contains("evening_review") == true)

        // 内置智能体本机提的提案有了结论 → 一次 proposal_resolved
        let ledger = BuiltinAgentRunLedger()
        _ = await e.tools.call("propose_change", arguments: #"{"title":"t","reason":"r","action":{"kind":"experimentNoop"},"changes":[{"field":"f"}]}"#,
                               eventId: nil, ledger: ledger)
        let p = try #require(e.center.proposals.first)
        _ = await e.center.decide(p.id, .decline)
        e.hub.proposalsRefreshed()
        e.hub.proposalsRefreshed()
        #expect(e.runtime.queuedCount == 1)

        // iPhone：晚 3 分钟才发，且对话里已有今天的复盘就不发
        let phone = env(isPhone: true, now: cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 21, minute: 31))!)
        phone.selection.select(.builtin)
        phone.defaults.set(true, forKey: EveningReviewSettings.enabledKey)
        #expect(phone.hub.dueEveningReview() == nil)
        phone.clock.now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 21, minute: 34))!
        #expect(phone.hub.dueEveningReview() != nil)
        _ = await phone.chat.receiveAgent(AgentChatReplyDraft(id: UUID(), text: "今天做成了…", kind: .eveningReview))
        #expect(phone.hub.dueEveningReview() == nil)
    }

    @Test func sentinelChannelDeliversInProcessWhenBuiltin() async throws {
        let e = env()
        let root = try tempRoot()
        let channel = AgentSentinelChannel(hub: e.hub, bridge: nil, localRoot: root)
        #expect(channel.isConnected == false)   // Claude Code 时：没有桥接 = 不连接
        e.selection.select(.builtin)
        #expect(channel.isConnected)
        try await channel.withBridge(refreshContext: true) { io in
            _ = try SentinelBridgeFiles.writeWake(io: io, verdict: SentinelVerdict(wake: true, reason: "计划开始已过", urgency: .normal, signals: ["planned_start_passed"]),
                                                  digestText: "前台：某编辑器", digestHash: String(repeating: "a", count: 64), digestBytes: 10,
                                                  trigger: .change, judge: .rule, decisionId: UUID(), now: e.clock.now)
        }
        #expect(e.runtime.queuedCount == 1)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("events").path).filter { $0.hasSuffix(".json") }
        #expect(left.isEmpty)
        await e.runtime.processPending()
        let text = try #require(e.model.requests.first?[1].content)
        #expect(text.contains("sentinel_wake") && text.contains("前台：某编辑器") && !text.contains("digestRef"))
    }

    @Test func chatStatusTalksAboutBuiltinNotMac() async throws {
        let e = env()
        e.chat.activeAgent = { .builtin }
        let said = try #require(await e.chat.send("hi"))
        #expect(e.chat.label(for: e.chat.status(of: said)).contains("内置智能体"))
        e.chat.activeAgent = { .claudeCode }
        #expect(e.chat.label(for: e.chat.status(of: said)).contains("Mac"))
    }
}
