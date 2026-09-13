import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

@MainActor @Suite struct DataReliabilityTests {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)
    private func container() throws -> ModelContainer {
        try ModelContainer(for: DataArchiveStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    @Test func archiveRestoresEveryEntityAndPhotoBytes() throws {
        let c = try container(); let context = c.mainContext
        let task = LongTask(title: "论文", note: "中文与 emoji 🌱", deadline: time,
                            cadenceMinutesPerWeek: 75, totalMinutes: 150, unitMinutes: 25,
                            createdAt: time, modifiedAt: time, family: "写作")
        context.insert(task)
        let cp = LongTaskCheckpoint(title: "校对", estimatedMinutes: 30, order: 2, createdAt: time)
        context.insert(cp); cp.task = task
        let planned = PlanBlock(title: "第一节", start: time, end: time.addingTimeInterval(900),
                                isFixed: true, kind: .planned, linkedTaskID: task.id)
        context.insert(planned)
        context.insert(PlanBlock(id: planned.id, title: planned.title, start: time,
                                end: time.addingTimeInterval(800), kind: .actual))
        let session = ExecutionSession(blockID: planned.id, start: time, end: time.addingTimeInterval(800))
        session.title = planned.title; context.insert(session)
        context.insert(DayRecord(dayKey: "2027-01-15", isActive: true, mvpTitle: "校对", modifiedAt: time))
        context.insert(DayPlanSnapshot(dayLabel: time, createdAt: time, items: [
            SnapshotItem(id: planned.id, title: planned.title, plannedStart: time,
                         plannedMinutes: 15, isFixed: true, isAnchor: false,
                         linkedTaskID: task.id, labels: ["family:写作"]) ]))
        context.insert(ResidualSample(dayLabel: time, blockID: planned.id, title: planned.title,
                                     plannedStart: time, plannedMinutes: 15, actualStart: time,
                                     actualMinutes: 13, source: .recall))
        context.insert(JournalEntry(date: time, body: "## 今天\n记录", tags: ["测试"], photoRefs: ["photo.jpg"]))
        context.insert(JournalPhoto(ref: "photo.jpg", data: Data([0, 1, 255, 90]), createdAt: time))
        context.insert(DeviceLog(deviceID: "fixture", deviceName: "test", dayKey: "2027-01-15", text: "test", modifiedAt: time))
        try context.save()
        let archive = try DataArchiveStore.capture(context, now: time)
        #expect(Set(archive.records.map(\.entity)).count == 10)
        #expect(archive.records.count == 11)
        let bytes = try ArchiveCodec.encoder().encode(SealedDataArchive(archive))
        let read = try ArchiveCodec.decoder().decode(SealedDataArchive.self, from: bytes).verified()
        try DataArchiveStore.validateRestoration(read)
        let destination = try container()
        try DataArchiveStore.restore(read, into: destination.mainContext)
        #expect(try destination.mainContext.fetch(FetchDescriptor<JournalPhoto>()).first?.data == Data([0, 1, 255, 90]))
        #expect(try destination.mainContext.fetch(FetchDescriptor<LongTaskCheckpoint>()).first?.task?.id == task.id)
        #expect(throws: (any Error).self) { try DataArchiveStore.restore(read, into: destination.mainContext) }
    }

    @Test func tamperingUnknownVersionsAndUnknownFieldsAreRejected() throws {
        let c = try container(); c.mainContext.insert(LongTask(title: "原文")); try c.mainContext.save()
        let archive = try DataArchiveStore.capture(c.mainContext)
        var sealed = try SealedDataArchive(archive)
        sealed.archive.records[0].values["title"] = .string("修改过")
        #expect(throws: (any Error).self) { _ = try sealed.verified() }
        var future = archive; future.formatVersion = 99
        #expect(throws: (any Error).self) { _ = try SealedDataArchive(future).verified() }
        var unknown = archive; unknown.records[0].values["newFutureField"] = .string("must not drop")
        #expect(throws: (any Error).self) { try DataArchiveStore.validateRestoration(unknown) }
    }

    @Test func externalEditIsConditionalAtomicAndVisibleOnReload() throws {
        let c = try container(); let context = c.mainContext
        let task = LongTask(title: "旧标题"); context.insert(task); try context.save()
        let store = LongTaskStore(context: context)
        let archive = try DataArchiveStore.capture(context)
        let row = try #require(archive.records.first)
        var replacement = row.values; replacement["title"] = .string("修正标题")
        let request = DataEditRequest(requestID: UUID(), edits: [.init(key: row.key, expected: row.values, replacement: replacement)])
        let prepared = try DataArchiveStore.prepare(request, current: archive)
        try DataArchiveStore.applyPrepared(prepared, request: request, to: context)
        store.reload(); #expect(store.items.first?.title == "修正标题")
        try DataArchiveStore.applyPrepared(prepared, request: request, to: context) // retry is idempotent
        task.title = "新的本机编辑"; try context.save()
        #expect(throws: (any Error).self) { try DataArchiveStore.applyPrepared(prepared, request: request, to: context) }
        #expect(task.title == "新的本机编辑")
        var broken = request; broken.edits[0].replacement["status"] = .string("not-a-status")
        #expect(throws: (any Error).self) { _ = try DataArchiveStore.prepare(broken, current: archive) }
        #expect(task.title == "新的本机编辑")
    }

    @Test func planReplacementPreservesPersistentIdentityAndCompletion() throws {
        let c = try container(); let store = PlanStore(context: c.mainContext)
        let day = DayContext.logicalStartOfDay(time)
        let b = ScheduledBlock(title: "原计划", start: time, end: time.addingTimeInterval(600))
        try store.replacePlanned([b], on: day)
        let original = try #require(c.mainContext.fetch(FetchDescriptor<PlanBlock>()).first)
        let pid = original.persistentModelID
        try store.latchCompletion(plannedID: b.id, .missed)
        let changed = ScheduledBlock(id: b.id, title: "改名", start: b.start, end: b.end)
        try store.replacePlanned([changed], on: day)
        let after = try #require(c.mainContext.fetch(FetchDescriptor<PlanBlock>()).first)
        #expect(after.persistentModelID == pid)
        #expect(after.completion == .missed)
        #expect(after.title == "改名")
    }

    @Test func noSharedBaseOrConcurrentChangesNeverOverwritesTruth() {
        let b = ScheduledBlock(title: "数据库新标题", start: time, end: time.addingTimeInterval(600))
        let event = CalendarEventDraft(title: "日历新标题", start: b.start, end: b.end, kind: .planned, blockID: b.id)
        let noBase = ReconcileService.diff(truth: [b], events: [event], fingerprint: [:])
        #expect(noBase.updates.isEmpty && noBase.conflicts == [b.id])
        let base = ProjectionFingerprints.tuple(start: b.start, end: b.end, title: "共同旧标题")
        let concurrent = ReconcileService.diff(truth: [b], events: [event], fingerprint: [b.id.uuidString: base])
        #expect(concurrent.updates.isEmpty && concurrent.conflicts == [b.id])
    }

    @Test func followedPauseFreezesElapsedAndUnshields() {
        let state = FollowRunState()
        let r = FollowRunState.Run(title: "任务", style: "pomodoro", startedAt: time,
                                   pausedAt: time.addingTimeInterval(60), updatedAt: time, seq: 1)
        state.set(r)
        #expect(r.elapsed(at: time.addingTimeInterval(600)) == 60)
        #expect(!state.shouldShield)
        state.exitFollow(); state.set(r)
        #expect(state.run == nil)
    }
}

@MainActor @Suite struct FollowOwnershipTests {
    @Test func delayedCompletionAndHeartbeatsCannotStealNewerRun() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!FocusFollow.canPublish(owner: "B", localDevice: "A", remoteDate: t,
                                       localDate: t.addingTimeInterval(1), kind: "complete", hasActive: false))
        #expect(!FocusFollow.canPublish(owner: "B", localDevice: "A", remoteDate: t,
                                       localDate: t.addingTimeInterval(1), kind: "tick-running", hasActive: true))
        #expect(!FocusFollow.canPublish(owner: "A", localDevice: "A", remoteDate: t,
                                       localDate: t.addingTimeInterval(-1), kind: "complete", hasActive: false))
        #expect(FocusFollow.canPublish(owner: "B", localDevice: "A", remoteDate: t,
                                      localDate: t.addingTimeInterval(1), kind: "running", hasActive: true))
    }
}

