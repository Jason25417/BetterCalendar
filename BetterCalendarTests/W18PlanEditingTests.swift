import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

/// SPEC §19 W18：智能体排时间线——加块 / 改块 / 删块（进回收站）/ 跨天挪 / 排一天（整组批准、整组撤销）。
/// 合法性归 App（PlanEditRules）：固定不动、不重叠、不越截止、图钉要越级、你的日历 = 已占用；写入只经 PlanStore。
/// 两台「设备」共用一个内存中转；内存 SwiftData（容器与 store 同寿命）；时钟注入（2026-10-18 周日 10:00）。
@MainActor @Suite struct W18PlanEditingTests {
    final class Clock { var now: Date
        init() { now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 10))! }
    }
    final class Progress: ExecutionProgressReading {
        var settledPlannedIDs: Set<UUID> = []
        var activePrediction: ActivePrediction?
    }
    /// 你的日历（只读替身）：排布用的「已占用」。
    final class Busy {
        var events: [SystemCalendarEvent] = []
        var failure: String?
    }

    struct Rig {
        let container: ModelContainer
        let clock: Clock
        let items: LongTaskStore
        let plans: PlanStore
        let progress: Progress
        let busy: Busy
        let mover: ApprovedPlanMover
        let mac: ProposalCenter
        let phone: ProposalCenter
        let ledger: MemoryOperationLedger
    }

    func rig(enabled: Bool = true) throws -> Rig {
        let container = try ModelContainer(for: DataArchiveStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let clock = Clock()
        let items = LongTaskStore(context: container.mainContext)
        let plans = PlanStore(context: container.mainContext, now: { clock.now })
        let progress = Progress(), busy = Busy()
        let mover = ApprovedPlanMover(planStore: plans, projection: nil, startedDays: nil, now: { clock.now })
        mover.progress = progress
        mover.enabledFlag = { enabled }
        mover.occupiedEvents = { window in
            if let f = busy.failure { throw ProposalExecutionError.unavailable(f) }
            return busy.events.filter { $0.start < window.end && $0.end > window.start }
        }
        let executor = ProposalActionExecutor(items: items, mover: mover, deviceId: "mac", now: { clock.now })
        let phoneExecutor = ProposalActionExecutor(items: items, mover: mover, deviceId: "phone", now: { clock.now })
        let transport = InMemoryProposalTransport(), ledger = MemoryOperationLedger()
        let mac = ProposalCenter(transport: transport, executor: executor, notifier: SilentProposalNotifier(), ledger: ledger,
                                 deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        let phone = ProposalCenter(transport: transport, executor: phoneExecutor, notifier: SilentProposalNotifier(), ledger: ledger,
                                   deviceId: "phone", deviceLabel: "iPhone", now: { clock.now })
        return Rig(container: container, clock: clock, items: items, plans: plans, progress: progress, busy: busy, mover: mover,
                   mac: mac, phone: phone, ledger: ledger)
    }

    func draft(_ action: ProposalAction, escalation: String? = nil) -> ProposalDraft {
        var d = ProposalDraft(origin: .agent, originLabel: "BetterCalendar 智能体", targetDeviceId: "mac", title: "排时间线",
                              changes: [], reason: "测试", action: action, experiment: false)
        d.escalation = escalation
        return d
    }

    /// 提交 → 手机批准 → Mac 执行，返回最新提案。
    func approve(_ r: Rig, _ action: ProposalAction, escalation: String? = nil) async throws -> Proposal {
        let p = try #require(await r.mac.submit(draft(action, escalation: escalation)), "\(r.mac.lastError ?? "")")
        await r.phone.decide(p.id, .approve)
        await r.mac.refresh(); await r.phone.refresh()
        return try #require(r.mac.proposals.first { $0.id == p.id })
    }

    func reason(_ r: Rig, _ action: ProposalAction, escalation: String? = nil) async -> String? {
        r.mac.clearError()
        let p = await r.mac.submit(draft(action, escalation: escalation))
        return p == nil ? r.mac.lastError : nil
    }

    /// 某天（offset：0 今天 / 1 明天）的 h:m。
    func at(_ h: Int, _ m: Int = 0, day offset: Int = 0, _ c: Clock) -> Date {
        let d = Calendar.current.date(byAdding: .day, value: offset, to: c.now)!
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: d)!
    }
    func label(_ offset: Int, _ c: Clock) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: c.now))!
    }
    func blocks(_ r: Rig, day offset: Int) throws -> [UUID: ScheduledBlock] {
        Dictionary(uniqueKeysWithValues: try r.plans.plannedBlocks(on: label(offset, r.clock)).map { ($0.id, $0) })
    }
    func newBlock(_ title: String, _ s: Date, _ e: Date, fixed: Bool = false, important: Bool = false,
                  deadline: Date? = nil, id: UUID = UUID()) -> ProposalNewBlock {
        ProposalNewBlock(id: id, title: title, start: s, end: e, isFixed: fixed, important: important, deadline: deadline)
    }

    /// 明天：组会（固定 14–15）、健身 18–19、杂事 20–21、交报告 15–16（截止 17:00）。
    func seedTomorrow(_ r: Rig) throws -> (meeting: UUID, gym: UUID, chores: UUID, report: UUID) {
        let c = r.clock
        let meeting = ScheduledBlock(title: "组会", start: at(14, day: 1, c), end: at(15, day: 1, c), isFixed: true)
        let gym = ScheduledBlock(title: "健身", start: at(18, day: 1, c), end: at(19, day: 1, c))
        let chores = ScheduledBlock(title: "杂事", start: at(20, day: 1, c), end: at(21, day: 1, c))
        let report = ScheduledBlock(title: "交报告", start: at(15, day: 1, c), end: at(16, day: 1, c), deadline: at(17, day: 1, c))
        try r.plans.replacePlanned([meeting, gym, chores, report], on: label(1, c))
        return (meeting.id, gym.id, chores.id, report.id)
    }

    // MARK: 新增

    @Test func createOnTomorrowShowsAppComputedChangeAndUndoesIntoTrash() async throws {
        let r = try rig()
        let c = r.clock
        let id = UUID()
        let p = try await approve(r, .blockCreate(day: label(1, c), blocks: [newBlock("  写论文 ", at(9, day: 1, c), at(11, day: 1, c), important: true, id: id)]))
        #expect(p.state == .applied, "\(p.resultNote ?? "")")
        #expect(p.changes.first == ProposalChange(field: "新计划块", before: nil, after: "明天 09:00–11:00「写论文」（要紧）"))
        #expect(p.action.ownership == .betterCalendar && !p.action.isDestructive)
        let made = try #require(try blocks(r, day: 1)[id])
        #expect(made.title == "写论文" && made.priority == .important && made.start == at(9, day: 1, c))
        #expect(!made.isPinned(at: c.now), "新加的块 = 确认过的计划，不钉（当天照常自愈）")
        #expect(p.undoHint?.contains("移入回收站") == true && r.phone.canUndo(p))
        #expect(await r.phone.undo(p.id))
        #expect(try blocks(r, day: 1)[id] == nil)
        #expect(try r.plans.trashedPlanned(id: id) != nil, "撤销 = 移入回收站，可恢复")
    }

    @Test func createLinksATodoAndBorrowsItsTitle() async throws {
        let r = try rig()
        let c = r.clock
        let todo = UUID()
        try r.items.createTodo(id: todo, title: "N1 语法", note: "", at: c.now)
        var nb = newBlock("", at(9, day: 2, c), at(10, day: 2, c))
        nb.linkedTaskID = todo
        let p = try await approve(r, .blockCreate(day: label(2, c), blocks: [nb]))
        #expect(p.state == .applied)
        let made = try #require(try blocks(r, day: 2)[nb.id])
        #expect(made.title == "N1 语法" && made.linkedTaskID == todo)
        var ghost = newBlock("", at(11, day: 2, c), at(12, day: 2, c)); ghost.linkedTaskID = UUID()
        #expect(await reason(r, .blockCreate(day: label(2, c), blocks: [ghost]))?.contains("找不到要关联的事项") == true)
    }

    // MARK: 改

    @Test func editTitleDurationFlagsDeadlineThenUndoRestoresAll() async throws {
        let r = try rig()
        let ids = try seedTomorrow(r)
        let c = r.clock
        var e = ProposalBlockEdit(id: ids.gym)
        e.title = "力量训练"; e.duration = 90 * 60; e.important = true; e.deadline = .set(at(20, day: 1, c))
        let p = try await approve(r, .blockEdit(e))
        #expect(p.state == .applied, "\(p.resultNote ?? "")")
        #expect(p.changes.contains(ProposalChange(field: "计划块标题", before: "健身", after: "力量训练")))
        #expect(p.changes.contains(ProposalChange(field: "「力量训练」时长", before: "明天 18:00–19:00（1 小时）", after: "明天 18:00–19:30（1 小时 30 分钟）")))
        #expect(p.changes.contains(ProposalChange(field: "「力量训练」截止", before: "（无）", after: "明天 20:00")))
        let edited = try #require(try blocks(r, day: 1)[ids.gym])
        #expect(edited.title == "力量训练" && edited.end == at(19, 30, day: 1, c) && edited.priority == .important && edited.deadline == at(20, day: 1, c))
        #expect(await r.mac.undo(p.id), "\(r.mac.lastError ?? "")")
        let back = try #require(try blocks(r, day: 1)[ids.gym])
        #expect(back.title == "健身" && back.end == at(19, day: 1, c) && back.priority == .normal && back.deadline == nil)
    }

    @Test func editRulesFixedDeadlineAndNothingToChange() async throws {
        let r = try rig()
        let ids = try seedTomorrow(r)
        let c = r.clock
        var longer = ProposalBlockEdit(id: ids.meeting); longer.duration = 2 * 3600
        #expect(await reason(r, .blockEdit(longer))?.contains("固定安排，按规则不改时长") == true)
        var late = ProposalBlockEdit(id: ids.report); late.duration = 3 * 3600   // 15:00–18:00 越过 17:00 截止
        #expect(await reason(r, .blockEdit(late))?.contains("越过截止时间") == true)
        var early = ProposalBlockEdit(id: ids.gym); early.deadline = .set(at(18, 30, day: 1, c))   // 截止早于结束
        #expect(await reason(r, .blockEdit(early))?.contains("越过截止时间") == true)
        var same = ProposalBlockEdit(id: ids.gym); same.title = "健身"
        #expect(await reason(r, .blockEdit(same))?.contains("没有要改的地方") == true)
        var unfix = ProposalBlockEdit(id: ids.meeting); unfix.isFixed = false
        #expect(await reason(r, .blockEdit(unfix))?.contains("固定安排；要删掉它或取消固定") == true)
        let ok = try #require(await r.mac.submit(draft(.blockEdit(unfix), escalation: "组会这周改成线上可选，他说不用当固定")))
        #expect(ok.escalation != nil && ok.changes.first?.field.contains("取消固定安排") == true)
    }

    // MARK: 删

    @Test func deleteGoesToTrashIsRecoverableAndUndoRestores() async throws {
        let r = try rig()
        let ids = try seedTomorrow(r)
        let c = r.clock
        let action = ProposalAction.blockDelete(id: ids.chores, expectedRevision: nil)
        #expect(action.isDestructive && action.ownership == .betterCalendar)
        let p = try await approve(r, action)
        #expect(p.state == .applied && p.changes.first?.field.contains("移入回收站") == true)
        #expect(try blocks(r, day: 1)[ids.chores] == nil)
        #expect(try r.plans.deletedPlannedIDs(on: label(1, c)).contains(ids.chores))
        // 回收站里看得到（Jason 也能自己去回收站恢复）
        let trash = RetainedTrashService(context: r.container.mainContext,
                                         projection: CalendarSyncEngine(planStore: r.plans, calendarStore: FakeCalendarStore()))
        #expect(try trash.entries().contains { $0.title == "杂事" && $0.category == "计划" })
        // 撤销 = 从回收站恢复，原样回来
        #expect(p.undoHint?.contains("从回收站恢复") == true)
        #expect(await r.phone.undo(p.id), "\(r.phone.lastError ?? "")")
        let back = try #require(try blocks(r, day: 1)[ids.chores])
        #expect(back.start == at(20, day: 1, c) && back.end == at(21, day: 1, c))
        #expect(try !trash.entries().contains { $0.title == "杂事" })
    }

    @Test func deleteRulesActiveDoneAndFixed() async throws {
        let r = try rig()
        let c = r.clock
        let ids = try seedTomorrow(r)
        let now = ScheduledBlock(title: "整理笔记", start: at(9, 30, c), end: at(11, 0, c))
        let done = ScheduledBlock(title: "晨跑", start: at(7, 0, c), end: at(8, 0, c))
        try r.plans.replacePlanned([now, done], on: label(0, c))
        r.progress.activePrediction = ActivePrediction(id: now.id, start: at(9, 30, c), end: at(11, 0, c))
        r.progress.settledPlannedIDs = [done.id]
        #expect(await reason(r, .blockDelete(id: now.id, expectedRevision: nil))?.contains("正在计时") == true)
        #expect(await reason(r, .blockDelete(id: done.id, expectedRevision: nil))?.contains("已经做完") == true)
        #expect(await reason(r, .blockDelete(id: ids.meeting, expectedRevision: nil))?.contains("固定安排；要删掉它") == true)
    }

    // MARK: 跨天挪

    @Test func moveAcrossDaysAppliesPinsOnTargetDayAndUndoes() async throws {
        let r = try rig()
        let c = r.clock
        let notes = ScheduledBlock(title: "整理笔记", start: at(11, 0, c), end: at(12, 0, c))
        try r.plans.replacePlanned([notes], on: label(0, c))
        _ = try seedTomorrow(r)
        let p = try await approve(r, .moveBlock(id: notes.id, start: at(10, day: 1, c), end: nil, expectedRevision: nil))
        #expect(p.state == .applied, "\(p.resultNote ?? "")")
        #expect(p.changes == [ProposalChange(field: "「整理笔记」时间", before: "11:00–12:00", after: "明天 10:00–11:00")])
        #expect(try blocks(r, day: 0)[notes.id] == nil)
        let moved = try #require(try blocks(r, day: 1)[notes.id])
        #expect(moved.start == at(10, day: 1, c) && moved.end == at(11, day: 1, c))
        #expect(moved.pinnedUntil == ScheduledBlock.pinExpiry(forStart: moved.start), "你批准的位置 = 图钉，到那天结束")
        #expect(await r.phone.undo(p.id), "\(r.phone.lastError ?? "")")
        #expect(try blocks(r, day: 0)[notes.id]?.start == at(11, 0, c))
        // 一起挪也能跨天：把明天的健身挪到后天，杂事顺到健身原来的位置
        let ids = try seedTomorrow(r)
        let g = try await approve(r, .moveBlocks(moves: [ProposalBlockMove(id: ids.gym, start: at(18, day: 2, c), end: nil, expectedRevision: nil),
                                                         ProposalBlockMove(id: ids.chores, start: at(18, day: 1, c), end: nil, expectedRevision: nil)], isUndo: false))
        #expect(g.state == .applied && g.changes.contains(ProposalChange(field: "「健身」时间", before: "明天 18:00–19:00", after: "10月20日（周二） 18:00–19:00")))
    }

    // MARK: 合法性：拒绝并写明原因

    @Test func legalityRejectionsGiveReasons() async throws {
        let r = try rig()
        let c = r.clock
        let ids = try seedTomorrow(r)
        let day1 = label(1, c)
        // 重叠（不悄悄挤）
        #expect(await reason(r, .blockCreate(day: day1, blocks: [newBlock("写论文", at(18, 30, day: 1, c), at(19, 30, day: 1, c))]))?
            .contains("和「健身」") == true)
        // 撞固定安排 / 挪固定安排
        #expect(await reason(r, .blockCreate(day: day1, blocks: [newBlock("读书", at(14, 30, day: 1, c), at(15, day: 1, c))]))?
            .contains("与固定安排「组会」") == true)
        #expect(await reason(r, .moveBlock(id: ids.meeting, start: at(9, day: 1, c), end: nil, expectedRevision: nil))?
            .contains("固定安排，按规则不挪") == true)
        // 截止
        #expect(await reason(r, .blockCreate(day: day1, blocks: [newBlock("赶稿", at(16, day: 1, c), at(17, 30, day: 1, c), deadline: at(17, day: 1, c))]))?
            .contains("越过截止时间") == true)
        #expect(await reason(r, .moveBlock(id: ids.report, start: at(16, 30, day: 1, c), end: nil, expectedRevision: nil))?
            .contains("越过截止时间") == true)
        // 你的日历 = 已占用（只读）
        r.busy.events = [SystemCalendarEvent(title: "牙医", start: at(10, day: 1, c), end: at(11, day: 1, c), isAllDay: false, calendarTitle: "家庭")]
        #expect(await reason(r, .blockCreate(day: day1, blocks: [newBlock("写论文", at(9, day: 1, c), at(11, day: 1, c))]))?
            .contains("你日历里的「牙医」") == true)
        #expect(await reason(r, .moveBlock(id: ids.gym, start: at(10, 30, day: 1, c), end: nil, expectedRevision: nil))?
            .contains("你日历里的「牙医」") == true)
        // 全天事件不占时段
        r.busy.events = [SystemCalendarEvent(title: "生日", start: label(1, c), end: label(2, c), isAllDay: true, calendarTitle: "家庭")]
        #expect(await reason(r, .blockCreate(day: day1, blocks: [newBlock("写论文", at(9, day: 1, c), at(11, day: 1, c))])) == nil)
        r.busy.events = []
        // 图钉：动它要越级
        try r.plans.setPinned(ids: [ids.gym], until: ScheduledBlock.pinExpiry(forStart: at(18, day: 1, c)))
        #expect(await reason(r, .blockDelete(id: ids.gym, expectedRevision: nil))?.contains("亲手放的位置") == true)
        #expect(await reason(r, .moveBlock(id: ids.gym, start: at(21, 30, day: 1, c), end: nil, expectedRevision: nil))?.contains("亲手放的位置") == true)
        var longer = ProposalBlockEdit(id: ids.gym); longer.duration = 2 * 3600
        #expect(await reason(r, .blockEdit(longer))?.contains("亲手放的位置") == true)
        var rename = ProposalBlockEdit(id: ids.gym); rename.title = "健身房"   // 只改名不动位置：不算越级
        #expect(await reason(r, .blockEdit(rename)) == nil)
        let esc = try #require(await r.mac.submit(draft(.blockDelete(id: ids.gym, expectedRevision: nil), escalation: "他说明天健身房关门")))
        #expect(esc.changes.first?.field.contains("这会动你亲手放的位置") == true && esc.state == .pending)
        // 范围：进过去、跨过凌晨 4:00、超出可排范围、day 和块对不上
        #expect(await reason(r, .blockCreate(day: label(0, c), blocks: [newBlock("补觉", at(8, 0, c), at(9, 0, c))]))?.contains("已经过去了") == true)
        #expect(await reason(r, .blockCreate(day: day1, blocks: [newBlock("通宵", at(23, day: 1, c), at(5, day: 2, c))]))?.contains("一块不跨过凌晨 4:00") == true)
        #expect(await reason(r, .blockCreate(day: label(9, c), blocks: [newBlock("远方", at(9, day: 9, c), at(10, day: 9, c))]))?.contains("不在可排的范围") == true)
        #expect(await reason(r, .blockCreate(day: label(2, c), blocks: [newBlock("错日子", at(9, day: 1, c), at(10, day: 1, c))]))?.contains("排一天的每一步都要落在这一天") == true)
        // 同组排完互相重叠
        #expect(await reason(r, .blockCreate(day: day1, blocks: [newBlock("A", at(9, day: 1, c), at(10, day: 1, c)),
                                                                 newBlock("B", at(9, 30, day: 1, c), at(10, 30, day: 1, c))]))?.contains("互相重叠") == true)
        #expect(r.mac.proposals.count == 3, "不合法的一律不进入审批（进去的只有全天事件那条、只改名那条、越级那条）")
    }

    /// 原则 10：读不到你的日历不当作空——这次不校验、明说。
    @Test func unreadableCalendarIsNotTreatedAsEmpty() async throws {
        let r = try rig()
        let c = r.clock
        r.busy.failure = "没有日历权限"
        #expect(await reason(r, .blockCreate(day: label(1, c), blocks: [newBlock("写论文", at(9, day: 1, c), at(11, day: 1, c))]))?
            .contains("读不到你的日历") == true)
    }

    // MARK: 排一天：整组批准、整组撤销

    func planTomorrow(_ r: Rig, _ ids: (meeting: UUID, gym: UUID, chores: UUID, report: UUID)) -> (ProposalAction, UUID) {
        let c = r.clock
        let paper = UUID()
        var rename = ProposalBlockEdit(id: ids.report); rename.title = "交周报"
        return (.planDay(day: label(1, c), steps: [
            .create(newBlock("写论文", at(9, day: 1, c), at(11, day: 1, c), important: true, id: paper)),
            .move(ProposalBlockMove(id: ids.gym, start: at(19, day: 1, c), end: nil, expectedRevision: nil)),   // 组会后健身，顺到 19:00
            .delete(id: ids.chores, expectedRevision: nil),                                                     // 杂事让位
            .edit(rename),
        ], isUndo: false), paper)
    }

    @Test func planDayBundleApprovesAndUndoesAsAGroup() async throws {
        let r = try rig()
        let c = r.clock
        let ids = try seedTomorrow(r)
        let (action, paper) = planTomorrow(r, ids)
        #expect(action.isDestructive, "含删除步骤 = 删除类")
        let p = try await approve(r, action)
        #expect(p.state == .applied, "\(p.resultNote ?? "")")
        #expect(p.changes.contains(ProposalChange(field: "新计划块", before: nil, after: "明天 09:00–11:00「写论文」（要紧）")))
        #expect(p.changes.contains(ProposalChange(field: "「健身」时间", before: "明天 18:00–19:00", after: "明天 19:00–20:00")))
        #expect(p.changes.contains { $0.field.contains("移入回收站") && $0.before?.contains("杂事") == true })
        #expect(p.changes.contains(ProposalChange(field: "计划块标题", before: "交报告", after: "交周报")))
        #expect(p.changes.last?.field.contains("可整组撤销") == true)
        var now = try blocks(r, day: 1)
        #expect(now[paper] != nil && now[ids.gym]?.start == at(19, day: 1, c) && now[ids.chores] == nil && now[ids.report]?.title == "交周报")
        #expect(p.undoHint?.contains("整组不撤") == true)
        #expect(await r.phone.undo(p.id), "\(r.phone.lastError ?? "")")
        now = try blocks(r, day: 1)
        #expect(now[paper] == nil && now[ids.gym]?.start == at(18, day: 1, c) && now[ids.chores]?.start == at(20, day: 1, c) && now[ids.report]?.title == "交报告")
        let undone = try #require(r.ledger.values.last { $0.event == "undone" })
        #expect(undone.actor == .user && undone.detail.contains("整组撤销 4 步"))
    }

    @Test func planDayUndoRefusedWhenAnyBlockChangedAndNothingMoves() async throws {
        let r = try rig()
        let c = r.clock
        let ids = try seedTomorrow(r)
        let (action, paper) = planTomorrow(r, ids)
        let p = try await approve(r, action)
        try r.plans.updatePlanned(id: ids.gym, start: at(21, day: 1, c), end: at(22, day: 1, c), title: "健身")   // 之后你又亲手挪了健身
        #expect(await r.mac.undo(p.id) == false)
        #expect(r.mac.lastError?.contains("被改过") == true && r.mac.lastError?.contains("整组") == true)
        let now = try blocks(r, day: 1)
        #expect(now[paper] != nil && now[ids.chores] == nil && now[ids.gym]?.start == at(21, day: 1, c), "一步都没撤")
    }

    @Test func planDayExecutionConflictWritesNothing() async throws {
        let r = try rig()
        let c = r.clock
        let ids = try seedTomorrow(r)
        let (action, paper) = planTomorrow(r, ids)
        let p = try #require(await r.mac.submit(draft(action)))
        try r.plans.updatePlanned(id: ids.report, start: at(15, day: 1, c), end: at(16, day: 1, c), title: "交报告（改）")   // 审批前你先改了
        await r.phone.decide(p.id, .approve); await r.mac.refresh()
        let failed = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(failed.state == .failed && failed.resultNote?.contains("被改过") == true)
        let now = try blocks(r, day: 1)
        #expect(now[paper] == nil && now[ids.chores] != nil && now[ids.gym]?.start == at(18, day: 1, c), "整组不写")
    }

    @Test func undoOnlyKindsCannotBeProposed() async throws {
        let r = try rig()
        let c = r.clock
        let ids = try seedTomorrow(r)
        #expect(await reason(r, .planDay(day: label(1, c), steps: [.delete(id: ids.gym, expectedRevision: nil)], isUndo: true))?.contains("只用于撤销") == true)
        #expect(await reason(r, .planDay(day: label(1, c), steps: [.restore(id: ids.gym, deletionID: nil)], isUndo: false))?.contains("只用于撤销") == true)
    }

    // MARK: 预授权：删除与越级永不自动放行

    @Test func preauthNeverAutoAllowsDeleteOrEscalation() async throws {
        let r = try rig()
        let c = r.clock
        let ids = try seedTomorrow(r)
        func rule(_ a: ProposalAction) -> PreauthRule {
            PreauthRule(id: UUID(), createdAt: c.now, createdByDeviceId: "phone", origin: .agent, ruleKind: a.ruleKind,
                        kindLabel: a.ruleKindLabel, scope: .kindOnBetterCalendar, effect: .allow, sourceProposalId: nil)
        }
        func proposal(_ a: ProposalAction, escalation: String? = nil) async throws -> Proposal {
            var p = try #require(await r.mac.submit(draft(a, escalation: escalation)))
            p.state = .pending
            return p
        }
        let delete = ProposalAction.blockDelete(id: ids.chores, expectedRevision: nil)
        #expect(PreauthPolicy.evaluate(try await proposal(delete), rules: [rule(delete)]).route == .ask)
        let (bundle, _) = planTomorrow(r, ids)
        #expect(PreauthPolicy.evaluate(try await proposal(bundle), rules: [rule(bundle)]).route == .ask)
        try r.plans.setPinned(ids: [ids.gym], until: ScheduledBlock.pinExpiry(forStart: at(18, day: 1, c)))
        let pinMove = ProposalAction.moveBlock(id: ids.gym, start: at(21, 30, day: 1, c), end: nil, expectedRevision: nil)
        #expect(PreauthPolicy.evaluate(try await proposal(pinMove, escalation: "他说晚点去"), rules: [rule(pinMove)]).route == .ask)
        // 只加 BetterCalendar 自己的块：「这一类改动且只动 BetterCalendar 自己的东西」可以放行
        let create = ProposalAction.blockCreate(day: label(1, c), blocks: [newBlock("读书", at(9, day: 1, c), at(10, day: 1, c))])
        #expect(PreauthPolicy.evaluate(try await proposal(create), rules: [rule(create)]).route == .apply)
    }

    // MARK: 开关关着 = 与以前完全一致

    @Test func switchOffKeepsTodayOnlyBehavior() async throws {
        let r = try rig(enabled: false)
        let c = r.clock
        let notes = ScheduledBlock(title: "整理笔记", start: at(11, 0, c), end: at(12, 0, c))
        try r.plans.replacePlanned([notes], on: label(0, c))
        #expect(await reason(r, .blockCreate(day: label(1, c), blocks: [newBlock("写论文", at(9, day: 1, c), at(11, day: 1, c))]))?
            .contains("在设置里关着") == true)
        #expect(await reason(r, .moveBlock(id: notes.id, start: at(10, day: 1, c), end: nil, expectedRevision: nil))?.contains("超出今天") == true)
        r.busy.events = [SystemCalendarEvent(title: "牙医", start: at(16, 0, c), end: at(17, 0, c), isAllDay: false, calendarTitle: "家庭")]
        #expect(await reason(r, .moveBlock(id: notes.id, start: at(16, 0, c), end: nil, expectedRevision: nil)) == nil, "关着不读你的日历（和以前一样）")
    }

    // MARK: W11 可调参数：作用于整组里的某一块

    @Test func parameterTargetsOneBlockInTheBundle() async throws {
        let r = try rig()
        let c = r.clock
        let ids = try seedTomorrow(r)
        let (action, paper) = planTomorrow(r, ids)
        var d = draft(action)
        d.parameters = [ProposalParameter(id: "paperStart", label: "写论文几点开始", kind: .timeOfDay, bind: .start, target: paper)]
        let p = try #require(await r.mac.submit(d), "\(r.mac.lastError ?? "")")
        #expect(p.parameters?.first?.defaultValue == .date(at(9, day: 1, c)))
        let tuned = try await r.mac.checkTuning(p, option: 0, values: ["paperStart": .date(at(8, day: 1, c))])
        #expect(tuned.changes?.contains(ProposalChange(field: "新计划块", before: nil, after: "明天 08:00–10:00「写论文」（要紧）")) == true)
        // 调到和健身撞上：当场写明原因
        await #expect(throws: (any Error).self) { _ = try await r.mac.checkTuning(p, option: 0, values: ["paperStart": .date(at(17, 30, day: 1, c))]) }
        // 多块方案里不写 target → 拒收
        var bad = draft(action)
        bad.parameters = [ProposalParameter(id: "x", label: "几点", kind: .timeOfDay, bind: .start)]
        #expect(await r.mac.submit(bad) == nil && r.mac.lastError?.contains("target") == true)
    }

    @Test func newActionsRoundTripThroughCodable() throws {
        let c = Clock()
        let actions: [ProposalAction] = [
            .blockCreate(day: label(1, c), blocks: [newBlock("a", c.now, c.now.addingTimeInterval(600), deadline: c.now.addingTimeInterval(900))]),
            .blockEdit(ProposalBlockEdit(id: UUID(), title: "t", duration: 600, isFixed: true, important: false, deadline: .clear, expectedRevision: "r")),
            .blockDelete(id: UUID(), expectedRevision: "r"),
            .planDay(day: label(1, c), steps: [.restore(id: UUID(), deletionID: UUID()), .edit(ProposalBlockEdit(id: UUID(), deadline: .set(c.now)))], isUndo: true),
        ]
        for a in actions {
            #expect(try JSONDecoder().decode(ProposalAction.self, from: JSONEncoder().encode(a)) == a)
        }
    }
}

