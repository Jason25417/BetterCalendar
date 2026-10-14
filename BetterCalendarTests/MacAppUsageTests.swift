import Foundation
import Testing
@testable import BetterCalendar

struct MacAppUsageTests {
    let at = Date(timeIntervalSince1970: 1791979200)
    var calendar: Calendar { var v = Calendar(identifier: .gregorian); v.timeZone = TimeZone(secondsFromGMT: 0)!; return v }
    @Test func switchingAttributesOnlyPrecedingIntervalAndRepeatsDoNotAdd() {
        var usage = MacAppUsage()
        usage.sample(at: at, uptime: 0, bundle: "a", name: "A", calendar: calendar)
        usage.sample(at: at.addingTimeInterval(10), uptime: 10, bundle: "b", name: "B", calendar: calendar)
        usage.sample(at: at.addingTimeInterval(10), uptime: 10, bundle: "b", name: "B", calendar: calendar)
        usage.sample(at: at.addingTimeInterval(20), uptime: 20, bundle: "b", name: "B", calendar: calendar)
        #expect(usage.apps["a"]?.seconds == 10 && usage.apps["b"]?.seconds == 10)
    }
    @Test func gapAndClockJumpAreUnknownNotAssignedToFrontmost() {
        var usage = MacAppUsage()
        usage.sample(at: at, uptime: 0, bundle: "a", name: "A", calendar: calendar)
        usage.sample(at: at.addingTimeInterval(3600), uptime: 3600, bundle: "a", name: "A", calendar: calendar)
        #expect(usage.apps["a"]?.seconds == 0 && usage.unobservedSeconds == 3600)
        usage.sample(at: at.addingTimeInterval(3700), uptime: 3610, bundle: "a", name: "A", calendar: calendar)
        #expect(usage.apps["a"]?.seconds == 0 && usage.unobservedSeconds == 3700)
    }
    @Test func restartAndSleepDoNotBackfill() throws {
        var usage = MacAppUsage()
        usage.sample(at: at, uptime: 0, bundle: "a", name: "A", calendar: calendar)
        usage.sample(at: at.addingTimeInterval(10), uptime: 10, bundle: "a", name: "A", calendar: calendar)
        var restored = try JSONDecoder().decode(MacAppUsage.self, from: JSONEncoder().encode(usage))
        restored.sample(at: at.addingTimeInterval(3600), uptime: 3600, bundle: "a", name: "A", calendar: calendar)
        #expect(restored.apps["a"]?.seconds == 10 && restored.unobservedSeconds == 3590)
        restored.stop(); restored.sample(at: at.addingTimeInterval(7200), uptime: 7200, bundle: "a", name: "A", calendar: calendar)
        #expect(restored.apps["a"]?.seconds == 10)
    }
    @Test func midnightSplitsCurrentDayAndKeepsSnapshotSemantics() throws {
        var usage = MacAppUsage()
        let midnight = calendar.startOfDay(for: at).addingTimeInterval(86400)
        usage.sample(at: midnight.addingTimeInterval(-5), uptime: 0, bundle: "a", name: "A", calendar: calendar)
        usage.sample(at: midnight.addingTimeInterval(5), uptime: 10, bundle: "a", name: "A", calendar: calendar)
        #expect(usage.apps["a"]?.seconds == 5 && usage.coverageStart == midnight)
        let v = try NativeRemoteJSON.object(usage.snapshot(at: midnight.addingTimeInterval(5)))
        #expect(v["accumulationKind"] == .string("cumulative_snapshot") && v["inputActor"] == .string("unknown"))
    }
}
