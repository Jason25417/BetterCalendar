import Foundation
import Testing
@testable import BetterCalendar

@Suite struct NativeEvidenceExportTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bc-evidence-isolated-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func read(_ capture: NativeEvidenceCapture) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: capture.data) as? [String: Any])
    }
    @Test func preservesActualEvidenceAndUnknownFieldsWithoutChangingSource() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = Data(#"{"version":1,"requests":[{"commandId":"fixture","attemptId":"same-attempt","phase":"result","outcome":"unknown","receipt":{"serviceResult":{"saved":true,"revision":3},"deviceApplied":"unknown"},"futureEvidence":{"保留":"原文","count":2}}],"failures":[{"error":"offline","at":42}]}"#.utf8)
        let path = root.appendingPathComponent("native-remote-v1.json"); try source.write(to: path)
        let capture = try NativeEvidenceExport.capture(root: root), report = try read(capture)
        #expect(capture.includedFiles == 1 && capture.unavailableFiles == 2)
        #expect(try Data(contentsOf: path) == source)
        let files = try #require(report["files"] as? [[String: Any]])
        let content = try #require(files[0]["content"] as? [String: Any])
        let requests = try #require(content["requests"] as? [[String: Any]])
        #expect(requests[0]["outcome"] as? String == "unknown")
        #expect((requests[0]["futureEvidence"] as? [String: Any])?["保留"] as? String == "原文")
        #expect(report["atomicAcrossFiles"] as? Bool == false)
        #expect((report["coverage"] as? [String: Any])?["deviceAppliedOrUserSeen"] as? String == "not_inferred_from_export")
        #expect((files[0]["originalSHA256"] as? String)?.count == 64)
    }
    @Test func excludesConfigurationAndRedactsNestedSecretsButKeepsAuthorizationStatus() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let content: [String: Any] = ["version":1,"system":["authorization":"authorized"],
            "nested":["deviceToken":"fixture-secret-A","platform_token":"fixture-secret-B","Authorization":"Bearer fixture-secret-C","privateKey":"fixture-secret-D"],
            "error":"request failed Bearer fixture-secret-E", "text":"api sk-fixturesecretlong123",
            "source":"https://fixture.invalid/?access_token=fixture-secret-H&x=1", "inputTokens":12,
            "chain_of_thought":"private fixture thinking"]
        let source = try JSONSerialization.data(withJSONObject: content)
        try source.write(to: root.appendingPathComponent("native-remote-v1.json"))
        try Data("configuration-secret-F".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data("credential-secret-G".utf8).write(to: root.appendingPathComponent("credentials.json"))
        let capture = try NativeEvidenceExport.capture(root: root), report = try read(capture)
        let text = try #require(String(data: capture.data, encoding: .utf8))
        for secret in ["fixture-secret-A","fixture-secret-B","fixture-secret-C","fixture-secret-D","fixture-secret-E","sk-fixturesecretlong123","configuration-secret-F","credential-secret-G","fixture-secret-H","private fixture thinking"] { #expect(!text.contains(secret)) }
        let files = try #require(report["files"] as? [[String: Any]])
        let result = try #require(files[0]["content"] as? [String: Any])
        #expect((result["system"] as? [String: Any])?["authorization"] as? String == "authorized")
        #expect(result["inputTokens"] as? Int == 12)
        #expect((files[0]["redactions"] as? Int) == 8)
        #expect(try Data(contentsOf: root.appendingPathComponent("native-remote-v1.json")) == source)
    }
    @Test func corruptOversizeAndSymbolicLinkProduceExplicitGapsAndKeepOriginals() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = Data("broken secret text {".utf8)
        try corrupt.write(to: root.appendingPathComponent("native-remote-v1.json"))
        let large = Data(repeating: 32, count: 129)
        try large.write(to: root.appendingPathComponent("native-actions-v1.json"))
        let target = root.appendingPathComponent("private-config.json")
        try Data("not authorized to export".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("task-commands-v1.json"), withDestinationURL: target)
        let capture = try NativeEvidenceExport.capture(root: root, byteLimit: 128), report = try read(capture)
        #expect(capture.includedFiles == 0 && capture.unavailableFiles == 3)
        let files = try #require(report["files"] as? [[String: Any]])
        #expect(files.map { $0["status"] as? String } == ["unreadable_json_original_retained","too_large_original_retained","unsupported_file_type"])
        #expect(files.allSatisfy { $0["content"] == nil })
        #expect(try Data(contentsOf: root.appendingPathComponent("native-remote-v1.json")) == corrupt)
        #expect(try Data(contentsOf: root.appendingPathComponent("native-actions-v1.json")) == large)
        #expect(!String(decoding: capture.data, as: UTF8.self).contains("not authorized to export"))
    }
    @Test func exportMakesNoFilesAndDoesNotInventMissingOperations() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = try NativeEvidenceExport.capture(root: root), report = try read(capture)
        #expect(capture.includedFiles == 0 && capture.unavailableFiles == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let files = try #require(report["files"] as? [[String: Any]])
        #expect(files.allSatisfy { $0["status"] as? String == "not_present" && $0["content"] == nil })
        #expect(report["purpose"] as? String == "local_execution_evidence_not_backup_or_restore")
    }
}
