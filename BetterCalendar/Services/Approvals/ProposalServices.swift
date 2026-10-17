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
    /// 执行设备回报结果（applied / failed）。只允许从 approved 转出。
    func report(id: UUID, state: ProposalState, note: String, at: Date) async throws -> Proposal
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

@MainActor protocol ProposalExecuting {
    /// 执行已同意的提案，返回给人看的结果说明；抛错 = 执行失败（不自动重试）。
    func execute(_ proposal: Proposal) async throws -> String
}

/// P1 只支持联调用的空改动：不碰任何真实数据。
@MainActor struct ExperimentOnlyExecutor: ProposalExecuting {
    func execute(_ proposal: Proposal) async throws -> String {
        switch proposal.action {
        case let .experimentNoop(note): "测试改动已应用：未修改任何真实数据（\(note)）"
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
    /// 发生了什么：submitted / decided / lost / applied / failed / notified / withdrawn / error
    var event: String
    var proposalId: UUID?
    /// 上下级：这一步由哪个提案/操作引出
    var parentId: UUID?
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

    func report(id: UUID, state: ProposalState, note: String, at: Date) async throws -> Proposal {
        guard var p = store[id] else { throw ProposalTransportError.notFound(id) }
        guard p.state == .approved, [.applied, .failed].contains(state) else {
            throw ProposalTransportError.invalidTransition("\(p.state.rawValue) → \(state.rawValue)")
        }
        p.state = state; p.appliedAt = at; p.resultNote = note
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
