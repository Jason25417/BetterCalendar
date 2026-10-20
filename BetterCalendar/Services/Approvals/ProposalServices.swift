//
//  ProposalServices.swift
//  BetterCalendar
//
//  SPEC §19 的可替换缝：审批中转（CloudKit / 内存）、预授权闸门（A3a）、执行器、通知、操作留底（A5）。
//  上层（ProposalCenter）只依赖这些协议，具体实现在组装点注入。
//

import Foundation

nonisolated enum ProposalDecisionOutcome: Sendable, Equatable {
    /// 本端的决定是首个有效决定，已生效。
    case won(Proposal)
    /// 别的端已先决定 / 已过期 / 已撤回：本端只拿到最新结果，不重复执行。
    case alreadyClosed(Proposal)
}

nonisolated enum ProposalTransportError: Error, LocalizedError {
    case notFound(UUID)
    case invalidTransition(String)
    var errorDescription: String? {
        switch self {
        case let .notFound(id): "找不到这份提案（\(id.uuidString.prefix(8))）"
        case let .invalidTransition(s): "提案状态不允许这样改：\(s)"
        }
    }
}

/// 审批中转：各端看到同一份提案；decide 必须保证「首个有效决定生效」。
nonisolated protocol ProposalTransport: Sendable {
    func submit(_ proposal: Proposal) async throws
    func fetchRecent() async throws -> [Proposal]
    /// choice = 选了第几个方案（0 = 主方案；nil = 没有备选方案时等同 0）。超出范围抛错。
    /// tuning（W11）= 你在卡片上调好的参数值 + 重新校验过的动作；nil = 按默认（通知上的「按默认批准」、没有参数）。
    func decide(id: UUID, decision: ProposalDecision, choice: Int?, tuning: ProposalTuning?, deviceId: String, at: Date) async throws -> ProposalDecisionOutcome
    /// W10 第三种回应：你回了一句话。与 decide 同样「首个有效回应生效」（pending → replied）；已被别的端处理 → alreadyClosed。
    func respond(id: UUID, reply: ProposalUserReply, at: Date) async throws -> ProposalDecisionOutcome
    /// 执行设备回报结果（applied / failed）。只允许从 approved 转出；applied 时一并存下撤销信息。
    func report(id: UUID, state: ProposalState, note: String, undo: ProposalUndoInfo?, at: Date) async throws -> Proposal
    /// 记下「已撤销」（SPEC §19 A3 后半）。只允许 applied 且尚未撤销；首个撤销生效，迟到的抛错。
    func markUndone(id: UUID, deviceId: String, note: String, at: Date) async throws -> Proposal
}

extension ProposalTransport {
    func report(id: UUID, state: ProposalState, note: String, at: Date) async throws -> Proposal {
        try await report(id: id, state: state, note: note, undo: nil, at: at)
    }
    func decide(id: UUID, decision: ProposalDecision, deviceId: String, at: Date) async throws -> ProposalDecisionOutcome {
        try await decide(id: id, decision: decision, choice: nil, tuning: nil, deviceId: deviceId, at: at)
    }
    func decide(id: UUID, decision: ProposalDecision, choice: Int?, deviceId: String, at: Date) async throws -> ProposalDecisionOutcome {
        try await decide(id: id, decision: decision, choice: choice, tuning: nil, deviceId: deviceId, at: at)
    }
}

extension Proposal {
    /// 首个有效决定：写入状态与所选方案（各中转实现共用，语义一致）。
    /// W11：批准一个带参数的方案时记下每个参数的最终值（没调 = 默认值）；调过的（与默认不同）连同重新校验过的动作一起存下。
    nonisolated mutating func applyDecision(_ decision: ProposalDecision, choice: Int?, tuning: ProposalTuning? = nil,
                                            deviceId: String, at: Date) throws {
        if let choice {
            guard options.indices.contains(choice) else {
                throw ProposalTransportError.invalidTransition("没有第 \(choice + 1) 个方案（共 \(options.count) 个）")
            }
            if decision == .approve, hasAlternatives { chosenOption = choice }
        } else if decision == .approve, hasAlternatives {
            chosenOption = 0
        }
        if decision == .approve {
            let params = options[chosenOption ?? 0].parameters
            if let tuning {
                guard !params.isEmpty else { throw ProposalTransportError.invalidTransition("选中的方案没有可调参数") }
                let known = Set(params.map(\.id))
                guard tuning.values.keys.allSatisfy(known.contains) else { throw ProposalTransportError.invalidTransition("调的参数不属于选中的方案") }
            }
            if !params.isEmpty {
                var values: [String: ProposalParameterValue] = [:]
                for p in params { values[p.id] = tuning?.values[p.id] ?? p.defaultValue }
                chosenValues = values
                if let tuning, params.contains(where: { ProposalParameterRules.isChanged($0, values[$0.id]) }) {
                    tunedAction = tuning.action; tunedChanges = tuning.changes
                }
            }
        }
        state = decision.resultingState; decidedAt = at; decidedByDeviceId = deviceId
    }

