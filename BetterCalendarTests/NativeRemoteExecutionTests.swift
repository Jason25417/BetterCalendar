import Foundation
import Testing
import SwiftData
@testable import BetterCalendar

@MainActor @Suite struct NativeRemoteExecutionTests {
    private let at = Date(timeIntervalSince1970: 1791885600)
    private func envelope(commandId: String = UUID().uuidString.lowercased(), state: String = "queued") throws -> BridgeJSON {
        let r: BridgeJSON = .object(["version": .number(1), "commandId": .string(commandId), "deviceId": .string("fixture-device"),
            "kind": .string("item"), "action": .string("create"), "recordId": .string(UUID().uuidString.lowercased()),
            "patch": .object(["title": .string("ISOLATED FIXTURE 中文 / <script>")]),
            "occurredAt": NativeRemoteJSON.timestamp(at), "expiresAt": NativeRemoteJSON.timestamp(at.addingTimeInterval(3600)),
            "userRequest": .string("isolated fixture, never actual user intent")])
        return .object(["version": .number(1), "commandId": .string(commandId), "nativeCommandId": .string(commandId),
            "deviceId": .string("fixture-device"), "requestHash": .string(BridgePoolCodec.hash(try BridgePoolCodec.encode(r))),
            "request": r, "permission": .string("item.create"), "grantRevision": .number(1), "state": .string(state),
            "approvedAt": NativeRemoteJSON.timestamp(at), "expiresAt": NativeRemoteJSON.timestamp(at.addingTimeInterval(3600))])
    }
    private func fixture(_ envelope: BridgeJSON) throws -> (RemoteService, RemotePersistence, SwiftDataNativeItemWriter, ModelContainer) {
        let c = try ModelContainer(for: DataArchiveStore.schema, configurations: ModelConfiguration(schema: DataArchiveStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = RemotePersistence(); store.file.grant = .init(deviceId: "fixture-device", revision: 1, capabilities: ["item.create"], expiresAt: at.addingTimeInterval(86400), synchronized: true)
        let service = RemoteService(envelope); let writer = SwiftDataNativeItemWriter(context: c.mainContext, journal: NativeActionMemoryJournal())
        return (service, store, writer, c)
    }
    @Test func realStoreWriteAndLostResponseRetryAfterRestartNeverDuplicate() async throws {
        let (service, store, writer, c) = try fixture(envelope())
        service.loseReceiptResponse = true
        let first = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await first.poll()
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 1)
        #expect(store.file.requests.first?.phase == "result")
        let attempt = store.file.requests.first?.attemptId
        let restarted = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await restarted.poll(); await restarted.poll()
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 1)
        #expect(store.file.requests.first?.phase == "reported" && store.file.requests.first?.attemptId == attempt)
        #expect(service.receipts.count == 2 && service.receipts[0] == service.receipts[1])
        #expect(service.claims.count == 1)
        #expect(store.file.requests.first?.envelope != nil)
    }
    @Test func lostClaimResponseKeepsIdentityAndExecutesOnce() async throws {
        let (service, store, writer, c) = try fixture(envelope()); service.loseClaimResponse = true
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll(); #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
        await executor.poll(); #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 1)
        #expect(service.claims.count == 2 && service.claims[0] == service.claims[1])
    }
    @Test func entireMalformedPageAndLostLocalAttemptDoNotExecute() async throws {
        let good = try envelope(), (service, store, writer, c) = try fixture(good)
        var malformed = try NativeRemoteJSON.object(envelope()); malformed["requestHash"] = .string(String(repeating: "f", count: 64))
        service.extra = .object(malformed)
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll(); #expect(service.claims.isEmpty && store.file.requests.isEmpty)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
        service.extra = nil
        var dispatched = try NativeRemoteJSON.object(good); dispatched["state"] = .string("dispatching"); service.envelope = .object(dispatched)
        await executor.poll(); #expect(service.claims.isEmpty && store.file.requests.isEmpty)
    }
    @Test func localGrantRevokedDuringNetworkWaitAndPermissionVersionMismatch() async throws {
        let (service, store, writer, c) = try fixture(envelope())
        service.beforeClaimReturn = { store.file.grant?.capabilities = []; store.file.grant?.revision = 2 }
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll()
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
        #expect(store.file.requests.first?.outcome == "failed" && service.receipts.count == 1)
    }
    @Test func intentPersistenceFailurePreventsClaimAndEffect() async throws {
        let (service, store, writer, c) = try fixture(envelope()); store.failAt = 1
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll()
        #expect(service.claims.isEmpty && service.receipts.isEmpty)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
    }
    @Test func missingHumanServerConfirmationAndWrongTargetNeverWrite() async throws {
        var e = try NativeRemoteJSON.object(envelope()); e["approvedAt"] = .null
        let (service, store, writer, c) = try fixture(.object(e))
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll(); #expect(service.receipts.isEmpty && store.file.requests.first?.phase == "prepared")
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
        e["deviceId"] = .string("wrong-target"); service.envelope = .object(e)
        await executor.poll(); #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
    }
    @Test func offlineHumanRevocationImmediatelyLocksTheDevice() async throws {
        let (service, store, writer, c) = try fixture(envelope())
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.setCapabilities(items: false, alarm: false) // fixture service has no grant endpoint: offline/failure
        #expect(store.file.grant?.synchronized == false && executor.allowItems == false)
        await executor.poll(); #expect(service.claims.isEmpty)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
    }
    @Test func effectSavedButRemoteReceiptDiskFailureRecoversWithoutSecondWrite() async throws {
        let (service, store, writer, c) = try fixture(envelope()); store.failAt = 4
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll()
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 1)
        #expect(store.file.requests.first?.phase == "claimed" && service.receipts.isEmpty)
        await executor.poll()
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 1)
        #expect(store.file.requests.first?.phase == "reported" && service.receipts.count == 1)
        #expect(store.file.failures.count == 1)
    }
    private func journalEnvelope(_ action: String, approved: Bool = false, revision: String? = nil, recordId: UUID = UUID()) throws -> BridgeJSON {
        var e = try NativeRemoteJSON.object(envelope()), r = try NativeRemoteJSON.object(e["request"] ?? .null)
        r["kind"] = .string("journal"); r["action"] = .string(action); r.removeValue(forKey: "patch"); r.removeValue(forKey: "recordId")
        if action == "read" { r["query"] = .object(["text": .string("fixture"), "limit": .number(1)]) }
        else {
            r["recordId"] = .string(recordId.uuidString); r["patch"] = .object(["body": .string("ISOLATED JOURNAL FIXTURE")])
            if action == "create" { r["entryDate"] = NativeRemoteJSON.timestamp(at) }
            else if let revision { r["expectedRevision"] = .string(revision) }
        }
        e["permission"] = .string("journal." + action); e["approvedAt"] = approved ? NativeRemoteJSON.timestamp(at) : .null
        e["request"] = .object(r); e["requestHash"] = .string(BridgePoolCodec.hash(try BridgePoolCodec.encode(.object(r))))
        return .object(e)
    }
    @Test func journalReadHasIndependentGrantNoWriteConfirmationAndFrozenReceiptRetry() async throws {
        let (service, store, writer, c) = try fixture(journalEnvelope("read"))
        store.file.grant?.capabilities = ["journal.read"]
        let diary = JournalEntry(date: at, body: "original fixture", photoRefs: ["fixture-reference"])
        c.mainContext.insert(diary); try c.mainContext.save()
        let journal = SwiftDataNativeJournal(context: c.mainContext, journal: NativeActionMemoryJournal(), now: { self.at })
        service.loseReceiptResponse = true
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), journal: journal, now: { self.at })
        await executor.poll()
        #expect(store.file.requests.first?.phase == "result" && store.file.requests.first?.outcome == "applied")
        let original = try NativeRemoteJSON.object(store.file.requests[0].receipt ?? .null)
        #expect(original["source"] == .string("bc.native.journal") && original["complete"] == .bool(true))
        diary.body = "changed fixture after saved read"; try c.mainContext.save()
        let restarted = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), journal: journal, now: { self.at })
        await restarted.poll()
        #expect(service.receipts.count == 2 && service.receipts[0] == service.receipts[1])
        #expect(store.file.requests.first?.phase == "reported" && service.claims.count == 1)
        #expect(diary.body == "changed fixture after saved read" && diary.photoRefs == ["fixture-reference"])
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<JournalEntry>()) == 1)
    }
    @Test func journalWritesStillNeedConfirmationAndSeparateWriteGrant() async throws {
        let e = try journalEnvelope("create"), (service, store, writer, c) = try fixture(e)
        let journal = SwiftDataNativeJournal(context: c.mainContext, journal: NativeActionMemoryJournal())
        store.file.grant?.capabilities = ["journal.create", "journal.update"]
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), journal: journal, now: { self.at })
        await executor.poll()
        #expect(try c.mainContext.fetchCount(FetchDescriptor<JournalEntry>()) == 0 && service.receipts.isEmpty)
        var approved = try NativeRemoteJSON.object(service.envelope); approved["approvedAt"] = NativeRemoteJSON.timestamp(at); service.envelope = .object(approved)
        store.file.grant?.capabilities = ["journal.read"]
        await executor.poll()
        #expect(try c.mainContext.fetchCount(FetchDescriptor<JournalEntry>()) == 0 && store.file.requests.first?.outcome == "failed")
        let new = try journalEnvelope("create", approved: true), (validService, validStore, validWriter, validContainer) = try fixture(new)
        validStore.file.grant?.capabilities = ["journal.create"]
        let validJournal = SwiftDataNativeJournal(context: validContainer.mainContext, journal: NativeActionMemoryJournal())
        let valid = NativeRemoteExecutor(service: validService, persistence: validStore, writer: validWriter, alarms: UnsupportedNativeAlarms(), journal: validJournal, now: { self.at })
        await valid.poll(); await valid.poll()
        #expect(try validContainer.mainContext.fetchCount(FetchDescriptor<JournalEntry>()) == 1 && validStore.file.requests.first?.phase == "reported")
        #expect(validService.receipts.count == 1 && validService.claims.count == 1)
    }
    @Test func journalReadRevocationDuringClaimAndReadFailureNeverBecomeEmptySuccess() async throws {
        let (service, store, writer, c) = try fixture(journalEnvelope("read"))
        store.file.grant?.capabilities = ["journal.read"]
        let journal = SwiftDataNativeJournal(context: c.mainContext, journal: NativeActionMemoryJournal())
        service.beforeClaimReturn = { store.file.grant?.capabilities = [] }
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), journal: journal, now: { self.at })
        await executor.poll()
        #expect(store.file.requests.first?.outcome == "failed")
        let (nextService, nextStore, nextWriter, nextContainer) = try fixture(journalEnvelope("read"))
        nextStore.file.grant?.capabilities = ["journal.read"]
        let diary = JournalEntry(date: at, body: "fixture unsaved editor")
        nextContainer.mainContext.insert(diary)
        let nextJournal = SwiftDataNativeJournal(context: nextContainer.mainContext, journal: NativeActionMemoryJournal())
        let next = NativeRemoteExecutor(service: nextService, persistence: nextStore, writer: nextWriter, alarms: UnsupportedNativeAlarms(), journal: nextJournal, now: { self.at })
        await next.poll()
        #expect(nextStore.file.requests.first?.outcome == "failed")
        let receipt = try NativeRemoteJSON.object(nextStore.file.requests[0].receipt ?? .null)
        #expect(receipt["effect"] == .string("read_only_no_mutation") && receipt["records"] == nil)
        #expect(diary.body == "fixture unsaved editor" && nextContainer.mainContext.hasChanges)
    }
    @Test func JSAndSwiftCanonicalRequestHashMatch() throws {
        let data = Data(#"{"version":1,"commandId":"12345678-1234-4234-8234-123456789abc","deviceId":"fixture","kind":"item","action":"create","recordId":"12345678-1234-4234-8234-123456789abd","patch":{"title":"中文 / \"line\"\n"},"userRequest":"fixture","occurredAt":"2026-10-13T10:00:00.000Z","expiresAt":"2026-10-13T11:00:00.000Z"}"#.utf8)
        let body = try JSONDecoder().decode(BridgeJSON.self, from: data)
        #expect(BridgePoolCodec.hash(try BridgePoolCodec.encode(body)) == "d10b45180b5c86f239f4e36165f2cd80361b3257c203d231046d80c8184f412c")
    }
}
@MainActor private final class RemotePersistence: NativeRemotePersisting {
    var file = NativeRemoteFile(); var failAt = -1; var saves = 0
    func load() throws -> NativeRemoteFile { file }
    func save(_ file: NativeRemoteFile) throws { saves += 1; if saves == failAt { throw URLError(.cannotWriteToFile) }; try file.validate(); self.file = file }
}
@MainActor private final class RemoteService: NativeRemoteServing {
    var nativeDeviceId: String? = "fixture-device"
    var envelope: BridgeJSON; var extra: BridgeJSON?
    var loseReceiptResponse = false; var loseClaimResponse = false
    var claims: [BridgeJSON] = []; var receipts: [BridgeJSON] = []
    var beforeClaimReturn: (() -> Void)?
    init(_ envelope: BridgeJSON) { self.envelope = envelope }
    func nativeRequest(_ path: String, body: BridgeJSON) async throws -> BridgeJSON {
        var e = try NativeRemoteJSON.object(envelope)
        if path == "native/pending" { return .object(["commands": .array([envelope] + (extra.map { [$0] } ?? [])), "hasMore": .bool(false), "nextCursor": e["commandId"]!, "through": e["commandId"]!]) }
        let input = try NativeRemoteJSON.object(body)
        if path == "native/claim" {
            claims.append(body); e["state"] = .string("dispatching"); e["attemptId"] = input["attemptId"]; envelope = .object(e)
            if loseClaimResponse { loseClaimResponse = false; throw URLError(.networkConnectionLost) }
            beforeClaimReturn?(); return .object(e)
        }
        if path == "native/receipt" {
            receipts.append(body); e["state"] = input["outcome"]; e["result"] = input["receipt"]; envelope = .object(e)
            if loseReceiptResponse { loseReceiptResponse = false; throw URLError(.networkConnectionLost) }
            return .object(e)
        }
        throw URLError(.unsupportedURL)
    }
}
