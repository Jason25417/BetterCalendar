//
//  Proposal.swift
//  BetterCalendar
//
//  SPEC §19 B 组：多端审批（Duo 式）的核心数据。
//  一份「提案」= 某个发起者（你 / 智能体 / 系统）想做的一项改动；需要同意时，各端看到的是同一份提案，
//  首个有效决定生效，其余端只显示最新结果。与旧 StateBridge 审批（NativeApproval*，已冻结）完全解耦。
//

import Foundation

/// 谁发起的（SPEC §19 A5：来源记录是将来预授权闸门的依据）。
nonisolated enum ProposalOrigin: String, Codable, Sendable, CaseIterable {
    case user, agent, system
    var label: String {
        switch self {
        case .user: "你"
        case .agent: "BetterCalendar 智能体"
        case .system: "BetterCalendar"
        }
    }
}

nonisolated enum ProposalState: String, Codable, Sendable {
    /// 等你决定
    case pending
    /// 已同意，等执行设备接手
    case approved
    case declined
    case expired
    /// 发起者撤回
    case cancelled
    /// 执行设备报告已应用
    case applied
    /// 执行设备报告失败（不自动重试，不复活）
    case failed
    /// W10：你没点批准/拒绝，而是用自然语言回了一句（如「改成 9 点吧」）。提案停止等待、不执行、不算拒绝；
    /// 这句话转给智能体，由它撤回并重新提案。
    case replied

    var label: String {
        switch self {
        case .pending: "待你确认"
        case .approved: "已同意，等待执行"
        case .declined: "已拒绝"
        case .expired: "已过期，不会执行"
        case .cancelled: "已撤回"
        case .applied: "已完成"
        case .failed: "执行失败"
        case .replied: "你回了一句，等智能体重新提"
        }
    }
    /// 已有最终结论、不会再变的状态。
    var isClosed: Bool { ![.pending, .approved].contains(self) }
}

nonisolated enum ProposalDecision: String, Codable, Sendable {
    case approve, decline
    var resultingState: ProposalState { self == .approve ? .approved : .declined }
}

/// 给人看的一行改动：「字段：原来 → 改成」。before 为 nil = 新增。
nonisolated struct ProposalChange: Codable, Equatable, Sendable {
    var field: String
    var before: String?
    var after: String?
}

/// 计时指令（SPEC §19 D1/D2）。结束计时 = 记下这段投入，**不等于**完成事项。
nonisolated enum ProposalTimerCommand: String, Codable, Sendable, CaseIterable {
    case start, pause, resume, stop
    var label: String {
        switch self {
        case .start: "开始计时"
        case .pause: "暂停计时"
        case .resume: "继续计时"
        case .stop: "结束计时"
        }
    }
}

/// 多块挪动里的一块（end=nil 则保持原时长）。
nonisolated struct ProposalBlockMove: Codable, Equatable, Sendable {
    var id: UUID
    var start: Date
    var end: Date?
    var expectedRevision: String?
}

/// W18：新加的一个计划块（时间线排程）。id 在提交前就定下（智能体给，或由提案 id 推出），撤销 = 按 id 移入回收站。
nonisolated struct ProposalNewBlock: Codable, Equatable, Sendable {
    var id: UUID
    /// 空串 = 用关联事项的标题（准备提案时由 App 补上）。
    var title: String
    var start: Date
    var end: Date
    var isFixed: Bool = false
    /// 要紧事（BlockPriority.important）
    var important: Bool = false
    var deadline: Date? = nil
    /// 关联的待办 / 长期事项（LongTask.id）
    var linkedTaskID: UUID? = nil
}

/// W18：截止时间怎么改。
nonisolated enum ProposalDeadlineChange: Codable, Equatable, Sendable {
    case set(Date)
    case clear
}

/// W18：改一个计划块的属性（nil = 该项不改）。时长改的是结束时间（开始不动）。
nonisolated struct ProposalBlockEdit: Codable, Equatable, Sendable {
    var id: UUID
    var title: String? = nil
    /// 新时长（秒）
    var duration: TimeInterval? = nil
    var isFixed: Bool? = nil
    var important: Bool? = nil
    var deadline: ProposalDeadlineChange? = nil
    var expectedRevision: String? = nil

    var isEmpty: Bool { title == nil && duration == nil && isFixed == nil && important == nil && deadline == nil }
}

