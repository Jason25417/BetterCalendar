import Foundation

nonisolated struct BridgeTaskSession: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, paused, finished }
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

    /// The midpoint anchor corrects the local wall clock using the server read.
    /// Paused time never grows; this is a projection, not another saved timer.
    func elapsed(at localDate: Date, localMidpoint: Date) -> TimeInterval {
        max(0, elapsedMs / 1000 + (status == .running ? max(0, localDate.timeIntervalSince(localMidpoint)) : 0))
    }
}

nonisolated struct BridgeTaskState: Codable, Sendable {
    var schemaVersion: Int
    var authority: String
    var readAt: Date
    var sessions: [BridgeTaskSession]
    var hasMore: Bool
    func validate() throws {
        guard schemaVersion == 1, authority == "bettercalendar", sessions.count <= 100,
              Set(sessions.map(\.id)).count == sessions.count,
              sessions.allSatisfy({ !$0.id.isEmpty && $0.revision > 0 && $0.elapsedMs.isFinite && $0.elapsedMs >= 0 && $0.status != .finished }) else {
            throw URLError(.cannotParseResponse)
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
}