    /// 你回了一句：停止等待（不执行、不算拒绝）。
    nonisolated mutating func applyReply(_ reply: ProposalUserReply) {
        state = .replied; decidedAt = reply.at; decidedByDeviceId = reply.deviceId; userReply = reply
    }
}

/// 执行真改动后保存的撤销信息（随提案存进 iCloud，各端都能看到「能不能撤销」）。
nonisolated struct ProposalUndoInfo: Codable, Equatable, Sendable {
    var action: ProposalAction?
    var deviceId: String?
    var unavailableReason: String?

    func apply(to p: inout Proposal) {
        p.undoAction = action; p.undoDeviceId = deviceId; p.undoUnavailableReason = unavailableReason
    }
}

extension Proposal {
    /// 已撤销后不再有撤销入口；记下撤销结果。
    nonisolated mutating func applyUndone(deviceId: String, note: String, at: Date) throws {
        guard state == .applied else { throw ProposalTransportError.invalidTransition("只有已完成的改动才能撤销（当前：\(state.label)）") }
        guard undoneAt == nil else { throw ProposalTransportError.invalidTransition("这项改动已经撤销过了") }
        undoneAt = at; undoneByDeviceId = deviceId; undoNote = note
    }
}

// MARK: - 预授权闸门（SPEC §19 A3a）

nonisolated enum ProposalRoute: String, Sendable {
    /// 先问你
    case ask
    /// 直接做，做完告诉你
    case applyThenInform
    /// 直接做
    case apply
    /// 按规则自动拒绝（deny 规则）
    case decline
}

/// 预授权闸门（W10 起有真实现 PreauthRuleGate，见 PreauthRules.swift）。
@MainActor protocol ProposalGate {
    func verdict(for proposal: Proposal) -> ProposalGateVerdict
}

/// 一律先问你（测试与没有规则存储的环境用；默认行为与 W10 之前完全一致）。
nonisolated struct AskAlwaysGate: ProposalGate {
    func verdict(for proposal: Proposal) -> ProposalGateVerdict { .ask("一律先问你") }
}

// MARK: - 执行器

/// 提交前的准备结果：补全基线版本后的动作 + 由 App 依据真实数据算出的「改动前 → 改动后」。
nonisolated struct PreparedProposalAction: Equatable, Sendable {
    var action: ProposalAction
    /// nil = 沿用发起者写的 changes（只有测试改动如此）；真改动一律由 App 计算，不信任发起者的描述。
    var changes: [ProposalChange]?
    /// 必须在哪台设备执行（计时 = 准备时读状态的那台）；nil = 不限。
    var requiredDeviceId: String? = nil
}

/// 一次执行（或撤销）的结果。
nonisolated struct ProposalExecutionOutcome: Equatable, Sendable {
    /// W32e：结果里「和你批准的不完全一样」（替身 / 降级 / 画面稍后同步）的那一句以它开头——审批卡把含它的结果说明
    /// 直接显示出来（P4 不暗减）；其余结果说明只是复述改动，收进「详情」。
    static let deviationMarker = "注意："
    /// 给人看的结果说明。
    var note: String
    var undo: ProposalUndoInfo? = nil
}

nonisolated enum ProposalExecutionError: Error, LocalizedError, Equatable {
    /// 目标已被改过：不覆盖用户事实。
    case conflict(String)
    /// 校验不通过（规则不允许 / 放不下 / 目标不存在等），附明确原因。
    case invalid(String)
    /// 本设备没有接入这种能力（例如测试环境没有计时）。
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case let .conflict(s): "目标已被改过，未执行：\(s)"
        case let .invalid(s): s
        case let .unavailable(s): s
        }
    }
}