/// W18：「排一天」整组里的一步（整组校验最终布局、整组批准、整组撤销）。
/// restore 只用于撤销（把这组删掉的块从回收站恢复），智能体不能提。
nonisolated enum ProposalPlanStep: Codable, Equatable, Sendable {
    case create(ProposalNewBlock)
    case move(ProposalBlockMove)
    case edit(ProposalBlockEdit)
    case delete(id: UUID, expectedRevision: String?)
    case restore(id: UUID, deletionID: UUID?)

    var blockID: UUID {
        switch self {
        case let .create(b): b.id
        case let .move(m): m.id
        case let .edit(e): e.id
        case let .delete(id, _), let .restore(id, _): id
        }
    }
    var op: String {
        switch self {
        case .create: "create"
        case .move: "move"
        case .edit: "edit"
        case .delete: "delete"
        case .restore: "restore"
        }
    }
}

/// 机器执行的内容。新增种类时在这里加 case，并在 ProposalExecuting 实现里处理；
/// 未识别的种类一律执行失败，绝不猜测。
/// expectedRevision = 提案时目标的版本（ProposalRevision）；执行时目标版本已变 → 失败并说明，不覆盖用户事实。
/// nil 只出现在刚解析、尚未 prepare 的草稿里——ProposalCenter 提交前一律补成当时的版本。
nonisolated enum ProposalAction: Codable, Equatable, Sendable {
    /// 联调用的空改动：批准后只记录「已应用」，不碰任何真实数据。
    case experimentNoop(note: String)
    /// 事项：新增一条待办（待办区）。id 在提交前就定下，撤销 = 按 id 移入回收站。
    case itemCreate(id: UUID, title: String, note: String?)
    /// 事项：改标题 / 备注（nil = 该字段不改）。
    case itemEdit(id: UUID, title: String?, note: String?, expectedRevision: String?)
    /// 事项：标完成（done=true）/ 取消完成（done=false）。
    case itemSetDone(id: UUID, done: Bool, expectedRevision: String?)
    /// 事项：移入回收站（30 天内可恢复）。只作「新增待办」的逆操作，智能体不能直接提。
    case itemDiscard(id: UUID, expectedRevision: String?)
    /// 计时：开始（今天某计划块 blockId，或一件计划外的事 title）/ 暂停 / 继续 / 结束。
    /// expectedRevision = 执行设备上的计时状态版本（计时是设备本地状态）。
    /// startAt（只用于开始，W8 Jason 2026-10-18）：回溯起点——像 Apple Watch 检测到运动，智能体判断你大概从这一刻起就在做；
    /// 批准前不写任何东西，批准后（有效期内何时批准都一样）从 startAt 起算；拒绝/过期 = 什么都没发生。nil = 从批准执行那刻起算。
    case timer(command: ProposalTimerCommand, blockId: UUID?, title: String?, expectedRevision: String?, startAt: Date? = nil)
    /// 时间线：挪动今天某个计划块（end=nil 则保持原时长）。必须过本地排布规则校验。
    case moveBlock(id: UUID, start: Date, end: Date?, expectedRevision: String?)
    /// 时间线：一次挪动今天的多个计划块（W8，Jason 2026-10-18：撞到别的块时连带挪，参照 reflow 顺延）。
    /// App 对**最终整体布局**校验（固定块不动、正在做/做完的不动、不进过去、不出今天、不越截止、最终互不重叠）；
    /// 撤销 = 整组挪回（isUndo=true：只作逆操作，智能体不能提；放宽「不进过去」与组内原有重叠，见 PlanMoveRules）。
    case moveBlocks(moves: [ProposalBlockMove], isUndo: Bool)
    /// 提醒（SPEC §19.5 D3，W8；W12 起 = SPEC §19.13 Q5）：写进 BetterCalendar 的提醒事项列表，iPhone 和 Mac 都会响；
    /// 列表只在本机 / 没有提醒事项权限时改用本机通知（结果里写明）。deviceId 只为兼容旧提案保留，不再决定执行设备。
    /// 要叫醒用 alarm。撤销 = 删掉那条提醒（你在提醒事项里改过 / 勾掉了就不删）。
    case reminder(id: UUID, title: String, body: String?, fireAt: Date, deviceId: String?)
    /// 闹钟（D3，W8）：在 iPhone（deviceId 必填）上设系统闹钟（AlarmKit），会像闹钟一样响铃。Mac 上拒收。撤销 = 取消闹钟。
    case alarm(id: UUID, title: String, fireAt: Date, deviceId: String)
    /// 逆操作：取消提醒（expectedRevision = 设好时的版本）/ 取消闹钟。只用于撤销，智能体不能直接提。
    case reminderCancel(id: UUID, expectedRevision: String?)
    case alarmCancel(id: UUID)
    // —— W18 时间线排程（Jason 2026-10-19：日用只走智能体，智能体必须能把事情放上时间线）——
    // 合法性归 App：全部经 PlanEditRules 对**最终整体布局**校验（固定不动、不重叠、不越截止、你的日历=已占用只读、
    // 正在做/做完的不动、放不下明说原因、不悄悄挤）。写入只经 PlanStore，绿色日历由 CalendarSyncEngine 投影。
    /// 往某个逻辑日（day = 该日零点）加一个或多个计划块。撤销 = 把这几块移入回收站。
    case blockCreate(day: Date, blocks: [ProposalNewBlock])
    /// 改一个计划块：标题 / 时长 / 固定 / 要紧 / 截止。撤销 = 改回原值。
    case blockEdit(ProposalBlockEdit)
    /// 从时间线删掉一个计划块（进回收站，30 天内可恢复）。删除类：预授权规则永远不自动放行。撤销 = 从回收站恢复。
    case blockDelete(id: UUID, expectedRevision: String?)
    /// 排一天：一份提案里若干步新增 / 挪动 / 改 / 删（都围绕 day 这个逻辑日），整组校验、整组批准、整组撤销。
    /// isUndo=true 只作逆操作（智能体不能提）：放宽「不进过去 / 不越截止 / 组内原有重叠」，见 PlanEditRules。
    case planDay(day: Date, steps: [ProposalPlanStep], isUndo: Bool)

    var kindLabel: String {
        switch self {
        case .experimentNoop: "测试改动（不改真实数据）"
        case .itemCreate: "事项：新增待办"
        case .itemEdit: "事项：改标题/备注"
        case let .itemSetDone(_, done, _): done ? "事项：标完成" : "事项：取消完成"
        case .itemDiscard: "事项：移入回收站"
        case let .timer(command, _, _, _, _): "计时：" + command.label
        case .moveBlock: "时间线：挪动计划块"
        case .reminder: "提醒：提醒事项（iPhone 和 Mac 都会响）"
        case .alarm: "闹钟：iPhone 系统闹钟"
        case .reminderCancel: "提醒：取消"
        case .alarmCancel: "闹钟：取消"
        case let .moveBlocks(moves, isUndo): isUndo ? "时间线：整组挪回" : "时间线：一起挪动 \(moves.count) 个计划块"
        case let .blockCreate(day, blocks): "时间线：\(PlanEditRules.dayName(day))加 \(blocks.count) 个计划块"
        case .blockEdit: "时间线：改计划块"
        case .blockDelete: "时间线：删掉计划块（进回收站）"
        case let .planDay(day, steps, isUndo): isUndo ? "时间线：整组撤销" : "时间线：排\(PlanEditRules.dayName(day))（\(steps.count) 步）"
        }
    }

    /// 稳定的机器名（桥接协议 action.kind 同名；操作留底、统计用）。
    var kind: String {
        switch self {
        case .experimentNoop: "experimentNoop"
        case .itemCreate: "itemCreate"
        case .itemEdit: "itemEdit"
        case .itemSetDone: "itemSetDone"
        case .itemDiscard: "itemDiscard"
        case .timer: "timer"
        case .moveBlock: "moveBlock"
        case .moveBlocks: "moveBlocks"
        case .reminder: "reminder"
        case .alarm: "alarm"
        case .reminderCancel: "reminderCancel"
        case .alarmCancel: "alarmCancel"
        case .blockCreate: "blockCreate"
        case .blockEdit: "blockEdit"
        case .blockDelete: "blockDelete"
        case .planDay: "planDay"
        }
    }

    /// 是否会改真实数据（测试改动不会）。
    var touchesRealData: Bool { if case .experimentNoop = self { false } else { true } }

    // MARK: 预授权规则用（W10，SPEC §19 A3a）

    /// 规则匹配用的「这一类改动」：比 kind 细一层（计时分开始/暂停/继续/结束，完成分标完成/取消完成），
    /// 让「以后暂停计时都直接做」不会顺带放行「结束计时」。
    var ruleKind: String {
        switch self {
        case let .itemSetDone(_, done, _): done ? "itemSetDone.done" : "itemSetDone.undone"
        case let .timer(command, _, _, _, _): "timer." + command.rawValue
        case let .moveBlocks(_, isUndo): isUndo ? "moveBlocks.undo" : "moveBlocks"
        case let .planDay(_, _, isUndo): isUndo ? "planDay.undo" : "planDay"
        default: kind
        }
    }

    /// 「这一类改动」给人看的名字（不带数量等具体内容）。
    var ruleKindLabel: String {
        switch self {
        case .moveBlocks(_, false): "时间线：一起挪动多个计划块"
        case .blockCreate: "时间线：加计划块"
        case .planDay(_, _, false): "时间线：排一天（整组新增/挪动/改/删）"
        default: kindLabel
        }
    }

    /// 这项改动动的是谁的东西（原则 8「谁的东西谁做主」）。现有种类全部只动 BetterCalendar 自己的东西
    /// （它的待办、计划块、计时、它排的提醒/闹钟）；将来写你的日历/提醒事项的种类在这里标 `.yours`。
    var ownership: ProposalOwnership { .betterCalendar }

    /// 删除类（移入回收站 / 取消提醒 / 取消闹钟 / W18 删计划块、含删除步骤的排一天）：预授权规则永远不能自动放行。
    var isDestructive: Bool {
        switch self {
        case .itemDiscard, .reminderCancel, .alarmCancel, .blockDelete: true
        case let .planDay(_, steps, _): steps.contains { if case .delete = $0 { true } else { false } }
        default: false
        }
    }
}

