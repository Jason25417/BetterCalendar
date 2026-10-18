//
//  ApprovedPlanMover.swift
//  BetterCalendar
//
//  SPEC §19 W1 ③：审批通过的「挪动今天某个计划块」；W8（Jason 2026-10-18）：一次挪多块（moveBlocks）。
//  - 规则校验（PlanMoveRules，纯函数）：固定块不动、正在做/做完的不动、不挪进过去、不出今天、不越 DDL、
//    **最终整体布局**里挪动的块不与别的块（含同组）重叠；放不下给出明确原因。撞到别的块时由智能体把受影响的块
//    一起放进同一个提案（参照 reflow 顺延），App 只校验最终布局——卡片上写什么就只改什么，不悄悄连带挪。
//  - 写入（ApprovedPlanMover）：计划块写权限的**第四个持有者**（前三：确认写入 / 对账回流 / 时间线协调器）。
//    理由：Jason 在卡片上批准的挪动 = 他亲手拖动（E1）的另一种输入方式，与对账回流同构——
//    只按 ID 改块时间（updatePlanned），不整日覆盖、不碰标题以外的元数据。写后：
//      · 发 planChangedExternally（带 updatedIDs）→ 时间线协调器把它当手改钉住 30 分钟（D12 用户最后动作赢）、排日程页刷新；
//      · 钉住（P4 Q6：你批准的位置等同你亲手放的，当天自动调整绕开）；
//      · ProjectionService 重投影绿色（P4 Q2：开工的日子绿色也一直在，橙色预览已退役）。
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

    /// 一块的目标位置（end=nil 保持原时长）。
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

    /// 纯技术防失控上限（W10）：**不是产品规则**。Jason 2026-10-18：「一次最多挪 10 块」这类判断类数字没有数据支撑，
    /// 取消；一次挪多少块以最终整体布局合法为准、由智能体按上下文判断。这里只防桥接文件出错时一次塞进成百上千块
    ///（一天的计划块远少于此）。
    nonisolated static let maxGroup = 200

    static func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    static func span(_ s: Date, _ e: Date) -> String { "\(hm(s))–\(hm(e))" }

    /// 单块：校验通过返回落点；不通过抛 ProposalExecutionError.invalid（带给人看的原因）。
    static func validate(id: UUID, start: Date, end requestedEnd: Date?, in c: Context) throws -> Checked {
        try validateGroup([Move(id: id, start: start, end: requestedEnd)], in: c)[0]
    }

    /// 多块：对**挪完之后的整体布局**校验，返回每块落点（顺序同输入）。
    /// restoring=true 只用于撤销（整组挪回执行前的位置）：原位置已过去也允许挪回、不查截止（原样恢复），
    /// 组内块之间不查重叠（恢复的就是它们原来的相对位置）；与组外块重叠仍拒绝（不硬塞）。
    static func validateGroup(_ moves: [Move], in c: Context, restoring: Bool = false) throws -> [Checked] {
        guard !moves.isEmpty else { throw ProposalExecutionError.invalid("没有要挪的块") }
        guard moves.count <= maxGroup else { throw ProposalExecutionError.invalid("这次要挪 \(moves.count) 块，超过技术防失控上限 \(maxGroup)，疑似提案文件出错") }
        guard Set(moves.map(\.id)).count == moves.count else { throw ProposalExecutionError.invalid("同一块在提案里出现了不止一次") }
        let single = moves.count == 1
        var checked: [Checked] = []
        for m in moves {
            guard let block = c.blocks.first(where: { $0.id == m.id }) else {
                throw ProposalExecutionError.invalid("今天的计划里找不到这块（可能已删除或不在今天）")
            }
            let name = "「\(block.title)」"
            guard !block.isFixed else { throw ProposalExecutionError.invalid("\(name)是固定安排，按规则不挪") }
            if c.active?.id == m.id { throw ProposalExecutionError.invalid("\(name)正在计时，先结束或暂停再挪") }
            guard !c.settledIDs.contains(m.id) else { throw ProposalExecutionError.invalid("\(name)已经做完或正在同时做，不挪") }
            let start = m.start
            let end = m.end ?? start.addingTimeInterval(block.end.timeIntervalSince(block.start))
            let duration = end.timeIntervalSince(start)
            guard duration >= 60, duration <= 16 * 3600 else {
                throw ProposalExecutionError.invalid("\(name)的新时间段无效（结束须晚于开始，且不超过 16 小时）")
            }
            if !restoring {
                guard start != block.start || end != block.end else {
                    throw ProposalExecutionError.invalid(single ? "\(name)已经在 \(span(start, end))，无需挪动"
                                                         : "\(name)已经在 \(span(start, end))，无需挪动（不变的块不用列进提案）")
                }
                guard start >= c.now.addingTimeInterval(-60) else {
                    throw ProposalExecutionError.invalid("\(name)的新开始时间 \(hm(start)) 已经过去了，只能往「从现在起」挪")
                }
            }
            guard start >= c.dayWindow.start, end <= c.dayWindow.end else {
                throw ProposalExecutionError.invalid("\(name)的新时间 \(span(start, end)) 超出今天（逻辑日到次日 4:00），本动作只挪今天之内")
            }
            if !restoring, let ddl = block.deadline, end > ddl {
                throw ProposalExecutionError.invalid("\(name)挪到 \(span(start, end)) 会越过截止时间 \(hm(ddl))，按规则不越截止")
            }
            checked.append(Checked(block: block, start: start, end: end))
        }
        let movedIDs = Set(moves.map(\.id))
        // 障碍（组外）：前台正在做的块此刻占的时间段 + 其余仍在「从现在起」时间线上、这次不挪的块（未落定、尚未结束）。
        var obstacles: [(title: String, start: Date, end: Date, fixed: Bool)] = []
        if let a = c.active, let b = c.blocks.first(where: { $0.id == a.id }) {
            obstacles.append((b.title, a.start, max(a.end, c.now), false))
        }
        for b in c.blocks where !movedIDs.contains(b.id) && b.id != c.active?.id && !c.settledIDs.contains(b.id) && b.end > c.now {
            obstacles.append((b.title, b.start, b.end, b.isFixed))
        }
        obstacles.sort { $0.start < $1.start }
        for k in checked {
            let name = single ? "" : "「\(k.block.title)」"
            guard let hit = obstacles.first(where: { $0.start < k.end && k.start < $0.end }) else { continue }
            if hit.fixed {
                throw ProposalExecutionError.invalid("\(name)新时间 \(span(k.start, k.end)) 与固定安排「\(hit.title)」(\(span(hit.start, hit.end))) 重叠，固定安排不动，放不下")
            }
            throw ProposalExecutionError.invalid("\(name)新时间 \(span(k.start, k.end)) 和「\(hit.title)」(\(span(hit.start, hit.end))) 重叠，放不下"
                + (restoring ? "（挪回原位会和它撞上，不硬塞）" : "（不硬塞；要连带挪「\(hit.title)」，请把它也放进同一个提案一起挪）"))
        }
        if !restoring {
            let sorted = checked.sorted { $0.start < $1.start }
            for (a, b) in zip(sorted, sorted.dropFirst()) where b.start < a.end {
                throw ProposalExecutionError.invalid("同组的「\(a.block.title)」(\(span(a.start, a.end))) 和「\(b.block.title)」(\(span(b.start, b.end))) 挪完会互相重叠")
            }
        }
        return checked
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
    /// 多块：只校验最终整体布局，不写。
    func checkGroup(_ moves: [PlanMoveRules.Move], restoring: Bool) throws -> [PlanMoveRules.Checked]
    /// 多块：逐块核版本（任一块已变 → conflict，整组不写）+ 整体校验 + 写入 + 刷新画面；返回每块改动前后（顺序同输入）。
    func moveGroup(_ moves: [ProposalBlockMove], restoring: Bool) async throws -> (changes: [(before: ScheduledBlock, after: ScheduledBlock)], note: String)
}

