import Foundation

/// A day-total read is a replaceable snapshot, never a delta to add to a prior read.
nonisolated struct BridgeHealthWindow: Sendable {
    let start: Date
    let end: Date
    let timeZone: String
    init(at date: Date, calendar: Calendar = .current) {
        start = calendar.startOfDay(for: date); end = date; timeZone = calendar.timeZone.identifier
    }
    func steps(_ raw: Double?, sources: [String]? = nil) -> BridgeJSON {
        let formatter = ISO8601DateFormatter()
        let valid = raw.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return .object(["day": .string(formatter.string(from: start)), "count": valid.map(BridgeJSON.number) ?? .null,
            "windowStart": .string(formatter.string(from: start)), "windowEnd": .string(formatter.string(from: end)),
            "queriedAt": .string(formatter.string(from: end)), "timeZone": .string(timeZone),
            "unit": .string("count"), "aggregation": .string("healthkit_cumulative_sum"),
            "snapshot": .bool(true), "additive": .bool(false), "mayBeRevised": .bool(true),
            "healthKitSources": sources.map { .array(Array(Set($0)).sorted().map(BridgeJSON.string)) } ?? .null,
            "sourceCoverage": .string(sources == nil ? "not_reported_by_statistics" : "statistics_reported_sources"),
            "deduplication": .string("healthkit_statistics_not_manual_sum_of_sources"),
            "displayCount": valid.map { .number($0.rounded()) } ?? .null,
            "displayRounding": .string("nearest_integer_raw_count_retained"),
            "availability": .string(valid == nil ? "no-readable-samples-not-proof-of-no-steps" : "readable")])
    }
}

nonisolated enum BridgeInputActivity {
    static func value(bundleID: String?, app: String?, idleSeconds: Double, foregroundChanged: Bool) -> BridgeJSON {
        let valid = idleSeconds.isFinite && idleSeconds >= 0
        let bucket = !valid ? "unknown" : idleSeconds < 60 ? "active" : idleSeconds < 300 ? "1-5min" : idleSeconds < 1800 ? "5-30min" : "over30min"
        return .object(["bundleId": .text(bundleID), "app": .text(app), "idle": .string(bucket),
            "inputIdleSeconds": valid ? .number(idleSeconds) : .null,
            "idleMeaning": .string("time_since_any_input_not_person_rest"),
            "inputEventQuery": .string("any_input_combined_session"), "foregroundChanged": .bool(foregroundChanged),
            "activityActor": .string("unknown_user_or_automation"), "personState": .string("unknown")])
    }
}

struct BridgeUploadPayload: Encodable { let observations: [BridgeObservation] }
extension BridgeOutbox {
    func uploadBatch(maxCount: Int = 20, maxBytes: Int = 96 * 1024) throws -> [BridgeObservation] {
        guard maxCount > 0, maxBytes > 0, let first = observations.first else { return [] }
        let pool = ["bc.pool", "bc.pool.chunk"], isPool = pool.contains(first.source)
        var batch: [BridgeObservation] = []
        for observation in observations.prefix(maxCount) {
            guard pool.contains(observation.source) == isPool else { break }
            let proposed = batch + [observation]
            if try JSONEncoder().encode(BridgeUploadPayload(observations: proposed)).count > maxBytes {
                if batch.isEmpty { throw DataArchiveError.invalid("单条观察超过上传批次容量，原队列保留") }
                break
            }
            batch = proposed
        }
        return batch
    }
    mutating func acknowledge(_ sent: [BridgeObservation], accepted: [String], ignored: [String]) throws {
        let ids = Set(sent.map(\.eventId)), acknowledged = Set(accepted + ignored)
        guard !ids.isEmpty, acknowledged == ids else { throw URLError(.cannotParseResponse) }
        observations.removeAll { ids.contains($0.eventId) }
    }
}
