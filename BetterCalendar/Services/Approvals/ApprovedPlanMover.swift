//
//  ApprovedPlanMover.swift
//  BetterCalendar
//
//  SPEC §19 W1 ③：审批通过的「挪动今天某个计划块」。
//  - 规则校验（PlanMoveRules，纯函数）：固定块不动、正在做/做完的不动、不挪进过去、不出今天、不越 DDL、
//    不与别的块重叠（不硬塞，也不悄悄连带挪别的块——卡片上写什么就只改什么）；放不下给出明确原因。
//  - 写入（ApprovedPlanMover）：计划块写权限的**第四个持有者**（前三：确认写入 / 对账回流 / 时间线协调器）。
//    理由：Jason 在卡片上批准的挪动 = 他亲手拖动（E1）的另一种输入方式，与对账回流同构——
//    只按 ID 改单块时间（updatePlanned），不整日覆盖、不碰标题以外的元数据。写后：
//      · 发 planChangedExternally（带 updatedIDs）→ 时间线协调器把它当手改钉住 30 分钟（D12 用户最后动作赢）、排日程页刷新；
//      · 未开工的日子由 ProjectionService 重投影绿色（实时日的画面归执行层橙色预览，同协调器影子期契约）。
//    权限表（架构地图 §2「计划块」行）需补这一行，见 W1 交付报告。
//

import Foundation

/// 挪动计划块的本地排布规则（纯函数、可单测）。
enum PlanMoveRules {
    struct Context {
        /// 今天（逻辑日）的全部计划块。
        var blocks: [ScheduledBlock]
        var now: Date
        /// 今天的逻辑日窗口（4:00–次日 4:00）。
        var dayWindow: DateInterval
        /// 已完成 / 后台同时在做的计划块（不挪，也不当障碍——它们已不占「从现在起」的时间线）。
        var settledIDs: Set<UUID> = []
        /// 前台正在做的块：不挪；它此刻占着的时间段是障碍。
        var active: (id: UUID, start: Date, end: Date)? = nil
    }

    struct Checked {
        var block: ScheduledBlock
        var start: Date
        var end: Date
    }

    static func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    static func span(_ s: Date, _ e: Date) -> String { "\(hm(s))–\(hm(e))" }

    /// 校验通过返回落点；不通过抛 ProposalExecutionError.invalid（带给人看的原因）。
    static func validate(id: UUID, start: Date, end requestedEnd: Date?, in c: Context) throws -> Checked {
        guard let block = c.blocks.first(where: { $0.id == id }) else {
            throw ProposalExecutionError.invalid("今天的计划里找不到这块（可能已删除或不在今天）")
        }
        let name = "「\(block.title)」"
        guard !block.isFixed else { throw ProposalExecutionError.invalid("\(name)是固定安排，按规则不挪") }
        if c.active?.id == id { throw ProposalExecutionError.invalid("\(name)正在计时，先结束或暂停再挪") }
        guard !c.settledIDs.contains(id) else { throw ProposalExecutionError.invalid("\(name)已经做完或正在同时做，不挪") }
        let end = requestedEnd ?? start.addingTimeInterval(block.end.timeIntervalSince(block.start))
        let duration = end.timeIntervalSince(start)
        guard duration >= 60, duration <= 16 * 3600 else { throw ProposalExecutionError.invalid("新时间段无效（结束须晚于开始，且不超过 16 小时）") }
        guard start != block.start || end != block.end else { throw ProposalExecutionError.invalid("\(name)已经在 \(span(start, end))，无需挪动") }
        guard start >= c.now.addingTimeInterval(-60) else {
            throw ProposalExecutionError.invalid("新开始时间 \(hm(start)) 已经过去了，只能往「从现在起」挪")
        }
        guard start >= c.dayWindow.start, end <= c.dayWindow.end else {
            throw ProposalExecutionError.invalid("新时间 \(span(start, end)) 超出今天（逻辑日到次日 4:00），本动作只挪今天之内")
        }
        if let ddl = block.deadline, end > ddl {
            throw ProposalExecutionError.invalid("挪到 \(span(start, end)) 会越过截止时间 \(hm(ddl))，按规则不越截止")
        }
        // 障碍：前台正在做的块此刻占的时间段 + 其余仍在「从现在起」时间线上的块（未落定、尚未结束）。
        var obstacles: [(title: String, start: Date, end: Date, fixed: Bool)] = []
        if let a = c.active, a.id != id, let b = c.blocks.first(where: { $0.id == a.id }) {
            obstacles.append((b.title, a.start, max(a.end, c.now), false))
        }
        for b in c.blocks where b.id != id && b.id != c.active?.id && !c.settledIDs.contains(b.id) && b.end > c.now {
            obstacles.append((b.title, b.start, b.end, b.isFixed))
        }
        if let hit = obstacles.sorted(by: { $0.start < $1.start }).first(where: { $0.start < end && start < $0.end }) {
            if hit.fixed {
                throw ProposalExecutionError.invalid("新时间 \(span(start, end)) 与固定安排「\(hit.title)」(\(span(hit.start, hit.end))) 重叠，固定安排不动，放不下")
            }
            throw ProposalExecutionError.invalid("新时间 \(span(start, end)) 和「\(hit.title)」(\(span(hit.start, hit.end))) 重叠，放不下（不硬塞，也不连带挪别的块；要一起挪请分别提出）")
        }
        return Checked(block: block, start: start, end: end)
    }
}

