//
//  BuiltinAgentRuntime.swift
//  BetterCalendar
//
//  W20：App 内置的 BetterCalendar 智能体（DeepSeek）。事件在进程内送达（不经桥接文件）：
//    user_message · block_finished · proposal_resolved · evening_review · calendar_user_deleted · sentinel_wake（只 Mac）。
//  运行方式：
//    · 串行：同一时刻只跑一轮；跑的时候新来的事件排队，下一轮**合并**成一批一起看（一阵连发只叫醒一次）。
//    · 每轮有步数上限（模型调用次数）与总超时；碰到就停下、直说。
//    · 每次调用前查当日预算（稳定性上限），用完就停下、直说。
//    · 只在「当前智能体 = 内置」时有通道（产品原则 9）；跑不了不切别的实现（原则 10），在对话与状态区写明哪里坏了、你能做什么。
//  iOS 后台：只在 App 活着时跑（前台、或推送 / 后台刷新唤醒的那几十秒）；每轮申请一段后台执行时间，
//  被系统收回就停在那里（那条消息显示「超过 10 分钟没回复」，可以重说）；还没开始处理的你的消息，下次 App 活过来时接着处理。
//

import Foundation
import Observation

/// 一个送给智能体的事件（与桥接 events/*.json 同一套 kind / summary / payload）。
@MainActor struct AgentEvent {
    let id: String
    let kind: String
    let summary: String
    let payload: [String: Any]
    let at: Date

    init(kind: String, summary: String, payload: [String: Any] = [:], at: Date) {
        self.id = "\(kind)-\(UUID().uuidString.prefix(8))"
        self.kind = kind; self.summary = summary; self.payload = payload; self.at = at
    }

    var json: [String: Any] {
        ["id": id, "kind": kind, "summary": summary, "payload": payload, "at": ISO8601DateFormatter().string(from: at)]
    }
}

/// 内置智能体跑不了 / 停下的原因：哪里坏了 + 你能做什么（不暗减、不让你猜）。
nonisolated enum BuiltinAgentProblem: Error, LocalizedError, Equatable {
    case missingResource(String)
    case unknownPricing(String)
    case budgetReached(spent: Double, budget: Double)
    case turnLimit(Int)
    case timeout(Int)
    case model(DeepSeekError)

    var errorDescription: String? { message }
    var message: String {
        switch self {
        case let .missingResource(name): "App 里缺少内置智能体的资源文件 \(name)"
        case let .unknownPricing(m): "不认识模型 \(m) 的价格，没法按预算记账，已停下"
        case let .budgetReached(spent, budget): String(format: "今天内置智能体的预算已用完（约 $%.3f / $%.2f），已停下", spent, budget)
        case let .turnLimit(n): "这一轮绕了 \(n) 步还没结束，已停下（防止空转）"
        case let .timeout(s): "这一轮超过 \(s) 秒还没结束，已停下"
        case let .model(e): e.message
        }
    }
    var hint: String {
        switch self {
        case .missingResource: "这是 App 的问题；请告诉开发会话，或先把当前智能体切回 Claude Code"
        case .unknownPricing: "到 设置 → 智能体 选一个列出的模型"
        case .budgetReached: "到 设置 → 智能体 调高每日预算，或明天再说；也可以切回 Claude Code"
        case .turnLimit, .timeout: "换个更具体的说法再说一次；常发生请告诉开发会话"
        case let .model(e): e.hint
        }
    }
}

nonisolated struct BuiltinAgentRunSummary: Equatable, Sendable {
    var at: Date
    var kinds: [String]
    var turns: Int
    var costUSD: Double
    var replies: Int
    var proposals: Int
    var problem: String?
}

/// 模型调用的缝（生产 = DeepSeekClient；单测 = 假实现）。
@MainActor protocol BuiltinAgentModel {
    func complete(model: String, messages: [DeepSeekMessage], tools: Data) async throws -> DeepSeekCompletion
}

