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

    var label: String {
        switch self {
        case .pending: "待你确认"
        case .approved: "已同意，等待执行"
        case .declined: "已拒绝"
        case .expired: "已过期，不会执行"
        case .cancelled: "已撤回"
        case .applied: "已完成"
        case .failed: "执行失败"
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
    /// 提醒（SPEC §19.5 D3，W8）：在 deviceId 那台设备（nil = 批准的那台）上排一条普通本地通知。
    /// **普通通知不保证叫醒**（静音 / 专注模式下可能不响）——要叫醒用 alarm。撤销 = 取消排程。
    case reminder(id: UUID, title: String, body: String?, fireAt: Date, deviceId: String?)
    /// 闹钟（D3，W8）：在 iPhone（deviceId 必填）上设系统闹钟（AlarmKit），会像闹钟一样响铃。Mac 上拒收。撤销 = 取消闹钟。
    case alarm(id: UUID, title: String, fireAt: Date, deviceId: String)
    /// 逆操作：取消提醒（expectedRevision = 设好时的版本）/ 取消闹钟。只用于撤销，智能体不能直接提。
    case reminderCancel(id: UUID, expectedRevision: String?)
    case alarmCancel(id: UUID)

    var kindLabel: String {
        switch self {
        case .experimentNoop: "测试改动（不改真实数据）"
        case .itemCreate: "事项：新增待办"
        case .itemEdit: "事项：改标题/备注"
        case let .itemSetDone(_, done, _): done ? "事项：标完成" : "事项：取消完成"
        case .itemDiscard: "事项：移入回收站"
        case let .timer(command, _, _, _, _): "计时：" + command.label
        case .moveBlock: "时间线：挪动计划块"
        case .reminder: "提醒：普通通知（不保证叫醒）"
        case .alarm: "闹钟：iPhone 系统闹钟"
        case .reminderCancel: "提醒：取消"
        case .alarmCancel: "闹钟：取消"
        case let .moveBlocks(moves, isUndo): isUndo ? "时间线：整组挪回" : "时间线：一起挪动 \(moves.count) 个计划块"
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
        }
    }

    /// 是否会改真实数据（测试改动不会）。
    var touchesRealData: Bool { if case .experimentNoop = self { false } else { true } }
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

    /// 撤销会做什么（面板、桥接结果文件给人看）；nil = 没有可撤销的内容。
    var undoHint: String? {
        switch undoAction {
        case let .moveBlocks(moves, _)?: "撤销 = 这 \(moves.count) 块整组挪回原来的时间（任一块之后被改过就整组不撤）"
        case .moveBlock?: "撤销 = 挪回原来的时间"
        case .itemDiscard?: "撤销 = 把这条待办移入回收站（30 天内可恢复）"
        case .itemEdit?: "撤销 = 改回原来的标题/备注"
        case .itemSetDone?: "撤销 = 恢复原来的完成状态"
        case .reminderCancel?: "撤销 = 取消这条提醒"
        case .alarmCancel?: "撤销 = 取消这个闹钟"
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
    var notificationBody: String {
        var lines = changes.map { c -> String in
            switch (c.before, c.after) {
            case let (b?, a?): "\(c.field)：\(b) → \(a)"
            case let (nil, a?): "\(c.field)：新增「\(a)」"
            case let (b?, nil): "\(c.field)：删除「\(b)」"
            case (nil, nil): c.field
            }
        }
        if !reason.isEmpty { lines.append("理由：" + reason) }
        lines.append("发起：" + originLabel)
        return lines.joined(separator: "\n")
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
    var lifetime: TimeInterval = 24 * 3600
}
