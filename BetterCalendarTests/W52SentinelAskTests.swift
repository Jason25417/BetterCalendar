//
//  W52SentinelAskTests.swift
//  BetterCalendarTests
//
//  W52（0.80，Jason 2026-10-27）：哨兵判断「像是开始了 / 像是停了」→ App 直接问（带按钮），答案直接执行。
//  摘要候选与问答记录 · 判断器多答 started / stopped · 引擎按提问线问、冷却 / 上限 / 关掉都不问 · 回答：在做 = 计时（有顺延就撤回）、停了 = 结束计时、
//  没在做 = 记下不再问。一次性 UserDefaults suite；不碰网络 / 通知。
//

import Foundation
import Testing
@testable import BetterCalendar

@MainActor @Suite struct W52SentinelAskTests {
    static let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
    func defaults() -> UserDefaults { UserDefaults(suiteName: "bc-ask-" + UUID().uuidString)! }

    func context(_ now: Date, running: Bool = false) -> (AgentContextInput, UUID) {
        var c = AgentContextInput(now: now)
        let id = UUID()
        c.today.items = [
            .init(title: "写论文", start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(40 * 60), id: id),
            .init(title: "组会", start: now.addingTimeInterval(2 * 3600), end: now.addingTimeInterval(3 * 3600), isFixed: true, id: UUID()),
        ]
        if running { c.running.foreground = .init(title: "写论文", start: now.addingTimeInterval(-20 * 60)) }
        return (c, id)
    }

    // MARK: 摘要

    @Test func digestListsStartedCandidateWithReflowOriginAndAskHistory() {
        let now = Self.noon
        let (ctx, id) = context(now)
        var input = SentinelDigestInput(now: now, context: ctx)
        var d = SentinelDigestBuilder.build(input)
        #expect(d.facts.askStarted?.id == id && d.facts.askStarted?.minutesSinceStart == 20 && d.facts.askStopped == nil)
        #expect(d.text.contains("【可以问他的】可能已开始但没计时：「写论文」（计划 11:40 开始，已过 20 分）"))
        input.recentReflows = [(id, now.addingTimeInterval(-50 * 60), now.addingTimeInterval(-20 * 60))]
        input.recentAsks = [(now.addingTimeInterval(-10 * 60), "started", "写论文", "no")]
        d = SentinelDigestBuilder.build(input)
        #expect(d.facts.askStarted?.reflowedFrom == now.addingTimeInterval(-50 * 60))
        #expect(d.text.contains("已自动顺延，原定 11:10") && d.text.contains("原定 11:10，已自动顺延到 11:40"))
        #expect(d.text.contains("【最近 24 小时问过他】11:50 在做「写论文」吗 → 没在做"))
    }