extension DeepSeekClient: BuiltinAgentModel {
    func complete(model: String, messages: [DeepSeekMessage], tools: Data) async throws -> DeepSeekCompletion {
        try await complete(model: model, messages: messages, tools: tools, maxTokens: 2048)
    }
}

@MainActor @Observable final class BuiltinAgentRuntime {
    // —— 给界面 ——
    private(set) var isRunning = false
    private(set) var lastRun: BuiltinAgentRunSummary?
    /// 最近一次跑不了 / 停下的原因（你点「知道了」前一直显示）。
    private(set) var problem: BuiltinAgentProblem?
    private(set) var problemAt: Date?
    private(set) var queuedCount = 0

    // —— 配置（稳定性参数，不是产品规则）——
    var maxTurns = 8
    var runTimeout: TimeInterval = 120
    /// 收到事件后等一小会儿再开跑，把一阵连发并成一轮。
    var debounce: TimeInterval = 1.5
    /// 生产 = true：enqueue 自动起一个串行工作任务；测试 = false，手动 `await processPending()`（不留游离 Task）。
    var autoStart = true

    var isActive: () -> Bool = { false }
    /// iOS：每轮申请后台执行时间（返回「结束」回调）；macOS / 测试 = 不需要。
    var beginBackgroundWork: (String) -> (() -> Void) = { _ in {} }
    /// 本机设备名（系统提示里写「你在哪台设备上被叫醒」）。
    var deviceLabel = "这台设备"
    /// 本轮成功结束后（哨兵用：智能体忙不忙）。
    var onRunStateChange: ((Bool) -> Void)?

    private let model: any BuiltinAgentModel
    let tools: BuiltinAgentToolbox
    let usage: BuiltinAgentUsageStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private let promptLoader: () throws -> String
    private let toolsLoader: () throws -> Data
    private var queue: [AgentEvent] = []
    private var worker: Task<Void, Never>?

    init(model: any BuiltinAgentModel, tools: BuiltinAgentToolbox, usage: BuiltinAgentUsageStore, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         promptLoader: @escaping () throws -> String = BuiltinAgentRuntime.loadPrompt,
         toolsLoader: @escaping () throws -> Data = { try BuiltinAgentToolbox.loadDefinitions() }) {
        self.model = model; self.tools = tools; self.usage = usage; self.defaults = defaults; self.now = now
        self.promptLoader = promptLoader; self.toolsLoader = toolsLoader
    }

    nonisolated static func loadPrompt() throws -> String {
        guard let url = Bundle.main.url(forResource: "BuiltinAgentPrompt", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            throw BuiltinAgentProblem.missingResource("BuiltinAgentPrompt.md")
        }
        return text
    }

    func clearProblem() { problem = nil; problemAt = nil }

    // MARK: 事件

