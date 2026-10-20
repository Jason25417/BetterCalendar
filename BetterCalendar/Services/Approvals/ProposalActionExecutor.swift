//
//  ProposalActionExecutor.swift
//  BetterCalendar
//
//  SPEC §19 W1：多端审批的「真改动」执行器（替换只做空改动的 ExperimentOnlyExecutor；协议缝不变）。
//  三类动作：① 事项（新增待办 / 改标题备注 / 标完成·取消完成）② 计时（开始 / 暂停 / 继续 / 结束）
//  ③ 时间线（挪动今天某个计划块；W8 起可一次挪多块，经 PlanMoveRules 对最终整体布局校验）。
//  W8（Jason 2026-10-18）：开始计时可带回溯起点 startAt（像 Apple Watch 检测到运动：「你大概从 13:00 起就在做」），
//  批准前不写任何东西；批准后从 startAt 起算；开始计时不提供撤销（要结束另提「结束计时」）。撤销多块挪动 = 整组挪回。
//  每种动作：
//    - prepare：严格校验 + 补全基线版本（expectedRevision）+ 由 App 依据真实数据算「改动前 → 改动后」；
//    - perform：执行前再核版本——目标在提案后被改过就失败并说明，绝不覆盖用户事实；
//      成功时返回逆操作（带执行后的版本），供「撤销」使用（A3 后半）。
//  能力全部经协议注入（事项 = ProposalItemStore，计时 = ProposalTimerControlling，挪动 = PlanBlockMoving），
//  缺哪种能力就让那种动作可见地失败，不猜测、不降级成别的动作。
//

import CryptoKit
import Foundation

// MARK: - 版本（乐观并发的「上次看到的样子」）

/// 目标对象的版本串：任一相关字段变了，版本就变。智能体从 context.json 的 actionTargets 读到，
/// 或由 App 在提交前补上（= Jason 在审批卡上看到的那一刻）。
enum ProposalRevision {
    nonisolated static func hash(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    /// 毫秒取整：CloudKit 同步后的日期精度为毫秒，避免同一时刻在两台设备上算出不同版本。
    nonisolated static func ms(_ d: Date?) -> String { d.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "-" }

    static func item(_ t: LongTask) -> String {
        hash(["item", t.id.uuidString, t.title, t.note, t.status.rawValue, t.zoneRaw,
              ms(t.doneAt), t.isInTrash ? "trash" : "live", ms(t.modifiedAt)])
    }
    static func block(_ b: ScheduledBlock) -> String {
        hash(["block", b.id.uuidString, b.title, ms(b.start), ms(b.end), b.isFixed ? "fixed" : "flex", ms(b.deadline)])
    }
    /// W32b：日记的版本只看正文（改心情 / 标签不算改了你写的字）。
    static func journal(_ e: JournalEntry) -> String {
        hash(["journal", e.id.uuidString, e.body, e.isInTrash ? "trash" : "live"])
    }
}

// MARK: - 能力缝

/// 事项写入（唯一写者 = LongTaskStore）。
@MainActor protocol ProposalItemStore: AnyObject {
    func task(id: UUID) throws -> LongTask?
    func createTodo(id: UUID, title: String, note: String, at date: Date) throws
    func update(id: UUID, at date: Date, _ change: (LongTask) -> Void) throws
    func discard(id: UUID, at date: Date) throws
    /// W32c：删除 / 恢复事项与阶段（回收站；返回 deletionID 供撤销）。
    func trash(id: UUID, at date: Date) throws -> UUID
    func restore(id: UUID, deletionID: UUID, at date: Date) throws
    func checkpoint(itemId: UUID, id: UUID) throws -> LongTaskCheckpoint?
    func trashCheckpoint(itemId: UUID, id: UUID, at date: Date) throws -> UUID
    func restoreCheckpoint(itemId: UUID, id: UUID, deletionID: UUID, at date: Date) throws
}

/// W32b：日记写入（唯一写者 = JournalStore）。
@MainActor protocol ProposalJournalWriting: AnyObject {
    func entry(id: UUID) throws -> JournalEntry?
    func entry(onLogicalDay day: Date) throws -> JournalEntry?
    func create(id: UUID, day: Date, body: String, at date: Date) throws
    func setBody(id: UUID, body: String, at date: Date) throws
    func discard(id: UUID, at date: Date) throws
}

extension LongTaskStore: ProposalItemStore {}

/// 某台设备此刻的计时状态（计时是设备本地状态 → 计时提案固定在读状态的那台设备执行）。
nonisolated struct ProposalTimerState: Equatable, Sendable {
    enum Phase: String, Sendable { case idle, running, paused }
    var phase: Phase
    var title: String? = nil
    var blockId: UUID? = nil
    var startedAt: Date? = nil
    /// 已计净时长（展示用，不进版本）。
    var elapsed: TimeInterval? = nil

    static let idle = ProposalTimerState(phase: .idle)

    var label: String {
        switch phase {
        case .idle: "空闲（没有在计时）"
        case .running: "正在计时「\(title ?? "")」"
        case .paused: "「\(title ?? "")」已暂停"
        }
    }
    var revision: String {
        ProposalRevision.hash(["timer", phase.rawValue, blockId?.uuidString ?? "-", title ?? "-", ProposalRevision.ms(startedAt)])
    }
}

/// 计时控制（生产 = ExecutionViewModel 的现有路径；结束计时 ≠ 完成事项）。
@MainActor protocol ProposalTimerControlling: AnyObject {
    var proposalTimerState: ProposalTimerState { get }
    /// 今天计划里某块的标题（不在今天的执行列表 = nil；作息锚点不计时）。
    func proposalPlanItemTitle(_ id: UUID) async -> String?
    /// at = 回溯起点（W8）；nil = 从此刻起算。
    func proposalStartTimer(blockId: UUID?, title: String?, at: Date?) async throws
    func proposalPauseTimer() async throws
    func proposalResumeTimer() async throws
    func proposalStopTimer() async throws
    /// 今天已经占用的时间段（W8，回溯起点查重叠用）：已记下的实际 + 正在跑的计时（前台 / 同时做 / 共享计时，算到此刻）。
    func proposalBusySpans() async -> [ProposalBusySpan]
}

/// 已被占用的一段时间（标题 + 起止），给回溯起点查重叠。
nonisolated struct ProposalBusySpan: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
}

/// 开始计时回溯起点的规则（W8，Jason 2026-10-18）。
/// W10（Jason 2026-10-18：判断类数字没有实验数据支撑、也不一定适合所有人）：取消「最多回溯 2 小时」——回溯多久由智能体
/// 按上下文判断、在理由里写依据（越久越要说明，见智能体 CLAUDE.md）；代码只守物理一致性：不在未来、在今天（逻辑日）之内、
/// 执行设备此刻没在计时、不与已记下的实际 / 正在跑的计时重叠。审批卡写明回溯了多久，让你一眼看到。
enum ProposalTimerRules {
    /// 早于此刻不到这么久的视为「从此刻起」，不算回溯（时钟抖动 / 智能体写的就是当下）。有效性容差，不是判断类数字。
    nonisolated static let nowTolerance: TimeInterval = 60

    /// 「回溯 1 小时 20 分钟」。
    nonisolated static func backdateText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        return "回溯 " + (h > 0 ? "\(h) 小时" + (m > 0 ? " \(m) 分钟" : "") : "\(m) 分钟")
    }
}

// MARK: - 执行器

@MainActor final class ProposalActionExecutor: ProposalExecuting {
    private let items: (any ProposalItemStore)?
    /// 计时与挪动依赖执行层/时间线，组装点在它们建好后挂上（weak：不延长执行层寿命）。
    weak var timer: (any ProposalTimerControlling)?
    var mover: (any PlanBlockMoving)?
    /// W8 D3：提醒 / 闹钟的排程能力（生产 = NativeProposalNotificationScheduler）。
    var notifications: (any ProposalNotificationScheduling)?
    /// W12（SPEC §19.13 Q5）：「几点提醒我」写成提醒事项里的原生提醒（两台设备都响）。nil = 这台设备没接 → 改用本机通知并写明。
    var askReminders: (any AskReminderProjecting)?
    /// W32：你的日程 / 提醒的唯一写者（生产 = EventKitYourItemsWriter；只注入给这里）。nil = 这台设备没接 → 可见地失败。
    var yourItems: (any YourItemsWriting)?
    /// W32b：日记写入（JournalStore）+ 两个开关（写：「允许智能体提议写日记」默认关；读：改原文要先看得到原文）。
    var journal: (any ProposalJournalWriting)?
    var journalWriteAllowed: () -> Bool = { AgentJournalSettings.allowWrite }
    var journalReadAllowed: () -> Bool = { AgentContextSettings.allowRecentJournal }
    /// W8 D3：最近见过的设备名册（含本机），给闹钟 / 提醒校验目标设备、在审批卡上写设备名。
    var knownDevices: () -> [KnownDevice] = { [] }
    let deviceId: String
    private let now: () -> Date

    static let titleLimit = 200
    /// W12：撤销信息里「这条提醒在提醒事项里」的版本前缀（没有前缀 = 旧的本机通知）。不加新的动作种类，旧提案照常撤销。
    nonisolated static let nativeRevisionPrefix = "ek:"
    static let noteLimit = 2000

    init(items: (any ProposalItemStore)?, timer: (any ProposalTimerControlling)? = nil, mover: (any PlanBlockMoving)? = nil,
         deviceId: String, now: @escaping () -> Date = { .now }) {
        self.items = items; self.timer = timer; self.mover = mover; self.deviceId = deviceId; self.now = now
    }

    // MARK: prepare

