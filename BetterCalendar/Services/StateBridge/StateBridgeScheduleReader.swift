import Foundation
import EventKit

nonisolated struct BridgeScheduleSnapshot: Sendable {
    let observedAt: Date
    let calendar: BridgeJSON
    let reminders: BridgeJSON
}

nonisolated protocol StateBridgeScheduleReading: Sendable {
    func snapshot(at date: Date) async -> BridgeScheduleSnapshot
    func requestPermissions() async -> [String: String]
}

/// EventKit's synchronous reads stay in this actor, never in the UI collector.
/// Keep native EventKit objects here; only Sendable JSON snapshots cross out.
actor EventKitBridgeScheduleReader: StateBridgeScheduleReading {
    private lazy var store = EKEventStore()

    func requestPermissions() async -> [String: String] {
        var failures: [String: String] = [:]
        do {
            if try await !store.requestFullAccessToEvents() { failures["calendar"] = "not-authorized" }
        } catch { failures["calendar"] = "permission-request-failed" }
        do {
            if try await !store.requestFullAccessToReminders() { failures["reminders"] = "not-authorized" }
        } catch { failures["reminders"] = "permission-request-failed" }
        return failures
    }

    func snapshot(at date: Date) async -> BridgeScheduleSnapshot {
        let events: BridgeJSON
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let rows = store.events(matching: store.predicateForEvents(
                withStart: date.addingTimeInterval(-86400), end: date.addingTimeInterval(14 * 86400), calendars: nil
            )).sorted { $0.startDate < $1.startDate }
            let format = ISO8601DateFormatter()
            let candidates: [BridgeJSON] = rows.prefix(120).map { row in
                .object(["id": .text(row.eventIdentifier), "title": .text(row.title.map { String($0.prefix(300)) }),
                         "start": .string(format.string(from: row.startDate)), "end": .string(format.string(from: row.endDate)),
                         "allDay": .bool(row.isAllDay), "location": .text(row.location.map { String($0.prefix(300)) })])
            }
            events = BridgeScheduleProjection.bounded(candidates, totalCount: rows.count, limit: 120)
        } else { events = .object(["availability": .string("not-authorized")]) }
        let reminders: BridgeJSON
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            reminders = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { rows in
                    // Convert on the callback's thread before resuming the actor.
                    guard let rows else {
                        continuation.resume(returning: BridgeScheduleProjection.unreadableReminders)
                        return
                    }
                    let format = ISO8601DateFormatter()
                    let candidates: [BridgeJSON] = rows.sorted { $0.calendarItemIdentifier < $1.calendarItemIdentifier }.prefix(100).map { row in
                        .object(["id": .string(row.calendarItemIdentifier), "title": .text(row.title.map { String($0.prefix(300)) }),
                                 "priority": .number(Double(row.priority)),
                                 "due": .text(row.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map { format.string(from: $0) })])
                    }
                    continuation.resume(returning: BridgeScheduleProjection.bounded(candidates, totalCount: rows.count, limit: 100))
                }
            }
        } else { reminders = .object(["availability": .string("not-authorized")]) }
        return BridgeScheduleSnapshot(observedAt: date, calendar: events, reminders: reminders)
    }
}

nonisolated enum BridgeScheduleProjection {
    static let unreadableReminders = BridgeJSON.object(["availability": .string("read-unavailable")])

    /// Stay below the upload envelope budget without silently dropping evidence.
    /// A readable zero-result list is different from a nil/failed callback.
    static func bounded(_ candidates: [BridgeJSON], totalCount: Int, limit: Int) -> BridgeJSON {
        var items: [BridgeJSON] = []
        var bytes = 512
        for item in candidates.prefix(max(0, limit)) {
            guard let data = try? JSONEncoder().encode(item), bytes + data.count + 1 < 44 * 1024 else { break }
            items.append(item); bytes += data.count + 1
        }
        let omitted = max(0, totalCount - items.count)
        return .object(["availability": .string(omitted > 0 ? "partial" : "available"), "items": .array(items),
                        "truncated": .bool(omitted > 0), "omittedItems": .number(Double(omitted))])
    }
}
