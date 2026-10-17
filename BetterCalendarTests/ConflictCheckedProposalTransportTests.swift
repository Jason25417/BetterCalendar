import CloudKit
import Foundation
import Testing
@testable import BetterCalendar

/// SPEC §19 B2：乐观并发下「首个有效决定生效」，以及云端记录编解码。
@Suite struct ConflictCheckedProposalTransportTests {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    func proposal(state: ProposalState = .pending, target: String? = "mac") -> Proposal {
        Proposal(id: UUID(), createdAt: t0, expiresAt: t0.addingTimeInterval(3600), origin: .agent,
                 originLabel: "BetterCalendar 智能体", originDeviceId: "mac", parentId: UUID(), targetDeviceId: target,
                 title: "测试改动", changes: [ProposalChange(field: "开始时间", before: "14:00", after: "15:00")],
                 reason: "联调", action: .experimentNoop(note: "x"), experiment: true, state: state)
    }

    @Test func concurrentApprovalOnOtherDeviceMakesLocalDecisionLose() async throws {
        let store = MemoryProposalRecordStore(), transport = ConflictCheckedProposalTransport(store: store)
        var p = proposal(); try await transport.submit(p)
        // 本端读完、写入前，另一端抢先批准。
        let at = t0
        await store.setBeforeUpdate { _ in
            p.state = .approved; p.decidedAt = at; p.decidedByDeviceId = "phone"
            await store.forceWrite(p)
        }
        let outcome = try await transport.decide(id: p.id, decision: .decline, deviceId: "mac", at: t0)
        guard case let .alreadyClosed(latest) = outcome else { Issue.record("另一端已先决定，本端应输"); return }
        #expect(latest.state == .approved && latest.decidedByDeviceId == "phone")
    }

    @Test func nonDecisionConflictIsRetriedAndWins() async throws {
        let store = MemoryProposalRecordStore(), transport = ConflictCheckedProposalTransport(store: store)
        let p = proposal(); try await transport.submit(p)
        await store.setBeforeUpdate { _ in await store.forceWrite(p) }   // 版本变了，但仍待决定
        let outcome = try await transport.decide(id: p.id, decision: .approve, deviceId: "mac", at: t0)
        guard case let .won(won) = outcome else { Issue.record("仍待决定时应重试并生效"); return }
        #expect(won.state == .approved && won.decidedByDeviceId == "mac")
    }

    @Test func reportOnlyFromApprovedAndOnlyAppliedOrFailed() async throws {
        let store = MemoryProposalRecordStore(), transport = ConflictCheckedProposalTransport(store: store)
        let pending = proposal(); try await transport.submit(pending)
        await #expect(throws: ProposalTransportError.self) {
            _ = try await transport.report(id: pending.id, state: .applied, note: "x", at: t0)
        }
        _ = try await transport.decide(id: pending.id, decision: .approve, deviceId: "mac", at: t0)
        await #expect(throws: ProposalTransportError.self) {
            _ = try await transport.report(id: pending.id, state: .pending, note: "x", at: t0)
        }
        let done = try await transport.report(id: pending.id, state: .applied, note: "ok", at: t0)
        #expect(done.state == .applied && done.resultNote == "ok")
    }

    @MainActor @Test func centerWorksEndToEndOverConflictCheckedTransport() async throws {
        let store = MemoryProposalRecordStore(), transport = ConflictCheckedProposalTransport(store: store)
        let ledger = MemoryOperationLedger()
        let macBell = ProposalCenterTests.FakeNotifier(), phoneBell = ProposalCenterTests.FakeNotifier()
        let at = t0
        let mac = ProposalCenter(transport: transport, executor: ExperimentOnlyExecutor(), notifier: macBell, ledger: ledger,
                                 deviceId: "mac", deviceLabel: "Mac", now: { at })
        let phone = ProposalCenter(transport: transport, executor: ExperimentOnlyExecutor(), notifier: phoneBell, ledger: ledger,
                                   deviceId: "phone", deviceLabel: "iPhone", now: { at })
        let draft = ProposalDraft(origin: .user, originLabel: "Claude（替 Jason 测试）", targetDeviceId: "mac", title: "测试",
                                  changes: [], reason: "联调", action: .experimentNoop(note: "e2e"), experiment: true)
        let p = try #require(await mac.submit(draft))
        await phone.refresh()
        #expect(phoneBell.shown == [p.id] && macBell.shown == [p.id])
        await phone.decide(p.id, .approve)
        await mac.refresh(); await phone.refresh()
        #expect(phone.proposals.first?.state == .applied)
        #expect(macBell.shown.isEmpty && phoneBell.shown.isEmpty)
    }

    @Test func recordCodecRoundTripsAndRejectsMismatchedIdentity() throws {
        let p = proposal(state: .approved)
        let zone = CloudKitProposalStore.zoneID
        let record = CKRecord(recordType: ProposalRecordCodec.recordType, recordID: ProposalRecordCodec.recordID(p.id, zoneID: zone))
        try ProposalRecordCodec.encode(p, into: record)
        #expect(try ProposalRecordCodec.decode(record) == p)
        #expect(record["state"] as? String == "approved" && record["title"] as? String == "测试改动")
        let wrong = CKRecord(recordType: ProposalRecordCodec.recordType, recordID: ProposalRecordCodec.recordID(UUID(), zoneID: zone))
        try ProposalRecordCodec.encode(p, into: wrong)
        #expect(throws: ProposalTransportError.self) { _ = try ProposalRecordCodec.decode(wrong) }
    }
}