@MainActor protocol ProposalExecuting {
    /// 提交前：严格校验 + 补全基线版本 + 计算改动前后；抛错 = 这份提案不能提交（附原因）。
    func prepare(_ action: ProposalAction) async throws -> PreparedProposalAction
    /// W10 合并缝：带上提案的越级理由再校验（如 W9：动图钉的挪块必须带越级理由）。默认忽略越级、等同 prepare(_:)。
    func prepare(_ action: ProposalAction, escalation: String?) async throws -> PreparedProposalAction
    /// W11：你在审批卡上调了数值后，对套回新值的动作重新校验（卡片实时预览 + 批准前再查一次）。
    /// executingDeviceId = 提案指定的执行设备：设备本地状态（计时）只有那台能完整核对，其他设备做能做的检查并写明。
    /// 默认等同 prepare(_:escalation:)。
    func recheck(_ action: ProposalAction, escalation: String?, executingDeviceId: String?) async throws -> PreparedProposalAction
    /// 执行动作（已同意的提案，或撤销用的逆操作）；抛错 = 执行失败（不自动重试）。
    func perform(_ action: ProposalAction) async throws -> ProposalExecutionOutcome
    /// W32d：依据真实数据，这份（已准备好的）动作有没有「不能低风险自动通过」的障碍（如动的是图钉）。默认 nil。
    func autoPassBlocker(_ action: ProposalAction) async -> String?
}

extension ProposalExecuting {
    func autoPassBlocker(_ action: ProposalAction) async -> String? { nil }
    func prepare(_ action: ProposalAction, escalation: String?) async throws -> PreparedProposalAction { try await prepare(action) }
    func recheck(_ action: ProposalAction, escalation: String?, executingDeviceId: String?) async throws -> PreparedProposalAction {
        try await prepare(action, escalation: escalation)
    }
    /// 执行你选中的方案（没有备选 = 主方案）。
    func execute(_ proposal: Proposal) async throws -> ProposalExecutionOutcome { try await perform(proposal.executedAction) }
}

/// 联调用的空改动执行器：不碰任何真实数据（测试环境 / 未接入真实能力时）。真改动一律拒绝。
@MainActor struct ExperimentOnlyExecutor: ProposalExecuting {
    func prepare(_ action: ProposalAction) async throws -> PreparedProposalAction {
        guard case .experimentNoop = action else {
            throw ProposalExecutionError.unavailable("本设备只接受测试改动（\(action.kindLabel) 未接入）")
        }
        return PreparedProposalAction(action: action, changes: nil)
    }
    func perform(_ action: ProposalAction) async throws -> ProposalExecutionOutcome {
        switch action {
        case let .experimentNoop(note):
            return ProposalExecutionOutcome(note: "测试改动已应用：未修改任何真实数据（\(note)）")
        default:
            throw ProposalExecutionError.unavailable("本设备只接受测试改动（\(action.kindLabel) 未接入）")
        }
    }
}

// MARK: - 通知

@MainActor protocol ProposalNotifying {
    /// 显示一条带「批准 / 拒绝」的通知；同一提案重复调用不重复弹。
    func show(_ proposal: Proposal) async
    /// 收起这份提案在本机的通知（已决定 / 过期 / 撤回后）。
    func withdraw(_ id: UUID) async
    /// 本机当前还挂着通知的提案。
    func shownIds() async -> Set<UUID>
    /// W10「做完告诉你」：预授权规则自动执行后的结果通知（可撤销）；自动执行失败也用它说明（失败必须可见）。
    func showResult(_ proposal: Proposal) async
    func withdrawResult(_ id: UUID) async
    func shownResultIds() async -> Set<UUID>
    /// 系统通知是否允许（nil = 尚未询问）。
    func permission() async -> Bool?
    /// 只由用户点击按钮触发。
    func requestPermission() async -> Bool
}

extension ProposalNotifying {
    func permission() async -> Bool? { true }
    func requestPermission() async -> Bool { true }
    func showResult(_ proposal: Proposal) async {}
    func withdrawResult(_ id: UUID) async {}
    func shownResultIds() async -> Set<UUID> { [] }
}

