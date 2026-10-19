//
//  PlanEditRules.swift
//  BetterCalendar
//
//  SPEC §19 W18（Jason 2026-10-19：日用起只走智能体这条路，智能体必须能把事情放上时间线）。
//  时间线改动的**唯一一套排布规则**（纯函数、可单测）：加块 / 改块 / 删块 / 挪块（含跨天）/ 排一天（整组），
//  以及 W8 的挪今天（PlanMoveRules 只是它的薄包装）。「理解你想要什么」归智能体，「时间怎么摆才合法」归这里：
//    - 固定安排不挪、不改时长；正在计时 / 已做完的不挪、不删；
//    - 落点不进过去、不跨凌晨 4:00 的日界线、在可排范围内（今天到 horizonDays 天后）；
//    - 不越截止；
//    - **最终整体布局**里，有新落点的块不与别的块重叠、不与你的日历事件重叠（你的东西 = 已占用、只读；
//      和某块是「同一件事」的你的事件只对那一块不算障碍）、同组之间也不重叠；
//    - 放不下就拒绝并写明原因——绝不悄悄挤、悄悄挪别的块、悄悄缩短。
//  撤销（restoring）放宽三条：原位置已过去也能放回、不查截止、组内原有的相对位置不查重叠；与组外 / 你的日历撞上照样拒绝。
//  图钉 / 固定安排的「越级」要求在执行器 prepare 里查（它要看提案的越级理由），见 ProposalActionExecutor。
//

import Foundation

enum PlanEditRules {
    /// 可排范围：今天 + 往后几个逻辑日。**技术窗口，不是产品规则**：与 context.json 给智能体看的「未来几天的计划 / 已占用」
    /// 一致——智能体看不到的日子它也排不准；更远的事先进待办（itemCreate），到了窗口里再排。
    nonisolated static let horizonDays = 7
    /// 纯技术防失控上限（W10）：防桥接文件出错一次塞进成百上千步，不是产品规则。
    nonisolated static let maxGroup = 200

    /// 你的日历里的一件事（只读、已占用）。linkedBlockID = 与之是「同一件事」的计划块（P4 Q4 关联），对那一块不算障碍。
    struct Occupied: Equatable {
        var title: String
        var start: Date
        var end: Date
        var calendar: String = ""
        var linkedBlockID: UUID? = nil
    }

    struct Context {
        /// 可排范围内全部计划块（今天起）。
        var blocks: [ScheduledBlock]
        var now: Date
        /// 可排范围：今天逻辑日起点 → 最后一个可排逻辑日的终点。
        var window: DateInterval
        /// 已完成 / 后台同时在做的计划块（不挪不删，也不当障碍）。
        var settledIDs: Set<UUID> = []
        /// 前台正在做的块：不挪不删；它此刻占着的时间段是障碍。
        var active: (id: UUID, start: Date, end: Date)? = nil
        /// 你的日历事件（只读，已按「排布时当作已占用的日历」设置过滤，不含全天）。
        var occupied: [Occupied] = []
        /// 回收站里的块（只给撤销用的 restore 步）：id → 块 + 这次删除的编号。
        var trashed: [UUID: (block: ScheduledBlock, deletionID: UUID?)] = [:]
    }

    /// 校验后的一步：规范化后的步骤 + 改动前后（新增 before=nil；删除 after=nil）。
    struct Resolved {
        var step: ProposalPlanStep
        var before: ScheduledBlock?
        var after: ScheduledBlock?
        /// 落点（时间）变了：要查障碍。
        var placed: Bool
    }

    // MARK: 显示

    nonisolated static func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    nonisolated static func span(_ s: Date, _ e: Date) -> String { "\(hm(s))–\(hm(e))" }

    /// 逻辑日的绝对名字（不随看的时间变）：「10月20日（周二）」。
    nonisolated static func dayName(_ label: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日（EEE）"
        return f.string(from: label)
    }

