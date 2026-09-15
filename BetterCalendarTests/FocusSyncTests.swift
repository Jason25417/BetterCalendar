import Foundation
import Testing
@testable import BetterCalendar

@MainActor @Suite struct FocusSyncTests {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func networkDelayDoesNotRestartTheFollowedClock() {
        let anchor = FocusSyncPolicy.anchor(sampledAt: t, elapsed: 123.75)
        let run = FollowRunState.Run(title: "test", style: "light", startedAt: anchor, updatedAt: t, seq: 1)
        // A record arriving 8 seconds late must already show 131.75 seconds, not 123 or 0.
        #expect(abs(run.elapsed(at: t.addingTimeInterval(8)) - 131.75) < 0.001)
        let paused = FollowRunState.Run(title: "test", style: "light", startedAt: anchor,
                                       pausedAt: t, updatedAt: t, seq: 2)
        #expect(abs(paused.elapsed(at: t.addingTimeInterval(100)) - 123.75) < 0.001)
    }

    @Test func lateReadCannotResurrectCompletedRun() {
        var gate = FocusRevisionGate()
        let accepted1 = gate.accept(serverDate: t, sourceDate: t)
        #expect(accepted1)
        let accepted2 = gate.accept(serverDate: t.addingTimeInterval(20), sourceDate: t.addingTimeInterval(20))
        #expect(accepted2)
        let accepted3 = !gate.accept(serverDate: t.addingTimeInterval(10), sourceDate: t.addingTimeInterval(10))
        #expect(accepted3)
        // Re-read accepted for freshness expiry, not counted as another measurement.
        let accepted4 = gate.accept(serverDate: t.addingTimeInterval(20), sourceDate: t.addingTimeInterval(20))
        #expect(accepted4)
    }

    @Test func serverRevisionOrdersDevicesWithDifferentClocks() {
        var gate = FocusRevisionGate()
        let accepted5 = gate.accept(serverDate: t, sourceDate: t.addingTimeInterval(120))
        #expect(accepted5)
        let accepted6 = gate.accept(serverDate: t.addingTimeInterval(1), sourceDate: t)
        #expect(accepted6)
        let accepted7 = !gate.accept(serverDate: t, sourceDate: t.addingTimeInterval(120))
        #expect(accepted7)
    }

    @Test func muteBelongsToSourceDeviceAsWellAsSequence() {
        let state = FollowRunState()
        let a = FollowRunState.Run(title: "A", sourceDevice: "mac", style: "light", startedAt: t, seq: 10)
        let b = FollowRunState.Run(title: "B", sourceDevice: "phone", style: "light", startedAt: t, seq: 10)
        state.set(a); state.exitFollow(); state.set(a)
        #expect(state.run == nil)
        state.set(b)
        #expect(state.run?.title == "B")
    }

    @Test func receiptsDeduplicateAndDoNotHideClockSkew() {
        let diag = FocusSyncDiagnostics()
        for _ in 0..<3 {
            diag.received(action: "paused", seq: 2, device: "phone", sourceAt: t.addingTimeInterval(30),
                          now: t, seconds: 0.2, reason: "poll", revision: "same")
        }
        #expect(diag.receipts.count == 1)
        #expect(diag.receivedActionAges == [-30])
        diag.sent(action: "running", seq: 3, device: "mac", sourceAt: t, now: t.addingTimeInterval(1), seconds: 0.5)
        #expect(diag.receivedActionAges.count == 1) // upload is not cross-device receipt
        for i in 0..<110 {
            diag.received(action: "tick-running", seq: Int64(i), device: "phone", sourceAt: t,
                          now: t, seconds: 0.1, reason: "push", revision: "v\(i)")
        }
        #expect(diag.receipts.count == 100)
        #expect(diag.receivedActionAges.isEmpty) // heartbeats not treated as user-action measurements
    }

    @Test func activePollingDoesNotIncreaseIdleTraffic() {
        #expect(FocusSyncPolicy.pollInterval(hasLocalRun: false, hasFollowedRun: false, hasPending: false) == 15)
        #expect(FocusSyncPolicy.pollInterval(hasLocalRun: false, hasFollowedRun: true, hasPending: false) == 5)
        #expect(FocusSyncPolicy.pollInterval(hasLocalRun: true, hasFollowedRun: false, hasPending: false) == 5)
        #expect(FocusSyncPolicy.pollInterval(hasLocalRun: false, hasFollowedRun: false, hasPending: true) == 5)
    }

    @Test func idleCatchUpNeverPublishesAFakeCompletion() {
        #expect(!FocusSyncPolicy.shouldPublish(kind: "tick", hasActive: false))
        #expect(FocusSyncPolicy.shouldPublish(kind: "complete", hasActive: false))
        #expect(FocusSyncPolicy.shouldPublish(kind: "tick", hasActive: true))
    }

    @Test func followedRunProducesRemoteLiveActivityAndRefreshesOnNewRevision() {
        let state = FollowRunState()
        var changes = 0
        state.onChange = { changes += 1 }
        let first = FollowRunState.Run(title: "写作", sourceDevice: "mac", style: "pomodoro",
                                       startedAt: t, updatedAt: t, seq: 10)
        state.set(first)
        let snapshot = first.liveActivitySnapshot
        #expect(snapshot.title == "写作")
        #expect(snapshot.timerStart == t)
        #expect(snapshot.isRemote)
        #expect(snapshot.mode == .light)

        var next = first
        next.seq = 11
        next.startedAt = t.addingTimeInterval(5)
        state.set(next)
        #expect(changes == 2)
    }
}