    /// 送一个事件。没接通（当前智能体不是内置）→ 什么都不做：没有通道。
    func enqueue(_ event: AgentEvent) {
        guard isActive() else { return }
        // 哨兵连发只留最新一条，其余理由并进去（同一阵的叫醒合并成一次）。
        if event.kind == "sentinel_wake", let i = queue.lastIndex(where: { $0.kind == "sentinel_wake" }) {
            var payload = event.payload
            var merged = (payload["coalesced"] as? [[String: Any]]) ?? []
            merged.append(["at": ISO8601DateFormatter().string(from: queue[i].at), "reason": queue[i].payload["reason"] ?? queue[i].summary])
            payload["coalesced"] = merged
            queue[i] = AgentEvent(kind: event.kind, summary: event.summary, payload: payload, at: event.at)
        } else {
            queue.append(event)
        }
        queuedCount = queue.count
        DevLog.shared.info("内置智能体", "收到事件 \(event.kind)：\(event.summary.prefix(60))")
        guard autoStart, worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            if self.debounce > 0 { try? await Task.sleep(for: .seconds(self.debounce)) }
            await self.processPending()
            self.worker = nil
            if !self.queue.isEmpty, self.isActive() { self.restartWorker() }
        }
    }

    private func restartWorker() {
        guard worker == nil, autoStart else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.processPending()
            self.worker = nil
        }
    }

    /// 切走（当前智能体不再是内置）：丢掉排队的事件（它们属于这个通道），不再跑。
    func deactivate() {
        if !queue.isEmpty { DevLog.shared.info("内置智能体", "已切走，丢弃排队的 \(queue.count) 个事件") }
        queue.removeAll(); queuedCount = 0
        worker?.cancel(); worker = nil
    }

    /// 把队列里的事件合并成一轮跑完（串行；跑的时候新来的留到下一轮）。
    func processPending() async {
        while !queue.isEmpty, isActive(), !isRunning {
            let batch = queue
            queue.removeAll(); queuedCount = 0
            await run(batch)
        }
    }

    // MARK: 一轮

    func run(_ events: [AgentEvent]) async {
        guard isActive(), !events.isEmpty else { return }
        isRunning = true; onRunStateChange?(true)
        let endBackground = beginBackgroundWork("BetterCalendar 智能体")
        defer { isRunning = false; onRunStateChange?(false); endBackground() }
        let ledger = BuiltinAgentRunLedger()
        // 你的消息：一接手就写「已转交」回执（各端显示「智能体已收到」，也防止重复处理）。
        let userMessageIds = events.filter { $0.kind == "user_message" }.compactMap { ($0.payload["messageId"] as? String).flatMap(UUID.init) }
        for id in userMessageIds { await tools.chat.markForwarded(id) }
        usage.recordRun()
        let counters = RunCounters()
        var outcome: BuiltinAgentProblem?
        do {
            try await Self.withTimeout(runTimeout) { [self] in
                try await loop(events, ledger: ledger, counters: counters)
            }
        } catch let p as BuiltinAgentProblem {
            outcome = p
        } catch is CancellationError {
            outcome = .timeout(Int(runTimeout.rounded(.up)))
        } catch let e as DeepSeekError {
            outcome = .model(e)
        } catch {
            outcome = .model(DeepSeekError(kind: .network, message: error.localizedDescription, hint: "稍后再说一次"))
        }
        // 他在等回复、这一轮却没回到他：直说（不假装回了）。
        let unanswered = userMessageIds.filter { !ledger.repliedTo.contains($0) }
        if let outcome {
            await report(outcome, unanswered: unanswered)
        } else if !unanswered.isEmpty, ledger.replies == 0 {
            DevLog.shared.warn("内置智能体", "这一轮没有回复 Jason 的消息")
            await say("（内置智能体）这一轮我没能组织出回复。可以换个说法再说一次。", replyTo: unanswered.last)
        }
        lastRun = BuiltinAgentRunSummary(at: now(), kinds: events.map(\.kind), turns: counters.turns, costUSD: counters.cost, replies: ledger.replies,
                                         proposals: ledger.proposals.count, problem: outcome?.message)
        if outcome == nil { DevLog.shared.resolve(source: "内置智能体") }
    }

    private final class RunCounters { var turns = 0; var cost = 0.0 }

    private func loop(_ events: [AgentEvent], ledger: BuiltinAgentRunLedger, counters: RunCounters) async throws {
        let modelName = BuiltinAgentSettings.model(defaults)
        guard DeepSeekPricing.offPeak(modelName) != nil else { throw BuiltinAgentProblem.unknownPricing(modelName) }
        let toolDefs = try toolsLoader()
        var messages: [DeepSeekMessage] = [.system(try systemPrompt()), .user(Self.eventMessage(events))]
        let parent = events.count == 1 ? events[0].id : events.last?.id
        while true {
            try Task.checkCancellation()
            if let budget = BuiltinAgentSettings.budget(defaults) {   // 默认不设预算（Jason 10-19）；设了才按它停
                let spent = usage.today.costUSD
                guard spent < budget else { throw BuiltinAgentProblem.budgetReached(spent: spent, budget: budget) }
            }
            guard counters.turns < maxTurns else { throw BuiltinAgentProblem.turnLimit(maxTurns) }
            counters.turns += 1
            let completion = try await model.complete(model: modelName, messages: messages, tools: toolDefs)
            let c = DeepSeekPricing.cost(completion.usage, model: modelName, at: now()) ?? 0
            usage.record(completion.usage, cost: c)
            counters.cost += c
            messages.append(completion.message)
            guard let calls = completion.message.toolCalls, !calls.isEmpty else {
                // 模型说完了。纯文字 Jason 看不到：要是他在等回复、它却没调 reply_jason，就把它的原话作为回复送到（同一个智能体的话，不是替身）。
                if let text = completion.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                   let waiting = events.last(where: { $0.kind == "user_message" }),
                   let mid = (waiting.payload["messageId"] as? String).flatMap(UUID.init), !ledger.repliedTo.contains(mid) {
                    let args = try JSONSerialization.data(withJSONObject: ["text": String(text.prefix(1000)), "replyTo": mid.uuidString])
                    _ = await tools.call("reply_jason", arguments: String(decoding: args, as: UTF8.self), eventId: waiting.id, ledger: ledger)
                }
                return
            }
            for call in calls {
                try Task.checkCancellation()
                let result = await tools.call(call.function.name, arguments: call.function.arguments, eventId: parent, ledger: ledger)
                messages.append(.tool(call.id, result))
            }
        }
    }

    /// 系统提示 = 资源文件（可编辑）+ 此刻的时间与设备 + 共享记忆全文。
    func systemPrompt() throws -> String {
        let base = try promptLoader()
        let f = ISO8601DateFormatter(); f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        let memory = AgentSharedMemoryStore.markdown(tools.memory.memory)
        return base + "\n\n## 此刻\n- 时间：\(f.string(from: now()))（时区 \(TimeZone.current.identifier)；今天的逻辑日 \(DayContext.dayKey(now()))）\n- 你在「\(deviceLabel)」上被叫醒\n\n## 共享记忆（这个角色的长期记忆，各实现共用；改写用 update_shared_memory）\n\n" + memory
    }

    static func eventMessage(_ events: [AgentEvent]) -> String {
        let body = (try? JSONSerialization.data(withJSONObject: ["events": events.map(\.json)], options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "本轮事件（\(events.count) 个，按时间先后；一起看、回应一次就好）：\n\(body)"
    }

    // MARK: 失败可见

    private func report(_ p: BuiltinAgentProblem, unanswered: [UUID]) async {
        problem = p; problemAt = now()
        DevLog.shared.error("内置智能体", "\(p.message)。你可以：\(p.hint)")
        // 他在等回复时，在对话里直说（回执已写，「正在想」不能一直挂着）；其余事件只进状态区与日志，不刷屏。
        if let last = unanswered.last {
            await say("（内置智能体没能回复）\(p.message)。你可以：\(p.hint)", replyTo: last)
        }
    }

    private func say(_ text: String, replyTo: UUID?) async {
        let draft = AgentChatReplyDraft(id: UUID(), text: text, kind: .chat, replyTo: replyTo, originLabel: AgentKind.builtin.originLabel)
        if await tools.chat.receiveAgent(draft) == nil {
            DevLog.shared.error("内置智能体", "连「没能回复」的说明也没存进对话：\(tools.chat.lastError ?? "")")
        }
    }

    // MARK: 超时

    private static func withTimeout(_ seconds: TimeInterval, _ op: @escaping @MainActor () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in try await op(); return true }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); return false }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return }
            if !first { throw BuiltinAgentProblem.timeout(Int(seconds.rounded(.up))) }
        }
    }
}