    /// W9（P4 Q6，SPEC §19.13，原则 8「审慎越级」）：时间线改动动到**图钉**（你亲手改过时间的块，当天有效）——
    /// 提案必须带越级理由，否则拒收；带了就在改动清单最前面点名是哪几块（审批卡另有 W10 的越级横幅）。
    /// W18：删掉或取消一个**固定安排**同样算越级（那是你定下的承诺）；挪固定安排 / 改它的时长仍一律不行（规则里拒）。
    /// 越级提案永远不被预授权放行（PreauthPolicy 看 Proposal.escalation）。撤销（整组挪回 / 整组撤销）是你的动作，不查。
    /// W32：动「你的东西」（ownership == .yours：你的日程 / 提醒 / 事项 / 你写的日记）是同一个越级概念——同样必须带越级理由，
    /// 点名行（⚠️ …）由各自的 prepare 算好放在改动清单最前面，审批卡把它放进橙色越级横条。
    func prepare(_ action: ProposalAction, escalation: String?) async throws -> PreparedProposalAction {
        var prepared = try await prepare(action)
        let (pinned, fixed) = try escalationTargets(prepared.action)
        let yours = prepared.action.ownership == .yours
        guard !pinned.isEmpty || !fixed.isEmpty || yours else { return prepared }
        let pinNames = pinned.map { "「\($0)」" }.joined(separator: "、")
        let fixedNames = fixed.map { "「\($0)」" }.joined(separator: "、")
        guard escalation != nil else {
            if !pinned.isEmpty {
                throw ProposalExecutionError.invalid("\(pinNames)是你亲手放的位置（图钉，当天有效）；要动它，提案必须标「越级」并写明理由")
            }
            if !fixed.isEmpty {
                throw ProposalExecutionError.invalid("\(fixedNames)是固定安排；要删掉它或取消固定，提案必须标「越级」并写明理由")
            }
            let subject = prepared.changes?.first(where: \.isEscalationSubject)
                .map { String($0.field.dropFirst(ProposalChange.escalationMarker.count)) } ?? "这会动你的东西"
            throw ProposalExecutionError.invalid("\(subject)——动你的东西，提案必须标「越级」并写明理由（你要求过，或哪里真冲突非改不可）")
        }
        var lines: [ProposalChange] = []
        if !pinned.isEmpty { lines.append(.escalationSubject("这会动你亲手放的位置：\(pinNames)（图钉，当天自动调整都绕开它）")) }
        if !fixed.isEmpty { lines.append(.escalationSubject("这会删掉或取消固定安排：\(fixedNames)")) }
        var changes = prepared.changes ?? []
        for line in lines.reversed() where !changes.contains(line) { changes.insert(line, at: 0) }
        prepared.changes = changes
        return prepared
    }

    /// W11：审批卡上调了数值后重新校验。计时是设备本地状态——不在执行设备上时，没法核对那台设备此刻在不在计时、
    /// 和已记下的实际重不重叠：这里只查能查的（不在未来、在今天），并在改动清单里写明「执行设备会再核对一次」；
    /// 执行时 perform 照常完整核对（失败可见）。其余种类走同一套 prepare（含 W9 图钉 / 越级校验）。
    func recheck(_ action: ProposalAction, escalation: String?, executingDeviceId: String?) async throws -> PreparedProposalAction {
        guard case let .timer(.start, blockId, title, expected, startAt) = action, let target = executingDeviceId, target != deviceId else {
            return try await prepare(action, escalation: escalation)
        }
        var name = title
        if let blockId, name == nil { name = await timer?.proposalPlanItemTitle(blockId) }
        var changes: [ProposalChange] = []
        var resolved: Date? = nil
        if let startAt {
            let hm = PlanMoveRules.hm(startAt)
            guard startAt <= now().addingTimeInterval(ProposalTimerRules.nowTolerance) else {
                throw ProposalExecutionError.invalid("回溯起点 \(hm) 在未来；开始计时只能从过去或此刻算起")
            }
            if now().timeIntervalSince(startAt) >= ProposalTimerRules.nowTolerance {
                guard DayContext.isSameLogicalDay(startAt, now()) else {
                    throw ProposalExecutionError.invalid("回溯起点 \(hm) 不在今天（逻辑日从凌晨 4:00 起）")
                }
                resolved = startAt
            }
        }
        changes.append(ProposalChange(field: "计时", before: "以执行设备上的计时状态为准",
                                      after: "正在计时「\(name ?? "这件事")」" + (resolved.map { "（从 \(PlanMoveRules.hm($0)) 开始计）" } ?? "")))
        if let s = resolved {
            changes.append(ProposalChange(field: ProposalTimerRules.backdateText(now().timeIntervalSince(s)) + "（智能体的依据见理由）", before: nil, after: nil))
        }
        changes.append(ProposalChange(field: "执行它的那台设备会再核对一次：那台设备此刻没在计时、不和已记下的实际重叠；不满足就不执行并告诉你", before: nil, after: nil))
        return PreparedProposalAction(action: .timer(command: .start, blockId: blockId, title: title, expectedRevision: expected, startAt: resolved),
                                      changes: changes, requiredDeviceId: target)
    }

    /// 这项时间线改动会越级动到哪些块（标题）：图钉（挪 / 删 / 改时长）、固定安排（删 / 取消固定）。撤销用的整组恢复不算。
    private func escalationTargets(_ action: ProposalAction) throws -> (pinned: [String], fixed: [String]) {
        let steps: [ProposalPlanStep]
        switch action {
        case let .moveBlock(id, start, end, rev): steps = [.move(ProposalBlockMove(id: id, start: start, end: end, expectedRevision: rev))]
        case let .moveBlocks(moves, false): steps = moves.map { .move($0) }
        case let .blockEdit(e): steps = [.edit(e)]
        case let .blockDelete(id, rev): steps = [.delete(id: id, expectedRevision: rev)]
        case let .planDay(_, s, false): steps = s
        default: return ([], [])
        }
        let mover = try planMover()
        var pinned: [String] = [], fixed: [String] = []
        for step in steps {
            guard let b = try mover.windowBlock(id: step.blockID) else { continue }
            switch step {
            case .move, .delete: if b.isPinned(at: now()) { pinned.append(b.title) }
            case let .edit(e): if e.duration != nil, b.isPinned(at: now()) { pinned.append(b.title) }
            default: break
            }
            switch step {
            case .delete: if b.isFixed { fixed.append(b.title) }
            case let .edit(e): if e.isFixed == false, b.isFixed { fixed.append(b.title) }
            default: break
            }
        }
        return (pinned, fixed)
    }

