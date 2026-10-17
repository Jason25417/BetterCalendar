//
//  ProposalCenter.swift
//  BetterCalendar
//
//  SPEC §19 B 组的协调者：发起 → 闸门 → 各端通知 → 首个决定生效 → 指定设备执行 → 各端收起通知。
//  通知、App 内列表、（将来）对话卡片都指向这里的同一份提案状态（B3）。
//  只依赖协议；CloudKit / 内存中转、真实 / 假通知在组装点注入。
//

import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// 本机在多端审批里的身份（复用多端跟随的安装级 ID）。
@MainActor enum ProposalDevice {
    static var id: String { FocusFollow.deviceID }
    static var label: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}

@MainActor @Observable final class ProposalCenter {
    private(set) var proposals: [Proposal] = []
    private(set) var lastError: String?

    let deviceId: String
    let deviceLabel: String
    private let transport: any ProposalTransport
    private let gate: any ProposalGate
    private let executor: any ProposalExecuting
    private let notifier: any ProposalNotifying
    let ledger: any OperationLedger
    private let now: () -> Date
    /// 正在执行的提案，防止同一台设备并发重复执行。
    private var executing: Set<UUID> = []

    init(transport: any ProposalTransport, gate: any ProposalGate = AskAlwaysGate(),
         executor: any ProposalExecuting, notifier: any ProposalNotifying, ledger: any OperationLedger,
         deviceId: String, deviceLabel: String, now: @escaping () -> Date = Date.init) {
        self.transport = transport; self.gate = gate; self.executor = executor
        self.notifier = notifier; self.ledger = ledger
        self.deviceId = deviceId; self.deviceLabel = deviceLabel; self.now = now
    }

    /// App 在前台时为 true：前台每 20 秒兜底刷新一次（推送丢失也能收敛）。
    var isForeground = false
    private var pollTask: Task<Void, Never>?