@MainActor final class ApprovedPlanMover: PlanBlockMoving {
    private let planStore: PlanReading & PlanWriting
    private let projection: ProjectionService?
    private let startedDays: StartedDayStore?   // P4 起不再按开工与否分流（保留注入，组装点不变）
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
        note += await afterWrite([id])
        DevLog.shared.info("多端审批", note)
        return (current, after, note)
    }

    func checkGroup(_ moves: [PlanMoveRules.Move], restoring: Bool) throws -> [PlanMoveRules.Checked] {
        try PlanMoveRules.validateGroup(moves, in: context(), restoring: restoring)
    }

    func moveGroup(_ moves: [ProposalBlockMove], restoring: Bool) async throws -> (changes: [(before: ScheduledBlock, after: ScheduledBlock)], note: String) {
        let ctx = try context()
        // ① 先逐块核版本：任一块在提案（或执行）之后被改过 → 整组不写。
        var originals: [ScheduledBlock] = []
        for m in moves {
            guard let current = ctx.blocks.first(where: { $0.id == m.id }) else {
                throw ProposalExecutionError.conflict("有一块已不在今天的计划里（可能被删除或挪到别的日子），整组不改")
            }
            guard let expected = m.expectedRevision else { throw ProposalExecutionError.invalid("「\(current.title)」缺少基线版本，未执行") }
            guard ProposalRevision.block(current) == expected else {
                throw ProposalExecutionError.conflict("「\(current.title)」在提案之后被改过（现在 \(PlanMoveRules.span(current.start, current.end))），整组不覆盖")
            }
            originals.append(current)
        }
        // ② 整体校验最终布局。
        let checked = try PlanMoveRules.validateGroup(moves.map { PlanMoveRules.Move(id: $0.id, start: $0.start, end: $0.end) },
                                                      in: ctx, restoring: restoring)
        // ③ 写入；中途失败 → 已写的块挪回原位（尽力），再抛错（不留半组）。
        var written: [ScheduledBlock] = []
        do {
            for (k, original) in zip(checked, originals) {
                try planStore.updatePlanned(id: original.id, start: k.start, end: k.end, title: original.title, reason: .agentApproval)
                written.append(original)
            }
        } catch {
            for o in written {
                do { try planStore.updatePlanned(id: o.id, start: o.start, end: o.end, title: o.title, reason: .agentApproval) } catch {
                    DevLog.shared.error("多端审批", "整组挪动中途失败后，「\(o.title)」没能挪回原位：\(error.localizedDescription)")
                }
            }
            DevLog.shared.error("多端审批", "整组挪动写入失败，已写的块已挪回：\(error.localizedDescription)")
            throw error
        }
        let changes = zip(originals, checked).map { o, k -> (before: ScheduledBlock, after: ScheduledBlock) in
            var after = o; after.start = k.start; after.end = k.end
            return (o, after)
        }
        var note = (restoring ? "已整组挪回 \(changes.count) 块：" : "已一起挪动 \(changes.count) 块：")
            + changes.map { "「\($0.before.title)」\(PlanMoveRules.span($0.before.start, $0.before.end)) → \(PlanMoveRules.span($0.after.start, $0.after.end))" }
                .joined(separator: "；")
        note += await afterWrite(changes.map(\.before.id))
        DevLog.shared.info("多端审批", note)
        return (changes, note)
    }

    /// 写后：钉住（P4 Q6：你批准的位置 = 你亲手放的，当天自动调整绕开）+ 通知时间线协调器 + 重投影绿色
    /// （P4 Q2：开工的日子绿色也一直在，不再跳过）。返回附加说明（刷新失败时）。
    private func afterWrite(_ ids: [UUID]) async -> String {
        do { try planStore.setPinned(ids: ids, until: ScheduledBlock.pinExpiry(forStart: now())) }
        catch { DevLog.shared.warn("多端审批", "挪动已写入，但没能钉住（自动调整可能再挪它）：\(error.localizedDescription)") }
        NotificationCenter.default.post(name: ReconcileService.planChangedExternally, object: nil,
                                        userInfo: ["updatedIDs": ids, "source": Self.notificationSource])
        let label = label
        guard let projection else { return "" }
        do { try await projection.project(label: label); return "" } catch {
            DevLog.shared.warn("多端审批", "挪动已写入，但日历画面刷新失败：\(error.localizedDescription)")
            return "（日历画面稍后同步：\(error.localizedDescription)）"
        }
    }
}