    func prepare(_ action: ProposalAction) async throws -> PreparedProposalAction {
        switch action {
        case .experimentNoop:
            return PreparedProposalAction(action: action, changes: nil)

        case let .itemCreate(id, title, note):
            let store = try itemStore()
            let title = try Self.cleanTitle(title)
            let note = try Self.cleanNote(note)
            guard try store.task(id: id) == nil else { throw ProposalExecutionError.invalid("事项 id 已存在，不重复新增") }
            var changes = [ProposalChange(field: "待办", before: nil, after: title)]
            if let note, !note.isEmpty { changes.append(ProposalChange(field: "「\(title)」备注", before: nil, after: note)) }
            return PreparedProposalAction(action: .itemCreate(id: id, title: title, note: note), changes: changes)

        case let .itemEdit(id, title, note, expected):
            let task = try liveTask(id)
            let newTitle = try title.map(Self.cleanTitle)
            let newNote = try Self.cleanNote(note)
            let titleChanges = newTitle.map { $0 != task.title } ?? false
            let noteChanges = newNote.map { $0 != task.note } ?? false
            guard titleChanges || noteChanges else { throw ProposalExecutionError.invalid("标题和备注都没有变化") }
            let revision = try Self.baseline(expected, current: ProposalRevision.item(task), what: "「\(task.title)」")
            var changes: [ProposalChange] = []
            if titleChanges { changes.append(ProposalChange(field: "事项标题", before: task.title, after: newTitle)) }
            if noteChanges {
                changes.append(ProposalChange(field: "「\(newTitle ?? task.title)」备注",
                                              before: task.note.isEmpty ? "（空）" : task.note,
                                              after: newNote!.isEmpty ? "（空）" : newNote))
            }
            return PreparedProposalAction(action: .itemEdit(id: id, title: titleChanges ? newTitle : nil,
                                                            note: noteChanges ? newNote : nil, expectedRevision: revision),
                                          changes: changes)

        case let .itemSetDone(id, done, expected):
            let task = try liveTask(id)
            try Self.checkStatusTransition(task, done: done)
            let revision = try Self.baseline(expected, current: ProposalRevision.item(task), what: "「\(task.title)」")
            return PreparedProposalAction(action: .itemSetDone(id: id, done: done, expectedRevision: revision),
                                          changes: [ProposalChange(field: "「\(task.title)」", before: done ? "在途" : "做成了",
                                                                   after: done ? "做成了" : "在途")])

        case .itemDiscard:
            throw ProposalExecutionError.invalid("「移入回收站」只用于撤销新增的待办，不能单独提出")

        case let .timer(command, blockId, title, expected, startAt):
            let control = try timerControl()
            let state = control.proposalTimerState
            var resolvedTitle = title
            var resolvedStart: Date? = nil
            var changes: [ProposalChange] = []
            if startAt != nil, command != .start { throw ProposalExecutionError.invalid("只有开始计时能带回溯起点 startAt") }
            switch command {
            case .start:
                switch (blockId, title?.trimmingCharacters(in: .whitespacesAndNewlines)) {
                case let (id?, nil):
                    guard let name = await control.proposalPlanItemTitle(id) else {
                        throw ProposalExecutionError.invalid("今天的执行列表里没有这块（可能不在今天，或是作息锚点）")
                    }
                    resolvedTitle = name
                    if state.blockId == id, state.phase != .idle { throw ProposalExecutionError.invalid("「\(name)」已经在计时") }
                case let (nil, name?) where !name.isEmpty:
                    resolvedTitle = try Self.cleanTitle(name)
                default:
                    throw ProposalExecutionError.invalid("开始计时需要二选一：今天的计划块 blockId，或一件计划外的事 title")
                }
                if state.phase != .idle {
                    changes.append(ProposalChange(field: "「\(state.title ?? "")」计时", before: state.phase == .paused ? "暂停中" : "进行中",
                                                  after: "结束（记下已投入的时间，不标完成）"))
                }
                if let startAt {
                    resolvedStart = try await Self.checkBackdate(startAt, now: now(), state: state, control: control)
                }
                changes.append(ProposalChange(field: "计时", before: state.label,
                                              after: "正在计时「\(resolvedTitle ?? "")」" + (resolvedStart.map { "（从 \(PlanMoveRules.hm($0)) 开始计）" } ?? "")))
                if let s = resolvedStart {
                    changes.append(ProposalChange(field: "从 \(PlanMoveRules.hm(s)) 开始计：什么时候批准都从这个时刻算；拒绝或过期 = 什么都不记", before: nil, after: nil))
                    changes.append(ProposalChange(field: ProposalTimerRules.backdateText(now().timeIntervalSince(s)) + "（智能体的依据见理由）", before: nil, after: nil))
                }

            case .pause:
                guard blockId == nil, title == nil else { throw ProposalExecutionError.invalid("暂停计时不带 blockId/title（作用于这台设备正在计的那件）") }
                guard state.phase == .running else { throw ProposalExecutionError.invalid("这台设备现在没有进行中的计时（\(state.label)）") }
                changes.append(ProposalChange(field: "「\(state.title ?? "")」计时", before: "进行中", after: "暂停"))
            case .resume:
                guard blockId == nil, title == nil else { throw ProposalExecutionError.invalid("继续计时不带 blockId/title") }
                guard state.phase == .paused else { throw ProposalExecutionError.invalid("这台设备现在没有暂停中的计时（\(state.label)）") }
                changes.append(ProposalChange(field: "「\(state.title ?? "")」计时", before: "暂停", after: "继续"))
            case .stop:
                guard blockId == nil, title == nil else { throw ProposalExecutionError.invalid("结束计时不带 blockId/title") }
                guard state.phase != .idle else { throw ProposalExecutionError.invalid("这台设备现在没有在计时") }
                let minutes = state.elapsed.map { " · 已计约 \(max(1, Int($0 / 60))) 分钟" } ?? ""
                changes.append(ProposalChange(field: "「\(state.title ?? "")」计时", before: (state.phase == .paused ? "暂停中" : "进行中") + minutes,
                                              after: "结束（记下这段投入；不等于完成这件事）"))
            }
            let revision = try Self.baseline(expected, current: state.revision, what: "计时状态")
            return PreparedProposalAction(action: .timer(command: command, blockId: command == .start ? blockId : nil,
                                                         title: command == .start && blockId == nil ? resolvedTitle : nil,
                                                         expectedRevision: revision, startAt: resolvedStart),
                                          changes: changes, requiredDeviceId: deviceId)

        case let .reminder(id, title, body, fireAt, deviceId):
            // W12（SPEC §19.13 Q5，Jason 2026-10-18）：提醒 = 提醒事项里的一条原生提醒，各台设备（iPhone / iPad / Mac）都会响；
            // device 参数只为兼容旧提案保留、不再决定在哪台设备执行（任一台批准的设备写进提醒事项即可）。
            let title = try Self.cleanReminderTitle(title)
            let body = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count <= ProposalReminderRules.bodyLimit else { throw ProposalExecutionError.invalid("提醒正文不超过 \(ProposalReminderRules.bodyLimit) 字") }
            try Self.checkFireAt(fireAt, now: now())
            var changes = [ProposalChange(field: "提醒", before: nil, after: title),
                           ProposalChange(field: "\(ProposalReminderRules.when(fireAt)) 会出现在提醒事项里，各台设备（iPhone / iPad / Mac）都会响", before: nil, after: nil),
                           ProposalChange(field: "要像闹钟那样叫醒你，请改用闹钟", before: nil, after: nil)]
            if !body.isEmpty { changes.insert(ProposalChange(field: "提醒正文", before: nil, after: body), at: 1) }
            return PreparedProposalAction(action: .reminder(id: id, title: title, body: body.isEmpty ? nil : body, fireAt: fireAt, deviceId: deviceId),
                                          changes: changes, requiredDeviceId: nil)

        case let .alarm(id, title, fireAt, deviceId):
            let title = try Self.cleanReminderTitle(title)
            try Self.checkFireAt(fireAt, now: now())
            // W30（原则 11）：没指定设备 = 默认随身的 iPhone（名册里最近见过的那台）；你明确指定的照旧
            let defaulted = deviceId == ProposalAction.carriedDeviceDefault
            let device = defaulted ? try Self.carriedIPhone(knownDevices()) : try knownDevice(deviceId, what: "闹钟")
            guard device.isIOSDevice else {
                throw ProposalExecutionError.invalid("闹钟只能设在 iPhone / iPad 上（「\(device.label)」是 \(device.deviceKind.label)）；Mac 上不设闹钟，也不改成普通通知")
            }
            var changes = [ProposalChange(field: "闹钟", before: nil, after: title),
                           ProposalChange(field: "在「\(device.label)」上 \(ProposalReminderRules.when(fireAt)) 响铃（\(device.deviceKind.label) 系统闹钟）", before: nil, after: nil)]
            if defaulted {
                changes.append(ProposalChange(field: "没指定设备：默认设在随身的 iPhone；其他设备到点只安静放一份", before: nil, after: nil))
            }
            return PreparedProposalAction(action: .alarm(id: id, title: title, fireAt: fireAt, deviceId: device.id),
                                          changes: changes, requiredDeviceId: device.id)

        case .reminderCancel, .alarmCancel:
            throw ProposalExecutionError.invalid("取消提醒/闹钟只用于撤销，不能单独提出")

        case let .moveBlocks(moves, isUndo):
            guard !isUndo else { throw ProposalExecutionError.invalid("「整组挪回」只用于撤销，不能单独提出") }
            let mover = try planMover()
            var baselined: [ProposalBlockMove] = []
            for m in moves {
                guard let block = try mover.windowBlock(id: m.id) else { throw notFound(mover, "其中一块") }
                let revision = try Self.baseline(m.expectedRevision, current: ProposalRevision.block(block), what: "「\(block.title)」")
                baselined.append(ProposalBlockMove(id: m.id, start: m.start, end: m.end, expectedRevision: revision))
            }
            let resolved = try await mover.evaluate(baselined.map { .move($0) }, restoring: false, planDay: nil)
            let resolvedMoves = resolved.compactMap { r -> ProposalBlockMove? in if case let .move(m) = r.step { m } else { nil } }
            var changes = PlanEditRules.changes(resolved, now: now())
            changes.append(ProposalChange(field: "一起挪动 \(resolved.count) 块；事后可整组挪回", before: nil, after: nil))
            return PreparedProposalAction(action: .moveBlocks(moves: resolvedMoves, isUndo: false), changes: changes)

        case let .moveBlock(id, start, end, expected):
            let mover = try planMover()
            guard let block = try mover.windowBlock(id: id) else { throw notFound(mover, "这块") }
            let revision = try Self.baseline(expected, current: ProposalRevision.block(block), what: "「\(block.title)」")
            let resolved = try await mover.evaluate([.move(ProposalBlockMove(id: id, start: start, end: end, expectedRevision: revision))],
                                                    restoring: false, planDay: nil)
            guard case let .move(m) = resolved[0].step else { throw ProposalExecutionError.invalid("挪动校验结果异常") }
            return PreparedProposalAction(action: .moveBlock(id: id, start: m.start, end: m.end, expectedRevision: revision),
                                          changes: PlanEditRules.changes(resolved, now: now()))

        case let .blockCreate(day, blocks):
            let mover = try editingMover()
            let cleaned = try blocks.map { try cleanNewBlock($0) }
            let resolved = try await mover.evaluate(cleaned.map { .create($0) }, restoring: false, planDay: day)
            var changes = PlanEditRules.changes(resolved, now: now())
            changes.append(ProposalChange(field: "在\(PlanEditRules.dayName(day))加 \(resolved.count) 块；事后可撤销（移入回收站）", before: nil, after: nil))
            return PreparedProposalAction(action: .blockCreate(day: day, blocks: cleaned), changes: changes)

        case let .blockEdit(edit):
            let mover = try editingMover()
            let step = try baselineStep(.edit(edit), mover)
            let resolved = try await mover.evaluate([step], restoring: false, planDay: nil)
            guard case let .edit(normalized) = resolved[0].step else { throw ProposalExecutionError.invalid("改块校验结果异常") }
            return PreparedProposalAction(action: .blockEdit(normalized), changes: PlanEditRules.changes(resolved, now: now()))

        case let .blockDelete(id, expected):
            let mover = try editingMover()
            let step = try baselineStep(.delete(id: id, expectedRevision: expected), mover)
            let resolved = try await mover.evaluate([step], restoring: false, planDay: nil)
            guard case let .delete(_, revision) = resolved[0].step else { throw ProposalExecutionError.invalid("删块校验结果异常") }
            return PreparedProposalAction(action: .blockDelete(id: id, expectedRevision: revision), changes: PlanEditRules.changes(resolved, now: now()))

        case let .planDay(day, steps, isUndo):
            guard !isUndo else { throw ProposalExecutionError.invalid("「整组撤销」只用于撤销，不能单独提出") }
            let mover = try editingMover()
            var prepared: [ProposalPlanStep] = []
            for step in steps {
                switch step {
                case let .create(nb): prepared.append(.create(try cleanNewBlock(nb)))
                case .restore: throw ProposalExecutionError.invalid("「从回收站恢复」只用于撤销，不能放进排一天")
                default: prepared.append(try baselineStep(step, mover))
                }
            }
            let resolved = try await mover.evaluate(prepared, restoring: false, planDay: day)
            var changes = PlanEditRules.changes(resolved, now: now())
            changes.append(ProposalChange(field: "排\(PlanEditRules.dayName(day))：\(resolved.count) 步一起批准；事后可整组撤销", before: nil, after: nil))
            return PreparedProposalAction(action: .planDay(day: day, steps: resolved.map(\.step), isUndo: false), changes: changes)

        // —— W32 你的日程 / 提醒（越级）——
        case let .yourEventEdit(edit):
            let snap = try await yourEvent(edit.ref)
            var e = try YourItemRules.checkEdit(snap, edit)
            e.ref = snap.ref
            e.expectedRevision = try Self.baseline(edit.expectedRevision, current: snap.revision, what: "你的日程「\(snap.title)」")
            return PreparedProposalAction(action: .yourEventEdit(e), changes: YourItemRules.eventChanges(snap, e))

        case let .yourEventDelete(ref, expected):
            let snap = try await yourEvent(ref)
            try YourItemRules.checkDelete(snap)
            let revision = try Self.baseline(expected, current: snap.revision, what: "你的日程「\(snap.title)」")
            return PreparedProposalAction(action: .yourEventDelete(ref: snap.ref, expectedRevision: revision), changes: YourItemRules.deleteChanges(snap))

        case let .yourReminderEdit(edit):
            let snap = try await yourReminder(edit.externalID)
            var e = try YourItemRules.checkEdit(snap, edit)
            e.expectedRevision = try Self.baseline(edit.expectedRevision, current: snap.revision, what: "你的提醒「\(snap.title)」")
            return PreparedProposalAction(action: .yourReminderEdit(e), changes: YourItemRules.reminderChanges(snap, e))

        // —— W32c 删事项 / 阶段（越级，进回收站）——
        case let .itemDelete(id, expected):
            let task = try liveTask(id)
            let revision = try Self.baseline(expected, current: ProposalRevision.item(task), what: "「\(task.title)」")
            let zone = task.poolZone == .todo ? "待办" : "长期事项"
            let cps = task.sortedCheckpoints.count
            return PreparedProposalAction(action: .itemDelete(id: id, expectedRevision: revision), changes: [
                .escalationSubject("删的是你的\(zone)：《\(task.title)》"),
                ProposalChange(field: zone, before: task.title + (cps > 0 ? "（连同它的 \(cps) 个阶段）" : ""), after: nil),
                ProposalChange(field: "进回收站，30 天内可恢复；批准后可一键撤销\(cps > 0 ? "（阶段一起回来）" : "")；已排进时间线的块不受影响", before: nil, after: nil),
            ])

        case let .checkpointDelete(itemId, checkpointId, expected):
            let task = try liveTask(itemId)
            guard let cp = try itemStore().checkpoint(itemId: itemId, id: checkpointId), !cp.isInTrash else {
                throw ProposalExecutionError.invalid("「\(task.title)」里找不到这个阶段（可能已删除）")
            }
            let revision = try Self.baseline(expected, current: ProposalRevision.item(task), what: "「\(task.title)」")
            return PreparedProposalAction(action: .checkpointDelete(itemId: itemId, checkpointId: checkpointId, expectedRevision: revision), changes: [
                .escalationSubject("删的是你长期事项《\(task.title)》里的阶段：《\(cp.title)》"),
                ProposalChange(field: "「\(task.title)」的阶段", before: cp.title + (cp.doneAt != nil ? "（已推进到）" : ""), after: nil),
                ProposalChange(field: "进回收站，30 天内可恢复；批准后可一键撤销", before: nil, after: nil),
            ])

        // —— W32b 日记 ——
        case let .journalAppend(day, text, newEntryID, expected):
            try checkJournalWrite()
            let store = try journalStore()
            let label = Calendar.current.startOfDay(for: day)   // day 是逻辑日标签（该日零点，同 blockCreate）
            guard label <= DayContext.logicalStartOfDay(now()) else { throw ProposalExecutionError.invalid("不能给还没到的日子写日记") }
            let t = try Self.cleanJournalText(text, what: "要加的一段")
            let existing = try store.entry(onLogicalDay: label)
            let revision: String?
            if let existing {
                revision = try Self.baseline(expected, current: ProposalRevision.journal(existing), what: "\(PlanEditRules.dayName(label))的日记")
            } else {
                guard expected == nil else { throw ProposalExecutionError.conflict("提案依据的那篇日记已经不在了，请重新读取再提") }
                revision = nil
            }
            let head = existing == nil ? "新建\(PlanEditRules.dayName(label))的日记，写一段" : "\(PlanEditRules.dayName(label))的日记：在末尾加一段"
            return PreparedProposalAction(action: .journalAppend(day: label, text: t, newEntryID: newEntryID, expectedRevision: revision), changes: [
                ProposalChange(field: head + "（智能体写的，用楷体显示，和你的字区分开；不改你写的任何字）", before: nil, after: t),
                ProposalChange(field: "批准后可一键撤销（你之后又写过这篇就不撤）", before: nil, after: nil),
            ])

        case let .journalEdit(entryID, find, replace, expected):
            try checkJournalWrite()
            guard journalReadAllowed() else {
                throw ProposalExecutionError.invalid("改你写的日记原文，要先在设置里允许智能体读最近日记（它得看得到原文）")
            }
            let entry = try liveJournal(entryID)
            _ = try Self.uniqueRange(find, in: entry.body)
            let replacement = replace.isEmpty ? "" : try Self.cleanJournalText(replace, what: "改成的文字")
            let revision = try Self.baseline(expected, current: ProposalRevision.journal(entry), what: "这篇日记")
            let day = PlanEditRules.dayName(DayContext.logicalStartOfDay(entry.date))
            return PreparedProposalAction(action: .journalEdit(entryID: entryID, find: find, replace: replacement, expectedRevision: revision), changes: [
                .escalationSubject("改的是你自己写的日记：《\(day)的日记》"),
                ProposalChange(field: "日记原文", before: find, after: replacement.isEmpty ? nil : replacement),
                ProposalChange(field: "改后的文字算智能体写的（楷体显示）；你再改其中任何一个字，那段就变回你的", before: nil, after: nil),
                ProposalChange(field: "批准后可一键撤销：正文原样改回（你之后又写过就不撤）", before: nil, after: nil),
            ])

        case .yourEventRecreate, .itemRestore, .checkpointRestore, .journalRestore:
            throw ProposalExecutionError.invalid("「\(action.kindLabel)」只用于撤销，不能单独提出")
        }
    }

