//
//  W32dLowRiskTests.swift
//  BetterCalendarTests
//
//  W32d（Jason 2026-10-20）：「低风险改动自动通过」——App 规则（不是智能体的判断）。每个档位的边界各一条：
//  能自动通过的（单块加 / 挪 / 改时长改名、建提醒）· 照旧要卡的（越级、图钉、闹钟、排一天、多块、改固定、删除、
//  备选 / 参数、智能体标了先问、开关关着、你写的 deny / ask 规则）。复用 W10 预授权的执行 + 撤销路径。
//  内存 SwiftData（cloudKitDatabase: .none）、注入时钟、一次性 UserDefaults suite；不碰真 EventKit / 通知。
//

import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

@MainActor @Suite struct W32dLowRiskTests {
    final class Clock { var now: Date
        init() { now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10))! }
    }
    final class Progress: ExecutionProgressReading {
        var settledPlannedIDs: Set<UUID> = []
        var activePrediction: ActivePrediction?
    }

    struct Rig {
        let container: ModelContainer
        let clock: Clock
        let plans: PlanStore
        let rules: PreauthRuleStore
        let center: ProposalCenter
        let suite: String
        let lowRisk: Flag
    }
    final class Flag { var on = true }

    func rig() throws -> Rig {
        let container = try ModelContainer(for: DataArchiveStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let clock = Clock(), flag = Flag()
        let plans = PlanStore(context: container.mainContext)
        let mover = ApprovedPlanMover(planStore: plans, projection: nil, startedDays: nil, now: { clock.now })
        mover.progress = Progress()
        mover.enabledFlag = { true }
        let executor = ProposalActionExecutor(items: LongTaskStore(context: container.mainContext), mover: mover, deviceId: "mac", now: { clock.now })
        let suite = "bc.w32d.\(UUID().uuidString)"
        let rules = PreauthRuleStore(defaults: UserDefaults(suiteName: suite)!)
        var gate = PreauthRuleGate(store: rules)
        gate.lowRiskAutoPass = { flag.on }
        let center = ProposalCenter(transport: InMemoryProposalTransport(), gate: gate, rules: rules, executor: executor,
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(),
                                    deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        return Rig(container: container, clock: clock, plans: plans, rules: rules, center: center, suite: suite, lowRisk: flag)
    }

    func at(_ h: Int, _ m: Int = 0, _ c: Clock) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: c.now)! }

    func seed(_ r: Rig) throws -> (flex: UUID, fixed: UUID, other: UUID) {
        let c = r.clock
        let flex = ScheduledBlock(title: "整理笔记", start: at(11, 0, c), end: at(12, 0, c))
        let fixed = ScheduledBlock(title: "组会", start: at(14, 0, c), end: at(15, 0, c), isFixed: true)
        let other = ScheduledBlock(title: "跑步", start: at(18, 0, c), end: at(19, 0, c))
        try r.plans.replacePlanned([flex, fixed, other], on: Calendar.current.startOfDay(for: c.now))
        return (flex.id, fixed.id, other.id)
    }

    func draft(_ a: ProposalAction, askFirst: Bool = false, escalation: String? = nil,
               alternatives: [ProposalAlternative] = []) -> ProposalDraft {
        ProposalDraft(origin: .agent, originLabel: "BetterCalendar 智能体", title: "W32d", changes: [], reason: "他说的",
                      action: a, experiment: false, escalation: escalation, alternatives: alternatives, askFirst: askFirst)
    }

    func submitted(_ r: Rig, _ d: ProposalDraft) async throws -> Proposal {
        let p = try #require(await r.center.submit(d), "提案没提交：\(r.center.lastError ?? "")")
        await r.center.refresh()
        return try #require(r.center.proposals.first { $0.id == p.id })
    }

    // MARK: 能自动通过

    @Test func singleBlockMoveAutoPassesExecutesImmediatelyAndUndoes() async throws {
        let r = try rig(); defer { UserDefaults().removePersistentDomain(forName: r.suite) }
        let ids = try seed(r)
        let p = try await submitted(r, draft(.moveBlock(id: ids.flex, start: at(16, 0, r.clock), end: nil, expectedRevision: nil)))
        #expect(p.preauth?.ruleId == PreauthPolicy.lowRiskRuleId && p.preauth?.effect == .allow)
        #expect(p.state == .applied)
        let label = Calendar.current.startOfDay(for: r.clock.now)
        #expect(try r.plans.plannedBlocks(on: label).first { $0.id == ids.flex }?.start == at(16, 0, r.clock))
        #expect(r.center.ledger.records().contains { $0.event == "decided" && $0.detail.contains("低风险") })   // 审批记录里留底
        #expect(await r.center.undo(p.id))
        #expect(try r.plans.plannedBlocks(on: label).first { $0.id == ids.flex }?.start == at(11, 0, r.clock))
    }

    @Test func singleBlockCreateRetimeRenameAndReminderAutoPass() async throws {
        let r = try rig(); defer { UserDefaults().removePersistentDomain(forName: r.suite) }
        let ids = try seed(r)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: r.clock.now))!
        let create = ProposalNewBlock(id: UUID(), title: "读论文", start: at(9, 0, r.clock).addingTimeInterval(86_400),
                                      end: at(10, 0, r.clock).addingTimeInterval(86_400))
        let p1 = try await submitted(r, draft(.blockCreate(day: tomorrow, blocks: [create])))
        #expect(p1.preauth?.ruleId == PreauthPolicy.lowRiskRuleId && p1.state == .applied)
        let p2 = try await submitted(r, draft(.blockEdit(ProposalBlockEdit(id: ids.other, title: "慢跑", duration: 30 * 60))))
        #expect(p2.preauth?.ruleId == PreauthPolicy.lowRiskRuleId && p2.state == .applied)
        // 提醒：判定层面放行（执行要提醒事项能力，这里只验档位）
        let reminder = Proposal(id: UUID(), createdAt: r.clock.now, expiresAt: r.clock.now.addingTimeInterval(3600), origin: .agent,
                                originLabel: "智能体", originDeviceId: "mac", parentId: nil, targetDeviceId: nil, title: "提醒", changes: [],
                                reason: "他说", action: .reminder(id: UUID(), title: "交表", body: nil, fireAt: at(18, 0, r.clock), deviceId: nil),
                                experiment: false, state: .pending, decidedAt: nil, decidedByDeviceId: nil, appliedAt: nil, resultNote: nil)
        #expect(PreauthPolicy.lowRiskReason(reminder) == nil)
        #expect(PreauthPolicy.evaluate(reminder, rules: [], lowRiskAutoPass: true).route == .apply)
    }

    // MARK: 照旧要卡

    @Test func cardStillRequiredAtEveryBoundary() async throws {
        let r = try rig(); defer { UserDefaults().removePersistentDomain(forName: r.suite) }
        let ids = try seed(r)
        let label = Calendar.current.startOfDay(for: r.clock.now)
        // 图钉：哪怕只是改名
        try r.plans.setPinned(ids: [ids.other], until: at(23, 0, r.clock))
        let pinned = try await submitted(r, draft(.blockEdit(ProposalBlockEdit(id: ids.other, title: "慢跑"))))
        #expect(pinned.state == .pending && pinned.autoPassBlocker?.contains("图钉") == true)
        // 改固定 / 截止
        let fixedEdit = try await submitted(r, draft(.blockEdit(ProposalBlockEdit(id: ids.flex, isFixed: true))))
        #expect(fixedEdit.state == .pending)
        // 智能体标了先问
        let ask = try await submitted(r, draft(.moveBlock(id: ids.flex, start: at(16, 0, r.clock), end: nil, expectedRevision: nil), askFirst: true))
        #expect(ask.state == .pending)
        // 有备选
        let alt = ProposalAlternative(label: "挪到 17 点", action: .moveBlock(id: ids.flex, start: at(17, 0, r.clock), end: nil, expectedRevision: nil))
        let withAlt = try await submitted(r, draft(.moveBlock(id: ids.flex, start: at(16, 0, r.clock), end: nil, expectedRevision: nil), alternatives: [alt]))
        #expect(withAlt.state == .pending)
        // 排一天整组 / 多块一起挪 / 一次加两块
        let plan = try await submitted(r, draft(.planDay(day: label, steps: [.move(ProposalBlockMove(id: ids.flex, start: at(16, 0, r.clock), end: nil))], isUndo: false)))
        #expect(plan.state == .pending)
        let two = try await submitted(r, draft(.moveBlocks(moves: [ProposalBlockMove(id: ids.flex, start: at(16, 0, r.clock), end: nil),
                                                                   ProposalBlockMove(id: ids.other, start: at(20, 0, r.clock), end: nil)], isUndo: false),
                                               escalation: "跑步是图钉"))
        #expect(two.state == .pending)
        let twoNew = ProposalAction.blockCreate(day: label, blocks: [
            ProposalNewBlock(id: UUID(), title: "a", start: at(20, 0, r.clock), end: at(20, 30, r.clock)),
            ProposalNewBlock(id: UUID(), title: "b", start: at(21, 0, r.clock), end: at(21, 30, r.clock))])
        #expect(try await submitted(r, draft(twoNew)).state == .pending)
        // 新块是固定安排
        let fixedNew = ProposalAction.blockCreate(day: label, blocks: [ProposalNewBlock(id: UUID(), title: "c", start: at(20, 0, r.clock), end: at(20, 30, r.clock), isFixed: true)])
        #expect(try await submitted(r, draft(fixedNew)).state == .pending)
        // 一个都没被执行
        #expect(try r.plans.plannedBlocks(on: label).first { $0.id == ids.flex }?.start == at(11, 0, r.clock))
        // 0.77（Jason 10-26）：删 BetterCalendar 自家的块 = 低风险自动通过（进回收站、可撤销）
        let del = try await submitted(r, draft(.blockDelete(id: ids.flex, expectedRevision: nil)))
        #expect(del.state == .applied && del.preauth?.ruleId == PreauthPolicy.lowRiskRuleId)
    }

    @Test func conflictsAreRejectedNotSqueezed() async throws {
        let r = try rig(); defer { UserDefaults().removePersistentDomain(forName: r.suite) }
        let ids = try seed(r)
        // 挪到组会（固定）上 → 排布规则拒收，根本没有提案、更不会自动执行
        #expect(await r.center.submit(draft(.moveBlock(id: ids.flex, start: at(14, 0, r.clock), end: nil, expectedRevision: nil))) == nil)
        #expect(r.center.proposals.isEmpty)
    }

    @Test func switchOffAndJasonsOwnRulesWin() async throws {
        let r = try rig(); defer { UserDefaults().removePersistentDomain(forName: r.suite) }
        let ids = try seed(r)
        r.lowRisk.on = false
        let off = try await submitted(r, draft(.moveBlock(id: ids.flex, start: at(16, 0, r.clock), end: nil, expectedRevision: nil)))
        #expect(off.state == .pending && off.preauth == nil)   // 关掉 = 和以前一样，一律先问
        await r.center.decide(off.id, .decline)
        r.lowRisk.on = true
        // 你写的 deny / ask 规则优先于低风险自动通过
        let move = ProposalAction.moveBlock(id: ids.flex, start: at(16, 0, r.clock), end: nil, expectedRevision: nil)
        r.rules.upsert(origin: .agent, action: move, scope: .kind, effect: .ask, deviceId: "mac", sourceProposalId: nil)
        let asked = try await submitted(r, draft(move))
        #expect(asked.state == .pending)
        await r.center.decide(asked.id, .decline)
        r.rules.upsert(origin: .agent, action: move, scope: .kind, effect: .deny, deviceId: "mac", sourceProposalId: nil)
        let denied = try await submitted(r, draft(move))
        #expect(denied.state == .declined && denied.preauth?.ruleId != PreauthPolicy.lowRiskRuleId)
    }

    @Test func policyBoundariesArePure() {
        func value(_ a: ProposalAction, origin: ProposalOrigin = .agent) -> Proposal {
            Proposal(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 3600), origin: origin,
                     originLabel: "x", originDeviceId: "mac", parentId: nil, targetDeviceId: nil, title: "t", changes: [], reason: "r",
                     action: a, experiment: false, state: .pending, decidedAt: nil, decidedByDeviceId: nil, appliedAt: nil, resultNote: nil)
        }
        let t = Date(timeIntervalSince1970: 1_000_000)
        #expect(PreauthPolicy.lowRiskReason(value(.moveBlock(id: UUID(), start: t, end: nil, expectedRevision: nil))) == nil)
        #expect(PreauthPolicy.lowRiskReason(value(.moveBlock(id: UUID(), start: t, end: nil, expectedRevision: nil), origin: .user)) != nil)
        #expect(PreauthPolicy.lowRiskReason(value(.alarm(id: UUID(), title: "起床", fireAt: t, deviceId: "p"))) == "闹钟")
        #expect(PreauthPolicy.lowRiskReason(value(.journalAppend(day: t, text: "x", newEntryID: UUID(), expectedRevision: nil))) != nil)
        #expect(PreauthPolicy.lowRiskReason(value(.itemCreate(id: UUID(), title: "x", note: nil))) != nil)
        #expect(PreauthPolicy.lowRiskReason(value(.timer(command: .pause, blockId: nil, title: nil, expectedRevision: nil))) != nil)
        #expect(PreauthPolicy.lowRiskReason(value(.yourReminderEdit(YourReminderEdit(externalID: "r", title: "x")))) != nil)
        #expect(PreauthPolicy.lowRiskReason(value(.blockEdit(ProposalBlockEdit(id: UUID(), deadline: .clear)))) != nil)
        var escalated = value(.moveBlock(id: UUID(), start: t, end: nil, expectedRevision: nil)); escalated.escalation = "图钉"
        #expect(PreauthPolicy.evaluate(escalated, rules: [], lowRiskAutoPass: true).route == .ask)
        var blocked = value(.moveBlock(id: UUID(), start: t, end: nil, expectedRevision: nil)); blocked.autoPassBlocker = "图钉"
        #expect(PreauthPolicy.evaluate(blocked, rules: [], lowRiskAutoPass: true).route == .ask)
        #expect(PreauthPolicy.evaluate(value(.moveBlock(id: UUID(), start: t, end: nil, expectedRevision: nil)), rules: [], lowRiskAutoPass: false).route == .ask)
    }

    @Test func switchIsSyncedAndBridgeParsesAskFirst() throws {
        #expect(SettingsSync.syncedKeys.contains(LowRiskAutoPassSettings.key))
        let file: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString, "title": "t", "reason": "r", "askFirst": true,
                                   "action": ["kind": "moveBlock", "blockId": UUID().uuidString, "start": "2026-10-20T16:00:00-04:00"]]
        #expect(try AgentBridgeIO.draft(from: JSONSerialization.data(withJSONObject: file)).askFirst)
        var bad = file; bad["askFirst"] = "yes"
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.draft(from: JSONSerialization.data(withJSONObject: bad)) }
    }
}
