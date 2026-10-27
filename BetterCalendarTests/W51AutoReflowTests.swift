//
//  W51AutoReflowTests.swift
//  BetterCalendarTests
//
//  W51（0.80，Jason 2026-10-27）：自动顺延——落后 10 分钟本地按原顺序往后挪（固定 / 图钉 / 正在做的 / 你的日历是障碍），
//  走审批中心的自动顺延规则直接执行（可撤回）、发回执消息、「我在做」= 撤回 + 从原开始时间起计时；
//  只在推过收工线 / 同一块二次漂 / 放不下时叫智能体。哨兵摘要补共享记忆 / 对话 / 待批提案 / 明天的计划。
//  内存 SwiftData、注入时钟、一次性 UserDefaults suite；不碰真 EventKit / 通知 / 网络。
//

import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

@MainActor @Suite struct W51AutoReflowTests {
    final class Clock { var now: Date
        init() { now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 11, minute: 12))! }
    }
    final class Progress: ExecutionProgressReading {
        var settledPlannedIDs: Set<UUID> = []
        var activePrediction: ActivePrediction?
    }
    final class Spy {
        var events: [(kind: String, payload: [String: Any])] = []
        var notices: [AgentMessageDraft] = []
        var timers: [(id: UUID, at: Date)] = []
    }

    struct Rig {
        let container: ModelContainer
        let clock: Clock
        let plans: PlanStore
        let center: ProposalCenter
        let progress: Progress
        let monitor: PlanDriftMonitor
        let spy: Spy
    }

    func at(_ h: Int, _ m: Int = 0, _ c: Clock) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: c.now)! }

    func rig() throws -> Rig {
        let container = try ModelContainer(for: DataArchiveStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let clock = Clock(), progress = Progress(), spy = Spy()
        let plans = PlanStore(context: container.mainContext)
        let mover = ApprovedPlanMover(planStore: plans, projection: nil, startedDays: nil, now: { clock.now })
        mover.progress = progress
        mover.enabledFlag = { true }
        let executor = ProposalActionExecutor(items: LongTaskStore(context: container.mainContext), mover: mover, deviceId: "mac", now: { clock.now })
        let suite = "bc.w51.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let rules = PreauthRuleStore(defaults: defaults)
        var gate = PreauthRuleGate(store: rules)
        gate.lowRiskAutoPass = { false }   // 低风险自动通过关着也要能顺延（走的是专用规则）
        let center = ProposalCenter(transport: InMemoryProposalTransport(), gate: gate, rules: rules, executor: executor,
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(),
                                    deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        let monitor = PlanDriftMonitor(planStore: plans, defaults: defaults, now: { clock.now })
        monitor.progress = progress
        monitor.enabled = { true }
        monitor.windDown = { _ in Calendar.current.date(bySettingHour: 15, minute: 30, second: 0, of: clock.now)! }
        monitor.submit = { await center.submit($0) }
        monitor.proposal = { id in center.proposals.first { $0.id == id } }
        monitor.undo = { await center.undo($0) }
        monitor.notify = { d in spy.notices.append(d); return nil }
        monitor.emit = { kind, _, payload in spy.events.append((kind, payload)) }
        monitor.startTimer = { id, at in spy.timers.append((id, at)) }
        return Rig(container: container, clock: clock, plans: plans, center: center, progress: progress, monitor: monitor, spy: spy)
    }

    /// A 11:00–12:00 弹性（没开始）· B 12:00–13:00 弹性 · C 13:00–14:00 固定 · D 14:00–15:00 弹性。现在 11:12。
    func seed(_ r: Rig) throws -> (a: UUID, b: UUID, c: UUID, d: UUID) {
        let c = r.clock
        let a = ScheduledBlock(title: "写论文", start: at(11, 0, c), end: at(12, 0, c))
        let b = ScheduledBlock(title: "整理笔记", start: at(12, 0, c), end: at(13, 0, c))
        let fixed = ScheduledBlock(title: "组会", start: at(13, 0, c), end: at(14, 0, c), isFixed: true)
        let d = ScheduledBlock(title: "跑步", start: at(14, 0, c), end: at(15, 0, c))
        try r.plans.replacePlanned([a, b, fixed, d], on: Calendar.current.startOfDay(for: c.now))
        return (a.id, b.id, fixed.id, d.id)
    }

    func blocks(_ r: Rig) throws -> [UUID: ScheduledBlock] {
        Dictionary(uniqueKeysWithValues: try r.plans.plannedBlocks(on: Calendar.current.startOfDay(for: r.clock.now)).map { ($0.id, $0) })
    }

    // MARK: 纯规则

    @Test func detectsOnlyFlexibleUnsettledBlocksTenMinutesLate() throws {
        let r = try rig()
        let ids = try seed(r)
        let c = r.clock
        var input = PlanDriftRules.Input(blocks: Array(try blocks(r).values), now: c.now)
        #expect(PlanDriftRules.detect(input) == .notStarted(id: ids.a, title: "写论文", minutesLate: 12))
        c.now = at(11, 8, c); input.now = c.now
        #expect(PlanDriftRules.detect(input) == nil)                                   // 没到 10 分钟
        c.now = at(11, 12, c); input.now = c.now
        input.settledIDs = [ids.a]
        #expect(PlanDriftRules.detect(input) == nil)                                   // 已完成 / 并行中的不算
        input.settledIDs = []
        input.active = ActivePrediction(id: ids.a, start: at(11, 0, c), end: at(12, 0, c))
        #expect(PlanDriftRules.detect(input) == nil)                                   // 正在计时、没超时
        c.now = at(13, 12, c); input.now = c.now
        input.active = nil
        #expect(PlanDriftRules.detect(input) == nil)                                   // 固定安排「组会」不算漂；B 已整块过去（不追）；D 未到
        input.active = ActivePrediction(id: ids.b, start: at(12, 0, c), end: at(13, 14, c))
        #expect(PlanDriftRules.detect(input) == .overrun(id: ids.b, title: "整理笔记", minutesOver: 12))
    }

    @Test func reflowKeepsOrderAndDurationRoutesAroundFixedAndFlagsBeyondWindDown() throws {
        let r = try rig()
        let ids = try seed(r)
        let c = r.clock
        let input = PlanDriftRules.Input(blocks: Array(try blocks(r).values), now: c.now)
        let plan = try #require(PlanDriftRules.reflow(input, windDown: at(15, 30, c)))
        let by = Dictionary(uniqueKeysWithValues: plan.moves.map { ($0.id, $0) })
        #expect(by[ids.a]?.start == at(11, 12, c) && by[ids.a]?.end == at(12, 12, c))
        #expect(by[ids.b]?.start == at(14, 0, c) && by[ids.b]?.end == at(15, 0, c))    // 撞上固定「组会」→ 绕到它后面
        #expect(by[ids.d]?.start == at(15, 0, c) && by[ids.d]?.end == at(16, 0, c))    // 被 B 推着走，顺序不变
        #expect(by[ids.c] == nil)                                                       // 固定安排不动
        #expect(plan.beyondWindDown == [ids.d])                                         // 16:00 > 15:30 + 10 分宽限
    }

    @Test func pinnedBlockIsAnObstacleNotAMovable() throws {
        let r = try rig()
        let ids = try seed(r)
        let c = r.clock
        try r.plans.setPinned(ids: [ids.b], until: at(23, 0, c))
        let input = PlanDriftRules.Input(blocks: Array(try blocks(r).values), now: c.now)
        let plan = try #require(PlanDriftRules.reflow(input, windDown: at(23, 0, c)))
        // A 11:12–12:12 撞上图钉 B（12:00–13:00）、再撞固定 C（13:00–14:00）→ 绕到 14:00；D 被 A 推到 15:00；B 不动
        #expect(plan.moves.map(\.id) == [ids.a, ids.d])
        let by = Dictionary(uniqueKeysWithValues: plan.moves.map { ($0.id, $0) })
        #expect(by[ids.a]?.start == at(14, 0, c) && by[ids.d]?.start == at(15, 0, c) && by[ids.b] == nil)
    }

    // MARK: 端到端：自动顺延提案 → 回执 → 撤回 / 我在做

    @Test func monitorAppliesSystemProposalPostsReceiptAndWakesAgentOnlyBeyondWindDown() async throws {
        let r = try rig()
        let ids = try seed(r)
        let c = r.clock
        let outcome = await r.monitor.tick()
        guard case let .reflowed(pid, moved) = outcome else { Issue.record("应已顺延：\(outcome) \(r.monitor.lastError ?? "")"); return }
        #expect(moved == 3)
        let p = try #require(r.center.proposals.first { $0.id == pid })
        #expect(p.origin == .system && p.state == .applied && p.preauth?.ruleId == PreauthPolicy.autoReflowRuleId)
        #expect(p.autoReflow == ids.a.uuidString)
        #expect(ProposalPresentation.headline(p).hasPrefix("已自动顺延："))
        let now = try blocks(r)
        #expect(now[ids.a]?.start == at(11, 12, c) && now[ids.b]?.start == at(14, 0, c) && now[ids.d]?.start == at(15, 0, c))
        #expect(now[ids.c]?.start == at(13, 0, c))
        // 回执：parentRef 指回提案，漂的是「没开始」→ 带「我在做」
        let notice = try #require(r.spy.notices.first)
        #expect(notice.parentRef == "reflow:\(pid.uuidString):notStarted")
        #expect(notice.title.contains("写论文") && notice.title.contains("11:12"))
        // D 推过了收工线 15:30 → 叫智能体（plan_reflowed）；只这一次
        #expect(r.spy.events.count == 1 && r.spy.events[0].kind == "plan_reflowed")
        let beyond = r.spy.events[0].payload["beyondWindDown"] as? [[String: Any]]
        #expect(beyond?.count == 1 && beyond?.first?["title"] as? String == "跑步")
        #expect(r.monitor.ledger.count == 1)
        // 顺延后 A 从 11:12 起，8 分钟后还没到「漂」的门槛 → 不再推
        c.now = at(11, 20, c)
        #expect(await r.monitor.tick() == .idle)
        // 「我在做」：撤回顺延 + 从 11:00 起计时
        #expect(await r.monitor.imDoing(proposalId: pid) == nil)
        let back = try blocks(r)
        #expect(back[ids.a]?.start == at(11, 0, c) && back[ids.b]?.start == at(12, 0, c) && back[ids.d]?.start == at(14, 0, c))
        #expect(r.spy.timers.count == 1 && r.spy.timers[0].id == ids.a && r.spy.timers[0].at == at(11, 0, c))
        #expect(r.center.proposals.first { $0.id == pid }?.undoneAt != nil)
        #expect(r.monitor.notes[pid]?.contains("从 11:00 起计时") == true)
    }

    @Test func overrunPushesFollowingBlocksFromPredictedEndWithoutDoingButton() async throws {
        let r = try rig()
        let ids = try seed(r)
        let c = r.clock
        c.now = at(12, 12, c)   // A 从 11:00 计到现在，超过计划结束 12 分钟；预计还要 3 分钟
        r.progress.activePrediction = ActivePrediction(id: ids.a, start: at(11, 0, c), end: at(12, 15, c))
        r.progress.settledPlannedIDs = [ids.a]
        let outcome = await r.monitor.tick()
        guard case .reflowed = outcome else { Issue.record("应已顺延：\(outcome) \(r.monitor.lastError ?? "")"); return }
        let now = try blocks(r)
        #expect(now[ids.a]?.start == at(11, 0, c))                                       // 正在做的不动
        #expect(now[ids.b]?.start == at(14, 0, c))                                       // 12:15 起放不下（撞固定 C）→ 14:00
        #expect(now[ids.d]?.start == at(15, 0, c))
        #expect(r.spy.notices.first?.parentRef.map { $0.hasSuffix(":overrun") } == true)
        #expect(LocalAgentMessageNotifier.categoryFor(AgentMessage(id: UUID(), createdAt: c.now, originLabel: "x", parentRef: r.spy.notices.first?.parentRef,
                                                                     title: "", body: "", reason: "", delivery: .delivered)) == LocalAgentMessageNotifier.category)
    }

    @Test func secondDriftOfSameBlockWakesAgent() async throws {
        let r = try rig()
        let ids = try seed(r)
        let c = r.clock
        r.monitor.windDown = { _ in Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: c.now)! }
        guard case .reflowed = await r.monitor.tick() else { Issue.record("第一次应顺延"); return }
        #expect(r.spy.events.isEmpty)                                                    // 没过收工线、第一次漂：智能体不开口
        c.now = at(11, 40, c)                                                            // A 已挪到 11:12，又过了 28 分钟没开始
        guard case .reflowed = await r.monitor.tick() else { Issue.record("第二次应顺延：\(r.monitor.lastOutcome.map { "\($0)" } ?? "")"); return }
        #expect(try blocks(r)[ids.a]?.start == at(11, 40, c))
        #expect(r.spy.events.count == 1 && r.spy.events[0].payload["driftCountToday"] as? Int == 2)
    }

    @Test func gatesSkipVisiblyAndTouchNothing() async throws {
        let r = try rig()
        _ = try seed(r)
        let c = r.clock
        r.monitor.enabled = { false }
        #expect(await r.monitor.tick() == .disabled)
        r.monitor.enabled = { true }
        r.monitor.isLooseDay = { _ in true }
        guard case let .skipped(why) = await r.monitor.tick(), why.contains("松散日") else { Issue.record("松散日应跳过"); return }
        r.monitor.isLooseDay = { _ in false }
        r.monitor.presenceGate = { "你此刻在「iPhone」" }
        guard case .skipped = await r.monitor.tick() else { Issue.record("别的设备在场应跳过"); return }
        r.monitor.presenceGate = { nil }
        r.monitor.syncCaution = { _ in "iCloud 同步卡住了" }
        guard case let .skipped(why2) = await r.monitor.tick(), why2.contains("数据可能不全") else { Issue.record("同步存疑应跳过"); return }
        #expect(r.center.proposals.isEmpty && r.spy.notices.isEmpty)
        #expect(try blocks(r).values.allSatisfy { $0.start.timeIntervalSince(at(11, 0, c)) >= 0 })
    }

    @Test func systemMoveWithoutMarkerStillAsksYou() async throws {
        let r = try rig()
        let ids = try seed(r)
        let c = r.clock
        let moves = [ProposalBlockMove(id: ids.b, start: at(14, 0, c), end: nil, expectedRevision: nil),
                     ProposalBlockMove(id: ids.d, start: at(15, 0, c), end: nil, expectedRevision: nil)]
        let draft = ProposalDraft(origin: .system, originLabel: "BetterCalendar", title: "两块", changes: [], reason: "测",
                                  action: .moveBlocks(moves: moves, isUndo: false), experiment: false)
        let p = try #require(await r.center.submit(draft), "提案没提交：\(r.center.lastError ?? "")")
        #expect(p.state == .pending && p.preauth == nil)
    }

    // MARK: 哨兵摘要补料

    @Test func sentinelDigestCarriesMemoryChatPendingAndTomorrowOnlyWhenGiven() throws {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
        var ctx = AgentContextInput(now: now)
        ctx.today.items = [.init(title: "写论文", start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(40 * 60), id: UUID())]
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        ctx.upcoming.items = [.init(title: "复习", start: tomorrow, end: tomorrow.addingTimeInterval(3600), id: UUID())]
        var input = SentinelDigestInput(now: now, context: ctx)
        let bare = SentinelDigestBuilder.build(input).text
        #expect(!bare.contains("【共享记忆") && !bare.contains("【最近 24 小时的对话】") && !bare.contains("【待 Jason 批的提案】") && !bare.contains("【明天的计划】"))
        input.sharedMemory = "晚上的题目可选，别催。"
        input.recentChat = [(now.addingTimeInterval(-3600), true, "醒了说一声再捋"), (now.addingTimeInterval(-30 * 3600), false, "太早的不算")]
        input.pendingProposals = [(now.addingTimeInterval(-600), "挪「写论文」到 14:00")]
        input.tomorrow = ctx.upcoming.items
        let text = SentinelDigestBuilder.build(input).text
        #expect(text.contains("【智能体的共享记忆") && text.contains("晚上的题目可选，别催"))
        #expect(text.contains("Jason：醒了说一声再捋") && !text.contains("太早的不算"))
        #expect(text.contains("【待 Jason 批的提案】") && text.contains("挪「写论文」到 14:00"))
        #expect(text.contains("【明天的计划】共 1 块") && text.contains("复习"))
    }

    @Test func messageRefRoundTrips() {
        let id = UUID()
        let ref = PlanDriftRules.messageRef(proposalId: id, drift: .notStarted(id: UUID(), title: "x", minutesLate: 10))
        let parsed = PlanDriftRules.parseMessageRef(ref)
        #expect(parsed?.proposalId == id && parsed?.kind == "notStarted")
        #expect(PlanDriftRules.parseMessageRef("proposal:\(id.uuidString)") == nil && PlanDriftRules.parseMessageRef(nil) == nil)
    }
}