    // MARK: perform

    func perform(_ action: ProposalAction) async throws -> ProposalExecutionOutcome {
        switch action {
        case let .experimentNoop(note):
            return ProposalExecutionOutcome(note: "测试改动已应用：未修改任何真实数据（\(note)）")

        case let .itemCreate(id, title, note):
            let store = try itemStore()
            try store.createTodo(id: id, title: title, note: note ?? "", at: now())
            let created = try liveTask(id)
            return ProposalExecutionOutcome(note: "已新增待办「\(title)」",
                                            undo: ProposalUndoInfo(action: .itemDiscard(id: id, expectedRevision: ProposalRevision.item(created))))

        case let .itemEdit(id, title, note, expected):
            let task = try checkedTask(id, expected)
            let oldTitle = task.title, oldNote = task.note
            try itemStore().update(id: id, at: now()) { t in
                if let title { t.title = title }
                if let note { t.note = note }
            }
            let after = try liveTask(id)
            var parts: [String] = []
            if let title { parts.append("标题「\(oldTitle)」→「\(title)」") }
            if note != nil { parts.append("备注已更新") }
            return ProposalExecutionOutcome(note: "已修改事项：" + parts.joined(separator: "，"),
                                            undo: ProposalUndoInfo(action: .itemEdit(id: id, title: title != nil ? oldTitle : nil,
                                                                                     note: note != nil ? oldNote : nil,
                                                                                     expectedRevision: ProposalRevision.item(after))))

        case let .itemSetDone(id, done, expected):
            let task = try checkedTask(id, expected)
            try Self.checkStatusTransition(task, done: done)
            let at = now()
            try itemStore().update(id: id, at: at) { t in
                t.status = done ? .done : .active
                t.doneAt = done ? at : nil
            }
            let after = try liveTask(id)
            return ProposalExecutionOutcome(note: done ? "「\(after.title)」标为做成了" : "「\(after.title)」回到在途",
                                            undo: ProposalUndoInfo(action: .itemSetDone(id: id, done: !done, expectedRevision: ProposalRevision.item(after))))

        case let .itemDiscard(id, expected):
            let task = try checkedTask(id, expected)
            try itemStore().discard(id: id, at: now())
            return ProposalExecutionOutcome(note: "「\(task.title)」已移入回收站（30 天内可恢复）",
                                            undo: ProposalUndoInfo(unavailableReason: "要找回请到回收站恢复"))

        case let .timer(command, blockId, title, expected, startAt):
            let control = try timerControl()
            let before = control.proposalTimerState
            guard let expected else { throw ProposalExecutionError.invalid("缺少计时状态的基线版本，未执行") }
            guard before.revision == expected else {
                throw ProposalExecutionError.conflict("这台设备的计时状态在提案之后变了（现在：\(before.label)）")
            }
            if let startAt, command == .start {
                // 批准时再查一遍：审批期间你可能已经记下了别的实际，回溯起点不能和它重叠（有效期内什么时候批准都从 startAt 算）。
                _ = try await Self.checkBackdate(startAt, now: now(), state: before, control: control)
            }
            switch command {
            case .start: try await control.proposalStartTimer(blockId: blockId, title: title, at: startAt)
            case .pause: try await control.proposalPauseTimer()
            case .resume: try await control.proposalResumeTimer()
            case .stop: try await control.proposalStopTimer()
            }
            let after = control.proposalTimerState
            let note = "\(command.label)：\(before.label) → \(after.label)" + (startAt.map { "（从 \(PlanMoveRules.hm($0)) 开始计）" } ?? "")
            let undo: ProposalUndoInfo
            switch command {
            case .pause:
                undo = ProposalUndoInfo(action: .timer(command: .resume, blockId: nil, title: nil, expectedRevision: after.revision, startAt: nil), deviceId: deviceId)
            case .resume:
                undo = ProposalUndoInfo(action: .timer(command: .pause, blockId: nil, title: nil, expectedRevision: after.revision, startAt: nil), deviceId: deviceId)
            case .start:
                // W8（Jason 2026-10-18）：开始计时批准执行后不提供撤销；结束计时是另一份提案，不是撤销。
                undo = ProposalUndoInfo(unavailableReason: "要结束计时请另提「结束计时」")
            case .stop:
                undo = ProposalUndoInfo(unavailableReason: "结束计时已把这段投入记下；不删除记录，需要继续可以再开始")
            }
            return ProposalExecutionOutcome(note: note, undo: undo)

        case let .reminder(id, title, body, fireAt, _):
            // 幂等（冒烟 2026-10-18）：上次执行成功但回报没落地 → 这里会再被调用；提醒事项里已有这条就直接算完成，不重写、不报「已过」。
            if let askReminders, let existing = await askReminders.existingAskReminder(id: id) {
                DevLog.shared.info("提醒", "「\(title)」已经在提醒事项里（上次执行过、回报没落地），按已完成回报")
                return ProposalExecutionOutcome(note: "已写进提醒事项：\(ProposalReminderRules.when(fireAt))「\(title)」，各台设备（iPhone / iPad / Mac）都会响",
                                                undo: ProposalUndoInfo(action: .reminderCancel(id: id, expectedRevision: Self.nativeRevisionPrefix + existing.revision)))
            }
            guard fireAt > now() else { throw ProposalExecutionError.invalid("提醒时刻 \(ProposalReminderRules.when(fireAt)) 已经过了，没有补发") }
            // W12：先写进提醒事项（两台设备都响）；列表只在本机 / 没有提醒事项权限 → 改用本机通知，结果里写明只有这台会响
            var fallbackWhy = "这台设备没有接入提醒事项"
            if let askReminders {
                do {
                    let receipt = try await askReminders.addAskReminder(id: id, title: title, body: body, fireAt: fireAt)
                    return ProposalExecutionOutcome(note: "已写进提醒事项：\(ProposalReminderRules.when(fireAt))「\(title)」，各台设备（iPhone / iPad / Mac）都会响",
                                                    undo: ProposalUndoInfo(action: .reminderCancel(id: id, expectedRevision: Self.nativeRevisionPrefix + receipt.revision)))
                } catch let error as AskReminderError where error.allowsLocalFallback {
                    fallbackWhy = error.localizedDescription
                } catch {
                    throw ProposalExecutionError.unavailable("提醒没写进提醒事项：\(error.localizedDescription)")
                }
            }
            DevLog.shared.warn("提醒", "「\(title)」没写进提醒事项（\(fallbackWhy)），改用这台设备的本机通知，只有这台会响")
            let revision = try await notificationScheduler().scheduleReminder(id: id, title: title, body: body ?? "", fireAt: fireAt)
            return ProposalExecutionOutcome(note: ProposalExecutionOutcome.deviationMarker + "没写进提醒事项（\(fallbackWhy)），改为只在这台设备上 \(ProposalReminderRules.when(fireAt)) 弹通知「\(title)」（普通通知，不保证叫醒）",
                                            undo: ProposalUndoInfo(action: .reminderCancel(id: id, expectedRevision: revision), deviceId: self.deviceId))

        case let .alarm(id, title, fireAt, deviceId):
            guard deviceId == self.deviceId else { throw ProposalExecutionError.invalid("这个闹钟指定在另一台设备上设，本机不执行") }
            guard fireAt > now() else { throw ProposalExecutionError.invalid("闹钟时刻 \(ProposalReminderRules.when(fireAt)) 已经过了，没有补响") }
            let scheduler = try notificationScheduler()
            guard scheduler.alarmsSupported else {
                throw ProposalExecutionError.unavailable("这台设备不能设系统闹钟（只有 iPhone / iPad 可以）；没有改用普通通知")
            }
            try await scheduler.scheduleAlarm(id: id, title: title, fireAt: fireAt)
            return ProposalExecutionOutcome(note: "已在本机设好 \(ProposalReminderRules.when(fireAt)) 的闹钟「\(title)」",
                                            undo: ProposalUndoInfo(action: .alarmCancel(id: id), deviceId: self.deviceId))

        case let .reminderCancel(id, expected) where expected?.hasPrefix(Self.nativeRevisionPrefix) == true:
            // W12：撤销提醒事项里的那条（任一台有提醒事项权限的设备都能撤；你在提醒事项里改过 / 勾掉了 → 不删）
            guard let askReminders else { throw ProposalExecutionError.unavailable("这台设备没有接入提醒事项，没法撤销这条提醒") }
            do {
                let note = try await askReminders.removeAskReminder(id: id, expectedRevision: String(expected!.dropFirst(Self.nativeRevisionPrefix.count)))
                return ProposalExecutionOutcome(note: note, undo: ProposalUndoInfo(unavailableReason: "提醒已删掉；需要可以重新设"))
            } catch let AskReminderError.conflict(why) {
                throw ProposalExecutionError.conflict(why)
            } catch {
                throw ProposalExecutionError.unavailable(error.localizedDescription)
            }

        case let .reminderCancel(id, expected):
            try await notificationScheduler().cancelReminder(id: id, expectedRevision: expected)
            return ProposalExecutionOutcome(note: "已取消这条提醒", undo: ProposalUndoInfo(unavailableReason: "提醒已取消；需要可以重新设"))

        case let .alarmCancel(id):
            try await notificationScheduler().cancelAlarm(id: id)
            return ProposalExecutionOutcome(note: "已取消这个闹钟", undo: ProposalUndoInfo(unavailableReason: "闹钟已取消；需要可以重新设"))

        case let .moveBlocks(moves, isUndo):
            let result = try await planMover().apply(moves.map { .move($0) }, restoring: isUndo, planDay: nil)
            let pairs = result.resolved.compactMap { r in r.before.flatMap { b in r.after.map { (b, $0) } } }
            let note = (isUndo ? "已整组挪回 \(pairs.count) 块：" : "已一起挪动 \(pairs.count) 块：")
                + pairs.map { "「\($0.0.title)」\(PlanEditRules.when($0.0.start, $0.0.end, now: now())) → \(PlanEditRules.when($0.1.start, $0.1.end, now: now()))" }
                    .joined(separator: "；") + result.note
            DevLog.shared.info("多端审批", note)
            let back = result.inverse.compactMap { s -> ProposalBlockMove? in if case let .move(m) = s { m } else { nil } }
            return ProposalExecutionOutcome(note: note,
                                            undo: isUndo ? ProposalUndoInfo(unavailableReason: "已整组挪回原来的时间")
                                                         : ProposalUndoInfo(action: .moveBlocks(moves: back, isUndo: true)))

        case let .moveBlock(id, start, end, expected):
            guard let expected else { throw ProposalExecutionError.invalid("缺少计划块的基线版本，未执行") }
            let result = try await planMover().apply([.move(ProposalBlockMove(id: id, start: start, end: end, expectedRevision: expected))],
                                                     restoring: false, planDay: nil)
            guard let b = result.resolved.first?.before, let a = result.resolved.first?.after,
                  case let .move(back)? = result.inverse.first else { throw ProposalExecutionError.invalid("挪动结果异常") }
            let note = "已把「\(b.title)」从 \(PlanEditRules.when(b.start, b.end, now: now())) 挪到 \(PlanEditRules.when(a.start, a.end, now: now()))" + result.note
            DevLog.shared.info("多端审批", note)
            return ProposalExecutionOutcome(note: note,
                                            undo: ProposalUndoInfo(action: .moveBlock(id: id, start: b.start, end: b.end, expectedRevision: back.expectedRevision)))

        case let .blockCreate(day, blocks):
            let mover = try planMover()
            // 幂等（同提醒，冒烟 2026-10-18 教训）：上次已写进计划、回报没落地 → 这里会再被调用；一模一样的块都已在 = 按已完成回报
            let existing = try blocks.map { try mover.windowBlock(id: $0.id) }
            if !existing.isEmpty, zip(blocks, existing).allSatisfy({ nb, b in b.map { $0.title == nb.title && $0.start == nb.start && $0.end == nb.end } ?? false }) {
                DevLog.shared.info("多端审批", "这 \(blocks.count) 块已经在计划里（上次执行过、回报没落地），按已完成回报")
                let back = try existing.compactMap { $0 }.map { ProposalPlanStep.delete(id: $0.id, expectedRevision: ProposalRevision.block($0)) }
                return ProposalExecutionOutcome(note: "已在\(PlanEditRules.dayName(day))加 \(blocks.count) 块（上次已写入）",
                                                undo: ProposalUndoInfo(action: .planDay(day: day, steps: back.reversed(), isUndo: true)))
            }
            let result = try await mover.apply(blocks.map { .create($0) }, restoring: false, planDay: day)
            return planOutcome(result, day: day, head: "已在\(PlanEditRules.dayName(day))加 \(blocks.count) 块")

        case let .blockEdit(edit):
            let result = try await planMover().apply([.edit(edit)], restoring: false, planDay: nil)
            return planOutcome(result, day: dayOf(result), head: "已改计划块")

        case let .blockDelete(id, expected):
            let result = try await planMover().apply([.delete(id: id, expectedRevision: expected)], restoring: false, planDay: nil)
            return planOutcome(result, day: dayOf(result), head: "已删掉计划块（在回收站，30 天内可恢复）")

        case let .planDay(day, steps, isUndo):
            let result = try await planMover().apply(steps, restoring: isUndo, planDay: isUndo ? nil : day)
            if isUndo {
                let note = "已整组撤销 \(result.resolved.count) 步：" + Self.summary(result.resolved, now: now()) + result.note
                DevLog.shared.info("多端审批", note)
                return ProposalExecutionOutcome(note: note, undo: ProposalUndoInfo(unavailableReason: "已整组撤销"))
            }
            return planOutcome(result, day: day, head: "已排好\(PlanEditRules.dayName(day))（\(steps.count) 步）")

        // —— W32 你的日程 / 提醒：执行前核版本（你在日历 / 提醒事项里改过 → 不覆盖），逆操作 = 执行前快照里的原值 ——
        case let .yourEventEdit(edit):
            guard let expected = edit.expectedRevision else { throw ProposalExecutionError.invalid("缺少你的日程的基线版本，未执行") }
            let before = try await yourEvent(edit.ref)
            guard before.revision == expected else { throw ProposalExecutionError.conflict("你的日程「\(before.title)」在提案之后被改过") }
            if let why = YourItemRules.eventBlocked(before.facts, title: before.title, calendar: before.calendarTitle) { throw ProposalExecutionError.invalid(why) }
            let after = try await yourItemsCall { try await $0.apply(edit) }
            var back = YourEventEdit(ref: after.ref, span: edit.span, expectedRevision: after.revision)
            if edit.title != nil { back.title = before.title }
            if edit.start != nil || edit.end != nil { back.start = before.start; back.end = before.end }
            if edit.notes != nil { back.notes = before.notes ?? "" }
            var parts: [String] = []
            if let t = edit.title { parts.append("标题「\(before.title)」→「\(t)」") }
            if edit.start != nil { parts.append("时间 \(YourItemRules.when(before.start, before.end, allDay: false)) → \(YourItemRules.when(after.start, after.end, allDay: false))") }
            if edit.notes != nil { parts.append("备注已更新") }
            let split = before.facts.isRecurring && edit.span == .futureEvents ? "（重复日程从这一次起改；苹果日历会在这里把系列分成两段，撤销会改回内容、分段保留）" : ""
            let note = "已改你的日程「\(before.title)」：" + parts.joined(separator: "，") + split
            DevLog.shared.info("多端审批", note)
            return ProposalExecutionOutcome(note: note, undo: ProposalUndoInfo(action: .yourEventEdit(back)))

        case let .yourEventDelete(ref, expected):
            guard let expected else { throw ProposalExecutionError.invalid("缺少你的日程的基线版本，未执行") }
            let before = try await yourEvent(ref)
            guard before.revision == expected else { throw ProposalExecutionError.conflict("你的日程「\(before.title)」在提案之后被改过") }
            try YourItemRules.checkDelete(before)
            try await yourItemsCall { try await $0.delete(before.ref) }
            let note = "已删你的日程「\(before.title)」（\(YourItemRules.when(before.start, before.end, allDay: before.isAllDay))）"
            DevLog.shared.info("多端审批", note)
            return ProposalExecutionOutcome(note: note, undo: ProposalUndoInfo(action: .yourEventRecreate(before)))

        case let .yourEventRecreate(snapshot):
            let after = try await yourItemsCall { try await $0.recreate(snapshot) }
            let note = "已按原样重建你的日程「\(after.title)」（\(YourItemRules.when(after.start, after.end, allDay: after.isAllDay))，日历「\(after.calendarTitle)」；苹果日历里是一条新建的同内容日程）"
            DevLog.shared.info("多端审批", note)
            return ProposalExecutionOutcome(note: note, undo: ProposalUndoInfo(unavailableReason: "已恢复；要删请另提"))

        case let .yourReminderEdit(edit):
            guard let expected = edit.expectedRevision else { throw ProposalExecutionError.invalid("缺少你的提醒的基线版本，未执行") }
            let before = try await yourReminder(edit.externalID)
            guard before.revision == expected else { throw ProposalExecutionError.conflict("你的提醒「\(before.title)」在提案之后被改过") }
            if let why = YourItemRules.reminderBlocked(before) { throw ProposalExecutionError.invalid(why) }
            let after = try await yourItemsCall { try await $0.apply(edit) }
            var back = YourReminderEdit(externalID: before.externalID, expectedRevision: after.revision)
            if edit.title != nil { back.title = before.title }
            if edit.due != nil { back.due = before.due }
            if edit.done != nil { back.done = before.isCompleted }
            var parts: [String] = []
            if let t = edit.title { parts.append("标题「\(before.title)」→「\(t)」") }
            if edit.due != nil { parts.append("截止 \(YourItemRules.due(before.due, hasTime: before.hasTime)) → \(YourItemRules.due(after.due, hasTime: after.hasTime))") }
            if let d = edit.done { parts.append(d ? "标完成" : "取消完成") }
            let note = "已改你的提醒「\(before.title)」：" + parts.joined(separator: "，")
            DevLog.shared.info("多端审批", note)
            return ProposalExecutionOutcome(note: note, undo: ProposalUndoInfo(action: .yourReminderEdit(back)))

        // —— W32c 删事项 / 阶段 ——
        case let .itemDelete(id, expected):
            let task = try checkedTask(id, expected)
            let title = task.title, cps = task.sortedCheckpoints.count
            let deletion = try itemStoreCall { try $0.trash(id: id, at: self.now()) }
            return ProposalExecutionOutcome(note: "「\(title)」已移入回收站（30 天内可恢复）" + (cps > 0 ? "，连同它的 \(cps) 个阶段" : ""),
                                            undo: ProposalUndoInfo(action: .itemRestore(id: id, deletionID: deletion)))

        case let .itemRestore(id, deletion):
            try itemStoreCall { try $0.restore(id: id, deletionID: deletion, at: self.now()) }
            let title = (try? itemStore().task(id: id))?.title ?? "这条事项"
            return ProposalExecutionOutcome(note: "已从回收站恢复「\(title)」", undo: ProposalUndoInfo(unavailableReason: "已恢复；要删请另提"))

        case let .checkpointDelete(itemId, checkpointId, expected):
            let task = try checkedTask(itemId, expected)
            guard let cp = try itemStore().checkpoint(itemId: itemId, id: checkpointId), !cp.isInTrash else {
                throw ProposalExecutionError.conflict("「\(task.title)」里这个阶段已不在")
            }
            let name = cp.title, taskTitle = task.title
            let deletion = try itemStoreCall { try $0.trashCheckpoint(itemId: itemId, id: checkpointId, at: self.now()) }
            return ProposalExecutionOutcome(note: "已把「\(taskTitle)」的阶段「\(name)」移入回收站（30 天内可恢复）",
                                            undo: ProposalUndoInfo(action: .checkpointRestore(itemId: itemId, checkpointId: checkpointId, deletionID: deletion)))

        case let .checkpointRestore(itemId, checkpointId, deletion):
            try itemStoreCall { try $0.restoreCheckpoint(itemId: itemId, id: checkpointId, deletionID: deletion, at: self.now()) }
            let name = (try? itemStore().checkpoint(itemId: itemId, id: checkpointId))?.title ?? "这个阶段"
            return ProposalExecutionOutcome(note: "已恢复阶段「\(name)」", undo: ProposalUndoInfo(unavailableReason: "已恢复；要删请另提"))

        // —— W32b 日记 ——
        case let .journalAppend(day, text, newEntryID, expected):
            try checkJournalWrite()   // 批准后、执行前你关了开关 → 不写
            let store = try journalStore()
            let existing = try store.entry(onLogicalDay: day)
            let dayName = PlanEditRules.dayName(day)
            switch (existing, expected) {
            case (nil, nil):
                try journalCall { try store.create(id: newEntryID, day: day, body: JournalAuthorship.mark(text), at: self.now()) }
                guard let created = try store.entry(id: newEntryID) else { throw ProposalExecutionError.unavailable("新建的日记没读回来") }
                DevLog.shared.info("多端审批", "新建\(dayName)的日记（智能体写的一段）")
                return ProposalExecutionOutcome(note: "已新建\(dayName)的日记，写了一段（楷体 = 智能体写的）",
                                                undo: ProposalUndoInfo(action: .journalRestore(entryID: newEntryID, body: nil, expectedRevision: ProposalRevision.journal(created))))
            case let (e?, nil) where e.id == newEntryID && e.body == JournalAuthorship.mark(text):
                // 幂等：上次已新建、回报没落地
                return ProposalExecutionOutcome(note: "已新建\(dayName)的日记（上次已写入）",
                                                undo: ProposalUndoInfo(action: .journalRestore(entryID: newEntryID, body: nil, expectedRevision: ProposalRevision.journal(e))))
            case let (e?, expected?) where ProposalRevision.journal(e) == expected:
                let old = e.body
                try journalCall { try store.setBody(id: e.id, body: JournalAuthorship.appending(text, to: old), at: self.now()) }
                DevLog.shared.info("多端审批", "在\(dayName)的日记末尾加了一段（智能体写的）")
                return ProposalExecutionOutcome(note: "已在\(dayName)的日记末尾加了一段（楷体 = 智能体写的；你写的字没动）",
                                                undo: ProposalUndoInfo(action: .journalRestore(entryID: e.id, body: old, expectedRevision: ProposalRevision.journal(e))))
            default:
                throw ProposalExecutionError.conflict("\(dayName)的日记在提案之后被改过（或新写了一篇）")
            }

        case let .journalEdit(entryID, find, replace, expected):
            try checkJournalWrite()
            let store = try journalStore()
            guard let e = try store.entry(id: entryID), !e.isInTrash else { throw ProposalExecutionError.conflict("这篇日记已不在") }
            guard let expected, ProposalRevision.journal(e) == expected else { throw ProposalExecutionError.conflict("这篇日记在提案之后被改过") }
            let old = e.body
            let range = try Self.uniqueRange(find, in: old)
            var body = old
            body.replaceSubrange(range, with: replace.isEmpty ? "" : JournalAuthorship.mark(replace))
            try journalCall { try store.setBody(id: entryID, body: body, at: self.now()) }
            let note = replace.isEmpty ? "已删掉你日记里的「\(find.prefix(40))」" : "已把你日记里的「\(find.prefix(40))」改成「\(replace.prefix(40))」（楷体 = 智能体写的）"
            DevLog.shared.info("多端审批", note)
            return ProposalExecutionOutcome(note: note, undo: ProposalUndoInfo(action: .journalRestore(entryID: entryID, body: old, expectedRevision: ProposalRevision.journal(e))))

        case let .journalRestore(entryID, body, expected):
            // 撤销是你的动作：不看「允许智能体写日记」开关
            let store = try journalStore()
            guard let e = try store.entry(id: entryID), !e.isInTrash else { throw ProposalExecutionError.conflict("这篇日记已不在（可能已删除）") }
            guard ProposalRevision.journal(e) == expected else {
                throw ProposalExecutionError.conflict("这篇日记在那之后又被写过，不撤销（不覆盖你后来写的）")
            }
            if let body {
                try journalCall { try store.setBody(id: entryID, body: body, at: self.now()) }
                return ProposalExecutionOutcome(note: "日记正文已改回原样", undo: ProposalUndoInfo(unavailableReason: "已改回原样"))
            }
            try journalCall { try store.discard(id: entryID, at: self.now()) }
            return ProposalExecutionOutcome(note: "这篇新建的日记已移入回收站（30 天内可恢复）", undo: ProposalUndoInfo(unavailableReason: "已撤销；要找回请到回收站恢复"))
        }
    }

