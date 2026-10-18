//
//  ProposalActionExecutor.swift
//  BetterCalendar
//
//  SPEC §19 W1：多端审批的「真改动」执行器（替换只做空改动的 ExperimentOnlyExecutor；协议缝不变）。
//  三类动作：① 事项（新增待办 / 改标题备注 / 标完成·取消完成）② 计时（开始 / 暂停 / 继续 / 结束）
//  ③ 时间线（挪动今天某个计划块，经 PlanMoveRules 校验）。
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
}

// MARK: - 能力缝

/// 事项写入（唯一写者 = LongTaskStore）。
@MainActor protocol ProposalItemStore: AnyObject {
    func task(id: UUID) throws -> LongTask?
    func createTodo(id: UUID, title: String, note: String, at date: Date) throws
    func update(id: UUID, at date: Date, _ change: (LongTask) -> Void) throws
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
    func proposalStartTimer(blockId: UUID?, title: String?) async throws
    func proposalPauseTimer() async throws
    func proposalResumeTimer() async throws
    func proposalStopTimer() async throws
}

// MARK: - 执行器

@MainActor final class ProposalActionExecutor: ProposalExecuting {
    private let items: (any ProposalItemStore)?
    /// 计时与挪动依赖执行层/时间线，组装点在它们建好后挂上（weak：不延长执行层寿命）。
    weak var timer: (any ProposalTimerControlling)?
    var mover: (any PlanBlockMoving)?
    let deviceId: String
    private let now: () -> Date

    static let titleLimit = 200
    static let noteLimit = 2000

    init(items: (any ProposalItemStore)?, timer: (any ProposalTimerControlling)? = nil, mover: (any PlanBlockMoving)? = nil,
         deviceId: String, now: @escaping () -> Date = { .now }) {
        self.items = items; self.timer = timer; self.mover = mover; self.deviceId = deviceId; self.now = now
    }

    // MARK: prepare

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

        case let .timer(command, blockId, title, expected):
            let control = try timerControl()
            let state = control.proposalTimerState
            var resolvedTitle = title
            var changes: [ProposalChange] = []
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
                changes.append(ProposalChange(field: "计时", before: state.label, after: "正在计时「\(resolvedTitle ?? "")」"))
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
                                                         expectedRevision: revision),
                                          changes: changes, requiredDeviceId: deviceId)

        case let .moveBlock(id, start, end, expected):
            let mover = try planMover()
            guard let block = try mover.todayBlock(id: id) else {
                throw ProposalExecutionError.invalid("今天的计划里找不到这块（可能已删除或不在今天）")
            }
            let revision = try Self.baseline(expected, current: ProposalRevision.block(block), what: "「\(block.title)」")
            let checked = try mover.check(id: id, start: start, end: end)
            return PreparedProposalAction(action: .moveBlock(id: id, start: checked.start, end: checked.end, expectedRevision: revision),
                                          changes: [ProposalChange(field: "「\(block.title)」时间",
                                                                   before: PlanMoveRules.span(block.start, block.end),
                                                                   after: PlanMoveRules.span(checked.start, checked.end))])
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

        case let .timer(command, blockId, title, expected):
            let control = try timerControl()
            let before = control.proposalTimerState
            guard let expected else { throw ProposalExecutionError.invalid("缺少计时状态的基线版本，未执行") }
            guard before.revision == expected else {
                throw ProposalExecutionError.conflict("这台设备的计时状态在提案之后变了（现在：\(before.label)）")
            }
            switch command {
            case .start: try await control.proposalStartTimer(blockId: blockId, title: title)
            case .pause: try await control.proposalPauseTimer()
            case .resume: try await control.proposalResumeTimer()
            case .stop: try await control.proposalStopTimer()
            }
            let after = control.proposalTimerState
            let note = "\(command.label)：\(before.label) → \(after.label)"
            let undo: ProposalUndoInfo
            switch command {
            case .pause:
                undo = ProposalUndoInfo(action: .timer(command: .resume, blockId: nil, title: nil, expectedRevision: after.revision), deviceId: deviceId)
            case .resume:
                undo = ProposalUndoInfo(action: .timer(command: .pause, blockId: nil, title: nil, expectedRevision: after.revision), deviceId: deviceId)
            case .start where before.phase == .idle:
                // 撤销「开始」= 结束这次计时：已计的时间照常记下（不删除任何记录）。
                undo = ProposalUndoInfo(action: .timer(command: .stop, blockId: nil, title: nil, expectedRevision: after.revision), deviceId: deviceId)
            case .start:
                undo = ProposalUndoInfo(unavailableReason: "开始前在计的那件已结束并记下投入，无法恢复原状")
            case .stop:
                undo = ProposalUndoInfo(unavailableReason: "结束计时已把这段投入记下；不删除记录，需要继续可以再开始")
            }
            return ProposalExecutionOutcome(note: note, undo: undo)

        case let .moveBlock(id, start, end, expected):
            guard let expected else { throw ProposalExecutionError.invalid("缺少计划块的基线版本，未执行") }
            let result = try await planMover().move(id: id, start: start, end: end, expectedRevision: expected)
            return ProposalExecutionOutcome(note: result.note,
                                            undo: ProposalUndoInfo(action: .moveBlock(id: id, start: result.before.start, end: result.before.end,
                                                                                      expectedRevision: ProposalRevision.block(result.after))))
        }
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
    private func planMover() throws -> any PlanBlockMoving {
        guard let mover else { throw ProposalExecutionError.unavailable("这台设备没有接入时间线") }
        return mover
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
