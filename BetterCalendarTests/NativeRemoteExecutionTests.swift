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
    @Test func mismatchedReceiptAcknowledgementKeepsOriginalResultAndRetryNeverReexecutes() async throws {
        for field in ["attemptId", "result", "deviceId", "permission"] {
            let (service, store, writer, c) = try fixture(envelope())
            service.receiptReturnTransform = { value in
                var fields = try NativeRemoteJSON.object(value)
                switch field {
                case "attemptId": fields[field] = .string(UUID().uuidString.lowercased())
                case "result": fields[field] = .object(["wrong": .bool(true)])
                case "deviceId": fields[field] = .string("different-device")
                default: fields[field] = .string("item.update")
                }
                return .object(fields)
            }
            let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
            await executor.poll()
            #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 1)
            #expect(store.file.requests.first?.phase == "result")
            let original = try #require(store.file.requests.first)
            #expect(original.receipt != nil && !store.file.failures.isEmpty)
            service.receiptReturnTransform = nil
            let restarted = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
            await restarted.poll()
            #expect(store.file.requests.first?.phase == "reported")
            #expect(store.file.requests.first?.attemptId == original.attemptId)
            #expect(store.file.requests.first?.receipt == original.receipt)
            #expect(service.receipts.count == 2 && service.receipts[0] == service.receipts[1])
            #expect(service.claims.count == 1)
            #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 1)
        }
    }
    @Test func terminalClaimResponseCannotCloseADifferentPersistedAttempt() async throws {
        for changedIdentity in ["attemptId", "request"] {
            let (service, store, writer, c) = try fixture(envelope())
            let unrelated = try envelope(state: "applied")
            service.claimReturnTransform = { value in
                var fields = try NativeRemoteJSON.object(changedIdentity == "request" ? unrelated : value)
                fields["state"] = .string("applied")
                fields["attemptId"] = changedIdentity == "request" ? try NativeRemoteJSON.object(value)["attemptId"] : .string(UUID().uuidString.lowercased())
                fields["result"] = .object(["saved": .bool(true)])
                return .object(fields)
            }
            let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
            await executor.poll()
            #expect(store.file.requests.first?.phase == "prepared")
            #expect(store.file.requests.first?.receipt == nil)
            #expect(service.receipts.isEmpty)
            #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
            service.claimReturnTransform = nil
            await executor.poll()
            #expect(store.file.requests.first?.phase == "reported")
            #expect(service.claims.count == 2 && service.claims[0] == service.claims[1])
            #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 1)
        }
    }
    @Test func matchingTerminalClaimRecoversTheSavedServerResultWithoutAnyNewEffect() async throws {
        let (service, store, writer, c) = try fixture(envelope())
        service.loseClaimResponse = true
        let first = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await first.poll()
        let original = try #require(store.file.requests.first)
        let saved: BridgeJSON = .object(["saved": .bool(true), "authority": .string("isolated historical result")])
        service.claimReturnTransform = { value in
            var fields = try NativeRemoteJSON.object(value)
            fields["state"] = .string("applied"); fields["result"] = saved
            return .object(fields)
        }
        let restarted = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await restarted.poll()
        #expect(store.file.requests.first?.phase == "reported")
        #expect(store.file.requests.first?.receipt == saved)
        #expect(store.file.requests.first?.attemptId == original.attemptId)
        #expect(service.claims.count == 2 && service.claims[0] == service.claims[1])
        #expect(service.receipts.isEmpty)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
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
    @Test func entirePageChecksOperationFieldsBeforeAnyClaim() async throws {
        let good = try envelope(), (service, store, writer, c) = try fixture(good)
        var malformed = try NativeRemoteJSON.object(envelope())
        var request = try NativeRemoteJSON.object(malformed["request"]!)
        request["patch"] = .object(["title": .number(123)])
        malformed["request"] = .object(request)
        malformed["requestHash"] = .string(BridgePoolCodec.hash(try BridgePoolCodec.encode(.object(request))))
        service.extra = .object(malformed)
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll()
        #expect(service.claims.isEmpty && store.file.requests.isEmpty)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
        #expect(store.file.failures.count == 1 && store.file.failures[0].commandId == nil)
        #expect(store.file.failures[0].response != nil)
    }
    @Test func failedClaimDoesNotBlockAnotherConfirmedRequestOrMisattributeItsError() async throws {
        let good = try envelope(), (service, store, writer, c) = try fixture(good)
        let blockedId = try NativeRemoteJSON.string(NativeRemoteJSON.object(good)["commandId"])
        let other = try envelope(); service.extra = other; service.claimFailureIds = [blockedId]
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll(); await executor.poll()
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 1)
        #expect(service.receipts.count == 1)
        #expect(store.file.failures.count == 2 && store.file.failures.allSatisfy { $0.commandId == blockedId })
        let otherId = try NativeRemoteJSON.string(NativeRemoteJSON.object(other)["commandId"])
        #expect(store.file.requests.first { $0.commandId == otherId }?.phase == "reported")
        #expect(store.file.requests.first { $0.commandId == blockedId }?.phase == "prepared")
    }
    @Test func failureLogMustPersistBeforeAnotherRequestCanExecute() async throws {
        let good = try envelope(commandId: "00000000-0000-4000-8000-000000000001"), (service, store, writer, c) = try fixture(good)
        let blockedId = try NativeRemoteJSON.string(NativeRemoteJSON.object(good)["commandId"])
        service.extra = try envelope(); service.claimFailureIds = [blockedId]; store.failAt = 3
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll()
        #expect(service.claims.count == 1 && service.receipts.isEmpty)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
        #expect(store.file.failures.first?.commandId == blockedId)
    }
    @Test func aSavedReceiptWithLostReportCannotBlockAnIndependentRequest() async throws {
        let good = try envelope(), (service, store, writer, c) = try fixture(good)
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        service.loseReceiptResponse = true; await executor.poll()
        let firstId = try NativeRemoteJSON.string(NativeRemoteJSON.object(good)["commandId"])
        #expect(store.file.requests.first?.phase == "result")
        service.receiptFailureIds = [firstId]; service.extra = try envelope()
        await executor.poll()
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 2)
        #expect(store.file.requests.first { $0.commandId == firstId }?.phase == "result")
        #expect(store.file.requests.filter { $0.phase == "reported" }.count == 1)
        #expect(store.file.failures.allSatisfy { $0.commandId == firstId })
        #expect(service.claims.count == 2)
    }
    @Test func duplicateRequestIdentityInOnePageNeverClaimsEitherPayload() async throws {
        let e = try envelope(), (service, store, writer, c) = try fixture(e); service.extra = e
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll()
        #expect(service.claims.isEmpty && store.file.requests.isEmpty)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
    }
    @Test func allKindsRejectMalformedFieldsBeforeAnEarlierItemIsWritten() async throws {
        let patches: [(String, String, [String: BridgeJSON])] = [
            ("item", "update", ["recordId": .string(UUID().uuidString), "expectedRevision": .string("fixture"), "patch": .object(["status": .string("unknown-status")])]),
            ("alarm", "cancel", ["alarmId": .string("not-a-uuid")]),
            ("alarm", "schedule", ["fireAt": NativeRemoteJSON.timestamp(at), "title": .number(1)]),
            ("journal", "read", ["query": .object(["limit": .number(0)])]),
            ("journal", "create", ["recordId": .string(UUID().uuidString), "entryDate": NativeRemoteJSON.timestamp(at), "patch": .object(["body": .number(1)])]),
            ("timer", "pause", ["sessionId": .string("fixture"), "expectedRevision": .number(1.5)]),
            ("timer", "start", ["title": .string("fixture"), "sessionId": .string("unexpected-widening")])
        ]
        for (kind, action, fields) in patches {
            let good = try envelope(), (service, store, writer, c) = try fixture(good)
            var e = try NativeRemoteJSON.object(envelope()), r = try NativeRemoteJSON.object(e["request"]!)
            r.removeValue(forKey: "recordId"); r.removeValue(forKey: "patch")
            r["kind"] = .string(kind); r["action"] = .string(action); r.merge(fields) { _, new in new }
            e["request"] = .object(r); e["permission"] = .string(kind + "." + action)
            e["requestHash"] = .string(BridgePoolCodec.hash(try BridgePoolCodec.encode(.object(r))))
            service.extra = .object(e)
            let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
            await executor.poll()
            #expect(service.claims.isEmpty && store.file.requests.isEmpty)
            #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
        }
    }
    @Test func rejectedPageDiagnosticKeepsEvidenceButExcludesApprovalSecretsBeforeSaving() async throws {
        let (service, store, writer, c) = try fixture(envelope())
        var malformed = try NativeRemoteJSON.object(envelope()), request = try NativeRemoteJSON.object(malformed["request"]!)
        request["patch"] = .object(["title": .number(123)])
        malformed["request"] = .object(request)
        malformed["requestHash"] = .string(BridgePoolCodec.hash(try BridgePoolCodec.encode(.object(request))))
        malformed["_meta"] = .object(["approvalToken": .string("ISOLATED_APPROVAL_SECRET_123")]); service.extra = .object(malformed)
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll()
        let failure = try #require(store.file.failures.first)
        #expect(failure.response != nil && failure.responseCanonicalHash?.count == 64 && failure.responseRedactions == 1)
        let text = String(decoding: try JSONEncoder().encode(store.file), as: UTF8.self)
        #expect(!text.contains("ISOLATED_APPROVAL_SECRET_123") && text.contains("[redacted]"))
        #expect(service.claims.isEmpty && store.file.requests.isEmpty)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
    }
    @Test func malformedEnvelopeStateAndPermissionMetadataInvalidateTheWholePage() async throws {
        for (key, value) in [("state", BridgeJSON.null), ("grantRevision", .number(0)), ("approvedAt", .string("invalid-time")), ("attemptId", .string("not-an-attempt"))] {
            let (service, store, writer, c) = try fixture(envelope())
            var malformed = try NativeRemoteJSON.object(envelope()); malformed[key] = value; service.extra = .object(malformed)
            let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
            await executor.poll()
            #expect(service.claims.isEmpty && store.file.requests.isEmpty)
            #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
        }
    }
    @Test func acceptedServerTitleLimitCanActuallyBeSavedNatively() async throws {
        let (service, store, writer, c) = try fixture(envelope())
        var e = try NativeRemoteJSON.object(service.envelope), r = try NativeRemoteJSON.object(e["request"]!)
        let title = String(repeating: "中", count: 500)
        r["patch"] = .object(["title": .string(title)]); e["request"] = .object(r)
        e["requestHash"] = .string(BridgePoolCodec.hash(try BridgePoolCodec.encode(.object(r)))); service.envelope = .object(e)
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll()
        #expect(try c.mainContext.fetch(FetchDescriptor<LongTask>()).first?.title == title)
        #expect(store.file.requests.first?.outcome == "applied")
    }
    @Test func boundedQueueScanResumesAfterRestartAndNeverClaimsWholeQueueCompleteEarly() async throws {
        let base = try envelope(), (_, initial, writer, c) = try fixture(base)
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("native-remote-v1.json")
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let disk = NativeRemoteFilePersistence(location: location); try disk.save(initial.file)
        let commands = try (1...201).map { try envelope(commandId: String(format: "00000000-0000-4000-8000-%012d", $0)) }
        let service = PagedRemoteService(commands: commands)
        let first = NativeRemoteExecutor(service: service, persistence: disk, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await first.poll()
        let partial = try disk.load()
        #expect(partial.lastPoll?.rangeReadComplete == false && partial.lastPoll?.pagesRead == 20)
        #expect(partial.lastPoll?.offeredRequests == 200 && partial.lastPoll?.requestErrors == 200)
        #expect(partial.pendingScan?.after == "00000000-0000-4000-8000-000000000200")
        let restarted = NativeRemoteExecutor(service: service, persistence: NativeRemoteFilePersistence(location: location), writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await restarted.poll()
        let completed = try disk.load()
        #expect(completed.pendingScan == nil && completed.lastPoll?.rangeReadComplete == true)
        #expect(completed.lastPoll?.pagesRead == 1 && completed.lastPoll?.offeredRequests == 1)
        #expect(service.claims.count == 201 && Set(service.claims).count == 201)
        #expect(service.afterCursors[20] == "00000000-0000-4000-8000-000000000200")
        #expect(completed.requests.allSatisfy { $0.phase == "prepared" } && completed.failures.count == 201)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
    }
    @Test func legacyLogLoadsWithoutNewDiagnosticsAndInvalidCursorNeverStartsNetwork() async throws {
        let (service, store, writer, c) = try fixture(envelope())
        store.file.failures = [.init(at: at, commandId: nil, error: "historical fixture")]
        let bytes = try JSONEncoder().encode(store.file)
        let legacy = try JSONDecoder().decode(NativeRemoteFile.self, from: bytes)
        #expect(legacy.pendingScan == nil && legacy.lastPoll == nil && legacy.failures[0].response == nil)
        store.file.pendingScan = .init(deviceId: "fixture-device", after: "not-a-cursor", through: "also-invalid")
        let validating = NativeRemoteFilePersistence(location: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("invalid.json"))
        try FileManager.default.createDirectory(at: validating.location.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: validating.location.deletingLastPathComponent()) }
        try JSONEncoder().encode(store.file).write(to: validating.location)
        let original = try Data(contentsOf: validating.location)
        let executor = NativeRemoteExecutor(service: service, persistence: validating, writer: writer, alarms: UnsupportedNativeAlarms(), now: { self.at })
        await executor.poll()
        #expect(service.claims.isEmpty && service.receipts.isEmpty)
        #expect(try Data(contentsOf: validating.location) == original)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
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
    private func timerFixture() throws -> (RemoteService, RemotePersistence, SwiftDataNativeItemWriter, ModelContainer, ConfirmedTimerCacheService, BridgeTaskMemoryPersistence, BridgeTaskViewModel) {
        var e = try NativeRemoteJSON.object(envelope()), r = try NativeRemoteJSON.object(e["request"]!)
        r["recordId"] = nil; r["patch"] = nil; r["kind"] = .string("timer"); r["action"] = .string("start"); r["title"] = .string("ISOLATED TIMER FIXTURE")
        e["request"] = .object(r); e["permission"] = .string("timer.start"); e["requestHash"] = .string(BridgePoolCodec.hash(try BridgePoolCodec.encode(.object(r))))
        let (service, store, writer, container) = try fixture(.object(e)); store.file.grant?.capabilities = ["timer.start"]
        let cache = ConfirmedTimerCacheService(at: at), disk = BridgeTaskMemoryPersistence()
        let tasks = BridgeTaskViewModel(service: cache, persistence: disk, enabled: { true }, now: { self.at })
        cache.state.sessions[0].lastCommandId = try NativeRemoteJSON.string(e["commandId"])
        service.timerResult = .object(["commandId": e["commandId"]!, "saved": .bool(true), "id": .string("task_fixture"), "revision": .number(1), "status": .string("running")])
        return (service, store, writer, container, cache, disk, tasks)
    }
    @Test func confirmedTimerCachesActualVersionAndLostReportDoesNotRepeatCommand() async throws {
        let (service, store, writer, container, cache, disk, tasks) = try timerFixture()
        service.loseReceiptResponse = true
        let first = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), canonicalTasks: tasks, now: { self.at })
        await first.poll()
        #expect(service.timerRequests.count == 1 && cache.reads == 1)
        #expect(store.file.requests.first?.outcome == "applied" && store.file.requests.first?.phase == "result")
        #expect(disk.file.state?.sessions.first?.id == "task_fixture")
        let result = try NativeRemoteJSON.object(store.file.requests[0].receipt!)
        #expect(result["deviceEffect"] == .string("local_cache_persisted") && result["savedRevision"] == .number(1))
        #expect(result["screenPresentation"] == .string("unknown") && result["userSeen"] == .string("unknown"))
        let restarted = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), canonicalTasks: tasks, now: { self.at })
        await restarted.poll(); await restarted.poll()
        #expect(service.timerRequests.count == 1 && service.receipts.count == 2 && service.receipts[0] == service.receipts[1])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<LongTask>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ExecutionSession>()) == 0)
    }
    @Test func lostTimerAcceptanceReplyRemainsUnknownAndIsNotBlindlyReissued() async throws {
        let (service, store, writer, _, cache, _, tasks) = try timerFixture(); service.loseTimerReply = true
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), canonicalTasks: tasks, now: { self.at })
        await executor.poll(); await executor.poll()
        #expect(service.timerRequests.count == 1 && cache.reads == 0)
        #expect(store.file.requests.first?.outcome == "unknown" && store.file.requests.first?.phase == "reported")
        #expect(store.file.requests.first?.envelope != nil && service.receipts.count == 1)
    }
    @Test func acceptedTimerWithoutSavedCacheKeepsRawReturnAndDoesNotClaimApplied() async throws {
        let (service, store, writer, _, cache, _, tasks) = try timerFixture(); cache.failRead = true
        let executor = NativeRemoteExecutor(service: service, persistence: store, writer: writer, alarms: UnsupportedNativeAlarms(), canonicalTasks: tasks, now: { self.at })
        await executor.poll(); await executor.poll()
        let receipt = try NativeRemoteJSON.object(store.file.requests[0].receipt!)
        #expect(receipt["serviceResult"] == service.timerResult)
        #expect(receipt["effect"] == .string("service_saved_device_application_unknown"))
        #expect(store.file.requests.first?.outcome == "unknown" && service.timerRequests.count == 1)
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
    var timerResult: BridgeJSON?; var timerRequests: [BridgeJSON] = []; var loseTimerReply = false
    var claims: [BridgeJSON] = []; var receipts: [BridgeJSON] = []
    var claimFailureIds: Set<String> = []
    var receiptFailureIds: Set<String> = []
    var beforeClaimReturn: (() -> Void)?
    var claimReturnTransform: ((BridgeJSON) throws -> BridgeJSON)?
    var receiptReturnTransform: ((BridgeJSON) throws -> BridgeJSON)?
    init(_ envelope: BridgeJSON) { self.envelope = envelope }
    func nativeRequest(_ path: String, body: BridgeJSON) async throws -> BridgeJSON {
        var e = try NativeRemoteJSON.object(envelope)
        if path == "native/pending" {
            let commands = ([envelope] + (extra.map { [$0] } ?? [])).sorted {
                (try? NativeRemoteJSON.string(NativeRemoteJSON.object($0)["commandId"])) ?? "" < (try? NativeRemoteJSON.string(NativeRemoteJSON.object($1)["commandId"])) ?? ""
            }
            let last = try NativeRemoteJSON.object(commands.last!)["commandId"]!
            return .object(["commands": .array(commands), "hasMore": .bool(false), "nextCursor": last, "through": last])
        }
        let input = try NativeRemoteJSON.object(body)
        let isExtra = extra.flatMap { try? NativeRemoteJSON.object($0)["commandId"] } == input["commandId"]
        if isExtra, let extra { e = try NativeRemoteJSON.object(extra) }
        if path == "native/claim" {
            claims.append(body)
            if case let .string(id) = input["commandId"], claimFailureIds.contains(id) { throw DataArchiveError.invalid("fixture claim refused, no side effect") }
            e["state"] = .string("dispatching"); e["attemptId"] = input["attemptId"]
            if isExtra { extra = .object(e) } else { envelope = .object(e) }
            if loseClaimResponse { loseClaimResponse = false; throw URLError(.networkConnectionLost) }
            beforeClaimReturn?(); return try claimReturnTransform?(.object(e)) ?? .object(e)
        }
        if path == "native/timer" {
            timerRequests.append(body)
            if loseTimerReply { loseTimerReply = false; throw URLError(.networkConnectionLost) }
            guard let result = timerResult else { throw URLError(.unsupportedURL) }; return result
        }
        if path == "native/receipt" {
            if case let .string(id) = input["commandId"], receiptFailureIds.contains(id) { throw URLError(.notConnectedToInternet) }
            receipts.append(body); e["state"] = input["outcome"]; e["result"] = input["receipt"]
            if isExtra { extra = .object(e) } else { envelope = .object(e) }
            if loseReceiptResponse { loseReceiptResponse = false; throw URLError(.networkConnectionLost) }
            return try receiptReturnTransform?(.object(e)) ?? .object(e)
        }
        throw URLError(.unsupportedURL)
    }
}

