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
    /// W30：闹钟没指定设备 = 默认随身的 iPhone（只在提案准备阶段出现，准备时换成那台 iPhone 的 id；存下来的提案里不会有它）。
    static let carriedDeviceDefault = ""
    /// 联调用的空改动：批准后只记录「已应用」，不碰任何真实数据。
    case experimentNoop(note: String)
    /// 事项：新增一条待办（待办区）。id 在提交前就定下，撤销 = 按 id 移入回收站。
    /// 0.78.1：longTerm = true 建在长期区（分阶段、持续很久的事；之后可用 checkpointCreate 加阶段），nil / false = 待办区。
    case itemCreate(id: UUID, title: String, note: String?, longTerm: Bool? = nil)
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
    // —— W32 越级审批你的东西（Jason 2026-10-19/20）：你自己的日程 / 提醒 / 待办与长期事项 / 你写的日记 ——
    // 全部 ownership = .yours：必须带越级理由、永远要你亲自批（预授权规则不放行）、撤销 = 按执行前的快照原样改回。
    // 只有日记的「加一段」是例外（只新增智能体自己的、标了字体的文字，不碰你的字）：普通审批。
    /// 改你的一条日程（标题 / 时间 / 备注；重复日程写明范围，默认只这一次）。写入只经 EventKitYourItemsWriter。
    case yourEventEdit(YourEventEdit)
    /// 删你的一条日程（只在你要求时）。W34：重复日程按 span 删（nil = 只这一次）；撤销 = 按快照重建
    ///（只这一次 → 一条独立日程；这一次及以后 → 按原规则重建剩下的系列）。
    case yourEventDelete(ref: YourEventRef, expectedRevision: String?, span: YourEventSpan? = nil)
    /// 逆操作：按快照重建删掉的日程。只用于撤销，智能体不能提。
    case yourEventRecreate(YourEventSnapshot)
    /// 改你的一条提醒（改名 / 挪截止 / 标完成）。撤销 = 原样改回。W34：重复提醒标完成 = 完成这一次（不能一键撤销）。
    case yourReminderEdit(YourReminderEdit)
    /// W34：删你的一条提醒（重复提醒 = 整个系列）。越级 + 删除类。撤销 = 按完整快照重建（新的一条）。
    case yourReminderDelete(externalID: String, expectedRevision: String?)
    /// 逆操作：按快照重建删掉的提醒。只用于撤销。
    case yourReminderRecreate(YourReminderSnapshot)
    /// W32c：删一条待办 / 长期事项（进回收站，30 天内可恢复；长期事项连同它的阶段）。撤销 = 从回收站恢复。
    case itemDelete(id: UUID, expectedRevision: String?)
    /// 逆操作：把 itemDelete 删掉的那条从回收站恢复（deletionID 对得上才恢复）。只用于撤销。
    case itemRestore(id: UUID, deletionID: UUID)
    /// W32c：删长期事项里的一个阶段（检查点，进回收站）。expectedRevision = 所属事项的版本。撤销 = 恢复。
    case checkpointDelete(itemId: UUID, checkpointId: UUID, expectedRevision: String?)
    case checkpointRestore(itemId: UUID, checkpointId: UUID, deletionID: UUID)
    /// W34：给长期事项加一个阶段（checkpointId 由提案 id 推出；position = 插在第几个之前，nil = 末尾）。
    /// 普通审批（只新增、不改你写的字）；但加在你的事项里 → 预授权规则 / 低风险自动通过都不放行（一律先问）。撤销 = 这个阶段移入回收站。
    case checkpointCreate(itemId: UUID, checkpointId: UUID, title: String, estimatedMinutes: Int?, position: Int?, expectedRevision: String?)
    /// W32b：在某天的日记末尾加一段智能体写的文字（没有那天的日记就新建；newEntryID 由提案 id 推出）。
    /// 智能体的文字用固定字体显示（JournalAuthorship 标记）。expectedRevision = 提案时那天日记的版本（nil = 当时还没有）。
    case journalAppend(day: Date, text: String, newEntryID: UUID, expectedRevision: String?)
    /// W32b：改你写的日记里的一段原文（find 必须恰好出现一次）→ replace（智能体写的，固定字体）。越级。
    case journalEdit(entryID: UUID, find: String, replace: String, expectedRevision: String?)
    /// 逆操作：把那篇日记的正文原样改回（body = nil：撤销新建 = 这篇移入回收站）。只用于撤销。
    case journalRestore(entryID: UUID, body: String?, expectedRevision: String?)
    /// 0.78（Jason 10-26）：补记一段已经做过的事（蓝色「做成了」，含实际用时）。blockId = 挂到那块计划上（同一个章，绿色让位）；
    /// nil = 计划外的事（章 = recordId，由提案 id 推出）。只记过去（结束不晚于此刻、最多往前 3 天）。撤销 = actualRemove。
    case actualRecord(recordId: UUID, blockId: UUID?, title: String, start: Date, end: Date)
    /// 逆操作：撤下补记的那条实际（id = 它的章）。只用于撤销。
    case actualRemove(id: UUID, start: Date)

    var kindLabel: String {
        switch self {
        case .experimentNoop: "测试改动（不改真实数据）"
        case .itemCreate: "事项：新增待办"
        case .itemEdit: "事项：改标题/备注"
        case let .itemSetDone(_, done, _): done ? "事项：标完成" : "事项：取消完成"
        case .itemDiscard: "事项：移入回收站"
        case let .timer(command, _, _, _, _): "计时：" + command.label
        case .moveBlock: "时间线：挪动计划块"
        case .reminder: "提醒：提醒事项（各台设备都会响）"
        case .alarm: "闹钟：iPhone / iPad 系统闹钟"
        case .reminderCancel: "提醒：取消"
        case .alarmCancel: "闹钟：取消"
        case let .moveBlocks(moves, isUndo): isUndo ? "时间线：整组挪回" : "时间线：一起挪动 \(moves.count) 个计划块"
        case let .blockCreate(day, blocks): "时间线：\(PlanEditRules.dayName(day))加 \(blocks.count) 个计划块"
        case .blockEdit: "时间线：改计划块"
        case .blockDelete: "时间线：删掉计划块（进回收站）"
        case let .planDay(day, steps, isUndo): isUndo ? "时间线：整组撤销" : "时间线：排\(PlanEditRules.dayName(day))（\(steps.count) 步）"
        case .yourEventEdit: "你的日程：改"
        case .yourEventDelete: "你的日程：删除"
        case .yourEventRecreate: "你的日程：按原样重建"
        case .yourReminderEdit: "你的提醒：改"
        case .yourReminderDelete: "你的提醒：删除"
        case .yourReminderRecreate: "你的提醒：按原样重建"
        case .checkpointCreate: "长期事项：加阶段"
        case .itemDelete: "事项：删除（进回收站）"
        case .itemRestore: "事项：从回收站恢复"
        case .checkpointDelete: "长期事项：删阶段（进回收站）"
        case .checkpointRestore: "长期事项：恢复阶段"
        case let .journalAppend(day, _, _, _): "日记：在\(PlanEditRules.dayName(Calendar.current.startOfDay(for: day)))的日记里加一段"
        case .journalEdit: "日记：改你写的原文"
        case .journalRestore: "日记：改回原样"
        case .actualRecord: "做成了：补记一段（实际用时）"
        case .actualRemove: "做成了：撤下补记"
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
        case .yourEventEdit: "yourEventEdit"
        case .yourEventDelete: "yourEventDelete"
        case .yourEventRecreate: "yourEventRecreate"
        case .yourReminderEdit: "yourReminderEdit"
        case .yourReminderDelete: "yourReminderDelete"
        case .yourReminderRecreate: "yourReminderRecreate"
        case .checkpointCreate: "checkpointCreate"
        case .itemDelete: "itemDelete"
        case .itemRestore: "itemRestore"
        case .checkpointDelete: "checkpointDelete"
        case .checkpointRestore: "checkpointRestore"
        case .journalAppend: "journalAppend"
        case .journalEdit: "journalEdit"
        case .journalRestore: "journalRestore"
        case .actualRecord: "actualRecord"
        case .actualRemove: "actualRemove"
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

    /// 这项改动动的是谁的东西（原则 8「谁的东西谁做主」）。`.yours` = 你的东西：提案必须带越级理由（执行器拒收没写的），
    /// 预授权规则永远不能自动放行（PreauthPolicy）。W32：你的日程 / 提醒、删你的待办与长期事项（Jason 2026-10-20：
    /// 你亲手建的事项算你的；智能体提、你批准建的也算——批准过就是你的决定，同 W1「批准的挪动等同亲手拖动」）、改你写的日记。
    /// 日记「加一段」只新增智能体自己的文字（固定字体标出，不碰你的字）→ 仍算 BetterCalendar 的。
    var ownership: ProposalOwnership {
        switch self {
        case .yourEventEdit, .yourEventDelete, .yourEventRecreate, .yourReminderEdit, .yourReminderDelete, .yourReminderRecreate,
             .itemDelete, .itemRestore, .checkpointDelete, .checkpointRestore, .journalEdit, .journalRestore: .yours
        default: .betterCalendar
        }
    }

    /// W34：加进你的东西里（不改你的字、不算越级），但预授权规则与低风险自动通过一律不放行（Jason 2026-10-21：先都问）。
    var alwaysAsks: Bool { if case .checkpointCreate = self { true } else { false } }

    /// 只作撤销用的逆操作（智能体不能提；prepare 拒收）。
    var isUndoOnly: Bool {
        switch self {
        case .itemDiscard, .reminderCancel, .alarmCancel, .yourEventRecreate, .yourReminderRecreate, .itemRestore, .checkpointRestore, .journalRestore,
             .actualRemove: true
        case .moveBlocks(_, true), .planDay(_, _, true): true
        default: false
        }
    }

    /// 0.77：删的是 BetterCalendar 自家的计划块（不是你的日历 / 提醒 / 事项）。
    var isBlockDelete: Bool { if case .blockDelete = self { return true } else { return false } }

    /// 删除类（移入回收站 / 取消提醒 / 取消闹钟 / W18 删计划块、含删除步骤的排一天 / W32 删你的日程、事项、阶段）：
    /// 预授权规则不能自动放行（0.77 起删自家计划块例外，见 PreauthPolicy.lowRiskReason）。
    var isDestructive: Bool {
        switch self {
        case .itemDiscard, .reminderCancel, .alarmCancel, .blockDelete, .yourEventDelete, .yourReminderDelete, .itemDelete, .checkpointDelete: true
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
    // —— W20（Optional：旧记录照常解码；只存在 JSON 载荷里，不改 CloudKit schema）——
    /// 发起者是智能体时，是哪种实现提的（AgentKind.rawValue：claudeCode / builtin）；nil = 旧记录或非智能体（按 Claude Code 理解）。
    /// 只用于追溯（留底、面板「发起」行）；Jason 2026-10-19：各实现是同一个 BetterCalendar 智能体，预授权规则不按实现分。
    var agentKey: String? = nil
    // —— W32d（Optional：旧记录照常解码；只在 JSON 载荷里）——
    /// 智能体标了「拿不准，先给他看一眼」：低风险自动通过不放行（一律先问你）。
    var askFirst: Bool? = nil
    /// 准备时 App 依据真实数据查到的「不能自动通过」原因（如动的是图钉）；nil = 没查到障碍。
    var autoPassBlocker: String? = nil
    // —— W34（Optional：旧记录照常解码；只在 JSON 载荷里，不改 CloudKit schema）——
    /// App 依据真实数据写的一句「做什么」（如「删除长期事项「C」（连同 1 个阶段）」）；nil = 用发起者写的 title。
    var headline: String? = nil

    /// 卡片 / 压缩条上的那一句：有备选方案时说不清是哪个 → 用发起者的 title。
    var cardHeadline: String { hasAlternatives ? title : (headline ?? title) }

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
        case .yourEventEdit?: "撤销 = 把你的日程按改之前的样子原样改回（你之后在日历里又改过就不撤）"
        case let .yourEventRecreate(s)?:
            s.recurrence != nil ? "撤销 = 按原来的重复规则重建剩下的系列" : s.facts.isRecurring ? "撤销 = 重建成一条独立日程（不会回到重复系列里）" : "撤销 = 按删之前的样子原样重建这条日程"
        case .yourReminderRecreate?: "撤销 = 按删之前的样子重建这条提醒（新的一条；子任务、标签、旗标、附件不会恢复）"
        case .checkpointDelete?: "撤销 = 把这个阶段移入回收站（30 天内可恢复）"
        case .yourReminderEdit?: "撤销 = 把你的提醒原样改回（你之后又改过就不撤）"
        case .itemRestore?: "撤销 = 从回收站恢复（长期事项连同它的阶段）"
        case .checkpointRestore?: "撤销 = 从回收站恢复这个阶段"
        case let .journalRestore(_, body, _)?: body == nil ? "撤销 = 这篇新建的日记移入回收站（你之后又写过就不撤）" : "撤销 = 日记正文改回原样（你之后又写过就不撤）"
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
        if let headline, !hasAlternatives, headline != title { lines.append(headline) }
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
    /// W20：智能体的哪种实现提的（见 Proposal.agentKey）；nil = 不是智能体 / 经桥接的 Claude Code。
    var agentKey: String? = nil
    /// W32d：见 Proposal.askFirst / autoPassBlocker（后者由 ProposalCenter.prepare 填）。
    var askFirst = false
    var autoPassBlocker: String? = nil
    /// W34：见 Proposal.headline（由 ProposalCenter.prepare 依据主方案填）。
    var headline: String? = nil
    /// W41：智能体说「连带的交给 App 算」（只在提交时用，不存）：prepare 前把 App 算好的连带顺延并进主方案。
    var cascade = false

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

extension ProposalAction {
    /// W42：这份改动会动到哪些计划块（哨兵源头去误报：有待批提案在动的块，「开始时间已过」不算它）。
    var touchedBlockIDs: [UUID] {
        switch self {
        case let .moveBlock(id, _, _, _), let .blockDelete(id, _): [id]
        case let .moveBlocks(moves, _): moves.map(\.id)
        case let .blockEdit(e): [e.id]
        case let .planDay(_, steps, _): steps.map(\.blockID)
        default: []
        }
    }
}