@MainActor @Suite struct DataRebuildTests {
    @Test func duplicateBusinessIDsKeepExactCheckpointParents() throws {
        let container = try ModelContainer(for: DataArchiveStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let id = UUID()
        let a = LongTask(id: id, title: "并发副本 A")
        let b = LongTask(id: id, title: "并发副本 B")
        let cp = LongTaskCheckpoint(title: "属于 B")
        container.mainContext.insert(a); container.mainContext.insert(b); container.mainContext.insert(cp)
        cp.task = b
        try container.mainContext.save()
        try DataArchiveStore.validateRestoration(DataArchiveStore.capture(container.mainContext))
    }

    @Test func oldSampleEditsAndRemovalsRebuildDerivedProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agg = LearningAggregator(directory: dir)
        let defaultMean = agg.read(taskID: nil, family: nil).mean
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = ResidualSample(dayLabel: t, blockID: UUID(), title: "test", plannedStart: t,
                                    plannedMinutes: 60, actualStart: t, actualMinutes: 60, source: .live)
        sample.createdAt = t
        #expect(agg.reconcile(samples: [sample]) == 1)
        let old = agg.read(taskID: nil, family: nil).mean
        sample.actualMinutes = 180
        #expect(agg.reconcile(samples: [sample]) == 1)
        #expect(agg.read(taskID: nil, family: nil).mean > old)
        #expect(agg.reconcile(samples: [sample]) == 0)
        agg.reconcile(samples: [])
        #expect(agg.read(taskID: nil, family: nil).mean == defaultMean)
    }
}
