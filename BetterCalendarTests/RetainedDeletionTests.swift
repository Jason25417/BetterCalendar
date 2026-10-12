import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

@MainActor @Suite struct RetainedDeletionTests {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)
    private func container() throws -> ModelContainer {
        try ModelContainer(for: DataArchiveStore.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
    private func service(_ context: ModelContext, _ calendar: CalendarStore) -> RetainedTrashService {
        RetainedTrashService(context: context, calendar: calendar,
            projection: ProjectionService(planStore: PlanStore(context: context), calendarStore: calendar))
    }

    @Test func deleteRetainsOriginalIdentityAndNeverRecreatesIt() throws {
        let c = try container(), context = c.mainContext
        let store = PlanStore(context: context)
        let block = ScheduledBlock(title: "原文", start: time, end: time.addingTimeInterval(600))
        let day = DayContext.logicalStartOfDay(time)
        try store.replacePlanned([block], on: day)
        let row = try #require(context.fetch(FetchDescriptor<PlanBlock>()).first)
        let identity = row.persistentModelID
        try store.deletePlanned(ids: [block.id])
        #expect(try store.plannedBlocks(on: day).isEmpty)
        #expect(row.isInTrash && row.persistentModelID == identity && row.title == "原文")
        #expect(try context.fetchCount(FetchDescriptor<PlanBlock>()) == 1)
        #expect(throws: (any Error).self) { try store.insertPlanned([block]) }
        #expect(try store.deletedPlannedIDs(on: day) == [block.id])
        #expect(row.retentionUntil?.timeIntervalSince(row.deletedAt!) == Double(30 * 86_400))
    }

    @Test func olderRestoreCannotAcknowledgeNewDeletionDespiteClockSkew() throws {
        let row = LongTask(title: "原记录")
        row.markDeleted(at: time)
        let first = try #require(row.deletionID)
        row.markDeleted(at: time.addingTimeInterval(600))
        #expect(row.deletionID == first && row.deletedAt == time)
        try row.acknowledgeRestoration(expected: first)
        row.markDeleted(at: time.addingTimeInterval(-500))
        #expect(row.isInTrash && row.deletionID != first)
        #expect(throws: (any Error).self) { try row.acknowledgeRestoration(expected: first) }
        #expect(row.isInTrash)
    }

    @Test func parentDeletionPreservesCheckpointsAndTheirIndependentDeletion() async throws {
        let c = try container(), context = c.mainContext
        let task = LongTask(title: "待办", zone: .todo)
        let cp = LongTaskCheckpoint(title: "阶段")
        context.insert(task); context.insert(cp); cp.task = task; try context.save()
        let store = LongTaskStore(context: context)
        store.deleteCheckpoint(cp); store.discard(task)
        #expect(store.todos.isEmpty && task.checkpoints?.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<LongTaskCheckpoint>()) == 1)
        let trash = service(context, FakeCalendarStore())
        let cpItem = try #require(trash.entries().first { $0.category == "阶段" })
        await #expect(throws: (any Error).self) { try await trash.restore(cpItem) }
        let taskItem = try #require(trash.entries().first { $0.category == "待办／长期事项" })
        try await trash.restore(taskItem); store.reload()
        #expect(store.todos.count == 1 && task.sortedCheckpoints.isEmpty)
        try await trash.restore(cpItem)
        #expect(task.sortedCheckpoints.count == 1)
    }

    @Test func photoRestoresOwnerPositionAndBytesWithoutDroppingLaterEdits() async throws {
        let c = try container(), context = c.mainContext
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photos = PhotoStore(context: context, directory: dir)
        let bytes = Data([0, 1, 2, 255])
        let ref = try #require(photos.save(bytes))
        let entry = JournalEntry(date: time, body: "原日记", photoRefs: ["before.jpg", ref, "after.jpg"])
        context.insert(entry); try context.save()
        #expect(photos.delete(ref))
        entry.photoRefs.removeAll { $0 == ref }; entry.body = "后来的正文"
        entry.photoRefs.append("new.jpg"); try context.save()
        #expect(photos.data(for: ref) == nil)
        #expect(FileManager.default.fileExists(atPath: photos.url(for: ref).path))
        let trash = service(context, FakeCalendarStore())
        try await trash.restore(#require(trash.entries().first { $0.category == "照片" }))
        #expect(photos.data(for: ref) == bytes)
        #expect(entry.photoRefs == ["before.jpg", ref, "after.jpg", "new.jpg"])
        #expect(entry.body == "后来的正文")
    }

    @Test func journalRestoreDoesNotAutomaticallyRestoreIndependentlyDeletedPhoto() async throws {
        let c = try container(), context = c.mainContext
        let entry = JournalEntry(date: time, body: "日记", photoRefs: ["original.jpg"])
        let photo = JournalPhoto(ref: "original.jpg", data: Data([23]))
        context.insert(entry); context.insert(photo); try context.save()
        try RetainedDeletion.save([photo], in: context, at: time)
        JournalStore(context: context).delete(entry)
        let trash = service(context, FakeCalendarStore())
        try await trash.restore(#require(trash.entries().first { $0.category == "日记" }))
        #expect(!entry.isInTrash && photo.isInTrash && entry.photoRefs == ["original.jpg"])
    }

    @Test func projectionDoesNotPassThroughDeletedDeviceEvent() async throws {
        let c = try container(), context = c.mainContext
        let store = PlanStore(context: context), cal = FakeCalendarStore()
        let block = ScheduledBlock(title: "跨端旧事件", start: time, end: time.addingTimeInterval(600))
        let day = DayContext.logicalStartOfDay(time)
        try store.replacePlanned([block], on: day)
        try await cal.write([CalendarEventDraft(title: block.title, start: block.start, end: block.end, kind: .planned, blockID: block.id)])
        try store.deletePlanned(ids: [block.id])
        ProjectionFingerprints.set(day, [:])
        defer { ProjectionFingerprints.set(day, [:]) }
        try await ProjectionService(planStore: store, calendarStore: cal).project(label: day)
        #expect(try await cal.read(kind: .planned).isEmpty)
        let trash = service(context, cal)
        try await trash.restore(#require(trash.entries().first))
        #expect(try store.plannedBlocks(on: day).map(\.id) == [block.id])
        #expect(try await cal.read(kind: .planned).map(\.blockID) == [block.id])
    }

    @Test func failedCalendarRestoreLeavesRecordRecoverable() async throws {
        let c = try container(), context = c.mainContext
        let row = PlanBlock(title: "保留", start: time, end: time.addingTimeInterval(600), kind: .actual)
        context.insert(row); try RetainedDeletion.save([row], in: context)
        let cal = FailingRestoreCalendar()
        let trash = service(context, cal)
        await #expect(throws: (any Error).self) { try await trash.restore(#require(trash.entries().first)) }
        #expect(row.isInTrash && row.title == "保留" && row.restoredDeletionID == nil)
    }

    @Test func actualRestorePreservesOtherCalendarEvents() async throws {
        let c = try container(), context = c.mainContext
        let row = PlanBlock(title: "恢复", start: time, end: time.addingTimeInterval(600), kind: .actual)
        context.insert(row); try RetainedDeletion.save([row], in: context)
        let cal = FakeCalendarStore(), other = UUID()
        try await cal.write([CalendarEventDraft(title: "另一个", start: time.addingTimeInterval(900), end: time.addingTimeInterval(1200), kind: .actual, blockID: other)])
        let trash = service(context, cal)
        try await trash.restore(#require(trash.entries().first))
        #expect(!row.isInTrash)
        #expect(try await Set(cal.read(kind: .actual).compactMap(\.blockID)) == [other, row.id])
    }

    @Test func duplicateActiveIdentityBlocksRestoration() async throws {
        let c = try container(), context = c.mainContext
        let a = LongTask(title: "删除的"), b = LongTask(title: "并发的")
        b.id = a.id
        context.insert(a); context.insert(b); try RetainedDeletion.save([a], in: context)
        let trash = service(context, FakeCalendarStore())
        await #expect(throws: (any Error).self) { try await trash.restore(#require(trash.entries().first)) }
        #expect(a.isInTrash && !b.isInTrash && b.title == "并发的")
    }

    @Test func versionOneArchiveUpgradesWithoutDroppingContentAndTrashRoundTrips() throws {
        let c = try container(), context = c.mainContext
        let row = LongTask(title: "旧记录", note: "保留原文")
        context.insert(row); try context.save()
        var legacy = try DataArchiveStore.capture(context)
        legacy.formatVersion = 1
        for i in legacy.records.indices {
            for name in DataArchiveStore.retentionFields { legacy.records[i].values.removeValue(forKey: name) }
        }
        let original = try ArchiveCodec.encoder().encode(legacy)
        try DataArchiveStore.validateRestoration(legacy)
        #expect(try ArchiveCodec.encoder().encode(legacy) == original)
        try RetainedDeletion.save([row], in: context, at: time.addingTimeInterval(-60 * 86_400))
        let retained = try DataArchiveStore.capture(context)
        #expect(retained.formatVersion == 2)
        try DataArchiveStore.validateRestoration(retained)
        let restored = try container()
        try DataArchiveStore.restore(retained, into: restored.mainContext)
        let result = try #require(restored.mainContext.fetch(FetchDescriptor<LongTask>()).first)
        #expect(result.isInTrash && result.deletionID == row.deletionID && result.note == "保留原文")
        #expect(result.retentionUntil! < time, "30天后也不自动物理清除")
    }

    @Test func failedActualReadNeverDeletesRecordedTime() async throws {
        let c = try container(), context = c.mainContext
        let plan = PlanStore(context: context)
        let now = Date.now, id = UUID()
        try plan.upsertActuals([ActualBlock(id: id, title: "已做", start: now.addingTimeInterval(-600), end: now)])
        let vm = ExecutionViewModel(calendarStore: FailingRestoreCalendar(),
            reschedule: RescheduleService(planStore: plan, planner: NaivePlanningEngine()),
            planStore: plan, reminderStore: FakeReminderStore(), liveActivity: NoLiveActivity(), persistsRunState: false)
        await vm.reconcileCalendarActuals()
        #expect(try plan.actualBlocks(on: DayContext.logicalStartOfDay(now)).map(\.id) == [id])
    }

    @Test func suppliedLegacySQLiteUpgradesInIsolation() throws {
        guard let path = ProcessInfo.processInfo.environment["BC_LEGACY_SQLITE"] else { return }
        let config = ModelConfiguration(schema: DataArchiveStore.schema,
            url: URL(fileURLWithPath: path), cloudKitDatabase: .none)
        let upgraded = try ModelContainer(for: DataArchiveStore.schema, configurations: config)
        let archive = try DataArchiveStore.capture(upgraded.mainContext)
        #expect(archive.records.count >= 432)
        if let output = ProcessInfo.processInfo.environment["BC_UPGRADE_ARCHIVE_OUTPUT"] {
            let file = URL(fileURLWithPath: output)
            try ArchiveCodec.encoder().encode(SealedDataArchive(archive)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output)
        }
        #expect(try upgraded.mainContext.fetchCount(FetchDescriptor<PlanBlock>()) == 268)
        #expect(try upgraded.mainContext.fetchCount(FetchDescriptor<ExecutionSession>()) == 70)
        #expect(try upgraded.mainContext.fetchCount(FetchDescriptor<JournalEntry>()) == 19)
        #expect(try upgraded.mainContext.fetchCount(FetchDescriptor<JournalPhoto>()) == 2)
        #expect(try upgraded.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 25)
        #expect(try upgraded.mainContext.fetchCount(FetchDescriptor<LongTaskCheckpoint>()) == 9)
        #expect(try service(upgraded.mainContext, FakeCalendarStore()).entries().isEmpty)
        if let originalPath = ProcessInfo.processInfo.environment["BC_LEGACY_ARCHIVE"] {
            let original = try ArchiveCodec.decoder().decode(SealedDataArchive.self,
                from: Data(contentsOf: URL(fileURLWithPath: originalPath))).verified()
            // Logs can advance between backups. Business content, checkpoint
            // ownership and external photo bytes must remain exactly readable.
            let entities: Set<String> = ["PlanBlock", "ExecutionSession", "LongTask", "LongTaskCheckpoint", "JournalEntry", "JournalPhoto"]
            let oldRows = original.records.filter { entities.contains($0.entity) }
            let newRows = archive.records.filter { entities.contains($0.entity) }
            func content(_ rows: [DataArchiveRecord]) throws -> [String] {
                let parents = Dictionary(uniqueKeysWithValues: rows.filter { $0.entity == "LongTask" }.map { ($0.key, $0) })
                return try rows.map { row in
                    var values = row.values.filter { !DataArchiveStore.retentionFields.contains($0.key) }
                    // Isolated ModelConfiguration changes store URI identities.
                    // Compare the exact referenced parent content, not its URI.
                    if row.entity == "LongTaskCheckpoint", let parentKey: String = try row.get("taskKey"),
                       let parent = parents[parentKey] {
                        values["taskKey"] = .object(parent.values.filter { !DataArchiveStore.retentionFields.contains($0.key) })
                    }
                    return row.entity + ":" + ArchiveCodec.digest(try ArchiveCodec.encoder().encode(values))
                }.sorted()
            }
            #expect(try content(oldRows) == content(newRows))
        }
        try DataArchiveStore.validateRestoration(archive)
        print("LEGACY_SQLITE_UPGRADE_VERIFIED records=\(archive.records.count)")
    }

    @Test func recoverySchemaSentinelsAreIdempotentAndCleanupPreservesUserRows() throws {
        let c = try container(), context = c.mainContext
        let user = LongTask(title: CloudKitSchemaSeeder.retainedTitle)
        context.insert(user); try context.save()
        #expect(try CloudKitSchemaSeeder.seedRetainedDeletion(in: context).count == 5)
        try context.save()
        #expect(try CloudKitSchemaSeeder.seedRetainedDeletion(in: context).isEmpty)
        let archive = try DataArchiveStore.capture(context)
        for row in archive.records where row.values["deletionID"] != .null {
            #expect(DataArchiveStore.retentionFields.allSatisfy { row.values[$0] != .null })
        }
        #expect(try CloudKitSchemaSeeder.cleanupRetainedDeletion(in: context) == 5)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<LongTask>()) == 1)
        #expect(!user.isInTrash && user.title == CloudKitSchemaSeeder.retainedTitle)
    }

    /// Only runs against an explicitly supplied private fixture. Never opens or
    /// mutates the live user database and never prints its contents.
    @Test func suppliedLegacyArchiveCanBeReadByNewSchema() throws {
        guard let path = ProcessInfo.processInfo.environment["BC_LEGACY_ARCHIVE"] else { return }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let old = try ArchiveCodec.decoder().decode(SealedDataArchive.self, from: bytes).verified()
        #expect(old.formatVersion == 1 && !old.records.isEmpty)
        try DataArchiveStore.validateRestoration(old)
        print("LEGACY_ARCHIVE_VERIFIED records=\(old.records.count) format=\(old.formatVersion)")
    }
}

@MainActor private final class FailingRestoreCalendar: CalendarStore {
    func write(_ drafts: [CalendarEventDraft]) async throws { throw CalendarError(message: "fixture read unavailable") }
    func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft] { throw CalendarError(message: "fixture read unavailable") }
    func clear(kind: PlanCalendarKind) async throws { throw CalendarError(message: "fixture read unavailable") }
    func apply(_ drafts: [CalendarEventDraft], kind: PlanCalendarKind, window: DateInterval) async throws { throw CalendarError(message: "fixture read unavailable") }
}
