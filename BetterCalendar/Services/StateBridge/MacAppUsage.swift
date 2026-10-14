import Foundation

/// Observed foreground exposure, not Screen Time or evidence of human work.
/// Persist only totals: a restarted process never fills its offline interval.
nonisolated struct MacAppUsage: Codable {
    struct App: Codable { var name: String; var seconds: Double }
    var dayStart: Date?
    var coverageStart: Date?
    var apps: [String: App] = [:]
    var unobservedSeconds: Double = 0
    var omittedSeconds: Double = 0
    var persistedThrough: Date?
    private var lastDate: Date?
    private var lastUptime: Double?
    private var lastBundle: String?
    private enum CodingKeys: String, CodingKey { case dayStart, coverageStart, apps, unobservedSeconds, omittedSeconds, persistedThrough }
    mutating func stop() { lastDate = nil; lastUptime = nil; lastBundle = nil }
    mutating func sample(at: Date, uptime: Double, bundle: String?, name: String?, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: at)
        let oldDate = lastDate, oldUptime = lastUptime, oldBundle = lastBundle
        if dayStart != today { dayStart = today; coverageStart = at; apps = [:]; unobservedSeconds = 0; omittedSeconds = 0; persistedThrough = nil }
        defer { lastDate = at; lastUptime = uptime; lastBundle = bundle; persistedThrough = at }
        if let bundle, apps[bundle] == nil, apps.count < 64, bundle.utf8.count <= 240 { apps[bundle] = App(name: String((name ?? bundle).prefix(64)), seconds: 0) }
        guard let oldDate, let oldUptime else {
            if let persistedThrough { unobservedSeconds += max(0, at.timeIntervalSince(max(persistedThrough, today))) }; return
        }
        let elapsed = uptime - oldUptime, wallElapsed = at.timeIntervalSince(oldDate)
        guard elapsed >= 0, elapsed <= 45, abs(wallElapsed - elapsed) <= 2 else {
            unobservedSeconds += max(0, at.timeIntervalSince(max(oldDate, today))); return
        }
        let seconds = min(elapsed, max(0, at.timeIntervalSince(max(oldDate, today))))
        guard let oldBundle, apps[oldBundle] != nil else { omittedSeconds += seconds; return }
        apps[oldBundle]?.seconds += seconds
        if oldDate < today { coverageStart = today }
    }
    func snapshot(at: Date) -> BridgeJSON {
        .object(["schemaVersion": .number(1), "accumulationKind": .string("cumulative_snapshot"),
            "measurement": .string("sampled_foreground_exposure"), "inputActor": .string("unknown"),
            "windowStart": dayStart.map { .string($0.ISO8601Format()) } ?? .null,
            "windowEnd": .string(at.ISO8601Format()), "coverageStart": coverageStart.map { .string($0.ISO8601Format()) } ?? .null,
            "unobservedSeconds": .number(unobservedSeconds), "omittedSeconds": .number(omittedSeconds),
            "coverage": .string("BC collector running only; up to 15s sampling; gaps over 45s excluded; no background apps; restart never backfills"),
            "apps": .array(apps.sorted { $0.key < $1.key }.map { key, app in .object(["bundleId": .string(key), "name": .string(app.name), "foregroundSeconds": .number(app.seconds)]) })])
    }
}
