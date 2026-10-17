//
//  ConflictCheckedProposalTransport.swift
//  BetterCalendar
//
//  「首个有效决定生效」的实现：读最新版本 → 本地检查 → 以「服务器版本未变」为条件保存；
//  冲突时拿服务器上的最新版本重新判断（乐观并发）。底层存储可替换：CloudKit（生产）/ 内存（测试）。
//

import Foundation

nonisolated enum ProposalUpdateResult: Sendable {
    case saved(Proposal)
    /// 自上次读取后服务器版本已变；附服务器上的最新版本。
    case conflict(Proposal)
}

/// 提案的版本化存储：update 只在服务器版本与最近一次读取一致时成功。
nonisolated protocol ProposalRecordStore: Sendable {
    func create(_ proposal: Proposal) async throws
    /// 全部提案（并刷新本地已知版本）。
    func all() async throws -> [Proposal]
    /// 从服务器读这一份的最新版本（并记住它的版本，供下一次 update 做条件保存）。
    func latest(_ id: UUID) async throws -> Proposal?
    func update(_ proposal: Proposal) async throws -> ProposalUpdateResult
}

nonisolated struct ConflictCheckedProposalTransport: ProposalTransport {
    let store: any ProposalRecordStore
    /// 冲突后最多重读几次（冲突来自非决定类写入时才需要重试；正常两三次足够）。
    var maxAttempts = 4

    func submit(_ proposal: Proposal) async throws { try await store.create(proposal) }

    func fetchRecent() async throws -> [Proposal] {
        try await store.all().sorted { $0.createdAt > $1.createdAt }
    }

    func decide(id: UUID, decision: ProposalDecision, deviceId: String, at: Date) async throws -> ProposalDecisionOutcome {
        for _ in 0..<maxAttempts {
            guard var p = try await store.latest(id) else { throw ProposalTransportError.notFound(id) }
            guard p.effectiveState(at: at) == .pending else { return .alreadyClosed(p) }
            p.state = decision.resultingState; p.decidedAt = at; p.decidedByDeviceId = deviceId
            switch try await store.update(p) {
            case let .saved(saved): return .won(saved)
            case let .conflict(server):
                if server.effectiveState(at: at) != .pending { return .alreadyClosed(server) }
                // 服务器版本变了但仍待决定（例如另一端只改了通知相关字段）：重读再试。
            }
        }
        throw ProposalTransportError.invalidTransition("连续冲突，决定未提交；请稍后重试")
    }

    func report(id: UUID, state: ProposalState, note: String, at: Date) async throws -> Proposal {
        guard [.applied, .failed].contains(state) else {
            throw ProposalTransportError.invalidTransition("只能回报 applied / failed")
        }
        for _ in 0..<maxAttempts {
            guard var p = try await store.latest(id) else { throw ProposalTransportError.notFound(id) }
            guard p.state == .approved else {
                throw ProposalTransportError.invalidTransition("\(p.state.rawValue) → \(state.rawValue)")
            }
            p.state = state; p.appliedAt = at; p.resultNote = note
            switch try await store.update(p) {
            case let .saved(saved): return saved
            case .conflict: continue
            }
        }
        throw ProposalTransportError.invalidTransition("连续冲突，执行结果未回报")
    }
}

/// 内存版版本化存储（测试用）：可注入「读和写之间另一端抢先写入」来验证冲突路径。
actor MemoryProposalRecordStore: ProposalRecordStore {
    private var rows: [UUID: (proposal: Proposal, version: Int)] = [:]
    private var lastSeen: [UUID: Int] = [:]
    /// 每次 update 前触发一次：模拟另一台设备在此刻写入。
    private var beforeUpdate: (@Sendable (UUID) async -> Void)?

    func setBeforeUpdate(_ hook: (@Sendable (UUID) async -> Void)?) { beforeUpdate = hook }

    func create(_ proposal: Proposal) async throws { rows[proposal.id] = (proposal, 1) }

    func all() async throws -> [Proposal] {
        for (id, row) in rows { lastSeen[id] = row.version }
        return rows.values.map(\.proposal)
    }

    func latest(_ id: UUID) async throws -> Proposal? {
        guard let row = rows[id] else { return nil }
        lastSeen[id] = row.version
        return row.proposal
    }

    func update(_ proposal: Proposal) async throws -> ProposalUpdateResult {
        if let hook = beforeUpdate { beforeUpdate = nil; await hook(proposal.id) }
        guard let row = rows[proposal.id] else { throw ProposalTransportError.notFound(proposal.id) }
        guard lastSeen[proposal.id] == row.version else { return .conflict(row.proposal) }
        rows[proposal.id] = (proposal, row.version + 1)
        lastSeen[proposal.id] = row.version + 1
        return .saved(proposal)
    }

    /// 模拟另一端直接写入（绕过本端的已知版本）。
    func forceWrite(_ proposal: Proposal) {
        let version = (rows[proposal.id]?.version ?? 0) + 1
        rows[proposal.id] = (proposal, version)
    }
}