    @Test func digestListsStoppedCandidateWhenTimerRunsAndHeIsAway() {
        let now = Self.noon
        let (ctx, id) = context(now, running: true)
        let events = [ActivityEvent(at: now.addingTimeInterval(-40 * 60), kind: .appActivated, deviceId: "mac", platform: "macOS", appName: "Pages"),
                      ActivityEvent(at: now.addingTimeInterval(-18 * 60), kind: .screenLocked, deviceId: "mac", platform: "macOS")]
        let d = SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: ctx, activity: events))
        #expect(d.facts.askStarted == nil)   // 正在计时的不算「没开始」
        #expect(d.facts.askStopped == .init(id: id, title: "写论文", awayMinutes: 18))
        #expect(d.text.contains("正在计时、可能已停下：「写论文」（已离开电脑 18 分）"))
    }

    // MARK: 判断器

    @Test func ruleJudgeAnswersStartedAndStopped() async throws {
        let now = Self.noon
        let (ctx, _) = context(now)
        let j1 = try await RuleSentinelJudge().judge(SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: ctx)))
        #expect(j1.verdict.started == 0.7 && j1.verdict.stopped == 0)
        let (running, _) = context(now, running: true)
        let away = [ActivityEvent(at: now.addingTimeInterval(-18 * 60), kind: .screenLocked, deviceId: "mac", platform: "macOS")]
        let j2 = try await RuleSentinelJudge().judge(SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: running, activity: away)))
        #expect(j2.verdict.started == 0 && j2.verdict.stopped == 0.8)
    }

    @Test func jevCarriesStartedAndStoppedProbabilities() async throws {
        let reply: [String: Any] = [
            "answers": ["wake": ["type": "noul", "noul": 0.2], "category": ["type": "choice", "choice": "other"],
                        "urgency": ["type": "score", "score": 0.1], "started": ["type": "noul", "noul": 0.83], "stopped": ["type": "noul", "noul": 0.05]],
            "usage": ["cost": 0.00002, "input_tokens": 500, "output_tokens": 90],
        ]
        nonisolated(unsafe) var captured: URLRequest?
        let jev = JevSentinelJudge(apiKey: { "k" }, transport: { req in
            captured = req
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let (ctx, _) = context(Self.noon)
        let j = try await jev.judge(SentinelDigestBuilder.build(SentinelDigestInput(now: Self.noon, context: ctx)))
        #expect(j.verdict.started == 0.83 && j.verdict.stopped == 0.05 && j.verdict.probability == 0.2)
        let body = try JSONSerialization.jsonObject(with: try #require(captured).httpBody!) as! [String: Any]
        let q = body["questions"] as! [String: Any]
        #expect((q["started"] as? [String: Any])?["type"] as? String == "noul" && (q["stopped"] as? [String: Any])?["type"] as? String == "noul")
    }

    // MARK: 问与答

    final class Spy {
        var drafts: [AgentMessageDraft] = []
        var timers: [(UUID, Date)] = []
        var stops = 0
        var acks: [UUID] = []
        var imDoing: [UUID] = []
    }

    func center(_ spy: Spy, now: @escaping () -> Date) -> SentinelAskCenter {
        let c = SentinelAskCenter(defaults: defaults(), now: now)
        c.notify = { d in spy.drafts.append(d); return AgentMessage(id: d.id ?? UUID(), createdAt: now(), originLabel: d.originLabel, parentRef: d.parentRef,
                                                                     title: d.title, body: d.body, reason: d.reason, delivery: .delivered) }
        c.acknowledge = { spy.acks.append($0) }
        c.startTimer = { id, at in spy.timers.append((id, at)) }
        c.stopTimer = { spy.stops += 1 }
        c.imDoing = { pid in spy.imDoing.append(pid); return nil }
        return c
    }

    @Test func askThenYesStartsTimerFromBlockStartOrUndoesReflow() async throws {
        let spy = Spy()
        var t = Self.noon
        let c = center(spy) { t }
        let block = UUID(), start = Self.noon.addingTimeInterval(-20 * 60)
        var settings = SentinelSettings()
        #expect(await c.ask(SentinelAsk(kind: .started, blockId: block, title: "写论文", start: start, probability: 0.8), settings: settings))
        let d = try #require(spy.drafts.first)
        #expect(d.title == "在做「写论文」吗？" && d.parentRef == "ask:started:\(block.uuidString)" && d.body.contains("11:40"))
        #expect(LocalAgentMessageNotifier.categoryFor(AgentMessage(id: UUID(), createdAt: t, originLabel: "x", parentRef: d.parentRef, title: "", body: "",
                                                                     reason: "", delivery: .delivered)) == LocalAgentMessageNotifier.askStartedCategory)
        // 刚问过还没答 → 不再问；答「在做」→ 从那块开始时间起计时
        #expect(c.cannotAskReason(.init(kind: .started, blockId: block, title: "写论文", start: start, probability: 0.9), settings: settings)?.contains("还没回答") == true)
        #expect(await c.answer(messageId: d.id!, yes: true) == nil)
        #expect(spy.timers.count == 1 && spy.timers[0].0 == block && spy.timers[0].1 == start && spy.acks == [d.id!])
        #expect(c.notes[d.id!]?.contains("已开始计时") == true)
        #expect(c.recentAsks().first?.answer == "yes")
        // 有未撤回的自动顺延 → 「在做」走撤回 + 原定时间
        t = t.addingTimeInterval(2 * 3600)
        settings.askCooldownMinutes = 1
        let pid = UUID()
        c.reflowProposalFor = { $0 == block ? pid : nil }
        #expect(await c.ask(SentinelAsk(kind: .started, blockId: block, title: "写论文", start: start, probability: 0.7), settings: settings))
        #expect(spy.drafts.last?.body.contains("顺延撤回") == true)
        #expect(await c.answer(messageId: spy.drafts.last!.id!, yes: true) == nil)
        #expect(spy.imDoing == [pid] && spy.timers.count == 1)
    }

    @Test func noTwiceStopsAskingThatBlockTodayAndStoppedYesEndsTimer() async throws {
        let spy = Spy()
        var t = Self.noon
        let c = center(spy) { t }
        let block = UUID()
        var settings = SentinelSettings(); settings.askCooldownMinutes = 1
        let ask = SentinelAsk(kind: .started, blockId: block, title: "写论文", start: t, probability: 0.7)
        #expect(await c.ask(ask, settings: settings))
        #expect(await c.answer(messageId: spy.drafts[0].id!, yes: false) == nil)
        #expect(c.notes[spy.drafts[0].id!]?.contains("没在做") == true && spy.timers.isEmpty)
        t = t.addingTimeInterval(120)
        #expect(await c.ask(ask, settings: settings))
        #expect(await c.answer(messageId: spy.drafts[1].id!, yes: false) == nil)
        t = t.addingTimeInterval(120)
        #expect(c.cannotAskReason(ask, settings: settings)?.contains("两次说没在做") == true)
        #expect(await c.ask(ask, settings: settings) == false && spy.drafts.count == 2)
        // 停了吗 → 停了 = 结束计时
        let stopAsk = SentinelAsk(kind: .stopped, blockId: block, title: "写论文", start: nil, probability: 0.9)
        #expect(await c.ask(stopAsk, settings: settings))
        #expect(spy.drafts.last?.title == "「写论文」停下来了吗？")
        #expect(await c.answer(messageId: spy.drafts.last!.id!, yes: true) == nil)
        #expect(spy.stops == 1)
    }

    @Test func dailyCapAndCooldownAreVisibleReasons() async throws {
        let spy = Spy()
        var t = Self.noon
        let c = center(spy) { t }
        var settings = SentinelSettings(); settings.askCooldownMinutes = 90; settings.askDailyCap = 2
        let ask = SentinelAsk(kind: .stopped, blockId: UUID(), title: "整理", start: nil, probability: 0.7)
        #expect(await c.ask(ask, settings: settings))
        #expect(await c.answer(messageId: spy.drafts[0].id!, yes: true) == nil)
        t = t.addingTimeInterval(30 * 60)
        #expect(c.cannotAskReason(ask, settings: settings)?.contains("90 分钟内问过") == true)
        t = t.addingTimeInterval(61 * 60)
        #expect(await c.ask(ask, settings: settings))
        #expect(await c.answer(messageId: spy.drafts[1].id!, yes: true) == nil)
        t = t.addingTimeInterval(91 * 60)
        #expect(c.cannotAskReason(ask, settings: settings)?.contains("到上限") == true)
    }

    // MARK: 引擎

    @Test func engineAsksWhenProbabilityPassesAskThresholdAndLogsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bc-ask-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Self.noon
        let (ctx, id) = context(now)
        let judge = FakeJudge(wake: false, kind: .jev)
        judge.verdict.probability = 0.1
        judge.verdict.started = 0.72
        let log = MemorySentinelDecisionLog()
        let e = SentinelEngine(judges: [judge], log: log, bridge: DirectorySentinelBridge(root: root), activity: MemoryActivityLog([]),
                               defaults: defaults(), now: { now }) { _ in ctx }
        var a = AttentionSettings(); a.quietStartHour = 0; a.quietEndHour = 0
        e.attention = { a }
        let spy = Spy()
        let asks = center(spy) { now }
        e.askCenter = asks
        await e.runNow()
        #expect(spy.drafts.count == 1 && spy.drafts[0].parentRef == "ask:started:\(id.uuidString)")
        #expect(log.rows.last?.asked == "started:写论文" && log.rows.last?.outcome == .noWake)
        #expect(e.asksToday.count == 1)
        // 关掉 → 不问；没过线 → 不问
        e.settings.askEnabled = false
        await e.runNow()
        e.settings.askEnabled = true
        judge.verdict.started = 0.4
        await e.runNow()
        #expect(spy.drafts.count == 1)
    }
}