@MainActor private final class ConfirmedTimerCacheService: BridgeTaskServing {
    var state: BridgeTaskState
    var reads = 0
    var failRead = false
    init(at: Date) {
        state = .init(schemaVersion: 1, authority: "bettercalendar", readAt: at,
                      sessions: [.init(id: "task_fixture", title: "ISOLATED TIMER FIXTURE", status: .running, startedAt: at, activeSince: at, elapsedMs: 0, updatedAt: at, revision: 1, provenance: "user")], hasMore: false,
                      applicationSnapshot: .init(id: "task_snapshot_timer_fixture", finishedVersions: [], finishedComplete: true))
    }
    func readTasks() async throws -> BridgeTaskState { reads += 1; if failRead { throw URLError(.notConnectedToInternet) }; return state }
    func submitTask(_ command: BridgeTaskCommand) async throws -> BridgeTaskReceipt { throw URLError(.unsupportedURL) }
    func reportSavedTaskSnapshots(_ ids: [String]) async throws -> Set<String> { Set(ids) }
}

@MainActor private final class PagedRemoteService: NativeRemoteServing {
    var nativeDeviceId: String? = "fixture-device"
    let commands: [BridgeJSON]
    var afterCursors: [String] = []
    var claims: [String] = []
    init(commands: [BridgeJSON]) { self.commands = commands }
    func nativeRequest(_ path: String, body: BridgeJSON) async throws -> BridgeJSON {
        let input = try NativeRemoteJSON.object(body)
        if path == "native/pending" {
            let after = try NativeRemoteJSON.string(input["after"]), upper = try input["through"].map { try NativeRemoteJSON.string($0) } ?? NativeRemoteJSON.string(NativeRemoteJSON.object(commands.last!)["commandId"])
            afterCursors.append(after)
            let offered = try commands.filter { let id = try NativeRemoteJSON.string(NativeRemoteJSON.object($0)["commandId"]); return id > after && id <= upper }
            let page = Array(offered.prefix(10)), next = try page.last.map { try NativeRemoteJSON.string(NativeRemoteJSON.object($0)["commandId"]) } ?? after
            return .object(["commands": .array(page), "nextCursor": .string(next), "through": .string(upper), "hasMore": .bool(offered.count > 10)])
        }
        if path == "native/claim" {
            claims.append(try NativeRemoteJSON.string(input["commandId"]))
            throw DataArchiveError.invalid("isolated claim refusal fixture, no user effect")
        }
        throw URLError(.unsupportedURL)
    }
}
