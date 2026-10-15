import Foundation
import Testing
import UserNotifications
@testable import BetterCalendar

@MainActor @Suite struct NativeReminderSchedulingTests {
    let at = Date(timeIntervalSince1970: 1792083600)
    func change() -> NativeReminderChange {
        .init(commandId: UUID(), reminderId: UUID(), action: .schedule, title: "BC 联调测试提醒", body: "隔离提醒，不计生活活动", fireAt: at.addingTimeInterval(600), sound: false, experiment: true)
    }
    @Test func scheduleReplaceCancelUsesOneIdentifierAndPreservesVersionAndExplicitFields() async throws {
        let system = ReminderSystemFixture(), disk = NativeReminderMemoryPersistence(), c = change()
        let scheduler = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        let receipt = try NativeRemoteJSON.object(await scheduler.apply(c, userConfirmed: true, grantCurrent: { true }))
        let original = try #require(scheduler.records().first)
        #expect(system.pendingValues.count == 1 && receipt["delivered"] == .string("unknown") && receipt["guaranteedWake"] == .bool(false))
        var update = c; update.commandId = UUID(); update.action = .update; update.expectedRevision = original.revision
        update.title = "BC 联调测试提醒（改期）"; update.fireAt = at.addingTimeInterval(1200)
        _ = try await scheduler.apply(update, userConfirmed: true, grantCurrent: { true })
        let updated = try #require(scheduler.records().first)
        #expect(updated.id == original.id && updated.identifier == original.identifier && updated.revision != original.revision)
        #expect(system.pendingValues[original.identifier] == updated && system.removed == [original.identifier])
        let cancel = NativeReminderChange(commandId: UUID(), reminderId: c.reminderId, action: .cancel, expectedRevision: updated.revision)
        _ = try await scheduler.apply(cancel, userConfirmed: true, grantCurrent: { true })
        _ = try await scheduler.apply(cancel, userConfirmed: true, grantCurrent: { true })
        let cancelled = try scheduler.records().first
        #expect(system.pendingValues.isEmpty && system.submitted.count == 2 && cancelled?.cancelled == true)
        // Old successful commands return their original receipt, never reapply.
        _ = try await scheduler.apply(c, userConfirmed: true, grantCurrent: { true })
        let finalRecord = try scheduler.records().first
        #expect(system.pendingValues.isEmpty && finalRecord?.cancelled == true)
    }
    @Test func explicitHumanAndIndependentGrantAndExistingSystemAuthorizationAreAllRequired() async throws {
        let system = ReminderSystemFixture(), disk = NativeReminderMemoryPersistence(), c = change()
        let scheduler = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        await #expect(throws: (any Error).self) { try await scheduler.apply(c, userConfirmed: false, grantCurrent: { true }) }
        await #expect(throws: (any Error).self) { try await scheduler.apply(c, userConfirmed: true, grantCurrent: { false }) }
        system.allowed = false
        await #expect(throws: (any Error).self) { try await scheduler.apply(c, userConfirmed: true, grantCurrent: { true }) }
        #expect(disk.value.attempts.isEmpty && system.submitted.isEmpty)
    }
    @Test func revocationWhileReadingSystemPermissionStopsBeforeAnyNotificationMutation() async throws {
        let system = ReminderSystemFixture(), disk = NativeReminderMemoryPersistence(), c = change()
        var granted = true; system.beforeAuthorizationReturns = { granted = false }
        let scheduler = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        await #expect(throws: (any Error).self) { try await scheduler.apply(c, userConfirmed: true, grantCurrent: { granted }) }
        #expect(system.submitted.isEmpty && system.removed.isEmpty && disk.value.records.isEmpty)
    }
    @Test func restartAfterOSAcceptedButReceiptPersistenceFailedReadsBackWithoutSecondSubmission() async throws {
        let system = ReminderSystemFixture(), disk = ReminderDiskFixture(), c = change()
        disk.failSaveNumber = 2
        let first = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        await #expect(throws: (any Error).self) { try await first.apply(c, userConfirmed: true, grantCurrent: { true }) }
        #expect(system.submitted.count == 1 && disk.value.records.isEmpty && disk.value.attempts.first?.applied == false)
        let restarted = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        _ = try await restarted.apply(c, userConfirmed: true, grantCurrent: { true })
        #expect(system.submitted.count == 1 && disk.value.records.count == 1 && disk.value.attempts.first?.applied == true)
    }
    @Test func crashBeforeOSAndMissingFuturePlanRemainUnknownInsteadOfAutomaticallyRescheduling() async throws {
        let system = ReminderSystemFixture(), disk = NativeReminderMemoryPersistence(), c = change()
        system.failSubmit = true
        let first = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        await #expect(throws: (any Error).self) { try await first.apply(c, userConfirmed: true, grantCurrent: { true }) }
        system.failSubmit = false
        let restarted = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        await #expect(throws: (any Error).self) { try await restarted.apply(c, userConfirmed: true, grantCurrent: { true }) }
        #expect(system.submitted.isEmpty && disk.value.attempts.count == 1 && disk.value.records.isEmpty)
        let pending = try NativeRemoteJSON.object(try #require(await restarted.status().first))
        #expect(pending["state"] == .string("operation_result_unknown"))
    }
    @Test func staleRevisionOrReusedCommandOrPastTimeNeverTouchesOS() async throws {
        let system = ReminderSystemFixture(), disk = NativeReminderMemoryPersistence(), c = change()
        let scheduler = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        _ = try await scheduler.apply(c, userConfirmed: true, grantCurrent: { true })
        var reused = c; reused.title = "different"
        await #expect(throws: (any Error).self) { try await scheduler.apply(reused, userConfirmed: true, grantCurrent: { true }) }
        var stale = c; stale.commandId = UUID(); stale.action = .update; stale.expectedRevision = "old"
        await #expect(throws: (any Error).self) { try await scheduler.apply(stale, userConfirmed: true, grantCurrent: { true }) }
        var past = change(); past.fireAt = at.addingTimeInterval(-1)
        await #expect(throws: (any Error).self) { try await scheduler.apply(past, userConfirmed: true, grantCurrent: { true }) }
        #expect(system.submitted.count == 1 && system.removed.isEmpty)
    }
    @Test func failedOldCancellationCannotDeleteANewerApprovedRevisionOnRetry() async throws {
        let system = ReminderSystemFixture(), disk = ReminderDiskFixture(), c = change()
        let scheduler = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        _ = try await scheduler.apply(c, userConfirmed: true, grantCurrent: { true })
        let oldRevision = try #require(scheduler.records().first?.revision)
        let cancel = NativeReminderChange(commandId: UUID(), reminderId: c.reminderId, action: .cancel, expectedRevision: oldRevision)
        disk.failSaveNumber = disk.saves + 2
        await #expect(throws: (any Error).self) { try await scheduler.apply(cancel, userConfirmed: true, grantCurrent: { true }) }
        var update = c; update.commandId = UUID(); update.action = .update; update.expectedRevision = oldRevision; update.title = "New approved revision"
        _ = try await scheduler.apply(update, userConfirmed: true, grantCurrent: { true })
        let current = try #require(scheduler.records().first)
        await #expect(throws: (any Error).self) { try await scheduler.apply(cancel, userConfirmed: true, grantCurrent: { true }) }
        #expect(system.pendingValues[current.identifier] == current && !current.cancelled)
        let latest = try NativeRemoteJSON.object(try #require(await scheduler.status().first))
        #expect(latest["state"] == .string("system_schedule_verified"))
    }
    @Test func firstDurableWriteFailurePreventsAnySystemOperationAndFileRoundTripIsIsolated() async throws {
        let system = ReminderSystemFixture(), disk = ReminderDiskFixture(), c = change(); disk.failSaveNumber = 1
        let scheduler = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        await #expect(throws: (any Error).self) { try await scheduler.apply(c, userConfirmed: true, grantCurrent: { true }) }
        #expect(system.submitted.isEmpty && system.removed.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = NativeReminderFilePersistence(url: directory.appendingPathComponent("fixture.json"))
        try file.save(disk.value); #expect(try file.load().records.isEmpty)
    }
    @Test func queryDistinguishesSavedRecordFromMissingSystemPlanAndDoesNotInventDelivery() async throws {
        let system = ReminderSystemFixture(), disk = NativeReminderMemoryPersistence(), c = change()
        let scheduler = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        _ = try await scheduler.apply(c, userConfirmed: true, grantCurrent: { true })
        let scheduled = try NativeRemoteJSON.object(try #require(await scheduler.status().first))
        #expect(scheduled["state"] == .string("system_schedule_verified") && scheduled["userSeen"] == .string("unknown"))
        system.pendingValues.removeAll()
        let missing = try NativeRemoteJSON.object(try #require(await scheduler.status().first))
        #expect(missing["state"] == .string("system_plan_missing_unknown") && system.submitted.count == 1)
        let later = NativeReminderScheduler(system: system, persistence: disk, now: { self.at.addingTimeInterval(1200) })
        let elapsed = try NativeRemoteJSON.object(try #require(await later.status().first))
        #expect(elapsed["state"] == .string("elapsed_delivery_unknown") && system.submitted.count == 1)
    }
    @Test func readPagingPinsCatalogAndFiltersAndReadRevocationNeverReturnsMixedData() async throws {
        let system = ReminderSystemFixture(), disk = NativeReminderMemoryPersistence()
        let scheduler = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        for _ in 0..<3 { _ = try await scheduler.apply(change(), userConfirmed: true, grantCurrent: { true }) }
        let first = try NativeRemoteJSON.object(await scheduler.read(.init(limit: 1), readAllowed: { true }))
        let cursor = try NativeRemoteJSON.string(first["nextCursor"])
        #expect(first["hasMore"] == .bool(true))
        let next = try NativeRemoteJSON.object(await scheduler.read(.init(limit: 1, cursor: cursor), readAllowed: { true }))
        #expect(next["records"] != first["records"] && next["catalogHash"] == first["catalogHash"])
        await #expect(throws: (any Error).self) { try await scheduler.read(.init(includeCancelled: true, limit: 1, cursor: cursor), readAllowed: { true }) }
        _ = try await scheduler.apply(change(), userConfirmed: true, grantCurrent: { true })
        await #expect(throws: (any Error).self) { try await scheduler.read(.init(limit: 1, cursor: cursor), readAllowed: { true }) }
        var allowed = true; system.beforePendingReturns = { allowed = false }
        await #expect(throws: (any Error).self) { try await scheduler.read(.init(), readAllowed: { allowed }) }
        #expect(system.submitted.count == 4)
    }
    @Test func clickProofIsBoundToOriginalPlanDeduplicatedAndNeverMarksNewRevisionSeen() async throws {
        let system = ReminderSystemFixture(), disk = NativeReminderMemoryPersistence(), c = change()
        let scheduler = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        _ = try await scheduler.apply(c, userConfirmed: true, grantCurrent: { true })
        let plan = try #require(scheduler.records().first)
        let raw = try #require(UNNativeReminderSystem.request(plan).content.userInfo["bcExplicitReminder"] as? String)
        try scheduler.recordClick(raw); try scheduler.recordClick(raw)
        #expect(disk.value.clicks?.count == 1 && system.submitted.count == 1)
        let clicked = try NativeRemoteJSON.object(try #require(await scheduler.status().first))
        #expect(clicked["clickedAt"] == NativeRemoteJSON.timestamp(at) && clicked["userSeen"] == .string("unknown"))
        var update = c; update.commandId = UUID(); update.action = .update; update.expectedRevision = plan.revision; update.body = "new revision"
        _ = try await scheduler.apply(update, userConfirmed: true, grantCurrent: { true })
        let latest = try NativeRemoteJSON.object(try #require(await scheduler.status().first))
        #expect(latest["clickedAt"] == .null && system.submitted.count == 2)
        #expect(throws: (any Error).self) { try scheduler.recordClick("invalid") }
    }
    @Test func systemDeliveryEvidenceIsDistinctFromSavedScheduleAndHumanClick() async throws {
        let system = ReminderSystemFixture(), disk = NativeReminderMemoryPersistence(), c = change()
        let scheduler = NativeReminderScheduler(system: system, persistence: disk, now: { self.at })
        _ = try await scheduler.apply(c, userConfirmed: true, grantCurrent: { true })
        let plan = try #require(scheduler.records().first)
        system.pendingValues.removeAll(); system.deliveredValues[plan.identifier] = plan
        let observed = try NativeRemoteJSON.object(try #require(await scheduler.status().first))
        #expect(observed["deliveryEvidence"] == .string("os_notification_center_entry") && observed["clickedAt"] == .null && observed["userSeen"] == .string("unknown"))
        let cancel = NativeReminderChange(commandId: UUID(), reminderId: plan.id, action: .cancel, expectedRevision: plan.revision)
        _ = try await scheduler.apply(cancel, userConfirmed: true, grantCurrent: { true })
        #expect(system.deliveredValues.isEmpty)
    }
    @Test func absoluteCalendarRequestHasStableIdentifierAndNoRepeatOrAlarmClaim() throws {
        let c = change(), plan = NativeReminderPlan(id: c.reminderId, revision: String(repeating: "a", count: 64), title: c.title!, body: c.body!, fireAt: c.fireAt!, sound: false, experiment: true)
        let request = try UNNativeReminderSystem.request(plan)
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(!trigger.repeats && trigger.dateComponents.date == plan.fireAt && request.content.sound == nil)
        #expect(request.identifier == plan.identifier && request.content.title == plan.title && request.content.body == plan.body)
        #expect(request.content.categoryIdentifier.isEmpty) // A reminder is never an approval.
    }
}
@MainActor private final class ReminderSystemFixture: NativeReminderSystem {
    var allowed = true, failSubmit = false
    var deliveredValues: [String: NativeReminderPlan] = [:]
    func delivered(_ identifier: String) async throws -> NativeReminderPlan? { deliveredValues[identifier] }
    var pendingValues: [String: NativeReminderPlan] = [:], submitted: [NativeReminderPlan] = [], removed: [String] = []
    var beforeAuthorizationReturns: (() -> Void)?
    func authorized() async -> Bool { beforeAuthorizationReturns?(); return allowed }
    var beforePendingReturns: (() -> Void)?
    func pending(_ identifier: String) async throws -> NativeReminderPlan? { beforePendingReturns?(); return pendingValues[identifier] }
    func submit(_ plan: NativeReminderPlan) async throws {
        if failSubmit { throw URLError(.networkConnectionLost) }
        submitted.append(plan); pendingValues[plan.identifier] = plan
    }
    func remove(_ identifier: String) async { removed.append(identifier); pendingValues.removeValue(forKey: identifier); deliveredValues.removeValue(forKey: identifier) }
}
@MainActor private final class ReminderDiskFixture: NativeReminderPersisting {
    var value = NativeReminderLedger(), saves = 0, failSaveNumber = 0
    func load() throws -> NativeReminderLedger { value }
    func save(_ value: NativeReminderLedger) throws {
        saves += 1; if saves == failSaveNumber { throw DataArchiveError.invalid("isolated reminder disk failure") }
        self.value = value
    }
}
