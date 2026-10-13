import Foundation

/// Local execution intents/receipts, not another item database. An intent is
/// durable before touching SwiftData or AlarmKit. Unknown effects stay unknown.
nonisolated struct NativeActionEntry: Codable, Equatable {
    var commandId: UUID
    var kind: String
    var requestHash: String
    var before: BridgeJSON?
    var proposed: BridgeJSON?
    var phase: String = "prepared"
    var receipt: BridgeJSON? = nil
}
@MainActor protocol NativeActionJournaling {
    func load() throws -> [NativeActionEntry]
    func save(_ entries: [NativeActionEntry]) throws
}
@MainActor final class NativeActionFileJournal: NativeActionJournaling {
    private let file: URL
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DotStateBridge/native-actions-v1.json")
    }
    func load() throws -> [NativeActionEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let entries = try JSONDecoder().decode([NativeActionEntry].self, from: Data(contentsOf: file))
        try validate(entries); return entries
    }
    func save(_ entries: [NativeActionEntry]) throws {
        try validate(entries)
        let bytes = try JSONEncoder().encode(entries)
        guard bytes.count <= 4 * 1024 * 1024 else { throw DataArchiveError.invalid("操作回执容量已满，原文件保留") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        #endif
    }
    private func validate(_ entries: [NativeActionEntry]) throws {
        guard entries.count <= 2000, Set(entries.map(\.commandId)).count == entries.count,
              entries.allSatisfy({ ["item", "alarm", "cancel_alarm"].contains($0.kind) &&
                  ["prepared", "applied"].contains($0.phase) && $0.requestHash.count == 64 &&
                  ($0.phase != "applied" || $0.receipt != nil) }) else {
            throw DataArchiveError.invalid("操作回执无效，保留原文件，不重放")
        }
    }
}
@MainActor final class NativeActionMemoryJournal: NativeActionJournaling {
    var entries: [NativeActionEntry] = []
    func load() throws -> [NativeActionEntry] { entries }
    func save(_ entries: [NativeActionEntry]) throws { self.entries = entries }
}