// MARK: - 桥接严格解析

@MainActor @Suite struct W18BridgeParsingTests {
    func file(_ action: [String: Any], extra: [String: Any] = [:]) throws -> Data {
        var o: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString, "title": "排明天", "reason": "他说的", "action": action]
        for (k, v) in extra { o[k] = v }
        return try JSONSerialization.data(withJSONObject: o)
    }

    @Test func validShapesParse() throws {
        let gym = UUID(), paper = UUID()
        let create = try AgentBridgeIO.draft(from: file(["kind": "blockCreate", "day": "2026-10-20", "blocks": [
            ["title": "写论文", "start": "2026-10-20T09:00:00-04:00", "durationMinutes": 120, "important": true],
            ["id": paper.uuidString, "title": "读书", "start": "2026-10-20T13:00:00-04:00", "end": "2026-10-20T14:00:00-04:00", "fixed": true,
             "deadline": "2026-10-20T18:00:00-04:00"]]]))
        guard case let .blockCreate(day, blocks) = create.action else { Issue.record("应解析为 blockCreate"); return }
        #expect(day == Calendar.current.startOfDay(for: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20))!))
        #expect(blocks.count == 2 && blocks[0].end.timeIntervalSince(blocks[0].start) == 7200 && blocks[0].important && blocks[1].id == paper && blocks[1].isFixed)
        #expect(create.experiment == false)
        // 没给 id 的块：由提案 id + 序号推出（重复导入同一文件得到同样的 id）
        let data = try file(["kind": "blockCreate", "day": "2026-10-20", "blocks": [["title": "x", "start": "2026-10-20T09:00:00-04:00", "durationMinutes": 30]]])
        guard case let .blockCreate(_, b1) = try AgentBridgeIO.draft(from: data).action, case let .blockCreate(_, b2) = try AgentBridgeIO.draft(from: data).action else { return }
        #expect(b1[0].id == b2[0].id)

        let edit = try AgentBridgeIO.draft(from: file(["kind": "blockEdit", "blockId": gym.uuidString, "durationMinutes": 90, "clearDeadline": true, "fixed": false]))
        #expect(edit.action == .blockEdit(ProposalBlockEdit(id: gym, duration: 5400, isFixed: false, deadline: .clear)))
        let del = try AgentBridgeIO.draft(from: file(["kind": "blockDelete", "blockId": gym.uuidString, "expectedRevision": "abc"]))
        #expect(del.action == .blockDelete(id: gym, expectedRevision: "abc"))

        let plan = try AgentBridgeIO.draft(from: file(["kind": "planDay", "day": "2026-10-20", "steps": [
            ["op": "create", "id": paper.uuidString, "title": "写论文", "start": "2026-10-20T09:00:00-04:00", "durationMinutes": 120],
            ["op": "move", "blockId": gym.uuidString, "start": "2026-10-20T19:00:00-04:00"],
            ["op": "edit", "blockId": UUID().uuidString, "title": "交周报"],
            ["op": "delete", "blockId": UUID().uuidString]]],
            extra: ["parameters": [["id": "s", "label": "几点开始", "type": "timeOfDay", "bind": "start", "target": paper.uuidString]]]))
        guard case let .planDay(_, steps, isUndo) = plan.action else { Issue.record("应解析为 planDay"); return }
        #expect(steps.map(\.op) == ["create", "move", "edit", "delete"] && !isUndo && plan.action.isDestructive)
        #expect(plan.parameters.first?.target == paper)
    }

    @Test func malformedInputIsRejected() throws {
        let id = UUID().uuidString
        let start = "2026-10-20T09:00:00-04:00"
        let bad: [[String: Any]] = [
            ["kind": "blockCreate", "blocks": [["title": "x", "start": start, "durationMinutes": 30]]],                         // 缺 day
            ["kind": "blockCreate", "day": "10/20", "blocks": [["title": "x", "start": start, "durationMinutes": 30]]],          // day 格式
            ["kind": "blockCreate", "day": "2026-10-20", "blocks": []],
            ["kind": "blockCreate", "day": "2026-10-20", "blocks": [["title": "x", "start": start]]],                           // end / 时长都没有
            ["kind": "blockCreate", "day": "2026-10-20", "blocks": [["title": "x", "start": start, "end": start, "durationMinutes": 30]]],   // 两个都写
            ["kind": "blockCreate", "day": "2026-10-20", "blocks": [["start": start, "durationMinutes": 30]]],                   // 没标题也没关联
            ["kind": "blockCreate", "day": "2026-10-20", "blocks": [["title": "x", "start": "9:00", "durationMinutes": 30]]],    // 时间不带时区
            ["kind": "blockCreate", "day": "2026-10-20", "blocks": [["title": "x", "start": start, "durationMinutes": 0]]],
            ["kind": "blockCreate", "day": "2026-10-20", "blocks": [["title": "x", "start": start, "durationMinutes": 30, "color": "red"]]],   // 不认识的字段
            ["kind": "blockCreate", "day": "2026-10-20", "blocks": [["title": "x", "start": start, "durationMinutes": 30, "fixed": "yes"]]],
            ["kind": "blockEdit", "blockId": id],                                                                                // 什么都不改
            ["kind": "blockEdit", "blockId": id, "deadline": start, "clearDeadline": true],
            ["kind": "blockEdit", "blockId": "nope", "title": "x"],
            ["kind": "blockEdit", "blockId": id, "start": start],                                                                 // 改时间请用 move
            ["kind": "blockDelete"],
            ["kind": "blockDelete", "blockId": id, "isUndo": true],
            ["kind": "planDay", "day": "2026-10-20", "steps": []],
            ["kind": "planDay", "day": "2026-10-20", "steps": [["op": "teleport", "blockId": id]]],
            ["kind": "planDay", "day": "2026-10-20", "steps": [["kind": "moveBlock", "blockId": id, "start": start]]],
            ["kind": "planDay", "day": "2026-10-20", "steps": [["op": "restore", "blockId": id]]],                              // 撤销专用
            ["kind": "planDay", "day": "2026-10-20", "steps": [["op": "delete", "blockId": id], ["op": "move", "blockId": id, "start": start]]],   // 同一块两次
            ["kind": "planDay", "day": "2026-10-20", "isUndo": true, "steps": [["op": "delete", "blockId": id]]],
        ]
        for action in bad {
            #expect(throws: AgentBridgeError.self, "应拒收：\(action)") { try AgentBridgeIO.draft(from: file(action)) }
        }
        // 参数的 target 必须是 UUID
        let withBadTarget = try file(["kind": "blockCreate", "day": "2026-10-20", "blocks": [["title": "x", "start": start, "durationMinutes": 30]]],
                                     extra: ["parameters": [["id": "s", "label": "几点", "type": "timeOfDay", "bind": "start", "target": "first"]]])
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.draft(from: withBadTarget) }
    }
}