    // MARK: W32d 低风险自动通过的真实数据检查

    /// 时间线单块改动：块是你亲手放的位置（图钉）→ 不自动通过（哪怕只是改名）。其余种类没有额外障碍（规则见 PreauthPolicy.lowRiskReason）。
    func autoPassBlocker(_ action: ProposalAction) async -> String? {
        let ids: [UUID]
        switch action {
        case let .moveBlock(id, _, _, _): ids = [id]
        case let .moveBlocks(moves, false): ids = moves.map(\.id)
        case let .blockEdit(e): ids = [e.id]
        default: return nil
        }
        guard let mover else { return "这台设备没有接入时间线" }
        for id in ids {
            do {
                guard let b = try mover.windowBlock(id: id) else { return "找不到这块" }
                if b.isPinned(at: now()) { return "「\(b.title)」是你亲手放的位置（图钉）" }
            } catch { return "读不到这块：\(error.localizedDescription)" }
        }
        return nil
    }

    // MARK: W32 内部

    private func yourItemsWriter() throws -> any YourItemsWriting {
        guard let yourItems else { throw ProposalExecutionError.unavailable("这台设备没有接入「改你的日程 / 提醒」") }
        return yourItems
    }

    /// 写者的错误 → 提案错误（找不到 = 目标变了；拒绝 = 规则；其余 = 系统失败）。失败由 ProposalCenter 记 DevLog + 写进提案结果。
    private func yourItemsCall<T>(_ body: (any YourItemsWriting) async throws -> T) async throws -> T {
        let w = try yourItemsWriter()
        do { return try await body(w) }
        catch let e as YourItemsError {
            switch e {
            case let .notFound(s): throw ProposalExecutionError.conflict(s)
            case let .refused(s): throw ProposalExecutionError.invalid(s)
            case let .failed(s): throw ProposalExecutionError.unavailable(s)
            }
        } catch let e as ProposalExecutionError { throw e }
        catch { throw ProposalExecutionError.unavailable(error.localizedDescription) }
    }

