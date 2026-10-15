import Foundation
import Testing
import SwiftData
@testable import BetterCalendar

@MainActor @Suite struct NativeItemCommandTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: DataArchiveStore.schema, configurations: ModelConfiguration(schema: DataArchiveStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
    private func command(_ id: UUID, _ action: NativeItemCommand.Action, _ revision: String? = nil, patch: [String: BridgeJSON] = [:]) -> NativeItemCommand {
        .init(commandId: UUID(), recordId: id, action: action, expectedRevision: revision, patch: patch,
              occurredAt: Date(timeIntervalSince1970: 1000), userAuthorizationRef: "fixture-explicit-user-request")
    }
    @Test func actualStoreCreateUpdateTrashRestorePreserveIdentityAndChildren() throws {
        let c = try container(), context = c.mainContext, journal = NativeActionMemoryJournal()
        let writer = SwiftDataNativeItemWriter(context: context, journal: journal)
        let id = UUID(), create = command(id, .create, patch: ["title": .string("fixture"), "note": .string("original")])
        let saved = try writer.execute(create, userConfirmed: true)
        #expect(try writer.execute(create, userConfirmed: true) == saved)
        #expect(try context.fetchCount(FetchDescriptor<LongTask>()) == 1)
        let task = try #require(context.fetch(FetchDescriptor<LongTask>()).first)
        let stage = LongTaskCheckpoint(title: "original stage"); stage.task = task; context.insert(stage); try context.save()
        var record = try #require(writer.records().first)
        let update = command(id, .update, record.revision, patch: ["title": .string("changed"), "status": .string("shelved")])
        _ = try writer.execute(update, userConfirmed: true)
        #expect(task.title == "changed" && task.status == .shelved && stage.title == "original stage")
        record = try #require(writer.records().first)
        let delete = command(id, .delete, record.revision)
        _ = try writer.execute(delete, userConfirmed: true)
        #expect(task.isInTrash && task.deletionID == delete.commandId)
        #expect(task.retentionUntil == delete.occurredAt.addingTimeInterval(30 * 86400))
        record = try #require(writer.records().first)
        _ = try writer.execute(command(id, .restore, record.revision), userConfirmed: true)
        #expect(!task.isInTrash && task.id == id && stage.task?.id == id && stage.title == "original stage")
    }
    @Test func everyItemMutationSurvivesLostReceiptRestartAndDuplicateWithoutRepeatingEffect() throws {
        let c = try container(), journal = FaultJournal(), id = UUID()
        let steps: [(NativeItemCommand.Action, [String: BridgeJSON])] = [
            (.create, ["title": .string("BC ISOLATED LIFECYCLE"), "note": .string("fixture")]),
            (.update, ["title": .string("BC ISOLATED RENAMED"), "note": .string("changed")]),
            (.update, ["status": .string("done")]), (.update, ["status": .string("active")]),
            (.delete, [:]), (.restore, [:])]
        for (action, patch) in steps {
            let writer = SwiftDataNativeItemWriter(context: ModelContext(c), journal: journal)
            let previous = try writer.records().first
            let request = command(id, action, action == .create ? nil : previous?.revision, patch: patch)
            journal.failAt = journal.saves + 2 // Effect saved, applied receipt lost.
            #expect(throws: Error.self) { try writer.execute(request, userConfirmed: true) }
            #expect(journal.entries.last?.phase == "prepared")
            let restarted = SwiftDataNativeItemWriter(context: ModelContext(c), journal: journal)
            let recovered = try restarted.execute(request, userConfirmed: true)
            let state = try #require(restarted.records().first)
            #expect(try restarted.execute(request, userConfirmed: true) == recovered)
            #expect(try restarted.records().first?.revision == state.revision)
            #expect(try ModelContext(c).fetchCount(FetchDescriptor<LongTask>()) == 1)
            #expect(journal.entries.last?.phase == "applied")
        }
        let final = try #require(ModelContext(c).fetch(FetchDescriptor<LongTask>()).first)
        #expect(final.id == id && !final.isInTrash && final.status == .active)
        #expect(final.title == "BC ISOLATED RENAMED" && final.note == "changed")
        #expect(journal.entries.count == steps.count)
    }

    @Test func editingCompletedTitleDoesNotRewriteTheOriginalAchievementTime() throws {
        let c = try container(), context = c.mainContext
        let completedAt = Date(timeIntervalSince1970: 50)
        let task = LongTask(title: "done", status: .done, doneAt: completedAt)
        context.insert(task); try context.save()
        let writer = SwiftDataNativeItemWriter(context: context, journal: NativeActionMemoryJournal())
        let record = try #require(writer.records().first)
        _ = try writer.execute(command(task.id, .update, record.revision, patch: ["title": .string("renamed"), "status": .string("done")]), userConfirmed: true)
        #expect(task.title == "renamed" && task.doneAt == completedAt)
    }
    @Test func externalChangesConflictAndRejectedPatchesDoNotPartiallyModify() throws {
        let c = try container(), context = c.mainContext, task = LongTask(title: "confirmed")
        context.insert(task); try context.save()
        let writer = SwiftDataNativeItemWriter(context: context, journal: NativeActionMemoryJournal())
        let old = try #require(writer.records().first)
        task.note = "direct external edit without modifiedAt"; try context.save()
        #expect(throws: (any Error).self) { try writer.execute(command(task.id, .update, old.revision, patch: ["title": .string("stale")]), userConfirmed: true) }
        var current = try #require(writer.records().first)
        #expect(throws: (any Error).self) { try writer.execute(command(task.id, .update, current.revision, patch: ["title": .string("must roll back"), "status": .string("invalid")]), userConfirmed: true) }
        #expect(task.title == "confirmed" && task.note == "direct external edit without modifiedAt" && !context.hasChanges)
        current = try #require(writer.records().first)
        #expect(throws: (any Error).self) { try writer.execute(command(task.id, .delete, current.revision), userConfirmed: true) } // Existing longterm policy.
        #expect(!task.isInTrash)
        var inferred = command(task.id, .update, current.revision, patch: ["title": .string("inference")]); inferred.provenance = "inferred"
        #expect(throws: (any Error).self) { try writer.execute(inferred, userConfirmed: true) }
        #expect(throws: (any Error).self) { try writer.execute(command(task.id, .update, current.revision), userConfirmed: false) }
        task.title = "unsaved"
        #expect(throws: (any Error).self) { try writer.records() }
        #expect(task.title == "unsaved") // Does not roll back someone else's edit.
    }
    @Test func persistedEffectWithLostReceiptRecoversSameCommandAfterRestart() throws {
        let c = try container(), context = c.mainContext, journal = FaultJournal()
        let create = command(UUID(), .create, patch: ["title": .string("one creation")])
        let writer = SwiftDataNativeItemWriter(context: context, journal: journal)
        journal.failAt = 2
        #expect(throws: (any Error).self) { try writer.execute(create, userConfirmed: true) }
        #expect(try context.fetchCount(FetchDescriptor<LongTask>()) == 1 && journal.entries.first?.phase == "prepared")
        let restarted = SwiftDataNativeItemWriter(context: ModelContext(c), journal: journal)
        let receipt = try restarted.execute(create, userConfirmed: true)
        #expect(journal.entries.first?.phase == "applied")
        #expect(try restarted.execute(create, userConfirmed: true) == receipt)
        #expect(try context.fetchCount(FetchDescriptor<LongTask>()) == 1)
        var changed = create; changed.patch["title"] = .string("changed same id")
        #expect(throws: (any Error).self) { try restarted.execute(changed, userConfirmed: true) }
    }
    @Test func failedIntentOrStoreSaveCannotClaimSuccessOrLoseUnrelatedContent() throws {
        let c = try container(), context = c.mainContext, journal = FaultJournal()
        let task = LongTask(title: "original"); context.insert(task); try context.save()
        var failSave = true
        let writer = SwiftDataNativeItemWriter(context: context, journal: journal, saveContext: {
            if failSave { throw URLError(.cannotWriteToFile) }; try context.save()
        })
        let record = try #require(writer.records().first)
        let update = command(task.id, .update, record.revision, patch: ["title": .string("new")])
        journal.failAt = 1
        #expect(throws: (any Error).self) { try writer.execute(update, userConfirmed: true) }
        #expect(task.title == "original" && !context.hasChanges && journal.entries.isEmpty)
        journal.failAt = -1
        #expect(throws: (any Error).self) { try writer.execute(update, userConfirmed: true) }
        #expect(task.title == "original" && !context.hasChanges && journal.entries.first?.phase == "prepared")
        failSave = false; _ = try writer.execute(update, userConfirmed: true)
        #expect(task.title == "new" && journal.entries.first?.phase == "applied")
    }
    @Test func lateChangeAfterUnknownEffectIsNotOverwrittenOnRetry() throws {
        let c = try container(), context = c.mainContext, journal = FaultJournal()
        let create = command(UUID(), .create, patch: ["title": .string("first")])
        let writer = SwiftDataNativeItemWriter(context: context, journal: journal); journal.failAt = 2
        #expect(throws: (any Error).self) { try writer.execute(create, userConfirmed: true) }
        let task = try #require(context.fetch(FetchDescriptor<LongTask>()).first)
        task.title = "user changed later"; try context.save()
        #expect(throws: (any Error).self) { try writer.execute(create, userConfirmed: true) }
        #expect(task.title == "user changed later" && journal.entries.first?.phase == "prepared")
    }
    @Test func corruptJournalRemainsUnchangedAndUnsupportedAlarmHasNoNotificationFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("journal.json"), bytes = Data("not json".utf8)
        try bytes.write(to: file)
        let journal = NativeActionFileJournal(file: file)
        #expect(throws: (any Error).self) { try journal.load() }
        #expect(try Data(contentsOf: file) == bytes)
        let alarms = UnsupportedNativeAlarms()
        #expect(!alarms.inspect().supported)
        await #expect(throws: (any Error).self) { try await alarms.schedule(.init(commandId: UUID(), fireAt: .now.addingTimeInterval(60), title: "fixture", userAuthorizationRef: "explicit"), userConfirmed: true) }
        #expect(try alarms.recordedAlarms().isEmpty)
    }
}
@MainActor private final class FaultJournal: NativeActionJournaling {
    var entries: [NativeActionEntry] = []
    var saves = 0
    var failAt = -1
    func load() throws -> [NativeActionEntry] { entries }
    func save(_ entries: [NativeActionEntry]) throws {
        saves += 1
        if saves == failAt { throw URLError(.cannotWriteToFile) }
        self.entries = entries
    }
}

