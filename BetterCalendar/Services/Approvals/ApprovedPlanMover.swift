//
//  ApprovedPlanMover.swift
//  BetterCalendar
//
//  SPEC §19 W1 ③：审批通过的「挪动今天某个计划块」；W8（Jason 2026-10-18）：一次挪多块（moveBlocks）；
//  W18（Jason 2026-10-19）：智能体排时间线——加块 / 改块 / 删块 / 跨天挪 / 排一天（整组）。
//  - 规则校验：全部走 PlanEditRules（唯一一套排布规则，纯函数）；PlanMoveRules 只是 W8 时代 API 的薄包装。
//    **最终整体布局**合法才写；放不下给出明确原因，卡片上写什么就只改什么，不悄悄连带挪、不悄悄挤。
//  - 写入（ApprovedPlanMover）：计划块写权限的**第四个持有者**（前三：确认写入 / 对账回流 / 时间线协调器）。
//    理由：Jason 在卡片上批准的改动 = 他亲手改（E1）的另一种输入方式，与对账回流同构——只经 PlanStore 按 ID 改，
//    不整日覆盖；删除走回收站（RetainedDeletion，30 天内可恢复）。写后：
//      · 发 planChangedExternally（带 updatedIDs）→ 时间线协调器把它当手改冷却、排日程页刷新；
//      · 挪过 / 改过时长的块钉住到它那天结束（P4 Q6：你批准的位置等同你亲手放的，自动调整绕开）；新加的块不钉
//        （= 旧「确认计划」写下的块，当天照常参与自愈）；
//      · 请 CalendarSyncEngine 重投影涉及的每一天（P4.1：它是唯一的日历写者，这里从不碰日历）。
//    权限表（架构地图 §2「计划块」行）需补这一行，见 W1 / W18 交付报告。
//  - W18 开关（agent.planEditing.enabled，默认开——日用版有意例外，见 PlanEditingSettings）：关着时只认今天、
//    不读你的日历当已占用，与 W18 之前完全一致；新种类在执行器里直接拒收。
//

import Foundation