/// 东西的主人（原则 8）：你的（你自己的日历、提醒、别人发来的邀请）／BetterCalendar 的（它排的计划块、记的实际、投影）。
nonisolated enum ProposalOwnership: String, Codable, Sendable {
    case betterCalendar, yours
}

/// W10：智能体自己填的备选方案（像 Claude Code 的选项卡）。每个都是一套完整的改动，经 App 同样的 prepare 校验，
/// changes 由 App 依据真实数据计算。你选哪个就执行哪个。
nonisolated struct ProposalAlternative: Codable, Equatable, Sendable {
    /// 按钮上的短名字（如「挪到 9 点」）。
    var label: String
    var action: ProposalAction
    var changes: [ProposalChange] = []
    /// W11：这个方案上的可调参数（可选；旧记录没有这个键照常解码）。
    var parameters: [ProposalParameter]? = nil
}

/// 审批卡 / 通知上的一个可选方案（index 0 = 主方案）。
nonisolated struct ProposalOption: Equatable, Sendable, Identifiable {
    var index: Int
    var label: String
    var action: ProposalAction
    var changes: [ProposalChange]
    /// W11：这个方案上的可调参数（空 = 没有）。
    var parameters: [ProposalParameter] = []
    var id: Int { index }
}

/// W10：你对提案回的一句话（第三种回应）。原文转给智能体，提案停止等待。
nonisolated struct ProposalUserReply: Codable, Equatable, Sendable {
    var text: String
    var at: Date
    var deviceId: String
}

