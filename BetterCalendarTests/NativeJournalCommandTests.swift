import Foundation
import Testing
import SwiftData
@testable import BetterCalendar

@MainActor @Suite struct NativeJournalCommandTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: DataArchiveStore.schema, configurations: ModelConfiguration(schema: DataArchiveStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
    private func command(_ id: UUID, _ action: NativeJournalCommand.Action, revision: String? = nil,
                         date: Date? = nil, patch: [String: BridgeJSON]) -> NativeJournalCommand {
        .init(commandId: UUID(), recordId: id, action: action, entryDate: date, expectedRevision: revision,
              patch: patch, occurredAt: Date(timeIntervalSince1970: 200000), userAuthorizationRef: "fixture-explicit-confirmation")
    }
    private func revision(_ entry: JournalEntry) throws -> String {
        BridgePoolCodec.hash(try BridgePoolCodec.encode(SwiftDataNativeJournal.values(entry)))
    }
    @Test func actualStoreCreateEditRecoverOriginalPreservesPhotosAndFormat() throws {
        let c = try container(), context = c.mainContext, log = NativeActionMemoryJournal()
        let service = SwiftDataNativeJournal(context: context, journal: log)
        let id = UUID(), date = Date(timeIntervalSince1970: 100000)
        let create = command(id, .create, date: date, patch: ["body": .string("original feeling"), "mood": .string("calm"), "tags": .array([.string("fixture")])])
        let receipt = try service.execute(create, userConfirmed: true)
        #expect(try service.execute(create, userConfirmed: true) == receipt)
        let entry = try #require(context.fetch(FetchDescriptor<JournalEntry>()).first)
        let bytes = Data([0,1,2,3,4]), photo = JournalPhoto(ref: "fixture-photo", data: bytes)
        context.insert(photo); entry.photoRefs = [photo.ref]; try context.save()
        let original = try SwiftDataNativeJournal.values(entry)
        _ = try service.execute(command(id, .update, revision: revision(entry), patch: ["body": .string("new wording"), "mood": .null]), userConfirmed: true)
        #expect(entry.body == "new wording" && entry.mood == nil && entry.date == date)
        #expect(entry.photoRefs == [photo.ref] && photo.data == bytes && entry.bodyFormat == "markdown")
        #expect(log.entries.last?.before == original)
        _ = try service.execute(command(id, .update, revision: revision(entry), patch: ["body": .string("original feeling"), "mood": .string("calm")]), userConfirmed: true)
        #expect(entry.body == "original feeling" && entry.photoRefs == [photo.ref] && photo.data == bytes)
        #expect(try context.fetchCount(FetchDescriptor<JournalEntry>()) == 1)
    }
    @Test func readPermissionDoesNotCreateEntriesAndPaginationDetectsDirectEdits() throws {
        let c = try container(), context = c.mainContext
        for n in 0..<3 {
            context.insert(JournalEntry(date: Date(timeIntervalSince1970: Double(n + 1) * 86400), body: "find fixture \(n)", tags: ["tag"]))
        }
        try context.save()
        let service = SwiftDataNativeJournal(context: context, journal: NativeActionMemoryJournal())
        #expect(throws: (any Error).self) { try service.read(.init(), readAllowed: false) }
        let first = try NativeRemoteJSON.object(service.read(.init(text: "fixture", limit: 1), readAllowed: true))
        #expect(first["matchingCount"] == .number(3) && first["hasMore"] == .bool(true) && first["complete"] == .bool(false))
        let cursor = try NativeRemoteJSON.string(first["nextCursor"])
        let second = try NativeRemoteJSON.object(service.read(.init(text: "fixture", limit: 1, cursor: cursor), readAllowed: true))
        #expect(second["hasMore"] == .bool(true))
        let final = try NativeRemoteJSON.object(service.read(.init(text: "fixture", limit: 1, cursor: NativeRemoteJSON.string(second["nextCursor"])), readAllowed: true))
        #expect(final["complete"] == .bool(true) && final["nextCursor"] == .null)
        #expect(throws: (any Error).self) { try service.read(.init(text: "tag", cursor: cursor), readAllowed: true) }
        let entry = try #require(context.fetch(FetchDescriptor<JournalEntry>()).first)
        entry.body = "direct edit without modifiedAt fixture"; try context.save()
        #expect(throws: (any Error).self) { try service.read(.init(text: "fixture", cursor: cursor), readAllowed: true) }
        #expect(try context.fetchCount(FetchDescriptor<JournalEntry>()) == 3)
    }
    @Test func explicitWindowTrashAndPhotoCoverageAreTruthful() throws {
        let c = try container(), context = c.mainContext
        let a = JournalEntry(date: Date(timeIntervalSince1970: 100), body: "inside", photoRefs: ["not-retrieved"])
        let b = JournalEntry(date: Date(timeIntervalSince1970: 200), body: "end excluded")
        let trash = JournalEntry(date: Date(timeIntervalSince1970: 150), body: "retained")
        trash.deletedAt = Date(timeIntervalSince1970: 300); trash.deletionID = UUID()
        for entry in [a,b,trash] { context.insert(entry) }; try context.save()
        let service = SwiftDataNativeJournal(context: context, journal: NativeActionMemoryJournal())
        let page = try NativeRemoteJSON.object(service.read(.init(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200)), readAllowed: true))
        #expect(page["matchingCount"] == .number(1))
        let coverage = try NativeRemoteJSON.object(page["coverage"] ?? .null)
        #expect(coverage["photoBinaries"] == .string("not_requested_or_retrieved") && coverage["otherDevicesSync"] == .string("unknown"))
        let withTrash = try NativeRemoteJSON.object(service.read(.init(includeTrash: true), readAllowed: true))
        #expect(withTrash["matchingCount"] == .number(3))
        #expect(throws: (any Error).self) { try service.execute(command(trash.id, .update, revision: revision(trash), patch: ["body": .string("must not edit trash")]), userConfirmed: true) }
        #expect(trash.body == "retained" && trash.isInTrash)
    }
    @Test func conflictsInvalidPatchAndUnsupportedFormatPreserveAllContent() throws {
        let c = try container(), context = c.mainContext
        let entry = JournalEntry(date: Date(timeIntervalSince1970: 100), body: "before", photoRefs: ["photo"])
        context.insert(entry); try context.save()
        let service = SwiftDataNativeJournal(context: context, journal: NativeActionMemoryJournal())
        let old = try revision(entry); entry.body = "external edit"; try context.save()
        #expect(throws: (any Error).self) { try service.execute(command(entry.id, .update, revision: old, patch: ["body": .string("stale")]), userConfirmed: true) }
        #expect(throws: (any Error).self) { try service.execute(command(entry.id, .update, revision: revision(entry), patch: ["body": .string("partial"), "tags": .array([.number(1)])]), userConfirmed: true) }
        #expect(throws: (any Error).self) { try service.execute(command(entry.id, .update, revision: revision(entry), patch: ["photoRefs": .array([])]), userConfirmed: true) }
        #expect(entry.body == "external edit" && entry.photoRefs == ["photo"] && !context.hasChanges)
        var inferred = command(entry.id, .update, revision: try revision(entry), patch: ["body": .string("inference")]); inferred.provenance = "inferred"
        #expect(throws: (any Error).self) { try service.execute(inferred, userConfirmed: true) }
        #expect(throws: (any Error).self) { try service.execute(command(entry.id, .update, revision: revision(entry), patch: ["body": .string("no consent")]), userConfirmed: false) }
        entry.bodyFormat = "richText"; try context.save()
        #expect(throws: (any Error).self) { try service.execute(command(entry.id, .update, revision: revision(entry), patch: ["body": .string("unsupported")]), userConfirmed: true) }
        #expect(entry.body == "external edit" && entry.bodyFormat == "richText")
        entry.body = "unsaved"
        #expect(throws: (any Error).self) { try service.read(.init(), readAllowed: true) }
        #expect(entry.body == "unsaved")
    }
    @Test func failedSaveRetriesSameIdentityAndLostReceiptRecoversAfterRestart() throws {
        let c = try container(), context = c.mainContext, log = JournalFaultLog()
        let request = command(UUID(), .create, date: Date(timeIntervalSince1970: 100), patch: ["body": .string("exactly once")])
        var failStore = true
        let service = SwiftDataNativeJournal(context: context, journal: log, saveContext: {
            if failStore { throw URLError(.cannotWriteToFile) }; try context.save()
        })
        log.failAt = 1
        #expect(throws: (any Error).self) { try service.execute(request, userConfirmed: true) }
        #expect(try context.fetchCount(FetchDescriptor<JournalEntry>()) == 0 && log.entries.isEmpty)
        log.failAt = -1
        #expect(throws: (any Error).self) { try service.execute(request, userConfirmed: true) }
        #expect(try context.fetchCount(FetchDescriptor<JournalEntry>()) == 0 && log.entries.first?.phase == "prepared")
        failStore = false; log.failAt = log.saves + 1
        #expect(throws: (any Error).self) { try service.execute(request, userConfirmed: true) }
        #expect(try context.fetchCount(FetchDescriptor<JournalEntry>()) == 1 && log.entries.first?.phase == "prepared")
        let restarted = SwiftDataNativeJournal(context: ModelContext(c), journal: log)
        let receipt = try restarted.execute(request, userConfirmed: true)
        #expect(try restarted.execute(request, userConfirmed: true) == receipt && log.entries.first?.phase == "applied")
        #expect(try context.fetchCount(FetchDescriptor<JournalEntry>()) == 1)
        var different = request; different.patch["body"] = .string("changed command")
        #expect(throws: (any Error).self) { try restarted.execute(different, userConfirmed: true) }
    }
    @Test func concurrentSameDayAndLateChangesAreNotOverwritten() throws {
        let c = try container(), context = c.mainContext, log = JournalFaultLog()
        let day = Date(timeIntervalSince1970: 100)
        let request = command(UUID(), .create, date: day, patch: ["body": .string("first")])
        var fail = true
        let service = SwiftDataNativeJournal(context: context, journal: log, saveContext: {
            if fail { throw URLError(.cannotWriteToFile) }; try context.save()
        })
        #expect(throws: (any Error).self) { try service.execute(request, userConfirmed: true) }
        let later = JournalEntry(date: day.addingTimeInterval(3600), body: "later same logical day")
        context.insert(later); try context.save(); fail = false
        #expect(throws: (any Error).self) { try service.execute(request, userConfirmed: true) }
        #expect(try context.fetchCount(FetchDescriptor<JournalEntry>()) == 1 && later.body == "later same logical day")
        let update = command(later.id, .update, revision: try revision(later), patch: ["body": .string("changed")])
        log.failAt = log.saves + 2
        #expect(throws: (any Error).self) { try service.execute(update, userConfirmed: true) }
        later.body = "user wrote after unknown effect"; try context.save()
        let restarted = SwiftDataNativeJournal(context: ModelContext(c), journal: log)
        #expect(throws: (any Error).self) { try restarted.execute(update, userConfirmed: true) }
        #expect(later.body == "user wrote after unknown effect")
    }
    @Test func pagingHonorsByteLimitWithoutTruncationAndRejectsOversizedSingleEntry() throws {
        let c = try container(), context = c.mainContext
        for n in 0..<3 { context.insert(JournalEntry(date: Date(timeIntervalSince1970: Double(n) * 86400), body: String(repeating: "a", count: 15000))) }
        try context.save()
        let service = SwiftDataNativeJournal(context: context, journal: NativeActionMemoryJournal())
        let first = try NativeRemoteJSON.object(service.read(.init(), readAllowed: true))
        #expect(first["hasMore"] == .bool(true))
        let records = try #require({ if case let .array(a) = first["records"] { return a }; return nil }())
        #expect(records.count == 2)
        for record in records { let v = try NativeRemoteJSON.object(NativeRemoteJSON.object(record)["values"] ?? .null); #expect(try NativeRemoteJSON.string(v["body"]).count == 15000) }
        let entry = try #require(context.fetch(FetchDescriptor<JournalEntry>()).first)
        entry.body = String(repeating: "x", count: 40000); try context.save()
        #expect(throws: (any Error).self) { try service.read(.init(), readAllowed: true) }
        #expect(entry.body.count == 40000)
    }
    @Test func subMillisecondDatesAndTamperedPreparedIntentRemainSafe() throws {
        let c = try container(), context = c.mainContext, log = JournalFaultLog()
        var request = command(UUID(), .create, date: Date(timeIntervalSince1970: 1791868682.866779), patch: ["body": .string("precision")])
        request.occurredAt = Date(timeIntervalSince1970: 1791868690.123456)
        let service = SwiftDataNativeJournal(context: context, journal: log)
        _ = try service.execute(request, userConfirmed: true)
        let entry = try #require(context.fetch(FetchDescriptor<JournalEntry>()).first)
        let date = entry.date, created = entry.createdAt
        let update = command(entry.id, .update, revision: try revision(entry), patch: ["body": .string("changed")])
        log.failAt = log.saves + 2
        #expect(throws: (any Error).self) { try service.execute(update, userConfirmed: true) }
        #expect(entry.date == date && entry.createdAt == created)
        let i = try #require(log.entries.firstIndex { $0.commandId == update.commandId })
        var corrupted = try NativeRemoteJSON.object(log.entries[i].proposed ?? .null)
        corrupted["body"] = .string("tampered snapshot")
        log.entries[i].proposed = .object(corrupted)
        #expect(throws: (any Error).self) { try service.execute(update, userConfirmed: true) }
        #expect(entry.body == "changed" && !context.hasChanges)
    }
    @Test func fileJournalAcceptsVersionedJournalIntentAndPreservesPrivateOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("native-actions.json")
        let log = NativeActionFileJournal(file: file)
        let c = try container(), service = SwiftDataNativeJournal(context: c.mainContext, journal: log)
        _ = try service.execute(command(UUID(), .create, date: Date(timeIntervalSince1970: 100), patch: ["body": .string("fixture private text")]), userConfirmed: true)
        let original = try log.load()
        #expect(original.count == 1 && original[0].kind == "journal" && original[0].phase == "applied")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try log.load() == original)
    }
}
@MainActor private final class JournalFaultLog: NativeActionJournaling {
    var entries: [NativeActionEntry] = [], saves = 0, failAt = -1
    func load() throws -> [NativeActionEntry] { entries }
    func save(_ entries: [NativeActionEntry]) throws {
        saves += 1; if saves == failAt { throw URLError(.cannotWriteToFile) }; self.entries = entries
    }
}
