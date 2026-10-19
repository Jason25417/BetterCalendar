import Foundation
import Testing
@testable import BetterCalendar

/// SPEC §19 B 组：两台「设备」共用一个内存中转，验证多端审批语义。
@MainActor @Suite struct ProposalCenterTests {
    @MainActor final class FakeNotifier: ProposalNotifying {
        var shown: Set<UUID> = []
        var showCount = 0
        func show(_ proposal: Proposal) async { if shown.insert(proposal.id).inserted { showCount += 1 } }
        func withdraw(_ id: UUID) async { shown.remove(id) }
        func shownIds() async -> Set<UUID> { shown }
    }
    @MainActor struct FailingExecutor: ProposalExecuting {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "模拟网络中断" } }
        func prepare(_ action: ProposalAction) async throws -> PreparedProposalAction { PreparedProposalAction(action: action, changes: nil) }
        func perform(_ action: ProposalAction) async throws -> ProposalExecutionOutcome { throw Boom() }
    }

    /// 冒烟 2026-10-18 bug A：回报（report）网络抖动——先失败 N 次再恢复。
    final class FlakyTransport: ProposalTransport, @unchecked Sendable {
        let inner = InMemoryProposalTransport()
        var failReports = 0
        var reportCalls = 0
        struct Net: Error, LocalizedError { var errorDescription: String? { "模拟 iCloud 不可达" } }
        func submit(_ proposal: Proposal) async throws { try await inner.submit(proposal) }
        func fetchRecent() async throws -> [Proposal] { try await inner.fetchRecent() }
        func decide(id: UUID, decision: ProposalDecision, choice: Int?, tuning: ProposalTuning?, deviceId: String, at: Date) async throws -> ProposalDecisionOutcome {
            try await inner.decide(id: id, decision: decision, choice: choice, tuning: tuning, deviceId: deviceId, at: at)
        }
        func respond(id: UUID, reply: ProposalUserReply, at: Date) async throws -> ProposalDecisionOutcome { try await inner.respond(id: id, reply: reply, at: at) }
        func report(id: UUID, state: ProposalState, note: String, undo: ProposalUndoInfo?, at: Date) async throws -> Proposal {
            reportCalls += 1
            if failReports > 0 { failReports -= 1; throw Net() }
            return try await inner.report(id: id, state: state, note: note, undo: undo, at: at)
        }
        func markUndone(id: UUID, deviceId: String, note: String, at: Date) async throws -> Proposal { try await inner.markUndone(id: id, deviceId: deviceId, note: note, at: at) }
    }
    @MainActor final class CountingExecutor: ProposalExecuting {
        var performed = 0
        func prepare(_ action: ProposalAction) async throws -> PreparedProposalAction { PreparedProposalAction(action: action, changes: nil) }
        func perform(_ action: ProposalAction) async throws -> ProposalExecutionOutcome { performed += 1; return ProposalExecutionOutcome(note: "做完了", undo: nil) }
    }

    @Test func reportFailureIsRetriedLaterWithoutReexecuting() async throws {
        let clock = Clock()
        let transport = FlakyTransport(); transport.failReports = 10   // 比重试次数多：这一轮回报注定失败
        let executor = CountingExecutor(), ledger = MemoryOperationLedger()
        let defaults = UserDefaults(suiteName: "bc-unreported-" + UUID().uuidString)!
        let mac = ProposalCenter(transport: transport, executor: executor, notifier: FakeNotifier(), ledger: ledger,
                                 deviceId: "mac", deviceLabel: "Mac", informDefaults: defaults, now: { clock.now })
        let proposal = try #require(await mac.submit(draft(target: "mac")))
        _ = await mac.decide(proposal.id, .approve)
        #expect(executor.performed == 1)
        #expect(mac.unreportedCount == 1 && mac.lastError?.contains("没回报") == true)
        #expect(ledger.records().contains { $0.event == "report.pending" })
        #expect(try await transport.fetchRecent().first?.state == .approved)   // iCloud 上仍是「已同意」
        // 网络恢复：刷新只补回报，不再执行
        transport.failReports = 0
        await mac.refresh()
        #expect(executor.performed == 1)
        #expect(mac.unreportedCount == 0)
        #expect(try await transport.fetchRecent().first?.state == .applied)
        #expect(ledger.records().contains { $0.event == "applied" })
        // 持久化：新实例（模拟重启）也不会重复执行
        transport.failReports = 10
        let mac2 = ProposalCenter(transport: transport, executor: executor, notifier: FakeNotifier(), ledger: ledger,
                                  deviceId: "mac", deviceLabel: "Mac", informDefaults: defaults, now: { clock.now })
        await mac2.refresh()
        #expect(executor.performed == 1)
    }

    final class Clock { var now = Date(timeIntervalSince1970: 1_792_000_000) }

    struct Pair {
        let mac: ProposalCenter, phone: ProposalCenter
        let macBell: FakeNotifier, phoneBell: FakeNotifier
        let ledger: MemoryOperationLedger
    }

    func pair(clock: Clock, executor: (any ProposalExecuting)? = nil) -> Pair {
        let executor = executor ?? ExperimentOnlyExecutor()
        let transport = InMemoryProposalTransport()
        let ledger = MemoryOperationLedger()
        let macBell = FakeNotifier(), phoneBell = FakeNotifier()
        let mac = ProposalCenter(transport: transport, executor: executor, notifier: macBell, ledger: ledger,
                                 deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        let phone = ProposalCenter(transport: transport, executor: executor, notifier: phoneBell, ledger: ledger,
                                   deviceId: "phone", deviceLabel: "iPhone", now: { clock.now })
        return Pair(mac: mac, phone: phone, macBell: macBell, phoneBell: phoneBell, ledger: ledger)
    }

    func draft(target: String? = "mac", parent: UUID? = nil, lifetime: TimeInterval = 3600) -> ProposalDraft {
        ProposalDraft(origin: .agent, originLabel: "BetterCalendar 智能体", parentId: parent, targetDeviceId: target,
                      title: "测试：把「整理笔记」挪到 15:00",
                      changes: [ProposalChange(field: "开始时间", before: "14:00", after: "15:00")],
                      reason: "联调测试", action: .experimentNoop(note: "联调"), experiment: true, lifetime: lifetime)
    }

    @Test func askAlwaysGateNotifiesEveryDeviceOnce() async throws {
        let clock = Clock(); let p = pair(clock: clock)
        let proposal = try #require(await p.mac.submit(draft()))
        await p.phone.refresh(); await p.mac.refresh(); await p.phone.refresh()
        #expect(proposal.state == .pending)
        #expect(p.macBell.shown == [proposal.id] && p.phoneBell.shown == [proposal.id])
        #expect(p.macBell.showCount == 1 && p.phoneBell.showCount == 1)   // 重复刷新不重复弹
    }

    @Test func firstDecisionWinsThenTargetExecutesAndAllDevicesWithdraw() async throws {
        let clock = Clock(); let p = pair(clock: clock)
        let proposal = try #require(await p.mac.submit(draft(target: "mac")))
        await p.phone.refresh()
        // 手机先批准（首个有效决定）；Mac 迟到的拒绝只拿到最新结果。
        let first = await p.phone.decide(proposal.id, .approve)
        guard case .won = first else { Issue.record("手机的首个决定应生效"); return }
        let late = await p.mac.decide(proposal.id, .decline)
        guard case let .alreadyClosed(latest)? = late else { Issue.record("迟到的决定不应生效"); return }
        #expect([.approved, .applied].contains(latest.state))
        // Mac 是指定执行设备：刷新后执行；手机不执行。
        await p.mac.refresh(); await p.phone.refresh()
        let final = try #require(p.phone.proposals.first { $0.id == proposal.id })
        #expect(final.state == .applied && final.decidedByDeviceId == "phone")
        #expect(final.resultNote?.contains("未修改任何真实数据") == true)
        #expect(p.macBell.shown.isEmpty && p.phoneBell.shown.isEmpty)
        #expect(p.ledger.values.filter { $0.event == "applied" }.count == 1)   // 只执行一次
    }

    @Test func untargetedProposalIsExecutedByTheApprovingDevice() async throws {
        let clock = Clock(); let p = pair(clock: clock)
        let proposal = try #require(await p.mac.submit(draft(target: nil)))
        await p.phone.refresh()
        await p.phone.decide(proposal.id, .approve)
        await p.mac.refresh()
        let applied = p.ledger.values.filter { $0.event == "applied" }
        #expect(applied.count == 1 && applied.first?.deviceId == "phone")
    }

    @Test func expiredProposalCannotBeApprovedAndIsWithdrawn() async throws {
        let clock = Clock(); let p = pair(clock: clock)
        let proposal = try #require(await p.mac.submit(draft(lifetime: 60)))
        await p.phone.refresh()
        clock.now = clock.now.addingTimeInterval(61)
        let outcome = await p.phone.decide(proposal.id, .approve)
        guard case let .alreadyClosed(latest)? = outcome else { Issue.record("过期提案不能被批准"); return }
        #expect(latest.effectiveState(at: clock.now) == .expired)
        await p.mac.refresh()
        #expect(p.phoneBell.shown.isEmpty && p.macBell.shown.isEmpty)
        #expect(!p.ledger.values.contains { $0.event == "applied" })
    }

    @Test func declinedProposalNeverExecutes() async throws {
        let clock = Clock(); let p = pair(clock: clock)
        let proposal = try #require(await p.mac.submit(draft()))
        await p.mac.decide(proposal.id, .decline)
        await p.phone.refresh(); await p.mac.refresh()
        #expect(p.mac.proposals.first?.state == .declined)
        #expect(!p.ledger.values.contains { $0.event == "applied" || $0.event == "failed" })
    }

    @Test func executionFailureIsVisibleAndNotRetried() async throws {
        let clock = Clock(); let p = pair(clock: clock, executor: FailingExecutor())
        let proposal = try #require(await p.mac.submit(draft()))
        await p.mac.decide(proposal.id, .approve)
        await p.mac.refresh(); await p.mac.refresh()
        #expect(p.mac.proposals.first?.state == .failed)
        #expect(p.mac.lastError?.contains("模拟网络中断") == true)
        #expect(p.ledger.values.filter { $0.event == "failed" }.count == 1)
    }

    @Test func ledgerKeepsOriginAndParentChain() async throws {
        let clock = Clock(); let p = pair(clock: clock)
        let parent = UUID()
        let proposal = try #require(await p.mac.submit(draft(parent: parent)))
        await p.phone.refresh()
        await p.phone.decide(proposal.id, .approve)
        let submitted = try #require(p.ledger.values.first { $0.event == "submitted" })
        #expect(submitted.actor == .agent && submitted.actorLabel == "BetterCalendar 智能体" && submitted.parentId == parent)
        let decided = try #require(p.ledger.values.first { $0.event == "decided" })
        #expect(decided.actor == .user && decided.deviceId == "phone" && decided.proposalId == proposal.id)
    }

    @Test func notificationBodyShowsBeforeAfterReasonAndOrigin() {
        let clock = Clock()
        let p = Proposal(id: UUID(), createdAt: clock.now, expiresAt: clock.now.addingTimeInterval(60), origin: .agent,
                         originLabel: "BetterCalendar 智能体", originDeviceId: "mac", parentId: nil, targetDeviceId: nil,
                         title: "挪动", changes: [ProposalChange(field: "开始时间", before: "14:00", after: "15:00"),
                                                  ProposalChange(field: "备注", before: nil, after: "带上草稿")],
                         reason: "下午会议推迟", action: .experimentNoop(note: "x"), experiment: true, state: .pending)
        #expect(p.notificationBody == "开始时间：14:00 → 15:00\n备注：新增「带上草稿」\n理由：下午会议推迟\n发起：BetterCalendar 智能体")
    }
}