/// W10：这份提案由哪条预授权规则代你决定的（来源 = 规则 id，操作留底同样记下）。
nonisolated struct ProposalPreauthStamp: Codable, Equatable, Sendable {
    var ruleId: UUID
    var effect: PreauthEffect
    /// 规则给人看的说明（规则之后被删了也看得懂当时依据的是什么）。
    var ruleLabel: String
}

nonisolated struct Proposal: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var expiresAt: Date
    var origin: ProposalOrigin
    /// 发起者的具体名字，如「BetterCalendar 智能体」「Claude（替 Jason 测试）」。
    var originLabel: String
    var originDeviceId: String
    /// 上下级：这份提案由哪个更早的操作/提案引出（nil = 直接发起）。
    var parentId: UUID?
    /// 指定执行设备；nil = 由做出同意决定的那台设备执行。
    var targetDeviceId: String?
    /// 通知标题：一句话说明是什么事。
    var title: String
    var changes: [ProposalChange]
    /// 一句话理由（SPEC §19 A3 / 原则 7 补充：讲得出依据）。
    var reason: String
    var action: ProposalAction
    var experiment: Bool
    var state: ProposalState
    var decidedAt: Date?
    var decidedByDeviceId: String?
    var appliedAt: Date?
    var resultNote: String?
    /// 非 UUID 形式的上级引用（如智能体事件 id「event-…」）；与 parentId 二选一或并存。
    var parentRef: String? = nil
    // —— 撤销（SPEC §19 A3 后半）。全部 Optional：旧版本写的记录照常解码。——
    /// 执行时保存的逆操作（带「执行后」的版本；目标再被改过 → 拒绝撤销）。nil = 不能撤销。
    var undoAction: ProposalAction? = nil
    /// 只能在这台设备上撤销（计时是设备本地状态）；nil = 任一设备。
    var undoDeviceId: String? = nil
    /// 不能撤销时给人看的原因（例如「结束计时已把投入记下」）。
    var undoUnavailableReason: String? = nil
    var undoneAt: Date? = nil
    var undoneByDeviceId: String? = nil
    var undoNote: String? = nil
    // —— W10（全部 Optional / 有默认值：旧版本写的记录照常解码）——
    /// 越级理由（原则 8「审慎越级」）：智能体判断确有必要动你的东西或你亲手放的位置（图钉）时必须写明。
    /// 有值 = 越级提案：审批卡醒目显示，预授权规则永远不能自动放行（一律先问你）。
    var escalation: String? = nil
    /// 主方案按钮上的短名字（有备选方案时显示；nil =「方案 1」）。
    var primaryLabel: String? = nil
    /// 智能体自填的备选方案（最多 3 个）。
    var alternatives: [ProposalAlternative]? = nil
    /// 你选了哪个方案（0 = 主方案；1… = 第几个备选）；nil = 没有备选或还没决定。
    var chosenOption: Int? = nil
    /// 你回的一句话（state = .replied）。
    var userReply: ProposalUserReply? = nil
    /// 预授权规则代你做的决定（nil = 你亲自决定 / 还没决定）。
    var preauth: ProposalPreauthStamp? = nil
    // —— W11 可调参数（全部 Optional：旧版本写的记录照常解码；只存在 JSON 载荷里，不改 CloudKit schema）——
    /// 主方案上的可调参数（默认值 = 主方案动作里写的那个）。备选方案的参数在 ProposalAlternative.parameters。
    var parameters: [ProposalParameter]? = nil
    /// 批准时选方案上每个参数的最终值（没动 = 默认值）；nil = 选中的方案没有参数 / 还没批准。
    var chosenValues: [String: ProposalParameterValue]? = nil
    /// 你调过数值时：套回你选的值、重新校验过的动作与「改动前 → 改动后」（执行的就是它）。没调 = nil，执行原方案。
    var tunedAction: ProposalAction? = nil
    var tunedChanges: [ProposalChange]? = nil

    /// 备选方案上限（卡片列得下、你看得过来；通知按钮另有系统限制）。
    static let maxAlternatives = 3

    /// 全部可选方案（主方案在前）。
    var options: [ProposalOption] {
        [ProposalOption(index: 0, label: primaryLabel ?? "方案 1", action: action, changes: changes, parameters: parameters ?? [])]
            + (alternatives ?? []).enumerated().map { i, a in
                ProposalOption(index: i + 1, label: a.label, action: a.action, changes: a.changes, parameters: a.parameters ?? [])
            }
    }
    var hasAlternatives: Bool { !(alternatives ?? []).isEmpty }
    /// W11：任一方案带可调参数（预授权规则一律先问你；通知上的批准 = 按默认批准）。
    var hasParameters: Bool { options.contains { !$0.parameters.isEmpty } }
    /// 选中的（或默认的主）方案；你调过数值时，动作与改动前后换成调好、重新校验过的那份（W11）。
    var chosen: ProposalOption {
        let all = options
        var o = all.indices.contains(chosenOption ?? 0) ? all[chosenOption ?? 0] : all[0]
        if let tunedAction { o.action = tunedAction; o.changes = tunedChanges ?? o.changes }
        return o
    }
    /// W11：选中方案上你批准时的参数说明（「提醒时间：08:00 → 你改成 07:45」）；没有参数 = 空。
    var tuningSummary: [String] {
        guard let chosenValues else { return [] }
        return ProposalParameterRules.summary(chosen.parameters, values: chosenValues)
    }
    /// W11：批准时改了至少一个参数的默认值（转译偏差信号：智能体给的数不合你意）。
    var tunedByUser: Bool {
        guard let chosenValues else { return false }
        return chosen.parameters.contains { ProposalParameterRules.isChanged($0, chosenValues[$0.id]) }
    }
    /// 批准后真正执行的动作。
    var executedAction: ProposalAction { chosen.action }

    /// 撤销会做什么（面板、桥接结果文件给人看）；nil = 没有可撤销的内容。
    var undoHint: String? {
        switch undoAction {
        case let .moveBlocks(moves, _)?: "撤销 = 这 \(moves.count) 块整组挪回原来的时间（任一块之后被改过就整组不撤）"
        case .moveBlock?: "撤销 = 挪回原来的时间"
        case .itemDiscard?: "撤销 = 把这条待办移入回收站（30 天内可恢复）"
        case .itemEdit?: "撤销 = 改回原来的标题/备注"
        case .itemSetDone?: "撤销 = 恢复原来的完成状态"
        case let .reminderCancel(_, rev)?:
            rev?.hasPrefix(ProposalActionExecutor.nativeRevisionPrefix) == true
                ? "撤销 = 从提醒事项里删掉这条提醒（你在提醒事项里改过或勾掉了就不删）" : "撤销 = 取消这条提醒"
        case .alarmCancel?: "撤销 = 取消这个闹钟"
        case let .planDay(_, steps, true)?: PlanEditRules.undoHint(steps)
        case let .timer(command, _, _, _, _)?: command == .resume ? "撤销 = 继续计时" : command == .pause ? "撤销 = 暂停计时" : nil
        default: nil
        }
    }

    /// 以此刻判断的有效状态：未决定且已过截止时间 = 已过期（不复活，不执行）。
    func effectiveState(at now: Date) -> ProposalState {
        state == .pending && now >= expiresAt ? .expired : state
    }

    /// 本机是否负责执行这份已同意的提案。
    func isExecutor(_ deviceId: String) -> Bool {
        (targetDeviceId ?? decidedByDeviceId) == deviceId
    }

    /// 通知正文：改动前后 + 理由，局外操作也看得懂（Duo 式）。
    /// W10：越级提案第一行醒目写明；有备选方案时逐个列出（选中后只列选中的那个）。
    var notificationBody: String {
        var lines: [String] = []
        if let escalation { lines.append(Self.escalationHeadline + "：" + escalation) }
        let undecided = state == .pending || state == .expired
        if hasAlternatives && chosenOption == nil {
            for o in options {
                lines.append("【\(o.index + 1). \(o.label)】")
                lines += o.changes.map(Self.line)
                if undecided { lines += Self.adjustableLines(o.parameters) }
            }
        } else {
            if hasAlternatives { lines.append("选了【\(chosen.index + 1). \(chosen.label)】") }
            lines += chosen.changes.map(Self.line)
            if chosenValues != nil { lines += tuningSummary }
            else if undecided { lines += Self.adjustableLines(chosen.parameters) }
        }
        if !reason.isEmpty { lines.append("理由：" + reason) }
        lines.append("发起：" + originLabel)
        return lines.joined(separator: "\n")
    }

    static let escalationHeadline = "【越级】这会动你亲手放的位置或你的东西"

    /// W11：通知里放不下滑块/选择器——写明默认值，并说明打开卡片可以调。
    static func adjustableLines(_ params: [ProposalParameter]) -> [String] {
        params.compactMap { p in
            p.defaultValue.map { adjustablePrefix + "\(p.label) 默认 \(ProposalParameterRules.format($0, p))（打开卡片可以调）" }
        }
    }
    /// 卡片上已有滑块/选择器时，过滤掉通知正文里的这几行。
    static let adjustablePrefix = "可调："

    static func line(_ c: ProposalChange) -> String {
        switch (c.before, c.after) {
        case let (b?, a?): "\(c.field)：\(b) → \(a)"
        case let (nil, a?): "\(c.field)：新增「\(a)」"
        case let (b?, nil): "\(c.field)：删除「\(b)」"
        case (nil, nil): c.field
        }
    }
}