    private func yourEvent(_ ref: YourEventRef) async throws -> YourEventSnapshot { try await yourItemsCall { try await $0.event(ref) } }
    private func yourReminder(_ id: String) async throws -> YourReminderSnapshot { try await yourItemsCall { try await $0.reminder(id) } }

    private func itemStoreCall<T>(_ body: (any ProposalItemStore) throws -> T) throws -> T {
        let store = try itemStore()
        do { return try body(store) } catch let e as DataArchiveError { throw ProposalExecutionError.conflict(e.localizedDescription) }
    }

    private func journalStore() throws -> any ProposalJournalWriting {
        guard let journal else { throw ProposalExecutionError.unavailable("这台设备没有接入日记") }
        return journal
    }
    private func journalCall(_ body: () throws -> Void) throws {
        do { try body() } catch let e as DataArchiveError { throw ProposalExecutionError.conflict(e.localizedDescription) }
    }
    private func checkJournalWrite() throws {
        guard journalWriteAllowed() else {
            throw ProposalExecutionError.unavailable("「允许智能体提议写日记」在设置里关着（设置 → 审批记录与规则），没有写")
        }
    }
    private func liveJournal(_ id: UUID) throws -> JournalEntry {
        guard let e = try journalStore().entry(id: id) else { throw ProposalExecutionError.invalid("找不到这篇日记（可能已删除）") }
        guard !e.isInTrash else { throw ProposalExecutionError.invalid("这篇日记在回收站里") }
        return e
    }

