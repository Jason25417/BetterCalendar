import Foundation

nonisolated struct BridgeTaskLocalFile: Codable {
    struct Pending: Codable {
        var command: BridgeTaskCommand
        var needsReview = false
    }
    var schemaVersion = 1
    var pending: [Pending] = []
    var state: BridgeTaskState?
    var localMidpoint: Date?
    var receivedAt: Date?
    func validate() throws {
        guard schemaVersion == 1, pending.count <= 100,
              Set(pending.map { $0.command.commandId }).count == pending.count,
              pending.allSatisfy({ !$0.command.commandId.isEmpty && $0.command.provenance == "user" }) else { throw URLError(.cannotParseResponse) }
        try state?.validate()
    }
}

@MainActor protocol BridgeTaskPersisting {
    func load() throws -> BridgeTaskLocalFile
    func save(_ file: BridgeTaskLocalFile) throws
}

@MainActor final class BridgeTaskFilePersistence: BridgeTaskPersisting {
    private var location: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DotStateBridge/task-commands-v1.json")
    }
    func load() throws -> BridgeTaskLocalFile {
        guard FileManager.default.fileExists(atPath: location.path) else { return BridgeTaskLocalFile() }
        let file = try JSONDecoder().decode(BridgeTaskLocalFile.self, from: Data(contentsOf: location)); try file.validate(); return file
    }
    func save(_ file: BridgeTaskLocalFile) throws {
        try file.validate()
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: location, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: location.path)
        #endif
    }
}

@MainActor final class BridgeTaskMemoryPersistence: BridgeTaskPersisting {
    var file = BridgeTaskLocalFile()
    func load() throws -> BridgeTaskLocalFile { file }
    func save(_ file: BridgeTaskLocalFile) throws { try file.validate(); self.file = file }
}