/// 发起时只填这些；身份、时间、状态由 ProposalCenter 统一盖章。
nonisolated struct ProposalDraft: Sendable {
    /// 指定提案 id（智能体桥接导入时沿用智能体给的 id，保证重复导入幂等）；nil = 新生成。
    var id: UUID? = nil
    var parentRef: String? = nil
    var origin: ProposalOrigin
    var originLabel: String
    var parentId: UUID? = nil
    var targetDeviceId: String? = nil
    var title: String
    var changes: [ProposalChange]
    var reason: String
    var action: ProposalAction
    var experiment: Bool
    /// 有效期（W11：多久合适由发起者按上下文判断——智能体见 CLAUDE.md；代码只守 ProposalLifetime 的技术稳定窗口）。
    /// 24 小时只是 App 内部发起（面板测试按钮等）没写时的缺省。
    var lifetime: TimeInterval = 24 * 3600
    /// W10：越级理由（见 Proposal.escalation）。
    var escalation: String? = nil
    var primaryLabel: String? = nil
    /// W10：备选方案（changes 由 prepare 依据真实数据重算）。
    var alternatives: [ProposalAlternative] = []
    /// W11：主方案上的可调参数（默认值由 prepare 依据主方案动作算出）。备选方案的参数挂在各自的 ProposalAlternative 上。
    var parameters: [ProposalParameter] = []

    /// 方案按钮名字的长度上限（通知按钮放得下）。
    static let optionLabelLimit = 40
}

/// W11（Jason 2026-10-18）：提案有效期的**技术稳定窗口，不是产品规则**。
/// 多久合适是判断（开始计时的猜测要快过期；「要不要下周一提醒你」可以活久一点），交给智能体按上下文定（CLAUDE.md）。
/// 代码只守两头：至少 1 分钟（来得及看到、审批）；最多 7 天（防「僵尸提案」一直挂着待确认；Jason 2026-10-18 定：
/// 一周已覆盖「下周一要不要提醒你」这类情形，更久只是过时的提案挂着）。
nonisolated enum ProposalLifetime {
    static let minimum: TimeInterval = 60
    /// 防僵尸提案的稳定上限，不是产品规则。
    static let maximum: TimeInterval = 7 * 86_400
    static func check(_ lifetime: TimeInterval) throws {
        guard lifetime.isFinite, lifetime >= minimum, lifetime <= maximum else {
            throw ProposalExecutionError.invalid("有效期要在 1 分钟到 7 天之间（7 天是防止提案一直挂着的技术上限，不是产品规则）")
        }
    }
}
