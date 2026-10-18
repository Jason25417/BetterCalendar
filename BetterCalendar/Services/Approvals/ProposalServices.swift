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
    func decide(id: UUID, decision: ProposalDecision, deviceId: String, at: Date) async throws -> ProposalDecisionOutcome
    /// 执行设备回报结果（applied / failed）。只允许从 approved 转出；applied 时一并存下撤销信息。
    func report(id: UUID, state: ProposalState, note: String, undo: ProposalUndoInfo?, at: Date) async throws -> Proposal
    /// 记下「已撤销」（SPEC §19 A3 后半）。只允许 applied 且尚未撤销；首个撤销生效，迟到的抛错。
    func markUndone(id: UUID, deviceId: String, note: String, at: Date) async throws -> Proposal
}

extension ProposalTransport {
    func report(id: UUID, state: ProposalState, note: String, at: Date) async throws -> Proposal {
        try await report(id: id, state: state, note: note, undo: nil, at: at)
    }
}

/// 执行真改动后保存的撤销信息（随提案存进 iCloud，各端都能看到「能不能撤销」）。
nonisolated struct ProposalUndoInfo: Equatable, Sendable {
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
}

nonisolated protocol ProposalGate: Sendable {
    func route(_ proposal: Proposal) -> ProposalRoute
}

/// 首版空实现：一律先问你（方便测试；与「无感」的冲突已登记在 SPEC §19.9 欠账②）。
nonisolated struct AskAlwaysGate: ProposalGate {
    func route(_ proposal: Proposal) -> ProposalRoute { .ask }
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
    /// 执行动作（已同意的提案，或撤销用的逆操作）；抛错 = 执行失败（不自动重试）。
    func perform(_ action: ProposalAction) async throws -> ProposalExecutionOutcome
}

extension ProposalExecuting {
    func execute(_ proposal: Proposal) async throws -> ProposalExecutionOutcome { try await perform(proposal.action) }
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
    /// 系统通知是否允许（nil = 尚未询问）。
    func permission() async -> Bool?
    /// 只由用户点击按钮触发。
    func requestPermission() async -> Bool
}

extension ProposalNotifying {
    func permission() async -> Bool? { true }
    func requestPermission() async -> Bool { true }
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

    func decide(id: UUID, decision: ProposalDecision, deviceId: String, at: Date) async throws -> ProposalDecisionOutcome {
        guard var p = store[id] else { throw ProposalTransportError.notFound(id) }
        guard p.effectiveState(at: at) == .pending else { return .alreadyClosed(p) }
        p.state = decision.resultingState; p.decidedAt = at; p.decidedByDeviceId = deviceId
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
    func show(_ proposal: Proposal) async { shown.insert(proposal.id) }
    func withdraw(_ id: UUID) async { shown.remove(id) }
    func shownIds() async -> Set<UUID> { shown }
}