/// W18 开关：智能体能不能排时间线（今天以外的日子、加 / 改 / 删块、排一天）。
/// **有意例外**：W17 约定新功能在日用版默认关；这条是 Jason 日用要走的主流程的核心，而且只是给智能体加能力，
/// 每项改动仍要他批准 → 两个通道都默认开（Jason 2026-10-19 任务说明）。随 iCloud 设置同步（SettingsSync 白名单）。
nonisolated enum PlanEditingSettings {
    static let key = "agent.planEditing.enabled"
    static var enabled: Bool {
        get { ExperimentDefaults.bool(key, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// W8 时代的「挪今天」规则 API（测试与旧调用方在用）：薄包装，规则本身在 PlanEditRules。
enum PlanMoveRules {
    struct Context {
        /// 今天（逻辑日）的全部计划块。
        var blocks: [ScheduledBlock]
        var now: Date
        /// 今天的逻辑日窗口（4:00–次日 4:00）。
        var dayWindow: DateInterval
        var settledIDs: Set<UUID> = []
        var active: (id: UUID, start: Date, end: Date)? = nil
    }

    struct Move: Equatable {
        var id: UUID
        var start: Date
        var end: Date?
    }

    struct Checked {
        var block: ScheduledBlock
        var start: Date
        var end: Date
    }

    nonisolated static let maxGroup = PlanEditRules.maxGroup

    static func hm(_ d: Date) -> String { PlanEditRules.hm(d) }
    static func span(_ s: Date, _ e: Date) -> String { PlanEditRules.span(s, e) }

    static func validate(id: UUID, start: Date, end requestedEnd: Date?, in c: Context) throws -> Checked {
        try validateGroup([Move(id: id, start: start, end: requestedEnd)], in: c)[0]
    }

    static func validateGroup(_ moves: [Move], in c: Context, restoring: Bool = false) throws -> [Checked] {
        let ctx = PlanEditRules.Context(blocks: c.blocks, now: c.now, window: c.dayWindow, settledIDs: c.settledIDs, active: c.active)
        let steps = moves.map { ProposalPlanStep.move(ProposalBlockMove(id: $0.id, start: $0.start, end: $0.end, expectedRevision: nil)) }
        return try PlanEditRules.evaluate(steps, in: ctx, restoring: restoring).compactMap { r in
            guard let b = r.before, let a = r.after else { return nil }
            return Checked(block: b, start: a.start, end: a.end)
        }
    }
}

/// 一次写入的结果：每步改动前后（顺序同输入）+ 反向步骤（带写后的版本，供撤销）+ 刷新附注。
struct PlanEditApplied {
    var resolved: [PlanEditRules.Resolved]
    /// 与 resolved 一一对应的反向步骤（撤销时逆序执行）。
    var inverse: [ProposalPlanStep]
    /// 日历画面刷新失败等附注（空 = 没事）。
    var note: String
}

/// 时间线改动的能力缝（执行器只依赖它；测试用 ApprovedPlanMover + 内存 PlanStore）。
@MainActor protocol PlanBlockMoving: AnyObject {
    /// W18 开关此刻是否打开（关 = 只认今天）。
    var planEditingEnabled: Bool { get }
    /// 可排范围内（今天起；开关关着只有今天）的某个计划块；不在 = nil。
    func windowBlock(id: UUID) throws -> ScheduledBlock?
    /// 只校验不写：依据真实数据（含你的日历 = 已占用）对最终整体布局校验。
    func evaluate(_ steps: [ProposalPlanStep], restoring: Bool, planDay: Date?) async throws -> [PlanEditRules.Resolved]
    /// 逐步核版本（任一步已变 → conflict，整组不写）+ 整体校验 + 写入 + 刷新画面。
    func apply(_ steps: [ProposalPlanStep], restoring: Bool, planDay: Date?) async throws -> PlanEditApplied
}

@MainActor final class ApprovedPlanMover: PlanBlockMoving {
    private let planStore: PlanReading & PlanWriting
    private let projection: ProjectionService?
    private let startedDays: StartedDayStore?   // P4 起不再按开工与否分流（保留注入，组装点不变）
    /// 执行进展（已完成 / 正在做）；组装点在执行层建好后挂上。
    weak var progress: (any ExecutionProgressReading)?
    /// W18：你的日历事件（只读，组装点按「排布时当作已占用的日历」设置过滤）。nil = 没接（测试）；读失败 = 这次不校验、明说。
    var occupiedEvents: ((DateInterval) async throws -> [SystemCalendarEvent])?
    /// W26b：早晚通知重排（改动涉及已排通知的那一天 → 按新计划重排）。nil = 不管通知（旧测试）。
    var reminderRefresher: DailyReminderRefresher?
    /// W18 开关（组装点 / 测试可换）。
    var enabledFlag: () -> Bool = { PlanEditingSettings.enabled }
    private let now: () -> Date

    /// 写后发的通知来源标记（时间线协调器只跳过自家标记，其余带 updatedIDs 的一律进手改冷却）。
    static let notificationSource = "approvedProposal"

    init(planStore: PlanReading & PlanWriting, projection: ProjectionService?, startedDays: StartedDayStore?,
         now: @escaping () -> Date = { .now }) {
        self.planStore = planStore; self.projection = projection; self.startedDays = startedDays; self.now = now
    }

    var planEditingEnabled: Bool { enabledFlag() }
    private var horizon: Int { planEditingEnabled ? PlanEditRules.horizonDays : 0 }
    private var labels: [Date] {
        let today = DayContext.logicalStartOfDay(now())
        return (0...horizon).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    private func windowBlocks() throws -> [ScheduledBlock] { try planStore.plannedBlocks(onLabels: labels) }

    func windowBlock(id: UUID) throws -> ScheduledBlock? { try windowBlocks().first { $0.id == id } }

    private func context(_ steps: [ProposalPlanStep]) async throws -> PlanEditRules.Context {
        let now = now()
        let blocks = try windowBlocks()
        let window = PlanEditRules.window(now: now, horizon: horizon)
        let settled = progress?.settledPlannedIDs ?? []
        let prediction = progress?.activePrediction
        var ctx = PlanEditRules.Context(blocks: blocks, now: now, window: window,
                                        settledIDs: settled.subtracting(prediction.map { [$0.id] } ?? []),
                                        active: prediction.map { ($0.id, $0.start, $0.end) })
        if planEditingEnabled, let occupiedEvents {
            let events: [SystemCalendarEvent]
            do { events = try await occupiedEvents(window) } catch {
                // 原则 10：不设保险降级——读不到你的日历就不假装它是空的
                DevLog.shared.warn("多端审批", "读不到你的日历，时间线改动这次没法校验：\(error.localizedDescription)")
                throw ProposalExecutionError.unavailable("读不到你的日历（排布要把你的安排当已占用），这次没法校验，没有改动：\(error.localizedDescription)")
            }
            let busy = events.filter { !$0.isAllDay && $0.end > $0.start }
            let links = ExternalEventLinker.links(blocks: blocks, events: busy)
            ctx.occupied = busy.map { e in
                PlanEditRules.Occupied(title: e.title, start: e.start, end: e.end, calendar: e.calendarTitle,
                                       linkedBlockID: links.first { $0.value == e }?.key)
            }
        }
        for case let .restore(id, _) in steps {
            if let t = try planStore.trashedPlanned(id: id) { ctx.trashed[id] = t }
        }
        return ctx
    }

    func evaluate(_ steps: [ProposalPlanStep], restoring: Bool, planDay: Date?) async throws -> [PlanEditRules.Resolved] {
        try PlanEditRules.evaluate(steps, in: await context(steps), restoring: restoring, planDay: planDay)
    }

    func apply(_ steps: [ProposalPlanStep], restoring: Bool, planDay: Date?) async throws -> PlanEditApplied {
        let ctx = try await context(steps)
        let single = steps.count == 1
        let byID = Dictionary(ctx.blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // ① 先逐步核版本：任一块在提案（或执行）之后被改过 → 整组不写。
        for step in steps {
            let id: UUID, expected: String?
            switch step {
            case let .move(m): id = m.id; expected = m.expectedRevision
            case let .edit(e): id = e.id; expected = e.expectedRevision
            case let .delete(i, rev): id = i; expected = rev
            case .create, .restore: continue
            }
            guard let current = byID[id] else {
                throw ProposalExecutionError.conflict(single ? "这块已不在计划里（可能被删除或挪到了可排范围以外）"
                                                             : "有一块已不在计划里（可能被删除或挪到了可排范围以外），整组不改")
            }
            guard let expected else { throw ProposalExecutionError.invalid("「\(current.title)」缺少基线版本，未执行") }
            guard ProposalRevision.block(current) == expected else {
                throw ProposalExecutionError.conflict("「\(current.title)」在提案之后被改过（现在 \(PlanEditRules.when(current.start, current.end, now: ctx.now))），"
                                                      + (single ? "不覆盖" : "整组不覆盖"))
            }
        }
        // ② 整体校验最终布局。
        let resolved = try PlanEditRules.evaluate(steps, in: ctx, restoring: restoring, planDay: planDay)
        // ③ 写入；中途失败 → 已写的步骤逆序回滚（尽力），再抛错（不留半组）。
        var inverse: [ProposalPlanStep] = []
        var written: [ProposalPlanStep] = []
        do {
            for r in resolved {
                let back = try write(r)
                inverse.append(back); written.append(back)
            }
        } catch {
            for back in written.reversed() {
                do { try rollback(back) } catch {
                    DevLog.shared.error("多端审批", "时间线整组写入中途失败后，有一步没能回滚：\(error.localizedDescription)")
                }
            }
            DevLog.shared.error("多端审批", "时间线整组写入失败，已写的步骤已回滚：\(error.localizedDescription)")
            throw error
        }
        let note = await afterWrite(resolved, restoring: restoring)
        return PlanEditApplied(resolved: resolved, inverse: inverse, note: note)
    }

    /// 写一步，返回它的反向步骤（带写后的版本）。
    private func write(_ r: PlanEditRules.Resolved) throws -> ProposalPlanStep {
        let reason = PlanWriteReason.agentApproval
        switch r.step {
        case .create:
            let a = r.after!
            try planStore.insertPlanned([a], reason: reason)
            return .delete(id: a.id, expectedRevision: ProposalRevision.block(try stored(a.id)))
        case .move:
            let b = r.before!, a = r.after!
            try planStore.updatePlanned(id: b.id, start: a.start, end: a.end, title: b.title, reason: reason)
            return .move(ProposalBlockMove(id: b.id, start: b.start, end: b.end, expectedRevision: ProposalRevision.block(try stored(b.id))))
        case let .edit(e):
            let b = r.before!, a = r.after!
            if e.title != nil || e.duration != nil {
                try planStore.updatePlanned(id: b.id, start: a.start, end: a.end, title: a.title, reason: reason)
            }
            if e.isFixed != nil || e.important != nil || e.deadline != nil {
                try planStore.updatePlannedAttributes(id: b.id, isFixed: a.isFixed, priority: a.priority, deadline: a.deadline, reason: reason)
            }
            var back = ProposalBlockEdit(id: b.id, expectedRevision: ProposalRevision.block(try stored(b.id)))
            if e.title != nil { back.title = b.title }
            if e.duration != nil { back.duration = b.end.timeIntervalSince(b.start) }
            if e.isFixed != nil { back.isFixed = b.isFixed }
            if e.important != nil { back.important = b.priority == .important }
            if e.deadline != nil { back.deadline = b.deadline.map { .set($0) } ?? .clear }
            return .edit(back)
        case .delete:
            let b = r.before!
            try planStore.deletePlanned(ids: [b.id], reason: reason)
            return .restore(id: b.id, deletionID: try planStore.trashedPlanned(id: b.id)?.deletionID)
        case let .restore(id, deletionID):
            try planStore.restorePlanned(id: id, deletionID: deletionID, reason: reason)
            return .delete(id: id, expectedRevision: ProposalRevision.block(try stored(id)))
        }
    }

    /// 回滚一步（不再校验，只把数据放回去）。
    private func rollback(_ back: ProposalPlanStep) throws {
        let reason = PlanWriteReason.agentApproval
        switch back {
        case let .delete(id, _): try planStore.deletePlanned(ids: [id], reason: reason)
        case let .restore(id, deletionID): try planStore.restorePlanned(id: id, deletionID: deletionID, reason: reason)
        case let .move(m):
            let cur = try stored(m.id)
            try planStore.updatePlanned(id: m.id, start: m.start, end: m.end ?? cur.end, title: cur.title, reason: reason)
        case let .edit(e):
            let cur = try stored(e.id)
            if e.title != nil || e.duration != nil {
                try planStore.updatePlanned(id: e.id, start: cur.start, end: e.duration.map { cur.start.addingTimeInterval($0) } ?? cur.end,
                                           title: e.title ?? cur.title, reason: reason)
            }
            if e.isFixed != nil || e.important != nil || e.deadline != nil {
                var deadline = cur.deadline
                switch e.deadline { case let .set(d)?: deadline = d; case .clear?: deadline = nil; case nil: break }
                try planStore.updatePlannedAttributes(id: e.id, isFixed: e.isFixed ?? cur.isFixed,
                                                      priority: e.important.map { $0 ? .important : .normal } ?? cur.priority,
                                                      deadline: deadline, reason: reason)
            }
        case .create: break
        }
    }

    private func stored(_ id: UUID) throws -> ScheduledBlock {
        guard let b = try windowBlock(id: id) else {
            throw ProposalExecutionError.unavailable("写入后读不回这一块，未完成")
        }
        return b
    }

    /// 写后：通知时间线协调器 + 请日历同步引擎重投影涉及的每一天。
    /// Jason 2026-10-19：**只钉你亲手拖的**——批准智能体的挪动 / 改时长不钉（那是智能体提议的位置，不是你亲手放的），当天照常参与自动调整；
    /// 原来就钉着的块保持钉着（动它本来就要越级）。返回附加说明（刷新失败时）。
    private func afterWrite(_ resolved: [PlanEditRules.Resolved], restoring: Bool) async -> String {
        let touched = resolved.compactMap { $0.after?.id }
        NotificationCenter.default.post(name: ReconcileService.planChangedExternally, object: nil,
                                        userInfo: ["updatedIDs": touched, "source": Self.notificationSource])
        let days = Set(resolved.flatMap { [$0.before?.start, $0.after?.start].compactMap { $0 }.map(DayContext.logicalStartOfDay) })
        await reminderRefresher?.refresh(affecting: days)
        guard let projection else { return "" }
        var failures: [String] = []
        for label in days.sorted() {
            do { try await projection.project(label: label) } catch {
                DevLog.shared.warn("多端审批", "改动已写入，但 \(PlanEditRules.dayName(label)) 的日历画面刷新失败：\(error.localizedDescription)")
                failures.append(error.localizedDescription)
            }
        }
        return failures.isEmpty ? "" : "（日历画面稍后同步：\(failures[0])）"
    }
}
