import Foundation
import Testing
@testable import BetterCalendar

@Suite struct DataSyncTransportEvidenceTests {
    @Test func openedAndExportedDoNotClaimRemoteImportOrApplication() throws {
        var evidence = DataSyncTransportEvidence()
        evidence.opened(cloud: true)
        guard case let .object(opened) = evidence.diagnostics() else { Issue.record("missing diagnostics"); return }
        #expect(opened["lastExportAt"] == .null && opened["lastImportAt"] == .null)
        evidence.finished(.export, at: Date(timeIntervalSince1970: 100), succeeded: true, error: nil)
        guard case let .object(exported) = evidence.diagnostics() else { Issue.record("missing diagnostics"); return }
        #expect(exported["lastImportAt"] == .null)
        #expect(exported["lastExportAt"] != .null)
        #expect(exported["otherDeviceApplied"] == .string("unknown"))
    }

    @Test func reorderedSuccessAndFailurePreserveSeparateEvidenceWithoutLeakingErrors() throws {
        var evidence = DataSyncTransportEvidence()
        let secret = "not-for-telemetry-private-credential"
        evidence.finished(.import, at: Date(timeIntervalSince1970: 200), succeeded: false,
                          error: NSError(domain: NSURLErrorDomain, code: -1009,
                                         userInfo: [NSLocalizedDescriptionKey: secret, "token": secret]))
        evidence.finished(.export, at: Date(timeIntervalSince1970: 300), succeeded: true, error: nil)
        evidence.finished(.setup, at: Date(timeIntervalSince1970: 100), succeeded: true, error: nil)
        #expect(evidence.lastEventPhase == .export && evidence.lastEventSucceeded == true)
        #expect(evidence.lastFailurePhase == .import && evidence.lastFailureCode == -1009)
        #expect(evidence.lastImport == nil)
        let encoded = String(decoding: try BridgePoolCodec.encode(evidence.diagnostics()), as: UTF8.self)
        #expect(!encoded.contains(secret) && !encoded.contains("token") && !encoded.contains("userInfo"))
        #expect(encoded.contains(NSURLErrorDomain))
    }

    @Test func customErrorDomainIsNotExportedAndRestartDoesNotInventHistory() throws {
        var evidence = DataSyncTransportEvidence()
        evidence.finished(.import, at: Date(timeIntervalSince1970: 100), succeeded: false,
                          error: NSError(domain: "private-user-text", code: 42))
        #expect(evidence.lastFailureDomain == "other")
        let restarted = DataSyncTransportEvidence()
        #expect(restarted.storage == .unknown && restarted.lastFailureAt == nil && restarted.lastImport == nil)
    }
}
