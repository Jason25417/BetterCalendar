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