    nonisolated static let journalTextLimit = 4000

    /// 智能体写进日记的文字：非空、不超长、不含作者标记语法（标记只由 App 加）。
    static func cleanJournalText(_ raw: String, what: String) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= journalTextLimit else { throw ProposalExecutionError.invalid("\(what)不能为空，且不超过 \(journalTextLimit) 字") }
        guard !t.contains("bc:agent") else { throw ProposalExecutionError.invalid("\(what)里不能带作者标记（标记由 App 加）") }
        return t
    }

    /// journalEdit 的原文：必须恰好出现一次，且不跨进 / 不落在作者标记里（改智能体以前写的段落另说）。
    static func uniqueRange(_ find: String, in body: String) throws -> Range<String.Index> {
        guard !find.isEmpty, find.count <= 2000 else { throw ProposalExecutionError.invalid("要改的原文不能为空，且不超过 2000 字") }
        guard !find.contains("<!--"), !find.contains("-->") else { throw ProposalExecutionError.invalid("要改的原文里不能带作者标记") }
        var ranges: [Range<String.Index>] = []
        var from = body.startIndex
        while let r = body.range(of: find, range: from..<body.endIndex) { ranges.append(r); from = r.upperBound }
        guard ranges.count == 1, let r = ranges.first else {
            throw ProposalExecutionError.invalid(ranges.isEmpty ? "日记原文里找不到这段文字（要逐字一致）" : "这段文字在日记里出现了 \(ranges.count) 次，请写长一点、能唯一定位")
        }
        // 落在智能体以前写的段落里 → 拒绝（嵌套标记会乱）
        let ns = body as NSString
        let target = NSRange(r, in: body)
        let pair = try NSRegularExpression(pattern: #"<!--bc:agent:[0-9a-f]{8}-->.*?<!--/bc:agent-->"#, options: [.dotMatchesLineSeparators])
        if pair.matches(in: body, range: NSRange(location: 0, length: ns.length)).contains(where: { NSIntersectionRange($0.range, target).length > 0 }) {
            throw ProposalExecutionError.invalid("这段文字落在智能体以前写的段落里：那段不是你写的原文，要改请用 journalAppend 另写，或请 Jason 自己改")
        }
        return r
    }

    /// W18 加 / 改 / 删 / 排一天的结果：一句话 + 撤销 = 反向步骤逆序整组执行（带写后的版本，之后被改过就整组不撤）。
    private func planOutcome(_ result: PlanEditApplied, day: Date, head: String) -> ProposalExecutionOutcome {
        let note = head + "：" + Self.summary(result.resolved, now: now()) + result.note
        DevLog.shared.info("多端审批", note)
        return ProposalExecutionOutcome(note: note, undo: ProposalUndoInfo(action: .planDay(day: day, steps: result.inverse.reversed(), isUndo: true)))
    }

    private func dayOf(_ result: PlanEditApplied) -> Date {
        DayContext.logicalStartOfDay(result.resolved.first?.before?.start ?? result.resolved.first?.after?.start ?? now())
    }

    /// 结果说明里的一句一句（「+ 09:00–11:00「写论文」」「「健身」18:00–19:00 → 19:00–20:00」）。
    private static func summary(_ resolved: [PlanEditRules.Resolved], now: Date) -> String {
        resolved.map { r -> String in
            switch r.step {
            case .create, .restore: r.after.map { "+ \(PlanEditRules.when($0.start, $0.end, now: now))「\($0.title)」" } ?? ""
            case .delete: r.before.map { "− 「\($0.title)」（\(PlanEditRules.when($0.start, $0.end, now: now))）" } ?? ""
            case .move, .edit:
                r.before.flatMap { b in r.after.map { a in
                    a.start == b.start && a.end == b.end && a.title == b.title
                        ? "「\(a.title)」属性已改"
                        : "「\(b.title)」\(PlanEditRules.when(b.start, b.end, now: now)) → " + (a.title == b.title ? "" : "「\(a.title)」") + PlanEditRules.when(a.start, a.end, now: now)
                } } ?? ""
            }
        }.joined(separator: "；")
    }

    // MARK: 内部

    private func itemStore() throws -> any ProposalItemStore {
        guard let items else { throw ProposalExecutionError.unavailable("这台设备没有接入事项") }
        return items
    }
    private func timerControl() throws -> any ProposalTimerControlling {
        guard let timer else { throw ProposalExecutionError.unavailable("这台设备没有接入计时") }
        return timer
    }
    private func notificationScheduler() throws -> any ProposalNotificationScheduling {
        guard let notifications else { throw ProposalExecutionError.unavailable("这台设备没有接入提醒/闹钟") }
        return notifications
    }

    /// W30：闹钟的默认设备 = 名册里最近见过的 iPhone（随身设备）。没有 iPhone → 直说，不猜别的设备。
    nonisolated static func carriedIPhone(_ devices: [KnownDevice]) throws -> KnownDevice {
        guard let phone = devices.filter({ $0.deviceKind == .iphone }).max(by: { $0.seenAt < $1.seenAt }) else {
            throw ProposalExecutionError.invalid("没指定闹钟设在哪台；默认是随身的 iPhone，但还没有登记过 iPhone（在 iPhone 上打开一次 BetterCalendar 就会登记），也可以指定一台 iPad")
        }
        return phone
    }

    /// 目标设备必须在名册里（最近见过）；不认识的 id 不猜。
    private func knownDevice(_ id: String, what: String) throws -> KnownDevice {
        guard let device = knownDevices().first(where: { $0.id == id }) else {
            throw ProposalExecutionError.invalid("不认识要设\(what)的设备「\(id.prefix(12))」：请用 context.json 里 actionTargets.devices 的 id")
        }
        return device
    }

    private static func cleanReminderTitle(_ raw: String) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= ProposalReminderRules.titleLimit else {
            throw ProposalExecutionError.invalid("标题不能为空，且不超过 \(ProposalReminderRules.titleLimit) 字")
        }
        return t
    }

    /// W10：只守有效性边界（至少 1 分钟以后：来得及审批 + 排程）；「30 天以内」的上限已取消——多远合适由智能体按上下文判断。
    private static func checkFireAt(_ fireAt: Date, now: Date) throws {
        guard fireAt >= now.addingTimeInterval(ProposalReminderRules.minLead) else {
            throw ProposalExecutionError.invalid("时刻 \(ProposalReminderRules.when(fireAt)) 已经过了或太近（至少 1 分钟以后）")
        }
    }

    private func planMover() throws -> any PlanBlockMoving {
        guard let mover else { throw ProposalExecutionError.unavailable("这台设备没有接入时间线") }
        return mover
    }

    /// W18 新种类（加 / 改 / 删 / 排一天）要的时间线能力：开关关着就拒收并说明。
    private func editingMover() throws -> any PlanBlockMoving {
        let mover = try planMover()
        guard mover.planEditingEnabled else {
            throw ProposalExecutionError.unavailable("「智能体排时间线」在设置里关着（设置 → 审批记录与规则）：现在只能挪今天的块")
        }
        return mover
    }

    private func notFound(_ mover: any PlanBlockMoving, _ what: String) -> ProposalExecutionError {
        .invalid(mover.planEditingEnabled
                 ? "今天到 \(PlanEditRules.horizonDays) 天后的计划里找不到\(what)（可能已删除，或不在这段时间里）"
                 : "今天的计划里找不到\(what)（可能已删除或不在今天）")
    }

    /// 改 / 挪 / 删现有块的一步：补全基线版本（带了就必须与此刻一致）。
    private func baselineStep(_ step: ProposalPlanStep, _ mover: any PlanBlockMoving) throws -> ProposalPlanStep {
        guard let block = try mover.windowBlock(id: step.blockID) else { throw notFound(mover, "这块") }
        let current = ProposalRevision.block(block), what = "「\(block.title)」"
        switch step {
        case let .move(m):
            return .move(ProposalBlockMove(id: m.id, start: m.start, end: m.end, expectedRevision: try Self.baseline(m.expectedRevision, current: current, what: what)))
        case let .edit(e):
            var e = e
            if let t = e.title { e.title = try Self.cleanTitle(t) }
            e.expectedRevision = try Self.baseline(e.expectedRevision, current: current, what: what)
            return .edit(e)
        case let .delete(id, rev):
            return .delete(id: id, expectedRevision: try Self.baseline(rev, current: current, what: what))
        case .create, .restore:
            return step
        }
    }

    /// 新块：标题（空 = 用关联事项的标题）+ 关联事项必须存在、不在回收站。
    private func cleanNewBlock(_ nb: ProposalNewBlock) throws -> ProposalNewBlock {
        var nb = nb
        if let taskID = nb.linkedTaskID {
            guard let task = try itemStore().task(id: taskID) else { throw ProposalExecutionError.invalid("找不到要关联的事项（可能已被删除）") }
            guard !task.isInTrash else { throw ProposalExecutionError.invalid("要关联的「\(task.title)」在回收站里") }
            if nb.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { nb.title = task.title }
        }
        nb.title = try Self.cleanTitle(nb.title)
        return nb
    }

    private func liveTask(_ id: UUID) throws -> LongTask {
        guard let task = try itemStore().task(id: id) else { throw ProposalExecutionError.invalid("找不到这条事项（可能已被删除）") }
        guard !task.isInTrash else { throw ProposalExecutionError.invalid("「\(task.title)」在回收站里，未改动") }
        return task
    }

    /// 执行时核版本：目标已被改过（或已删）→ conflict，不覆盖。
    private func checkedTask(_ id: UUID, _ expected: String?) throws -> LongTask {
        guard let expected else { throw ProposalExecutionError.invalid("缺少事项的基线版本，未执行") }
        guard let task = try itemStore().task(id: id) else { throw ProposalExecutionError.conflict("这条事项已不存在") }
        guard !task.isInTrash else { throw ProposalExecutionError.conflict("「\(task.title)」已被移入回收站") }
        guard ProposalRevision.item(task) == expected else {
            throw ProposalExecutionError.conflict("「\(task.title)」在提案之后被改过")
        }
        return task
    }

    /// 回溯起点校验（只守物理一致性，W10 起不设回溯时长上限）：不在未来、在今天（逻辑日）之内、这台设备此刻没在计时、
    /// 不与已记下的实际 / 正在跑的计时重叠。返回规范化后的起点（离此刻不到 1 分钟 = nil，按「从此刻起」）。
    private static func checkBackdate(_ startAt: Date, now: Date, state: ProposalTimerState, control: any ProposalTimerControlling) async throws -> Date? {
        let hm = PlanMoveRules.hm(startAt)
        guard startAt <= now.addingTimeInterval(ProposalTimerRules.nowTolerance) else {
            throw ProposalExecutionError.invalid("回溯起点 \(hm) 在未来；开始计时只能从过去或此刻算起")
        }
        if now.timeIntervalSince(startAt) < ProposalTimerRules.nowTolerance { return nil }
        guard DayContext.isSameLogicalDay(startAt, now) else {
            throw ProposalExecutionError.invalid("回溯起点 \(hm) 不在今天（逻辑日从凌晨 4:00 起）")
        }
        guard state.phase == .idle else {
            throw ProposalExecutionError.invalid("这台设备现在正在计时「\(state.title ?? "")」，从 \(hm) 算起会和它重叠；先结束它，或不带回溯起点")
        }
        if let hit = await control.proposalBusySpans().sorted(by: { $0.start < $1.start })
            .first(where: { $0.start < now && startAt < $0.end }) {
            throw ProposalExecutionError.invalid("从 \(hm) 算起会和已记下的「\(hit.title)」(\(PlanMoveRules.span(hit.start, hit.end))) 重叠；起点请放在它之后")
        }
        return startAt
    }

    /// 基线版本：发起者带了版本就必须与此刻一致（它看到的是旧状态 → 拒绝）；没带就用此刻的。
    private static func baseline(_ expected: String?, current: String, what: String) throws -> String {
        if let expected, expected != current {
            throw ProposalExecutionError.conflict("\(what)和提案依据的版本不一致（已被改过），请重新读取状态再提")
        }
        return current
    }

    private static func checkStatusTransition(_ task: LongTask, done: Bool) throws {
        if done, task.status != .active {
            throw ProposalExecutionError.invalid("只有在途的事项能标完成（「\(task.title)」现在是\(task.status == .done ? "做成了" : "先放下")）")
        }
        if !done, task.status != .done {
            throw ProposalExecutionError.invalid("「\(task.title)」并没有标完成，无需取消")
        }
    }

    static func cleanTitle(_ raw: String) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= titleLimit else { throw ProposalExecutionError.invalid("标题不能为空，且不超过 \(titleLimit) 字") }
        return t
    }

    static func cleanNote(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard raw.count <= noteLimit else { throw ProposalExecutionError.invalid("备注不超过 \(noteLimit) 字") }
        return raw
    }
}
