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
    /// W8 D3：最近见过的设备名册（含本机），给闹钟 / 提醒校验目标设备、在审批卡上写设备名。
    var knownDevices: () -> [KnownDevice] = { [] }
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
            let title = try Self.cleanReminderTitle(title)
            let body = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count <= ProposalReminderRules.bodyLimit else { throw ProposalExecutionError.invalid("提醒正文不超过 \(ProposalReminderRules.bodyLimit) 字") }
            try Self.checkFireAt(fireAt, now: now())
            let device = try deviceId.map { try knownDevice($0, what: "提醒") }
            let place = device.map { "在「\($0.label)」上" } ?? "在批准的那台设备上"
            var changes = [ProposalChange(field: "提醒", before: nil, after: title),
                           ProposalChange(field: "\(place) \(ProposalReminderRules.when(fireAt)) 弹一条通知", before: nil, after: nil),
                           ProposalChange(field: "普通通知：静音或专注模式下可能不响，不保证叫醒（要叫醒请用闹钟）", before: nil, after: nil)]
            if !body.isEmpty { changes.insert(ProposalChange(field: "提醒正文", before: nil, after: body), at: 1) }
            return PreparedProposalAction(action: .reminder(id: id, title: title, body: body.isEmpty ? nil : body, fireAt: fireAt, deviceId: deviceId),
                                          changes: changes, requiredDeviceId: deviceId)

        case let .alarm(id, title, fireAt, deviceId):
            let title = try Self.cleanReminderTitle(title)
            try Self.checkFireAt(fireAt, now: now())
            let device = try knownDevice(deviceId, what: "闹钟")
            guard device.isPhone else {
                throw ProposalExecutionError.invalid("闹钟只能设在 iPhone 上（「\(device.label)」是 \(device.platform)）；Mac 上不设闹钟，也不改成普通通知")
            }
            return PreparedProposalAction(action: .alarm(id: id, title: title, fireAt: fireAt, deviceId: deviceId),
                                          changes: [ProposalChange(field: "闹钟", before: nil, after: title),
                                                    ProposalChange(field: "在「\(device.label)」上 \(ProposalReminderRules.when(fireAt)) 响铃（iPhone 系统闹钟）", before: nil, after: nil)],
                                          requiredDeviceId: deviceId)

        case .reminderCancel, .alarmCancel:
            throw ProposalExecutionError.invalid("取消提醒/闹钟只用于撤销，不能单独提出")

        case let .moveBlocks(moves, isUndo):
            guard !isUndo else { throw ProposalExecutionError.invalid("「整组挪回」只用于撤销，不能单独提出") }
            let mover = try planMover()
            var baselined: [ProposalBlockMove] = []
            for m in moves {
                guard let block = try mover.todayBlock(id: m.id) else {
                    throw ProposalExecutionError.invalid("今天的计划里找不到其中一块（可能已删除或不在今天）")
                }
                let revision = try Self.baseline(m.expectedRevision, current: ProposalRevision.block(block), what: "「\(block.title)」")
                baselined.append(ProposalBlockMove(id: m.id, start: m.start, end: m.end, expectedRevision: revision))
            }
            let checked = try mover.checkGroup(moves.map { PlanMoveRules.Move(id: $0.id, start: $0.start, end: $0.end) }, restoring: false)
            let resolved = zip(baselined, checked).map { ProposalBlockMove(id: $0.id, start: $1.start, end: $1.end, expectedRevision: $0.expectedRevision) }
            var changes = checked.map { k in
                ProposalChange(field: "「\(k.block.title)」时间", before: PlanMoveRules.span(k.block.start, k.block.end),
                               after: PlanMoveRules.span(k.start, k.end))
            }
            changes.append(ProposalChange(field: "一起挪动 \(checked.count) 块；事后可整组挪回", before: nil, after: nil))
            return PreparedProposalAction(action: .moveBlocks(moves: resolved, isUndo: false), changes: changes)

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

        case let .reminder(id, title, body, fireAt, deviceId):
            if let deviceId, deviceId != self.deviceId { throw ProposalExecutionError.invalid("这条提醒指定在另一台设备上设，本机不执行") }
            guard fireAt > now() else { throw ProposalExecutionError.invalid("提醒时刻 \(ProposalReminderRules.when(fireAt)) 已经过了，没有补发") }
            let revision = try await notificationScheduler().scheduleReminder(id: id, title: title, body: body ?? "", fireAt: fireAt)
            return ProposalExecutionOutcome(note: "已在本机排好 \(ProposalReminderRules.when(fireAt)) 的提醒「\(title)」（普通通知，不保证叫醒）",
                                            undo: ProposalUndoInfo(action: .reminderCancel(id: id, expectedRevision: revision), deviceId: self.deviceId))

        case let .alarm(id, title, fireAt, deviceId):
            guard deviceId == self.deviceId else { throw ProposalExecutionError.invalid("这个闹钟指定在另一台设备上设，本机不执行") }
            guard fireAt > now() else { throw ProposalExecutionError.invalid("闹钟时刻 \(ProposalReminderRules.when(fireAt)) 已经过了，没有补响") }
            let scheduler = try notificationScheduler()
            guard scheduler.alarmsSupported else {
                throw ProposalExecutionError.unavailable("这台设备不能设系统闹钟（只有 iPhone 可以）；没有改用普通通知")
            }
            try await scheduler.scheduleAlarm(id: id, title: title, fireAt: fireAt)
            return ProposalExecutionOutcome(note: "已在本机设好 \(ProposalReminderRules.when(fireAt)) 的闹钟「\(title)」",
                                            undo: ProposalUndoInfo(action: .alarmCancel(id: id), deviceId: self.deviceId))

        case let .reminderCancel(id, expected):
            try await notificationScheduler().cancelReminder(id: id, expectedRevision: expected)
            return ProposalExecutionOutcome(note: "已取消这条提醒", undo: ProposalUndoInfo(unavailableReason: "提醒已取消；需要可以重新设"))

        case let .alarmCancel(id):
            try await notificationScheduler().cancelAlarm(id: id)
            return ProposalExecutionOutcome(note: "已取消这个闹钟", undo: ProposalUndoInfo(unavailableReason: "闹钟已取消；需要可以重新设"))

        case let .moveBlocks(moves, isUndo):
            let result = try await planMover().moveGroup(moves, restoring: isUndo)
            let back = result.changes.map { ProposalBlockMove(id: $0.before.id, start: $0.before.start, end: $0.before.end,
                                                              expectedRevision: ProposalRevision.block($0.after)) }
            return ProposalExecutionOutcome(note: result.note,
                                            undo: isUndo ? ProposalUndoInfo(unavailableReason: "已整组挪回原来的时间")
                                                         : ProposalUndoInfo(action: .moveBlocks(moves: back, isUndo: true)))

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
    private func notificationScheduler() throws -> any ProposalNotificationScheduling {
        guard let notifications else { throw ProposalExecutionError.unavailable("这台设备没有接入提醒/闹钟") }
        return notifications
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
