#if os(macOS)
import Foundation
import Testing
@testable import BetterCalendar

@Suite struct StateBridgeFileScannerTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }
    @Test func recursiveMetadataExcludesDependenciesSecretsAndEscapingLinks() throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try write("study/week1/proof.md", in: root)
        try write("node_modules/package/index.js", in: root)
        try write("project/.env", in: root)
        try write("project/AuthKey.p8", in: root)
        try write("project/credentials.json", in: root)
        try write("external.txt", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let snapshot = StateBridgeFileScanner.scan(roots: [root], secondsPerRoot: 10)
        #expect(snapshot.items.map(\.relativePath) == ["study/week1/proof.md"])
        #expect(snapshot.roots.first?.status == "complete")
    }
    @Test func overlappingRootsDeduplicateAndKeepNewestFirst() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("study/old.md", in: root); try write("study/new.md", in: root)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: root.appendingPathComponent("study/old.md").path)
        let snapshot = StateBridgeFileScanner.scan(roots: [root, root.appendingPathComponent("study")], secondsPerRoot: 10)
        #expect(snapshot.items.count == 2)
        #expect(snapshot.items.first?.relativePath == "study/new.md")
        #expect(snapshot.roots.count == 2)
    }
    @Test func largeRootsResumeAndCompleteCyclesRemoveDeletedFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<8 { try write("file\(i).md", in: root) }
        var cursors: [String: StateBridgeFileScanner.Cursor] = [:]
        var snapshot = StateBridgeFileScanner.advance(roots: [root], cursors: &cursors, entryLimit: 2, secondsPerRoot: 10)
        #expect(snapshot.roots.first?.status == "partial-budget")
        for _ in 0..<4 { snapshot = StateBridgeFileScanner.advance(roots: [root], cursors: &cursors, entryLimit: 2, secondsPerRoot: 10) }
        #expect(snapshot.roots.first?.status == "complete")
        #expect(snapshot.items.count == 8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("file0.md"))
        snapshot = StateBridgeFileScanner.advance(roots: [root], cursors: &cursors, secondsPerRoot: 10)
        #expect(snapshot.items.count == 7)
        #expect(!snapshot.items.contains { $0.relativePath == "file0.md" })
    }
    @Test func budgetAndUnavailableRootsAreVisible() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one.md", in: root); try write("two.md", in: root)
        let limited = StateBridgeFileScanner.scan(roots: [root], entryLimit: 1, secondsPerRoot: 10)
        #expect(limited.roots.first?.status == "partial-budget")
        let missing = StateBridgeFileScanner.scan(roots: [root.appendingPathComponent("missing")])
        #expect(missing.roots.first?.status == "unavailable")
        #expect(missing.items.isEmpty)
        let omitted = StateBridgeFileScanner.scan(roots: [root], secondsPerRoot: 10, itemLimit: 1)
        #expect(omitted.omittedItems)
    }
}
#endif
