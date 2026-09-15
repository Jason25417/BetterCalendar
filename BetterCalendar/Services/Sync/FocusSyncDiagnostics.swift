import Foundation
import Observation

/// Local measurements only. Cross-device age includes clock skew; it is not a network RTT.
@MainActor @Observable
final class FocusSyncDiagnostics {
    static let shared = FocusSyncDiagnostics()
    struct Receipt: Codable {
        var direction: String
        var action: String
        var sequence: Int64
        var sourceDevice: String
        var sourceAt: Date
        var observedAt: Date
        var requestSeconds: Double
        var apparentAgeSeconds: Double
        var trigger: String
    }
    private(set) var receipts: [Receipt] = []
    private(set) var lastRead: Date?
    private(set) var lastWrite: Date?
    private(set) var lastRequestSeconds: Double?
    private(set) var issue: String?
    private(set) var subscriptionReady = false
    private var lastRevision: String?

    func subscriptionSucceeded() { subscriptionReady = true }
    func failed(_ message: String) { issue = message }
    func read(at now: Date, seconds: Double) {
        lastRead = now; lastRequestSeconds = seconds; issue = nil
    }
    @discardableResult
    func received(action: String, seq: Int64, device: String, sourceAt: Date,
                  now: Date, seconds: Double, reason: String, revision: String) -> Bool {
        // Re-reading the same record is not a new latency sample.
        guard revision != lastRevision else { return false }
        lastRevision = revision
        append(.init(direction: "received", action: action, sequence: seq, sourceDevice: device,
                     sourceAt: sourceAt, observedAt: now, requestSeconds: seconds,
                     apparentAgeSeconds: now.timeIntervalSince(sourceAt), trigger: reason))
        return true
    }
    func sent(action: String, seq: Int64, device: String, sourceAt: Date, now: Date, seconds: Double) {
        lastWrite = now
        append(.init(direction: "uploaded", action: action, sequence: seq, sourceDevice: device,
                     sourceAt: sourceAt, observedAt: now, requestSeconds: seconds,
                     apparentAgeSeconds: now.timeIntervalSince(sourceAt), trigger: "outbox"))
    }
    private func append(_ receipt: Receipt) {
        receipts.append(receipt)
        if receipts.count > 100 { receipts.removeFirst(receipts.count - 100) }
    }
    var latestReceived: Receipt? { receipts.last { $0.direction == "received" } }
    var receivedActionAges: [Double] {
        receipts.filter { $0.direction == "received" && !$0.action.hasPrefix("tick") }
            .map(\.apparentAgeSeconds)
    }
    func export(to directory: URL) throws -> URL {
        struct Report: Encodable {
            var formatVersion = 1
            var capturedAt = Date.now
            var localDevice = FocusFollow.deviceID
            var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            var build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            var activePollSeconds = FocusSyncPolicy.activePoll
            var idlePollSeconds = FocusSyncPolicy.idlePoll
            var heartbeatSeconds = FocusSyncPolicy.heartbeat
            var note = "Local bounded measurements; uploaded is not remote receipt. Apparent age includes clock skew and first-read age. Match sourceDevice + sequence + action across both device reports. No task titles or journal content."
            var receipts: [Receipt]
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("focus-sync-\(UUID().uuidString).json")
        try ArchiveCodec.encoder().encode(Report(receipts: receipts)).write(to: url, options: .atomic)
        return url
    }
}

nonisolated enum FocusSyncPolicy {
    static let activePoll: TimeInterval = 5
    static let idlePoll: TimeInterval = 15
    static let heartbeat: TimeInterval = 60
    static let staleAfter: TimeInterval = 720
    static func pollInterval(hasLocalRun: Bool, hasFollowedRun: Bool, hasPending: Bool) -> TimeInterval {
        hasLocalRun || hasFollowedRun || hasPending ? activePoll : idlePoll
    }
    static func shouldPublish(kind: String, hasActive: Bool) -> Bool {
        hasActive || kind != "tick"
    }
    static func anchor(sampledAt: Date, elapsed: TimeInterval) -> Date {
        sampledAt.addingTimeInterval(-max(0, elapsed))
    }
}

/// Server modification order wins over client wall clocks. Keeps late reads from rolling back UI.
nonisolated struct FocusRevisionGate {
    private var latestServerDate: Date?
    private var latestSourceDate: Date?
    mutating func accept(serverDate: Date?, sourceDate: Date) -> Bool {
        if let serverDate, let latestServerDate {
            guard serverDate >= latestServerDate else { return false }
        } else if let latestSourceDate {
            guard sourceDate >= latestSourceDate else { return false }
        }
        latestServerDate = serverDate
        latestSourceDate = sourceDate
        return true
    }
}