/// 挪动计划块的能力缝（执行器只依赖它；测试可换内存实现）。
@MainActor protocol PlanBlockMoving: AnyObject {
    /// 今天（逻辑日）的某个计划块；不在今天 = nil。
    func todayBlock(id: UUID) throws -> ScheduledBlock?
    /// 只校验不写。
    func check(id: UUID, start: Date, end: Date?) throws -> PlanMoveRules.Checked
    /// 版本核对 + 校验 + 写入 + 刷新画面；返回改动前后。目标版本已变 → ProposalExecutionError.conflict。
    func move(id: UUID, start: Date, end: Date?, expectedRevision: String) async throws -> (before: ScheduledBlock, after: ScheduledBlock, note: String)
}

@MainActor final class ApprovedPlanMover: PlanBlockMoving {
    private let planStore: PlanReading & PlanWriting
    private let projection: ProjectionService?
    private let startedDays: StartedDayStore?
    /// 执行进展（已完成 / 正在做）；组装点在执行层建好后挂上。
    weak var progress: (any ExecutionProgressReading)?
    private let now: () -> Date

    /// 写后发的通知来源标记（时间线协调器只跳过自家标记，其余带 updatedIDs 的一律进手改冷却）。
    static let notificationSource = "approvedProposal"

    init(planStore: PlanReading & PlanWriting, projection: ProjectionService?, startedDays: StartedDayStore?,
         now: @escaping () -> Date = { .now }) {
        self.planStore = planStore; self.projection = projection; self.startedDays = startedDays; self.now = now
    }

    private var label: Date { DayContext.logicalStartOfDay(now()) }

    private func context() throws -> PlanMoveRules.Context {
        let label = label
        let settled = progress?.settledPlannedIDs ?? []
        let prediction = progress?.activePrediction
        return PlanMoveRules.Context(blocks: try planStore.plannedBlocks(on: label), now: now(),
                                     dayWindow: DayContext.logicalWindow(forLabel: label),
                                     settledIDs: settled.subtracting(prediction.map { [$0.id] } ?? []),
                                     active: prediction.map { ($0.id, $0.start, $0.end) })
    }

    func todayBlock(id: UUID) throws -> ScheduledBlock? {
        try planStore.plannedBlocks(on: label).first { $0.id == id }
    }

    func check(id: UUID, start: Date, end: Date?) throws -> PlanMoveRules.Checked {
        try PlanMoveRules.validate(id: id, start: start, end: end, in: context())
    }

    func move(id: UUID, start: Date, end: Date?, expectedRevision: String) async throws -> (before: ScheduledBlock, after: ScheduledBlock, note: String) {
        let ctx = try context()
        guard let current = ctx.blocks.first(where: { $0.id == id }) else {
            throw ProposalExecutionError.conflict("这块已不在今天的计划里（可能被删除或挪到别的日子）")
        }
        guard ProposalRevision.block(current) == expectedRevision else {
            throw ProposalExecutionError.conflict("「\(current.title)」在提案之后被改过（现在 \(PlanMoveRules.span(current.start, current.end))），不覆盖")
        }
        let checked = try PlanMoveRules.validate(id: id, start: start, end: end, in: ctx)
        try planStore.updatePlanned(id: id, start: checked.start, end: checked.end, title: current.title,
                                   reason: .agentApproval)
        var after = current; after.start = checked.start; after.end = checked.end
        var note = "已把「\(current.title)」从 \(PlanMoveRules.span(current.start, current.end)) 挪到 \(PlanMoveRules.span(checked.start, checked.end))"
        NotificationCenter.default.post(name: ReconcileService.planChangedExternally, object: nil,
                                        userInfo: ["updatedIDs": [id], "source": Self.notificationSource])
        let label = label
        if !(startedDays?.isStarted(label) ?? false), let projection {
            do { try await projection.project(label: label) } catch {
                DevLog.shared.warn("多端审批", "挪动已写入，但日历画面刷新失败：\(error.localizedDescription)")
                note += "（日历画面稍后同步：\(error.localizedDescription)）"
            }
        }
        DevLog.shared.info("多端审批", note)
        return (current, after, note)
    }
}
