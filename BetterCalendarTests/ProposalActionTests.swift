import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

/// SPEC §19 W1：多端审批的真改动（事项 / 计时 / 挪动计划块）+ 撤销。
/// 两台「设备」共用一个内存中转；数据用内存 SwiftData（容器与 store 同寿命）；时钟注入。
@MainActor @Suite struct ProposalActionTests {
    final class Clock { var now: Date
        init() { now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 10))! }
    }

    final class FakeTimer: ProposalTimerControlling {
        var state = ProposalTimerState.idle
        var calls: [String] = []
        var plan: [UUID: String] = [:]
        var proposalTimerState: ProposalTimerState { state }
        func proposalPlanItemTitle(_ id: UUID) async -> String? { plan[id] }
        func proposalStartTimer(blockId: UUID?, title: String?) async throws {
            calls.append("start")
            state = ProposalTimerState(phase: .running, title: blockId.flatMap { plan[$0] } ?? title, blockId: blockId,
                                       startedAt: Date(timeIntervalSince1970: 1_000 + Double(calls.count)))
        }
        func proposalPauseTimer() async throws { calls.append("pause"); state.phase = .paused }
        func proposalResumeTimer() async throws { calls.append("resume"); state.phase = .running }
        func proposalStopTimer() async throws { calls.append("stop"); state = .idle }
    }

    final class Progress: ExecutionProgressReading {
        var settledPlannedIDs: Set<UUID> = []
        var activePrediction: ActivePrediction?
    }

    struct Rig {
        let container: ModelContainer
        let clock: Clock
        let items: LongTaskStore
        let plans: PlanStore
        let timer: FakeTimer
        let progress: Progress
        let mac: ProposalCenter
        let phone: ProposalCenter
        let ledger: MemoryOperationLedger
        let executor: ProposalActionExecutor
    }

    func rig() throws -> Rig {
        let container = try ModelContainer(for: DataArchiveStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let clock = Clock()
        let items = LongTaskStore(context: container.mainContext)
        let plans = PlanStore(context: container.mainContext)
        let timer = FakeTimer(), progress = Progress()
        let mover = ApprovedPlanMover(planStore: plans, projection: nil, startedDays: nil, now: { clock.now })
        mover.progress = progress
        let executor = ProposalActionExecutor(items: items, timer: timer, mover: mover, deviceId: "mac", now: { clock.now })
        let phoneExecutor = ProposalActionExecutor(items: items, timer: FakeTimer(), mover: mover, deviceId: "phone", now: { clock.now })
        let transport = InMemoryProposalTransport(), ledger = MemoryOperationLedger()
        let mac = ProposalCenter(transport: transport, executor: executor, notifier: SilentProposalNotifier(), ledger: ledger,
                                 deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        let phone = ProposalCenter(transport: transport, executor: phoneExecutor, notifier: SilentProposalNotifier(), ledger: ledger,
                                   deviceId: "phone", deviceLabel: "iPhone", now: { clock.now })
        return Rig(container: container, clock: clock, items: items, plans: plans, timer: timer, progress: progress,
                   mac: mac, phone: phone, ledger: ledger, executor: executor)
    }

    func draft(_ action: ProposalAction, target: String? = nil) -> ProposalDraft {
        ProposalDraft(origin: .agent, originLabel: "BetterCalendar 智能体", targetDeviceId: target, title: "测试真改动",
                      changes: [ProposalChange(field: "智能体自己写的", before: "x", after: "y")], reason: "测试",
                      action: action, experiment: true)
    }

    /// 提交 → 手机批准 → 执行设备执行，返回最新提案。
    func approve(_ r: Rig, _ action: ProposalAction, target: String? = "mac") async throws -> Proposal {
        let p = try #require(await r.mac.submit(draft(action, target: target)))
        await r.phone.decide(p.id, .approve)
        await r.mac.refresh(); await r.phone.refresh()
        return try #require(r.mac.proposals.first { $0.id == p.id })
    }

    func at(_ h: Int, _ m: Int = 0, _ c: Clock) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: c.now)!
    }

    // MARK: 事项

    @Test func createTodoShowsAppComputedChangesAppliesAndUndoesToTrash() async throws {
        let r = try rig()
        let id = UUID()
        let p = try await approve(r, .itemCreate(id: id, title: "  买牛奶 ", note: "低脂"), target: nil)
        #expect(p.experiment == false)
        #expect(p.changes.first == ProposalChange(field: "待办", before: nil, after: "买牛奶"))   // App 算的，不是智能体写的
        #expect(p.state == .applied && p.resultNote?.contains("买牛奶") == true)
        let task = try #require(try r.items.task(id: id))
        #expect(task.poolZone == .todo && task.note == "低脂" && task.createdAt == r.clock.now)
        #expect(r.mac.canUndo(p) && r.phone.canUndo(p))   // 事项随 iCloud 同步：任一设备都能撤销
        #expect(await r.phone.undo(p.id))
        #expect(try r.items.task(id: id)?.isInTrash == true)
        let undone = try #require(r.ledger.values.first { $0.event == "undone" })
        #expect(undone.actor == .user && undone.deviceId == "phone" && undone.proposalId == p.id)
        await r.mac.refresh()
        let after = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(after.undoneAt == r.clock.now && !r.mac.canUndo(after))
        #expect(await r.mac.undo(p.id) == false)   // 不能撤销两次
        #expect(r.ledger.values.contains { $0.event == "undo.failed" })
    }

    @Test func editTitleAndNoteThenUndoRestoresBoth() async throws {
        let r = try rig()
        let id = UUID()
        try r.items.createTodo(id: id, title: "读论文", note: "", at: r.clock.now)
        let p = try await approve(r, .itemEdit(id: id, title: "读 Attention 论文", note: "第 3 节", expectedRevision: nil))
        #expect(p.changes.contains(ProposalChange(field: "事项标题", before: "读论文", after: "读 Attention 论文")))
        #expect(p.changes.contains { $0.before == "（空）" && $0.after == "第 3 节" })
        #expect(try r.items.task(id: id)?.title == "读 Attention 论文")
        r.clock.now = r.clock.now.addingTimeInterval(60)
        #expect(await r.mac.undo(p.id))
        let t = try #require(try r.items.task(id: id))
        #expect(t.title == "读论文" && t.note == "")
    }

    @Test func editConflictsWhenUserChangedItemAfterProposal() async throws {
        let r = try rig()
        let id = UUID()
        try r.items.createTodo(id: id, title: "读论文", note: "", at: r.clock.now)
        let p = try #require(await r.mac.submit(draft(.itemEdit(id: id, title: "智能体的标题", note: nil, expectedRevision: nil), target: "mac")))
        r.clock.now = r.clock.now.addingTimeInterval(30)
        try r.items.update(id: id, at: r.clock.now) { $0.title = "我自己改的标题" }   // 用户在审批前亲手改了
        await r.phone.decide(p.id, .approve); await r.mac.refresh()
        let latest = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(latest.state == .failed && latest.resultNote?.contains("被改过") == true)
        #expect(try r.items.task(id: id)?.title == "我自己改的标题")   // 不覆盖用户事实
    }

    @Test func staleRevisionFromAgentIsRejectedAtSubmit() async throws {
        let r = try rig()
        let id = UUID()
        try r.items.createTodo(id: id, title: "读论文", note: "", at: r.clock.now)
        let result = await r.mac.submit(draft(.itemSetDone(id: id, done: true, expectedRevision: "deadbeefdeadbeef")))
        #expect(result == nil && r.mac.proposals.isEmpty)
        #expect(r.mac.lastError?.contains("版本不一致") == true)
        #expect(r.ledger.values.contains { $0.event == "rejected" })
    }

    @Test func setDoneThenUndoReopensAndUndoRefusedWhenItemChangedAgain() async throws {
        let r = try rig()
        let id = UUID()
        try r.items.createTodo(id: id, title: "交表", note: "", at: r.clock.now)
        let p = try await approve(r, .itemSetDone(id: id, done: true, expectedRevision: nil))
        #expect(p.changes == [ProposalChange(field: "「交表」", before: "在途", after: "做成了")])
        #expect(try r.items.task(id: id)?.status == .done && r.items.task(id: id)?.doneAt == r.clock.now)
        // 执行之后用户又改了它 → 撤销被拒绝并说明原因
        r.clock.now = r.clock.now.addingTimeInterval(60)
        try r.items.update(id: id, at: r.clock.now) { $0.note = "已经交了" }
        #expect(await r.mac.undo(p.id) == false)
        #expect(r.mac.lastError?.contains("被改过") == true)
        #expect(try r.items.task(id: id)?.status == .done)
        let failed = try #require(r.ledger.values.last { $0.event == "undo.failed" })
        #expect(failed.actor == .user && failed.proposalId == p.id)
    }

    @Test func setDoneUndoReopens() async throws {
        let r = try rig()
        let id = UUID()
        try r.items.createTodo(id: id, title: "交表", note: "", at: r.clock.now)
        let p = try await approve(r, .itemSetDone(id: id, done: true, expectedRevision: nil))
        #expect(await r.mac.undo(p.id))
        let t = try #require(try r.items.task(id: id))
        #expect(t.status == .active && t.doneAt == nil)
        // 已在途的再「取消完成」不合规则：提交即被拒
        #expect(await r.mac.submit(draft(.itemSetDone(id: id, done: false, expectedRevision: nil))) == nil)
    }

    // MARK: 计时

    @Test func timerStartPauseResumeStopWithUndoRules() async throws {
        let r = try rig()
        let block = UUID()
        r.timer.plan[block] = "写报告"
        // 未指定设备的计时提案：固定在读状态的那台（Mac）执行，即使手机批准
        let start = try await approve(r, .timer(command: .start, blockId: block, title: nil, expectedRevision: nil), target: nil)
        #expect(start.targetDeviceId == "mac" && start.state == .applied)
        #expect(start.changes.last == ProposalChange(field: "计时", before: "空闲（没有在计时）", after: "正在计时「写报告」"))
        #expect(r.timer.calls == ["start"])
        let pause = try await approve(r, .timer(command: .pause, blockId: nil, title: nil, expectedRevision: nil))
        #expect(r.timer.state.phase == .paused)
        #expect(r.phone.undoBlockedReason(pause)?.contains("那台设备") == true)   // 计时是设备本地状态
        #expect(await r.mac.undo(pause.id))
        #expect(r.timer.state.phase == .running && r.timer.calls.last == "resume")
        let stop = try await approve(r, .timer(command: .stop, blockId: nil, title: nil, expectedRevision: nil))
        #expect(stop.changes.first?.after?.contains("不等于完成") == true)   // 结束计时 ≠ 完成事项
        #expect(r.timer.state.phase == .idle && stop.undoAction == nil && stop.undoUnavailableReason != nil)
        #expect(!r.mac.canUndo(stop))
    }

    @Test func timerProposalFailsWhenStateChangedBeforeApproval() async throws {
        let r = try rig()
        r.timer.state = ProposalTimerState(phase: .running, title: "写报告", startedAt: r.clock.now)
        let p = try #require(await r.mac.submit(draft(.timer(command: .pause, blockId: nil, title: nil, expectedRevision: nil))))
        r.timer.state.phase = .paused   // 你在审批前自己按了暂停
        await r.phone.decide(p.id, .approve); await r.mac.refresh()
        let latest = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(latest.state == .failed && latest.resultNote?.contains("计时状态") == true)
        #expect(r.timer.calls.isEmpty)
        // 没在计时就不能暂停：提交即拒
        r.timer.state = .idle
        #expect(await r.mac.submit(draft(.timer(command: .pause, blockId: nil, title: nil, expectedRevision: nil))) == nil)
        #expect(await r.mac.submit(draft(.timer(command: .start, blockId: UUID(), title: nil, expectedRevision: nil))) == nil)
    }

    @Test func undoOfStartStopsTimer() async throws {
        let r = try rig()
        let p = try await approve(r, .timer(command: .start, blockId: nil, title: "临时回邮件", expectedRevision: nil))
        #expect(r.timer.state.title == "临时回邮件")
        #expect(await r.mac.undo(p.id))
        #expect(r.timer.state.phase == .idle && r.timer.calls == ["start", "stop"])
    }

    // MARK: 挪动计划块

    func seedDay(_ r: Rig) throws -> (flex: UUID, fixed: UUID, ddl: UUID, other: UUID) {
        let c = r.clock
        let flex = ScheduledBlock(title: "整理笔记", start: at(11, 0, c), end: at(12, 0, c))
        let fixed = ScheduledBlock(title: "组会", start: at(14, 0, c), end: at(15, 0, c), isFixed: true)
        let ddl = ScheduledBlock(title: "交作业", start: at(15, 0, c), end: at(16, 0, c), deadline: at(17, 0, c))
        let other = ScheduledBlock(title: "跑步", start: at(18, 0, c), end: at(19, 0, c))
        try r.plans.replacePlanned([flex, fixed, ddl, other], on: Calendar.current.startOfDay(for: c.now))
        return (flex.id, fixed.id, ddl.id, other.id)
    }

    @Test func moveBlockAppliesAndUndoes() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let p = try await approve(r, .moveBlock(id: ids.flex, start: at(16, 0, r.clock), end: nil, expectedRevision: nil))
        #expect(p.changes == [ProposalChange(field: "「整理笔记」时间", before: "11:00–12:00", after: "16:00–17:00")])
        #expect(p.state == .applied)
        let label = Calendar.current.startOfDay(for: r.clock.now)
        let moved = try #require(try r.plans.plannedBlocks(on: label).first { $0.id == ids.flex })
        #expect(moved.start == at(16, 0, r.clock) && moved.end == at(17, 0, r.clock))
        #expect(await r.phone.undo(p.id))
        let back = try #require(try r.plans.plannedBlocks(on: label).first { $0.id == ids.flex })
        #expect(back.start == at(11, 0, r.clock) && back.end == at(12, 0, r.clock))
    }

    @Test func moveBlockRulesGiveClearReasons() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        func reason(_ id: UUID, _ s: Date, _ e: Date? = nil) async -> String? {
            r.mac.clearError()
            _ = await r.mac.submit(draft(.moveBlock(id: id, start: s, end: e, expectedRevision: nil)))
            return r.mac.lastError
        }
        #expect(await reason(ids.fixed, at(16, 0, c))?.contains("固定安排，按规则不挪") == true)
        #expect(await reason(ids.flex, at(13, 30, c))?.contains("与固定安排「组会」") == true)
        #expect(await reason(ids.ddl, at(16, 30, c))?.contains("越过截止时间 17:00") == true)
        #expect(await reason(ids.flex, at(18, 30, c))?.contains("和「跑步」") == true)
        #expect(await reason(ids.flex, at(9, 0, c))?.contains("已经过去了") == true)
        #expect(await reason(ids.flex, at(23, 30, c), at(23, 30, c).addingTimeInterval(6 * 3600))?.contains("超出今天") == true)
        #expect(await reason(UUID(), at(16, 0, c))?.contains("找不到") == true)
        r.progress.activePrediction = ActivePrediction(id: ids.flex, start: at(10, 0, c), end: at(11, 30, c))
        #expect(await reason(ids.flex, at(16, 0, c))?.contains("正在计时") == true)
        r.progress.settledPlannedIDs = [ids.other]
        r.progress.activePrediction = nil
        #expect(await reason(ids.other, at(20, 0, c))?.contains("已经做完") == true)
        #expect(r.mac.proposals.isEmpty)   // 规则不通过的一律不进入审批
    }

    @Test func moveBlockConflictsWhenBlockChangedAndUndoRefusedAfterLaterEdit() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        let p = try #require(await r.mac.submit(draft(.moveBlock(id: ids.flex, start: at(16, 0, c), end: nil, expectedRevision: nil), target: "mac")))
        try r.plans.updatePlanned(id: ids.flex, start: at(12, 0, c), end: at(13, 0, c), title: "整理笔记")   // 你在日历里先拖了它
        await r.phone.decide(p.id, .approve); await r.mac.refresh()
        let failed = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(failed.state == .failed && failed.resultNote?.contains("被改过") == true)
        let label = Calendar.current.startOfDay(for: c.now)
        #expect(try r.plans.plannedBlocks(on: label).first { $0.id == ids.flex }?.start == at(12, 0, c))
        // 成功挪动后又被手改 → 撤销拒绝
        let ok = try await approve(r, .moveBlock(id: ids.other, start: at(20, 0, c), end: nil, expectedRevision: nil))
        #expect(ok.state == .applied)
        try r.plans.updatePlanned(id: ids.other, start: at(21, 0, c), end: at(22, 0, c), title: "跑步")
        #expect(await r.mac.undo(ok.id) == false)
        #expect(r.mac.lastError?.contains("被改过") == true)
        #expect(try r.plans.plannedBlocks(on: label).first { $0.id == ids.other }?.start == at(21, 0, c))
    }

    @Test func experimentOnlyExecutorRejectsRealKinds() async throws {
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(),
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(), deviceId: "x", deviceLabel: "X")
        #expect(await center.submit(draft(.itemCreate(id: UUID(), title: "t", note: nil))) == nil)
        #expect(center.lastError?.contains("只接受测试改动") == true)
    }

    @Test func proposalWithUndoFieldsRoundTripsAndOldPayloadDecodes() throws {
        let clock = Clock()
        var p = Proposal(id: UUID(), createdAt: clock.now, expiresAt: clock.now, origin: .agent, originLabel: "a", originDeviceId: "mac",
                         parentId: nil, targetDeviceId: nil, title: "t", changes: [], reason: "r",
                         action: .moveBlock(id: UUID(), start: clock.now, end: nil, expectedRevision: "abc"), experiment: false, state: .applied)
        p.undoAction = .timer(command: .resume, blockId: nil, title: nil, expectedRevision: "r1"); p.undoDeviceId = "mac"
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(Proposal.self, from: data) == p)
        // 旧版本写的记录（没有撤销字段）照常解码
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["undoAction", "undoDeviceId"] { object.removeValue(forKey: key) }
        object["action"] = ["experimentNoop": ["note": "旧"]]
        let old = try JSONDecoder().decode(Proposal.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.undoAction == nil && old.action == .experimentNoop(note: "旧"))
    }

    // MARK: 生产计时路径（ExecutionViewModel 本地计时）

    @Test func executionViewModelTimerPathEndsTimingWithoutCompletingItem() async throws {
        let r = try rig()
        let todo = UUID()
        try r.items.createTodo(id: todo, title: "写报告", note: "", at: r.clock.now)
        let execution = ExecutionViewModel(calendarStore: FakeCalendarStore(),
                                           reschedule: RescheduleService(planStore: r.plans, planner: NaivePlanningEngine()),
                                           planStore: r.plans, reminderStore: FakeReminderStore(),
                                           liveActivity: NoLiveActivity(), persistsRunState: false)
        r.executor.timer = execution
        _ = try await approve(r, .timer(command: .start, blockId: nil, title: "写报告", expectedRevision: nil))
        #expect(execution.proposalTimerState.phase == .running && execution.active?.title == "写报告")
        _ = try await approve(r, .timer(command: .pause, blockId: nil, title: nil, expectedRevision: nil))
        #expect(execution.isOnBreak && execution.proposalTimerState.phase == .paused)
        _ = try await approve(r, .timer(command: .resume, blockId: nil, title: nil, expectedRevision: nil))
        #expect(!execution.isOnBreak)
        let stop = try await approve(r, .timer(command: .stop, blockId: nil, title: nil, expectedRevision: nil))
        await execution.waitForPreview()
        #expect(stop.state == .applied && execution.active == nil && execution.proposalTimerState == .idle)
        #expect(execution.done.contains { $0.title == "写报告" })              // 投入照常记下
        #expect(try r.items.task(id: todo)?.status == .active)               // 结束计时 ≠ 完成事项
    }
}
