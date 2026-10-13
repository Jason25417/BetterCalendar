import Foundation
import Testing
@testable import BetterCalendar

@MainActor @Suite struct StateBridgeOutboxTests {
    private func observation(_ sequence: Int, id: String = "fixture") -> BridgeObservation {
        BridgeObservation(eventId:id,source:"mac.activity",sequence:sequence,observedAt:"2026-10-12T06:00:00Z",expiresAt:nil,value:.object(["app":.string("fixture")]))
    }
    @Test func originalQueueRoundTripsWithoutChangingEventIdentityOrTime() throws {
        let queue = BridgeOutbox(nextSequence:3,observations:[observation(1),observation(2,id:"second")])
        let bytes = try JSONEncoder().encode(queue)
        let restored = try JSONDecoder().decode(BridgeOutbox.self,from:bytes)
        try restored.validate()
        #expect(restored.nextSequence == 3)
        #expect(restored.observations[0].eventId == "fixture")
        #expect(restored.observations[0].observedAt == "2026-10-12T06:00:00Z")
    }
    @Test func conflictingExternalQueueEditsCannotRestartSequenceOrSilentlyLoseRecords() throws {
        #expect(throws:(any Error).self) { try BridgeOutbox(nextSequence:1,observations:[observation(1)]).validate() }
        #expect(throws:(any Error).self) { try BridgeOutbox(nextSequence:3,observations:[observation(1),observation(2)]).validate() }
        #expect(throws:(any Error).self) { try BridgeOutbox(nextSequence:3,observations:[observation(1),observation(1,id:"second")]).validate() }
        try BridgeOutbox(nextSequence:50,observations:[]).validate()
    }
}

@MainActor @Suite struct StateBridgeObservationSemanticsTests {
    @Test func boundedBatchPreservesFIFOEndpointsTimesAndUnsavedAcknowledgements() throws {
        func observation(_ n: Int, _ source: String = "health.steps", _ bytes: Int = 0) -> BridgeObservation {
            .init(eventId: "isolated-\(n)", source: source, sequence: n, observedAt: "2026-10-12T06:00:00Z", expiresAt: "2026-10-12T06:05:00Z", value: .string(String(repeating: "x", count: bytes)))
        }
        var q = BridgeOutbox(nextSequence: 30, observations: (1...22).map { observation($0) })
        let batch = try q.uploadBatch(); #expect(batch.count == 20)
        #expect(batch.first?.eventId == "isolated-1" && batch.last?.eventId == "isolated-20")
        #expect(batch.first?.observedAt == "2026-10-12T06:00:00Z")
        #expect(throws: (any Error).self) { try q.acknowledge(batch, accepted: batch.map(\.eventId) + ["isolated-21"], ignored: []) }
        #expect(q.observations.count == 22)
        try q.acknowledge(batch, accepted: batch.dropLast().map(\.eventId), ignored: [batch.last!.eventId])
        #expect(q.observations.map(\.eventId) == ["isolated-21", "isolated-22"])
        let mixed = BridgeOutbox(nextSequence: 4, observations: [observation(1), observation(2, "bc.pool.chunk"), observation(3)])
        #expect(try mixed.uploadBatch().count == 1)
        let large = BridgeOutbox(nextSequence: 4, observations: (1...3).map { observation($0, "health.steps", 40000) })
        #expect(try large.uploadBatch().count == 2)
        #expect(throws: (any Error).self) { try large.uploadBatch(maxBytes: 10) }
    }
    @Test func fixedHealthWindowHandlesDSTAndRetainsFractionsCorrectionsAndUnknowns() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-01T23:00:00Z"))
        let window = BridgeHealthWindow(at: date, calendar: calendar)
        #expect(window.start == ISO8601DateFormatter().date(from: "2026-11-01T04:00:00Z"))
        guard case let .object(a) = window.steps(1664.876), case let .object(b) = window.steps(1209), case let .object(empty) = window.steps(nil) else { Issue.record("missing snapshot"); return }
        #expect(a["count"] == .number(1664.876) && a["displayCount"] == .number(1665))
        #expect(b["count"] == .number(1209) && b["additive"] == .bool(false))
        #expect(a["windowStart"] == b["windowStart"] && a["windowEnd"] == b["windowEnd"])
        #expect(empty["count"] == .null && empty["availability"] != .string("readable"))
        #expect(window.steps(.nan) == window.steps(nil))
    }
    @Test func inputIdleAndAppChangesDoNotInventActorRestOrTimerActions() {
        let changed = BridgeInputActivity.value(bundleID: "fixture", app: "Fixture", idleSeconds: 2000, foregroundChanged: true)
        guard case let .object(v) = changed, case let .object(invalid) = BridgeInputActivity.value(bundleID: nil, app: nil, idleSeconds: .infinity, foregroundChanged: false) else { Issue.record("missing activity"); return }
        #expect(v["foregroundChanged"] == .bool(true) && v["idle"] == .string("over30min"))
        #expect(v["personState"] == .string("unknown") && v["activityActor"] == .string("unknown_user_or_automation"))
        #expect(invalid["idle"] == .string("unknown") && invalid["inputIdleSeconds"] == .null)
    }
}