    /// 逻辑日标签（该日零点）→「yyyy-MM-dd」（桥接 day 字段的格式）。⚠️ 不能用 DayContext.dayKey：它先按 4 点日界线换算，
    /// 零点标签会被算成前一天。
    nonisolated static func dayKey(_ label: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: label)
    }

    /// 相对此刻的日子名：今天 / 明天 / 10月22日（周四）。
    nonisolated static func relativeDayName(_ label: Date, now: Date) -> String {
        let today = DayContext.logicalStartOfDay(now)
        if label == today { return "今天" }
        if label == Calendar.current.date(byAdding: .day, value: 1, to: today) { return "明天" }
        return dayName(label)
    }

    /// 一段时间给人看：今天的只写「11:00–12:00」，别的日子带上日子名。
    nonisolated static func when(_ s: Date, _ e: Date, now: Date) -> String {
        let label = DayContext.logicalStartOfDay(s)
        return label == DayContext.logicalStartOfDay(now) ? span(s, e) : "\(relativeDayName(label, now: now)) \(span(s, e))"
    }
    nonisolated static func when(_ d: Date, now: Date) -> String {
        let label = DayContext.logicalStartOfDay(d)
        return label == DayContext.logicalStartOfDay(now) ? hm(d) : "\(relativeDayName(label, now: now)) \(hm(d))"
    }

    /// 可排范围（今天起 horizon 个逻辑日之后）。
    nonisolated static func window(now: Date, horizon: Int) -> DateInterval {
        let today = DayContext.logicalStartOfDay(now)
        let last = Calendar.current.date(byAdding: .day, value: max(0, horizon), to: today) ?? today
        return DateInterval(start: DayContext.logicalWindow(forLabel: today).start, end: DayContext.logicalWindow(forLabel: last).end)
    }

    /// 撤销会做什么（给审批面板 / 桥接结果看）。
    nonisolated static func undoHint(_ steps: [ProposalPlanStep]) -> String {
        var parts: [String] = []
        let deletes = steps.filter { if case .delete = $0 { true } else { false } }.count
        let restores = steps.filter { if case .restore = $0 { true } else { false } }.count
        let moves = steps.filter { if case .move = $0 { true } else { false } }.count
        let edits = steps.filter { if case .edit = $0 { true } else { false } }.count
        if deletes > 0 { parts.append("新加的 \(deletes) 块移入回收站（30 天内可恢复）") }
        if restores > 0 { parts.append("删掉的 \(restores) 块从回收站恢复") }
        if moves > 0 { parts.append("挪过的 \(moves) 块挪回原来的时间") }
        if edits > 0 { parts.append("改过的 \(edits) 块改回原样") }
        return "撤销 = " + parts.joined(separator: "，") + "（任一块之后被改过就整组不撤）"
    }

    // MARK: 校验

    /// 对**改完之后的整体布局**校验，返回每步改动前后（顺序同输入）。不通过抛 ProposalExecutionError.invalid（带给人看的原因）。
    /// planDay = 排一天：每一步都要落在这一天（新增 / 改 / 删的块在这天；挪动从这天挪出或挪进这天）。
    static func evaluate(_ steps: [ProposalPlanStep], in c: Context, restoring: Bool = false, planDay: Date? = nil) throws -> [Resolved] {
        guard !steps.isEmpty else { throw invalid("没有要改的块") }
        guard steps.count <= maxGroup else {
            throw invalid("这次要改 \(steps.count) 块，超过技术防失控上限 \(maxGroup)，疑似提案文件出错")
        }
        guard Set(steps.map(\.blockID)).count == steps.count else { throw invalid("同一块在提案里出现了不止一次") }
        let single = steps.count == 1
        let onlyMoves = steps.allSatisfy { if case .move = $0 { true } else { false } }
        let todayLabel = DayContext.logicalStartOfDay(c.now)
        let horizonIsToday = c.window.end <= DayContext.logicalWindow(forLabel: todayLabel).end
        let byID = Dictionary(c.blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let isActive: (UUID) -> Bool = { c.active?.id == $0 }
        let isSettled: (UUID) -> Bool = { c.settledIDs.contains($0) }

        func existing(_ id: UUID) throws -> ScheduledBlock {
            guard let b = byID[id] else {
                throw invalid(horizonIsToday ? "今天的计划里找不到这块（可能已删除或不在今天）"
                                             : "今天到 \(horizonDays) 天后的计划里找不到这块（可能已删除，或不在这段时间里）")
            }
            return b
        }
        /// 落点的有效性：时长、日界线、可排范围、不进过去（restoring 放宽）。
        func checkPlacement(_ name: String, _ start: Date, _ end: Date, mustBeFuture: Bool) throws {
            guard end.timeIntervalSince(start) >= 60 else {
                throw invalid("\(name)的新时间段无效（结束须晚于开始，至少 1 分钟）")
            }
            if mustBeFuture, !restoring {
                guard start >= c.now.addingTimeInterval(-60) else {
                    throw invalid("\(name)的新开始时间 \(when(start, now: c.now)) 已经过去了，只能往「从现在起」挪")
                }
            }
            let label = DayContext.logicalStartOfDay(start)
            let dayWindow = DayContext.logicalWindow(forLabel: label)
            guard start >= c.window.start, dayWindow.end <= c.window.end else {
                throw invalid(horizonIsToday
                              ? "\(name)的新时间 \(when(start, end, now: c.now)) 超出今天（逻辑日到次日 4:00）"
                              : "\(name)的新时间 \(when(start, end, now: c.now)) 不在可排的范围里（今天到 \(horizonDays) 天后；更远的事先放进待办）")
            }
            guard end <= dayWindow.end else {
                throw invalid("\(name)的新时间 \(span(start, end)) 超出\(relativeDayName(label, now: c.now))（逻辑日到次日 4:00，一块不跨过凌晨 4:00）")
            }
        }
        func checkDeadline(_ name: String, _ start: Date, _ end: Date, _ deadline: Date?, verb: String) throws {
            guard !restoring, let ddl = deadline, end > ddl else { return }
            throw invalid("\(name)\(verb) \(when(start, end, now: c.now)) 会越过截止时间 \(when(ddl, now: c.now))，按规则不越截止")
        }
        func onPlanDay(_ dates: [Date]) -> Bool {
            guard let planDay else { return true }
            return dates.contains { DayContext.logicalStartOfDay($0) == planDay }
        }

        var resolved: [Resolved] = []
        for (i, step) in steps.enumerated() {
            switch step {
            case let .create(nb):
                guard !restoring else { throw invalid("撤销里不能新增块") }
                let name = "「\(nb.title)」"
                guard byID[nb.id] == nil else { throw invalid("\(name)的 id 已经在计划里了，不重复新增") }
                guard c.trashed[nb.id] == nil else { throw invalid("\(name)的 id 属于回收站里的一块，不重复新增（要找回请到回收站恢复）") }
                try checkPlacement(name, nb.start, nb.end, mustBeFuture: true)
                try checkDeadline(name, nb.start, nb.end, nb.deadline, verb: "排在")
                let after = ScheduledBlock(id: nb.id, title: nb.title, start: nb.start, end: nb.end, isFixed: nb.isFixed,
                                           priority: nb.important ? .important : .normal, deadline: nb.deadline,
                                           linkedTaskID: nb.linkedTaskID)
                guard onPlanDay([nb.start]) else { throw notOnDay(i, name, planDay!) }
                resolved.append(Resolved(step: step, before: nil, after: after, placed: true))

            case let .move(m):
                let block = try existing(m.id)
                let name = "「\(block.title)」"
                guard !block.isFixed else { throw invalid("\(name)是固定安排，按规则不挪") }
                if isActive(m.id) { throw invalid("\(name)正在计时，先结束或暂停再挪") }
                guard !isSettled(m.id) else { throw invalid("\(name)已经做完或正在同时做，不挪") }
                let end = m.end ?? m.start.addingTimeInterval(block.end.timeIntervalSince(block.start))
                // W11：单块时长不设判断类上限；只守有效性（结束晚于开始，至少 1 分钟）。
                guard end.timeIntervalSince(m.start) >= 60 else {
                    throw invalid("\(name)的新时间段无效（结束须晚于开始，至少 1 分钟）")
                }
                if !restoring {
                    guard m.start != block.start || end != block.end else {
                        throw invalid(single ? "\(name)已经在 \(span(m.start, end))，无需挪动"
                                             : "\(name)已经在 \(span(m.start, end))，无需挪动（不变的块不用列进提案）")
                    }
                }
                try checkPlacement(name, m.start, end, mustBeFuture: true)
                try checkDeadline(name, m.start, end, block.deadline, verb: "挪到")
                guard onPlanDay([block.start, m.start]) else { throw notOnDay(i, name, planDay!) }
                var after = block; after.start = m.start; after.end = end
                resolved.append(Resolved(step: .move(ProposalBlockMove(id: m.id, start: m.start, end: end, expectedRevision: m.expectedRevision)),
                                         before: block, after: after, placed: true))

            case let .edit(e):
                let block = try existing(e.id)
                let name = "「\(block.title)」"
                var after = block
                var edit = ProposalBlockEdit(id: e.id, expectedRevision: e.expectedRevision)
                if let t = e.title, t != block.title { after.title = t; edit.title = t }
                var placed = false
                if let d = e.duration {
                    let newEnd = block.start.addingTimeInterval(d)
                    if newEnd != block.end {
                        // 同一步里把它改成不固定（越级，执行器要求写理由；撤销「设为固定」时也是这样）才允许改时长
                        guard !(block.isFixed && (e.isFixed ?? true)) else { throw invalid("\(name)是固定安排，按规则不改时长") }
                        if isActive(e.id) { throw invalid("\(name)正在计时，先结束或暂停再改时长") }
                        guard !isSettled(e.id) else { throw invalid("\(name)已经做完或正在同时做，不改时长") }
                        guard d >= 60 else { throw invalid("\(name)的新时长无效（至少 1 分钟）") }
                        if !restoring, newEnd <= c.now {
                            throw invalid("\(name)改成这个时长会在 \(when(newEnd, now: c.now)) 结束，已经过去了")
                        }
                        try checkPlacement(name, block.start, newEnd, mustBeFuture: false)
                        after.end = newEnd; edit.duration = d; placed = true
                    }
                }
                if let f = e.isFixed, f != block.isFixed { after.isFixed = f; edit.isFixed = f }
                if let imp = e.important, imp != (block.priority == .important) {
                    after.priority = imp ? .important : .normal; edit.important = imp
                }
                switch e.deadline {
                case let .set(d)? where d != block.deadline: after.deadline = d; edit.deadline = .set(d)
                case .clear? where block.deadline != nil: after.deadline = nil; edit.deadline = .clear
                default: break
                }
                guard !edit.isEmpty else { throw invalid("\(name)没有要改的地方（写的值和现在一样）") }
                if placed || edit.deadline != nil {
                    try checkDeadline(name, after.start, after.end, after.deadline, verb: placed ? "改成" : "现在排在")
                }
                guard onPlanDay([block.start]) else { throw notOnDay(i, name, planDay!) }
                resolved.append(Resolved(step: .edit(edit), before: block, after: after, placed: placed))

            case let .delete(id, rev):
                let block = try existing(id)
                let name = "「\(block.title)」"
                if isActive(id) { throw invalid("\(name)正在计时，先结束或暂停再删") }
                guard !isSettled(id) else { throw invalid("\(name)已经做完或正在同时做，不删（做成的事留在记录里）") }
                guard onPlanDay([block.start]) else { throw notOnDay(i, name, planDay!) }
                resolved.append(Resolved(step: .delete(id: id, expectedRevision: rev), before: block, after: nil, placed: false))

            case let .restore(id, deletionID):
                guard restoring else { throw invalid("「从回收站恢复」只用于撤销，不能单独提出") }
                guard byID[id] == nil else { throw invalid("这一块已经回到计划里了（可能你已在回收站恢复过）") }
                guard let t = c.trashed[id], deletionID == nil || t.deletionID == deletionID else {
                    throw invalid("回收站里找不到这次删掉的那一块（可能已经恢复过，或又被删了一次）")
                }
                try checkPlacement("「\(t.block.title)」", t.block.start, t.block.end, mustBeFuture: false)
                resolved.append(Resolved(step: step, before: nil, after: t.block, placed: true))
            }
        }

        // —— 最终整体布局 ——
        let changedIDs = Set(resolved.map(\.step.blockID))
        let placed = resolved.filter(\.placed).compactMap(\.after)
        // 障碍（组外）：前台正在做的块此刻占的时间段 + 仍在「从现在起」时间线上、这次没动的块 + 这次改了属性但没动时间的块。
        var obstacles: [(title: String, start: Date, end: Date, fixed: Bool, mine: Bool, linked: UUID?)] = []
        if let a = c.active, let b = byID[a.id] { obstacles.append((b.title, a.start, max(a.end, c.now), false, false, nil)) }
        let unplacedChanged = Dictionary(resolved.filter { !$0.placed }.compactMap { r in r.after.map { (r.step.blockID, $0) } },
                                         uniquingKeysWith: { a, _ in a })
        for b in c.blocks where b.id != c.active?.id && !isSettled(b.id) && b.end > c.now {
            if changedIDs.contains(b.id) {
                guard let kept = unplacedChanged[b.id] else { continue }   // 挪了 / 改了时长 / 删了：不当障碍
                obstacles.append((kept.title, kept.start, kept.end, kept.isFixed, false, nil))
            } else {
                obstacles.append((b.title, b.start, b.end, b.isFixed, false, nil))
            }
        }
        for o in c.occupied where o.end > o.start {
            obstacles.append((o.title, o.start, o.end, true, true, o.linkedBlockID))
        }
        obstacles.sort { $0.start < $1.start }
        for k in placed {
            let name = single && onlyMoves ? "" : "「\(k.title)」"
            guard let hit = obstacles.first(where: { $0.start < k.end && k.start < $0.end && !($0.mine && $0.linked == k.id) }) else { continue }
            let at = when(k.start, k.end, now: c.now), theirs = when(hit.start, hit.end, now: c.now)
            if hit.mine {
                throw invalid("\(name)新时间 \(at) 和你日历里的「\(hit.title)」(\(theirs)) 重叠：那是你的安排（只读、不动），放不下")
            }
            if hit.fixed {
                throw invalid("\(name)新时间 \(at) 与固定安排「\(hit.title)」(\(theirs)) 重叠，固定安排不动，放不下")
            }
            throw invalid("\(name)新时间 \(at) 和「\(hit.title)」(\(theirs)) 重叠，放不下"
                + (restoring ? "（放回原位会和它撞上，不硬塞）" : "（不硬塞；要连带挪「\(hit.title)」，请把它也放进同一个提案一起挪）"))
        }
        if !restoring {
            let sorted = placed.sorted { $0.start < $1.start }
            for (a, b) in zip(sorted, sorted.dropFirst()) where b.start < a.end {
                throw invalid("同组的「\(a.title)」(\(when(a.start, a.end, now: c.now))) 和「\(b.title)」(\(when(b.start, b.end, now: c.now))) \(onlyMoves ? "挪" : "排")完会互相重叠")
            }
        }
        return resolved
    }

    /// 给人看的「改动前 → 改动后」。
    static func changes(_ resolved: [Resolved], now: Date) -> [ProposalChange] {
        resolved.flatMap { r -> [ProposalChange] in
            switch r.step {
            case .create:
                guard let a = r.after else { return [] }
                var flags: [String] = []
                if a.isFixed { flags.append("固定") }
                if a.priority == .important { flags.append("要紧") }
                if let d = a.deadline { flags.append("截止 \(when(d, now: now))") }
                return [ProposalChange(field: "新计划块", before: nil,
                                       after: "\(when(a.start, a.end, now: now))「\(a.title)」" + (flags.isEmpty ? "" : "（" + flags.joined(separator: "，") + "）"))]
            case .move:
                guard let b = r.before, let a = r.after else { return [] }
                return [ProposalChange(field: "「\(b.title)」时间", before: when(b.start, b.end, now: now), after: when(a.start, a.end, now: now))]
            case let .edit(e):
                guard let b = r.before, let a = r.after else { return [] }
                var out: [ProposalChange] = []
                if e.title != nil { out.append(ProposalChange(field: "计划块标题", before: b.title, after: a.title)) }
                if e.duration != nil {
                    out.append(ProposalChange(field: "「\(a.title)」时长", before: "\(when(b.start, b.end, now: now))（\(minutes(b))）",
                                              after: "\(when(a.start, a.end, now: now))（\(minutes(a))）"))
                }
                if let f = e.isFixed { out.append(ProposalChange(field: "「\(a.title)」固定安排", before: f ? "否" : "是", after: f ? "是" : "否")) }
                if let imp = e.important { out.append(ProposalChange(field: "「\(a.title)」要紧事", before: imp ? "否" : "是", after: imp ? "是" : "否")) }
                if e.deadline != nil {
                    out.append(ProposalChange(field: "「\(a.title)」截止", before: b.deadline.map { when($0, now: now) } ?? "（无）",
                                              after: a.deadline.map { when($0, now: now) } ?? "（无）"))
                }
                return out
            case .delete:
                guard let b = r.before else { return [] }
                return [ProposalChange(field: "计划块（移入回收站，30 天内可恢复）", before: "\(when(b.start, b.end, now: now))「\(b.title)」", after: nil)]
            case .restore:
                guard let a = r.after else { return [] }
                return [ProposalChange(field: "从回收站恢复", before: nil, after: "\(when(a.start, a.end, now: now))「\(a.title)」")]
            }
        }
    }

    private static func minutes(_ b: ScheduledBlock) -> String {
        let m = max(1, Int((b.end.timeIntervalSince(b.start) / 60).rounded())), h = m / 60, r = m % 60
        return h > 0 ? "\(h) 小时" + (r > 0 ? " \(r) 分钟" : "") : "\(r) 分钟"
    }

    private static func invalid(_ s: String) -> ProposalExecutionError { .invalid(s) }
    private static func notOnDay(_ i: Int, _ name: String, _ day: Date) -> ProposalExecutionError {
        .invalid("第 \(i + 1) 步\(name)不在\(dayName(day))：排一天的每一步都要落在这一天（新增 / 改 / 删这一天的块，或从这一天挪出、挪进这一天）")
    }
}
