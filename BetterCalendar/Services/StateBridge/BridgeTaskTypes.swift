import Foundation

nonisolated struct BridgeTaskSession: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, paused, finished }
    enum Mode: String, Codable, Sendable { case light, pomodoro }
    var id: String
    var title: String
    var status: Status
    var startedAt: Date
    var activeSince: Date?
    var elapsedMs: Double
    var updatedAt: Date
    var revision: Int
    var provenance: String
    var relatedRecordId: String? = nil
    var origin: String? = nil
    var lastCommandId: String? = nil
    // Optional wire fields preserve pre-mode network and on-disk caches.
    var mode: Mode? = nil
    var focusMinutes: Int? = nil
    var experiment: Bool? = nil
    var resolvedMode: Mode { mode ?? .light }
    var isExperiment: Bool { experiment ?? false }
    var validMode: Bool {
        resolvedMode == .light ? focusMinutes == nil : focusMinutes.map { (1...240).contains($0) } == true
    }
    func presentation(elapsed: TimeInterval) -> BridgeTaskPresentation {
        let total = max(0, elapsed)
        let remaining = resolvedMode == .pomodoro ? max(0, Double(focusMinutes ?? 0) * 60 - total) : 0
        return BridgeTaskPresentation(elapsed: total, remaining: remaining,
                                      countingDown: resolvedMode == .pomodoro && remaining > 0)
    }

    /// The midpoint anchor corrects the local wall clock using the server read.
    /// Paused time never grows; this is a projection, not another saved timer.
    func elapsed(at localDate: Date, localMidpoint: Date) -> TimeInterval {
        max(0, elapsedMs / 1000 + (status == .running ? max(0, localDate.timeIntervalSince(localMidpoint)) : 0))
    }
}

/// Pure display arithmetic. No session mutation, notification or completion.
nonisolated struct BridgeTaskPresentation: Equatable, Sendable {
    let elapsed: TimeInterval
    let remaining: TimeInterval
    let countingDown: Bool
    var displaySeconds: TimeInterval { countingDown ? remaining : elapsed }
    var label: String { countingDown ? "番茄剩余" : "已用" }
}

nonisolated struct BridgeTaskState: Codable, Sendable {
    struct ApplicationSnapshot: Codable, Sendable {
        struct FinishedVersion: Codable, Sendable {
            var sessionId: String
            var revision: Int
            var status: BridgeTaskSession.Status
            var commandId: String
            var mode: BridgeTaskSession.Mode? = nil
            var focusMinutes: Int? = nil
            var experiment: Bool? = nil
        }
        var id: String
        var finishedVersions: [FinishedVersion]
        var finishedComplete: Bool
    }
    var schemaVersion: Int
    var authority: String
    var readAt: Date
    var sessions: [BridgeTaskSession]
    var hasMore: Bool
    var applicationSnapshot: ApplicationSnapshot? = nil
    func validate() throws {
        guard schemaVersion == 1, authority == "bettercalendar", sessions.count <= 100,
              Set(sessions.map(\.id)).count == sessions.count,
              sessions.allSatisfy({ !$0.id.isEmpty && $0.revision > 0 && $0.elapsedMs.isFinite && $0.elapsedMs >= 0 && $0.validMode && $0.status != .finished }) else {
            throw URLError(.cannotParseResponse)
        }
        if let snapshot = applicationSnapshot {
            guard snapshot.id.hasPrefix("task_snapshot_"), snapshot.id.count <= 100,
                  snapshot.finishedVersions.count <= 100,
                  Set(snapshot.finishedVersions.map(\.sessionId)).count == snapshot.finishedVersions.count,
                  snapshot.finishedVersions.allSatisfy({ !$0.sessionId.isEmpty && $0.revision > 0 && $0.status == .finished && !$0.commandId.isEmpty }),
                  Set(sessions.map(\.id)).isDisjoint(with: snapshot.finishedVersions.map(\.sessionId)) else { throw URLError(.cannotParseResponse) }
        }
    }
}

nonisolated struct BridgeTaskCommand: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case start, pause, resume, finish }
    var commandId: String
    var action: Action
    var title: String? = nil
    var sessionId: String? = nil
    var expectedRevision: Int? = nil
    var occurredAt: Date
    var provenance: String = "user"
    var relatedRecordId: String? = nil
    var mode: BridgeTaskSession.Mode? = nil
    var focusMinutes: Int? = nil
    var experiment: Bool? = nil
    var validMode: Bool {
        if action != .start { return mode == nil && focusMinutes == nil && experiment == nil }
        return (mode ?? .light) == .light ? focusMinutes == nil : focusMinutes.map { (1...240).contains($0) } == true
    }
}

nonisolated struct BridgeTaskReceipt: Decodable, Sendable {
    let commandId: String
    let saved: Bool
}

nonisolated enum BridgeTaskCodec {
    static func networkDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = format.date(from: text) { return date }
            format.formatOptions = [.withInternetDateTime]
            guard let date = format.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid task timestamp")
            }
            return date
        }
        return decoder
    }
    static func networkEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer(); try container.encode(format.string(from: date))
        }
        return encoder
    }
}

@MainActor protocol BridgeTaskServing {
    func readTasks() async throws -> BridgeTaskState
    func submitTask(_ command: BridgeTaskCommand) async throws -> BridgeTaskReceipt
    func reportSavedTaskSnapshots(_ ids: [String]) async throws -> Set<String>
}

extension BridgeTaskServing {
    // Legacy/mock services have no application-receipt protocol.
    func reportSavedTaskSnapshots(_ ids: [String]) async throws -> Set<String> { [] }
}