// MARK: - 操作留底（SPEC §19 A5）

nonisolated struct OperationRecord: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var at: Date
    /// 谁做的这一步
    var actor: ProposalOrigin
    var actorLabel: String
    var deviceId: String
    /// 发生了什么：submitted / rejected / decided / lost / applied / failed / notified / withdrawn / undone / undo.failed / error
    var event: String
    var proposalId: UUID?
    /// 上下级：这一步由哪个提案/操作引出
    var parentId: UUID?
    var parentRef: String? = nil
    var detail: String
    /// W10：由哪条预授权规则代你决定（「来源 = 规则 id」）；nil = 不是规则做的。
    var ruleId: UUID? = nil
}

@MainActor protocol OperationLedger {
    func append(_ record: OperationRecord)
    func records() -> [OperationRecord]
}

@MainActor final class MemoryOperationLedger: OperationLedger {
    private(set) var values: [OperationRecord] = []
    func append(_ record: OperationRecord) { values.append(record) }
    func records() -> [OperationRecord] { values }
}

/// 本机 JSONL 追加写（只增不改，便于事后回看与审计）。
@MainActor final class FileOperationLedger: OperationLedger {
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterCalendarApprovals/operations-v1.jsonl")
    }
    func append(_ record: OperationRecord) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var line = try encoder.encode(record); line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            DevLog.shared.error("审批留底", "操作记录写入失败：\(error.localizedDescription)")
        }
    }
    func records() -> [OperationRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(OperationRecord.self, from: Data($0)) }
    }
}

// MARK: - 内存中转（测试与本机演示用；语义与 CloudKit 实现对齐）

actor InMemoryProposalTransport: ProposalTransport {
    private var store: [UUID: Proposal] = [:]

    func submit(_ proposal: Proposal) async throws { store[proposal.id] = proposal }

    func fetchRecent() async throws -> [Proposal] {
        store.values.sorted { $0.createdAt > $1.createdAt }
    }

    func decide(id: UUID, decision: ProposalDecision, choice: Int?, tuning: ProposalTuning?, deviceId: String, at: Date) async throws -> ProposalDecisionOutcome {
        guard var p = store[id] else { throw ProposalTransportError.notFound(id) }
        guard p.effectiveState(at: at) == .pending else { return .alreadyClosed(p) }
        try p.applyDecision(decision, choice: choice, tuning: tuning, deviceId: deviceId, at: at)
        store[id] = p
        return .won(p)
    }

    func respond(id: UUID, reply: ProposalUserReply, at: Date) async throws -> ProposalDecisionOutcome {
        guard var p = store[id] else { throw ProposalTransportError.notFound(id) }
        guard p.effectiveState(at: at) == .pending else { return .alreadyClosed(p) }
        p.applyReply(reply)
        store[id] = p
        return .won(p)
    }

    func report(id: UUID, state: ProposalState, note: String, undo: ProposalUndoInfo?, at: Date) async throws -> Proposal {
        guard var p = store[id] else { throw ProposalTransportError.notFound(id) }
        guard p.state == .approved, [.applied, .failed].contains(state) else {
            throw ProposalTransportError.invalidTransition("\(p.state.rawValue) → \(state.rawValue)")
        }
        p.state = state; p.appliedAt = at; p.resultNote = note
        if state == .applied { undo?.apply(to: &p) }
        store[id] = p
        return p
    }

    func markUndone(id: UUID, deviceId: String, note: String, at: Date) async throws -> Proposal {
        guard var p = store[id] else { throw ProposalTransportError.notFound(id) }
        try p.applyUndone(deviceId: deviceId, note: note, at: at)
        store[id] = p
        return p
    }
}

/// 测试 host 用：不碰系统通知中心。
@MainActor final class SilentProposalNotifier: ProposalNotifying {
    private var shown: Set<UUID> = []
    private(set) var results: Set<UUID> = []
    func show(_ proposal: Proposal) async { shown.insert(proposal.id) }
    func withdraw(_ id: UUID) async { shown.remove(id) }
    func shownIds() async -> Set<UUID> { shown }
    func showResult(_ proposal: Proposal) async { results.insert(proposal.id) }
    func withdrawResult(_ id: UUID) async { results.remove(id) }
    func shownResultIds() async -> Set<UUID> { results }
}