    /// 前台兜底轮询（测试环境不要启动：游离任务会拖垮 test host）。
    func startPolling(every seconds: Double = 20) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                if self.isForeground { await self.refresh() }
            }
        }
    }

    /// 报错一直显示到用户主动关掉（失败必须可见，不因下一次成功刷新而静默消失）。
    func clearError() { lastError = nil }

    /// SPEC §19 B2 延迟埋点（本机视角）：提交 → 本机弹通知、决定 → 本机收起。
    /// 跨设备时含两台设备的时钟差，只作观察值，不是保证值。
    func latency(for id: UUID) -> (notify: TimeInterval?, withdraw: TimeInterval?) {
        guard let p = proposals.first(where: { $0.id == id }) else { return (nil, nil) }
        let mine = ledger.records().filter { $0.proposalId == id && $0.deviceId == deviceId }
        let notified = mine.first { $0.event == "notified" }?.at
        let withdrawn = mine.first { $0.event == "withdrawn" }?.at
        return (notified.map { $0.timeIntervalSince(p.createdAt) },
                withdrawn.flatMap { w in p.decidedAt.map { w.timeIntervalSince($0) } })
    }

    func notificationPermission() async -> Bool? { await notifier.permission() }
    func requestNotificationPermission() async -> Bool { await notifier.requestPermission() }

    var pending: [Proposal] { proposals.filter { $0.effectiveState(at: now()) == .pending } }

    // MARK: 发起

    @discardableResult
    func submit(_ draft: ProposalDraft) async -> Proposal? {
        let at = now()
        let proposal = Proposal(id: draft.id ?? UUID(), createdAt: at, expiresAt: at.addingTimeInterval(draft.lifetime),
                                origin: draft.origin, originLabel: draft.originLabel, originDeviceId: deviceId,
                                parentId: draft.parentId, targetDeviceId: draft.targetDeviceId,
                                title: draft.title, changes: draft.changes, reason: draft.reason,
                                action: draft.action, experiment: draft.experiment, state: .pending, parentRef: draft.parentRef)
        do {
            try await transport.submit(proposal)
            record(proposal.origin, proposal.originLabel, "submitted", proposal, "发起：\(proposal.title)")
            let route = gate.route(proposal)
            if route != .ask {
                // 预授权范围内：由系统代为同意（首版闸门恒为 ask，此分支只为接口完整）。
                _ = await decide(proposal.id, .approve, actor: .system, actorLabel: "预授权闸门（\(route.rawValue)）")
            }
            await refresh()
            return proposals.first { $0.id == proposal.id } ?? proposal
        } catch {
            fail("提交提案失败", error, proposal)
            return nil
        }
    }

    // MARK: 同步（推送唤醒 / 回到前台 / 轮询时调用）

    func refresh() async {
        do {
            proposals = try await transport.fetchRecent()
        } catch {
            fail("读取提案失败", error, nil)
            return
        }
        await reconcileNotifications()
        for p in proposals where p.state == .approved && p.isExecutor(deviceId) && !executing.contains(p.id) {
            await execute(p)
        }
    }

    // MARK: 决定（通知按钮 / App 内按钮）

    @discardableResult
    func decide(_ id: UUID, _ decision: ProposalDecision,
                actor: ProposalOrigin = .user, actorLabel: String = "你") async -> ProposalDecisionOutcome? {
        do {
            let outcome = try await transport.decide(id: id, decision: decision, deviceId: deviceId, at: now())
            switch outcome {
            case let .won(p):
                record(actor, actorLabel, "decided", p, "\(decision == .approve ? "同意" : "拒绝")（在 \(deviceLabel)）")
            case let .alreadyClosed(p):
                record(actor, actorLabel, "lost", p, "已被处理：\(p.effectiveState(at: now()).label)；本次点击不重复执行")
            }
            await refresh()
            return outcome
        } catch {
            fail("提交决定失败", error, proposals.first { $0.id == id })
            return nil
        }
    }

    // MARK: 内部

    private func execute(_ p: Proposal) async {
        executing.insert(p.id); defer { executing.remove(p.id) }
        do {
            let note = try await executor.execute(p)
            let done = try await transport.report(id: p.id, state: .applied, note: note, at: now())
            record(.system, "BetterCalendar（\(deviceLabel)）", "applied", done, note)
        } catch {
            let note = "执行失败：\(error.localizedDescription)"
            if let failed = try? await transport.report(id: p.id, state: .failed, note: note, at: now()) {
                record(.system, "BetterCalendar（\(deviceLabel)）", "failed", failed, note)
            }
            fail("执行提案失败", error, p)
        }
        if let latest = try? await transport.fetchRecent() { proposals = latest }
        await reconcileNotifications()
    }

    /// 待决定的都挂一条通知；不再待决定的都收起（B2：一端决定后其他端收起）。
    private func reconcileNotifications() async {
        let shown = await notifier.shownIds()
        let open = Set(pending.map(\.id))
        for p in pending where !shown.contains(p.id) {
            await notifier.show(p)
            record(.system, "BetterCalendar（\(deviceLabel)）", "notified", p, "已在本机显示审批通知")
        }
        for id in shown where !open.contains(id) {
            await notifier.withdraw(id)
            if let p = proposals.first(where: { $0.id == id }) {
                record(.system, "BetterCalendar（\(deviceLabel)）", "withdrawn", p, "已收起：\(p.effectiveState(at: now()).label)")
            }
        }
    }

    private func record(_ actor: ProposalOrigin, _ label: String, _ event: String, _ p: Proposal?, _ detail: String) {
        ledger.append(OperationRecord(at: now(), actor: actor, actorLabel: label, deviceId: deviceId, event: event,
                                      proposalId: p?.id, parentId: p?.parentId, parentRef: p?.parentRef, detail: detail))
    }

    private func fail(_ what: String, _ error: Error, _ p: Proposal?) {
        let message = "\(what)：\(error.localizedDescription)"
        lastError = message
        DevLog.shared.error("多端审批", message)
        record(.system, "BetterCalendar（\(deviceLabel)）", "error", p, message)
    }
}