// MARK: - 上下文：未来几天的计划 + 你的日历「已占用」

@MainActor @Suite struct W18ContextTests {
    final class BusyCalendar: CalendarReading {
        var events: [SystemCalendarEvent] = []
        func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft] { [] }
        func externalEvents(in window: DateInterval) async throws -> [SystemCalendarEvent] {
            events.filter { $0.start < window.end && $0.end > window.start }
        }
    }

    @Test func contextExposesFutureDayBlocksWithIdsRevisionsPinsAndOccupied() async throws {
        let container = try ModelContainer(for: DataArchiveStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15))!
        let plans = PlanStore(context: container.mainContext, now: { now })
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let h: (Int, Date) -> Date = { hour, day in cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)! }
        let gym = ScheduledBlock(title: "健身", start: h(18, tomorrow), end: h(19, tomorrow))
        let meeting = ScheduledBlock(title: "组会 5529", start: h(14, tomorrow), end: h(15, tomorrow), isFixed: true)
        try plans.replacePlanned([gym, meeting], on: tomorrow)
        try plans.setPinned(ids: [gym.id], until: ScheduledBlock.pinExpiry(forStart: gym.start))
        let busy = BusyCalendar()
        busy.events = [SystemCalendarEvent(title: "组会 5529", start: h(14, tomorrow), end: h(15, tomorrow), isAllDay: false, calendarTitle: "学校"),
                       SystemCalendarEvent(title: "牙医", start: h(10, tomorrow), end: h(11, tomorrow), isAllDay: false, calendarTitle: "家庭"),
                       SystemCalendarEvent(title: "生日", start: tomorrow, end: cal.date(byAdding: .day, value: 1, to: tomorrow)!, isAllDay: true, calendarTitle: "家庭")]
        let gatherer = AgentContextGatherer(planStore: plans, actualStore: plans, longTasks: nil, calendarStore: busy, journalStore: nil,
                                            running: { .init() }, journalAllowed: { false }, planEditing: { true })
        let c = await gatherer.snapshot(now: now)
        #expect(JSONSerialization.isValidJSONObject(c))
        #expect((c["today"] as? [String: Any])?["day"] as? String == "2026-10-18")
        let planning = try #require(c["planning"] as? [String: Any])
        #expect(planning["enabled"] as? Bool == true && planning["horizonDays"] as? Int == PlanEditRules.horizonDays)
        let days = try #require(planning["days"] as? [[String: Any]])
        #expect(days.count == PlanEditRules.horizonDays && days[0]["day"] as? String == "2026-10-19")
        let rows = try #require(days[0]["blocks"] as? [[String: Any]])
        let gymRow = try #require(rows.first { $0["title"] as? String == "健身" })
        #expect(gymRow["id"] as? String == gym.id.uuidString && gymRow["revision"] as? String == ProposalRevision.block(gym))
        #expect(gymRow["pinnedUntil"] is String, "图钉要让智能体看得到（动它须越级）")
        #expect(rows.first { $0["title"] as? String == "组会 5529" }?["fixed"] as? Bool == true)
        let occupied = try #require((planning["occupied"] as? [String: Any])?["items"] as? [[String: Any]])
        #expect(occupied.count == 2, "全天事件不占时段")
        #expect(occupied.first { $0["title"] as? String == "组会 5529" }?["linkedBlockId"] as? String == meeting.id.uuidString)
        #expect(occupied.first { $0["title"] as? String == "牙医" }?["linkedBlockId"] == nil)
        // 开关关着：不附未来几天，写明只能挪今天
        let off = AgentContextGatherer(planStore: plans, actualStore: plans, longTasks: nil, calendarStore: busy, journalStore: nil,
                                       running: { .init() }, journalAllowed: { false }, planEditing: { false })
        let offPlanning = try #require(await off.snapshot(now: now)["planning"] as? [String: Any])
        #expect(offPlanning["enabled"] as? Bool == false && offPlanning["days"] == nil)
        _ = container
    }
}
