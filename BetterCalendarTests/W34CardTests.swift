//
//  W34CardTests.swift
//  BetterCalendarTests
//
//  W34（Jason 2026-10-21）审批卡改版的纯规则 + 「点完一张下一张立即出现」（乐观更新，失败回滚可见）。
//  内存中转、注入时钟（不用 Date.now）。
//

import Foundation
import Testing
@testable import BetterCalendar

@MainActor @Suite struct W34CardTests {
    let base = ProposalCenterTests()

    let clock = ProposalCenterTests.Clock()
    var t0: Date { clock.now }

    /// 经真提交流程建一份（createdAt = 注入时钟的此刻）。
    func proposal(lifetime: TimeInterval) async throws -> Proposal {
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ProposalCenterTests.CountingExecutor(),
                                    notifier: ProposalCenterTests.FakeNotifier(), ledger: MemoryOperationLedger(),
                                    deviceId: "mac", deviceLabel: "Mac", now: { [clock] in clock.now })
        return try #require(await center.submit(base.draft(lifetime: lifetime)))
    }

    // MARK: 每样信息只出现一次

    @Test func cardSplitsChangesConsequencesAndEscalationSubjects() {
        let changes: [ProposalChange] = [
            .escalationSubject("删的是你的长期事项：《C》"),
            ProposalChange(field: "时间", before: "14:00", after: "16:00"),
            .consequence("进回收站，30 天内可恢复"),
            .consequence("可一键撤销"),
        ]
        #expect(ProposalPresentation.changeLines(changes) == [Proposal.line(changes[1])])
        #expect(ProposalPresentation.consequenceLine(changes) == "进回收站，30 天内可恢复 · 可一键撤销")
        #expect(ProposalPresentation.escalationSubjects(changes) == ["删的是你的长期事项：《C》"])
        #expect(ProposalPresentation.consequenceLine([]) == nil)
    }

    @Test func headlinePrefersAppWrittenSentenceUnlessThereAreAlternatives() async throws {
        var p = try await proposal(lifetime: 3600)
        #expect(ProposalPresentation.headline(p) == p.title)
        p.headline = "删除长期事项「C」（连同 1 个阶段）"
        #expect(ProposalPresentation.headline(p) == "删除长期事项「C」（连同 1 个阶段）")
        p.preauth = ProposalPreauthStamp(ruleId: PreauthPolicy.lowRiskRuleId, effect: .allow, ruleLabel: "低风险")
        #expect(ProposalPresentation.headline(p).hasPrefix("已自动通过：删除长期事项"))
    }

    // MARK: 有效期：默认不显示，临近作废才出闹钟；到期只作废

    @Test func alarmShowsOnlyInTheLastQuarterCappedAtAnHour() async throws {
        let short = try await proposal(lifetime: 15 * 60)   // 15 分钟 → 最后 3 分 45 秒
        #expect(!ProposalPresentation.isNearExpiry(short, at: t0.addingTimeInterval(10 * 60)))
        #expect(ProposalPresentation.isNearExpiry(short, at: t0.addingTimeInterval(12 * 60)))
        let week = try await proposal(lifetime: 7 * 86_400)   // 7 天 → 最后 1 小时
        #expect(!ProposalPresentation.isNearExpiry(week, at: week.expiresAt.addingTimeInterval(-2 * 3600)))
        #expect(ProposalPresentation.isNearExpiry(week, at: week.expiresAt.addingTimeInterval(-30 * 60)))
        // 过了就是「已作废」，不再提示，也不会变成同意
        #expect(!ProposalPresentation.isNearExpiry(short, at: short.expiresAt.addingTimeInterval(1)))
        #expect(short.effectiveState(at: short.expiresAt.addingTimeInterval(1)) == .expired)
        #expect(ProposalPresentation.compactStatus(short, at: short.expiresAt.addingTimeInterval(1)) == "已作废")
    }

    @Test func timeLeftIsPlainAndSaysExpiryNeverApproves() async throws {
        let p = try await proposal(lifetime: 3600)
        #expect(ProposalPresentation.timeLeft(p, at: p.expiresAt.addingTimeInterval(-12 * 60)).hasPrefix("还有 12 分钟作废"))
        #expect(ProposalPresentation.timeLeft(p, at: p.expiresAt.addingTimeInterval(-20)).hasPrefix("马上就作废了"))
        #expect(ProposalPresentation.timeLeft(p, at: p.expiresAt.addingTimeInterval(-20)).contains("不会默认同意"))
        #expect(ProposalPresentation.expiryDetail(p).contains("到期只作废"))
    }

    // MARK: 点完一张，下一张立即出现

    /// iCloud 条件保存卡在半路的中转（测试放行或让它失败）。
    final class GatedTransport: ProposalTransport, @unchecked Sendable {
        let inner = InMemoryProposalTransport()
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        var failDecide = false
        struct Net: Error, LocalizedError { var errorDescription: String? { "模拟 iCloud 不可达" } }
        var isWaiting: Bool { lock.withLock { waiting != nil } }
        func release() { lock.withLock { let c = waiting; waiting = nil; return c }?.resume() }

        func submit(_ proposal: Proposal) async throws { try await inner.submit(proposal) }
        func fetchRecent() async throws -> [Proposal] { try await inner.fetchRecent() }
        func decide(id: UUID, decision: ProposalDecision, choice: Int?, tuning: ProposalTuning?, deviceId: String, at: Date) async throws -> ProposalDecisionOutcome {
            await withCheckedContinuation { c in lock.withLock { waiting = c } }
            if failDecide { throw Net() }
            return try await inner.decide(id: id, decision: decision, choice: choice, tuning: tuning, deviceId: deviceId, at: at)
        }
        func respond(id: UUID, reply: ProposalUserReply, at: Date) async throws -> ProposalDecisionOutcome { try await inner.respond(id: id, reply: reply, at: at) }
        func report(id: UUID, state: ProposalState, note: String, undo: ProposalUndoInfo?, at: Date) async throws -> Proposal {
            try await inner.report(id: id, state: state, note: note, undo: undo, at: at)
        }
        func markUndone(id: UUID, deviceId: String, note: String, at: Date) async throws -> Proposal { try await inner.markUndone(id: id, deviceId: deviceId, note: note, at: at) }
    }

    func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<2000 where !cond() { await Task.yield() }
    }

    @Test func nextCardAppearsBeforeICloudAnswersAndFailureRollsBack() async throws {
        let clock = ProposalCenterTests.Clock()
        let transport = GatedTransport()
        let center = ProposalCenter(transport: transport, executor: ProposalCenterTests.CountingExecutor(), notifier: ProposalCenterTests.FakeNotifier(),
                                    ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        let first = try #require(await center.submit(base.draft()))
        let second = try #require(await center.submit(base.draft()))
        #expect(Set(center.pending.map(\.id)) == [first.id, second.id])

        // 同意第一张：iCloud 还没回 → 它已离开「待你确认」，第二张就是当前那张
        let approving = Task { await center.decide(first.id, .approve) }
        await waitUntil { transport.isWaiting }
        #expect(center.deciding.contains(first.id))
        #expect(center.pending.map(\.id) == [second.id])
        transport.release()
        _ = await approving.value
        #expect(!center.deciding.contains(first.id))
        #expect(center.proposals.first { $0.id == first.id }?.state != .pending)

        // 拒绝第二张时 iCloud 失败 → 卡片回到「待你确认」，原因可见
        transport.failDecide = true
        let declining = Task { await center.decide(second.id, .decline) }
        await waitUntil { transport.isWaiting }
        #expect(center.pending.isEmpty)
        transport.release()
        #expect(await declining.value == nil)
        #expect(center.pending.map(\.id) == [second.id])
        #expect(center.lastError?.contains("提交决定失败") == true)
    }

    // MARK: 批量卡 / 整批撤销

    @Test func sameActionSameFamilyBatchesWithinTwoMinutes() async throws {
        let w = W32EscalationTests()
        let r = try w.rig()
        var ids: [UUID] = []
        for (i, title) in ["IEEE 754", "X86-64", "leaq"].enumerated() {
            let id = UUID(); ids.append(id)
            try r.items.createTodo(id: id, title: title, note: "", at: r.clock.now)
            r.clock.now = r.clock.now.addingTimeInterval(i == 0 ? 0 : 30)
            _ = try #require(await r.center.submit(w.draft(.itemDelete(id: id, expectedRevision: nil), escalation: "Jason 说这几条都做完了")))
        }
        r.clock.now = r.clock.now.addingTimeInterval(10)
        let created = try #require(await r.center.submit(w.draft(.itemCreate(id: UUID(), title: "买菜", note: nil), escalation: nil)))
        r.clock.now = r.clock.now.addingTimeInterval(400)   // 隔太久 = 另一次行动
        let late = UUID()
        try r.items.createTodo(id: late, title: "复印", note: "", at: r.clock.now)
        _ = try #require(await r.center.submit(w.draft(.itemDelete(id: late, expectedRevision: nil), escalation: "另一件事")))

        let groups = ProposalBatching.groups(r.center.pending)
        let batch = try #require(groups.first { $0.isBatch })
        #expect(groups.count == 3)
        #expect(batch.title == "删除 3 项" && batch.family == .delete)
        #expect(groups.contains { $0.proposals.map(\.id) == [created.id] })
        #expect(groups.filter(\.isBatch).count == 1)

        // 勾两项、去掉一项：勾上的同意、没勾的拒绝；批准的一批整批撤销
        let members = batch.proposals.map(\.id)
        #expect(await r.center.decideBatch(approve: Array(members.prefix(2)), decline: [members[2]]) == 3)
        await r.center.refresh()
        let states = members.map { id in r.center.proposals.first { $0.id == id }?.state }
        #expect(states == [.applied, .applied, .declined])
        #expect(r.items.todoItems().map(\.title).sorted() == ["leaq", "复印"])
        #expect(await r.center.undoBatch(members) == 2)
        #expect(r.items.todoItems().map(\.title).sorted() == ["IEEE 754", "X86-64", "leaq", "复印"])
    }

    @Test func alternativesParametersAndTimelinePlansNeverBatch() {
        #expect(ProposalFamily.of(.planDay(day: Date(timeIntervalSince1970: 0), steps: [], isUndo: false)) == nil)
        #expect(ProposalFamily.of(.experimentNoop(note: "x")) == nil)
        #expect(ProposalFamily.of(.itemRestore(id: UUID(), deletionID: UUID())) == nil)   // 撤销用的逆操作
        #expect(ProposalFamily.of(.yourReminderEdit(YourReminderEdit(externalID: "r", done: true))) == .complete)
        #expect(ProposalFamily.of(.yourReminderEdit(YourReminderEdit(externalID: "r", title: "x"))) == .edit)
        #expect(ProposalFamily.of(.yourReminderDelete(externalID: "r", expectedRevision: nil)) == .delete)
        #expect(ProposalFamily.of(.checkpointCreate(itemId: UUID(), checkpointId: UUID(), title: "x", estimatedMinutes: nil, position: nil, expectedRevision: nil)) == .create)
    }
}
