import Foundation
import Testing
import SwiftData
@testable import BetterCalendar

@MainActor struct BridgeTaskTests {
    private final class Service: BridgeTaskServing {
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        var sessions: [BridgeTaskSession] = []
        var requests: [BridgeTaskCommand] = []
        var committed: Set<String> = []
        var loseFirstReply = false
        func readTasks() async throws -> BridgeTaskState {
            BridgeTaskState(schemaVersion: 1, authority: "bettercalendar", readAt: clock, sessions: sessions, hasMore: false)
        }
        func submitTask(_ command: BridgeTaskCommand) async throws -> BridgeTaskReceipt {
            requests.append(command)
            if !committed.contains(command.commandId) {
                if command.action == .start {
                    sessions.append(BridgeTaskSession(id: "session", title: command.title!, status: .running,
                                                      startedAt: command.occurredAt, activeSince: command.occurredAt,
                                                      elapsedMs: 0, updatedAt: command.occurredAt, revision: 1,
                                                      provenance: "user", relatedRecordId: command.relatedRecordId))
                } else {
                    guard let i = sessions.firstIndex(where: { $0.id == command.sessionId }),
                          sessions[i].revision == command.expectedRevision else { throw NSError(domain: "StateBridge.HTTP", code: 409) }
                    sessions[i].status = command.action == .pause ? .paused : command.action == .resume ? .running : .finished
                    sessions[i].revision += 1
                    if command.action == .finish { sessions.remove(at: i) }
                }
                committed.insert(command.commandId)
                if loseFirstReply { loseFirstReply = false; throw URLError(.timedOut) }
            }
            return BridgeTaskReceipt(commandId: command.commandId, saved: true)
        }
    }

    @Test func lostReplyAndAppRestartRetryTheOriginalCommandWithoutSecondSession() async {
        let service = Service(), disk = BridgeTaskMemoryPersistence()
        service.loseFirstReply = true
        let first = BridgeTaskViewModel(service: service, persistence: disk, enabled: { true }, now: { service.clock })
        await first.refresh()
        await first.start(title: "数学", relatedRecordId: "PlanBlock:old-id")
        #expect(first.pendingCount == 1)
        #expect(first.sessions.isEmpty) // Never claim a received receipt that was lost.
        let replay = BridgeTaskViewModel(service: service, persistence: disk, enabled: { true }, now: { service.clock })
        await replay.refresh()
        #expect(replay.pendingCount == 0 && replay.sessions.count == 1)
        #expect(service.requests.count == 2 && service.requests[0] == service.requests[1])
        #expect(replay.sessions[0].relatedRecordId == "PlanBlock:old-id")
    }

    @Test func otherDeviceRevisionWinsAndRejectedRequestRemainsInspectable() async {
        let service = Service(), disk = BridgeTaskMemoryPersistence()
        let model = BridgeTaskViewModel(service: service, persistence: disk, enabled: { true }, now: { service.clock })
        await model.refresh()
        await model.start(title: "阅读")
        let stale = model.sessions[0]
        service.sessions[0].revision = 2; service.sessions[0].status = .paused
        await model.act(.pause, on: stale)
        #expect(model.pendingCount == 0 && model.reviewCount == 1)
        #expect(model.sessions[0].revision == 2 && model.sessions[0].status == .paused)
        await model.act(.resume, on: model.sessions[0])
        #expect(model.sessions[0].revision == 3 && model.sessions[0].status == .running)
        #expect(disk.file.pending.count == 1 && disk.file.pending[0].needsReview)
    }

    @Test func corruptQueueIsPreservedAndBlocksNewCommands() async {
        let service = Service(), disk = BridgeTaskMemoryPersistence(); disk.file.schemaVersion = 99
        let model = BridgeTaskViewModel(service: service, persistence: disk, enabled: { true })
        await model.start(title: "不应发出")
        #expect(!model.canSubmit && model.lastError != nil)
        #expect(disk.file.schemaVersion == 99 && service.requests.isEmpty)
    }

    @Test func failedLocalSaveCannotConfirmOrSendAnOperation() async {
        final class FailingDisk: BridgeTaskPersisting {
            func load() throws -> BridgeTaskLocalFile {
                BridgeTaskLocalFile(state: BridgeTaskState(schemaVersion: 1, authority: "bettercalendar", readAt: .now, sessions: [], hasMore: false),
                                    localMidpoint: .now, receivedAt: .now)
            }
            func save(_ file: BridgeTaskLocalFile) throws { throw CocoaError(.fileWriteOutOfSpace) }
        }
        let service = Service(), model = BridgeTaskViewModel(service: service, persistence: FailingDisk(), enabled: { true })
        await model.start(title: "不应发出")
        #expect(service.requests.isEmpty && model.pendingCount == 0 && model.lastError != nil)
    }

    @Test func displayProjectsOneServerClockAndPausedElapsedNeverGrows() throws {
        let at = Date(timeIntervalSince1970: 1000)
        var session = BridgeTaskSession(id: "x", title: "计时", status: .running, startedAt: at, activeSince: at,
                                        elapsedMs: 120000, updatedAt: at, revision: 1, provenance: "user")
        #expect(session.elapsed(at: at.addingTimeInterval(10), localMidpoint: at) == 130)
        session.status = .paused
        #expect(session.elapsed(at: at.addingTimeInterval(10000), localMidpoint: at) == 120)
        let data = Data("{\"schemaVersion\":1,\"authority\":\"bettercalendar\",\"readAt\":\"2026-10-12T14:00:00.123Z\",\"sessions\":[],\"hasMore\":false}".utf8)
        let state = try BridgeTaskCodec.networkDecoder().decode(BridgeTaskState.self, from: data)
        try state.validate()
        #expect(abs(state.readAt.timeIntervalSince1970 - 1791813600.123) < 0.001)
    }

    @Test func nativeButtonsUseCloudSessionWithoutWritingSecondLocalHistory() async throws {
        final class Activity: ExecutionLiveActivity {
            var snapshot: LiveActivitySnapshot?
            func start(_ snapshot: LiveActivitySnapshot) { self.snapshot = snapshot }
            func update(_ snapshot: LiveActivitySnapshot) { self.snapshot = snapshot }
            func end() { snapshot = nil }
        }
        let container = try ModelContainer(for: PlanBlock.self, ExecutionSession.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let plans = PlanStore(context: container.mainContext), service = Service(), activity = Activity()
        service.clock = Date()
        let tasks = BridgeTaskViewModel(service: service, persistence: BridgeTaskMemoryPersistence(), enabled: { true }, now: { service.clock })
        let execution = ExecutionViewModel(calendarStore: FakeCalendarStore(),
                                           reschedule: RescheduleService(planStore: plans, planner: NaivePlanningEngine()),
                                           planStore: plans, reminderStore: FakeReminderStore(), liveActivity: activity,
                                           sessionStore: ExecutionSessionStore(context: container.mainContext),
                                           persistsRunState: false, canonicalTasks: tasks)
        tasks.onChange = { [weak execution] in execution?.syncCanonicalPresentation() }
        await tasks.refresh()
        await execution.startAdHoc(title: "同一份计时")
        #expect(execution.active == nil && tasks.sessions.count == 1)
        #expect(activity.snapshot?.title == "同一份计时")
        await execution.toggleBreak()
        #expect(tasks.sessions[0].status == .paused && activity.snapshot?.pausedAt != nil)
        await execution.completeCurrent()
        #expect(tasks.sessions.isEmpty && activity.snapshot == nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ExecutionSession>()) == 0)
        #expect(try plans.actualBlocks(on: Date()).isEmpty)
        #expect(service.requests.map(\.action) == [.start, .pause, .finish])
    }

    @Test func deviceClockOffsetIsCorrectedForCommandsAsWellAsDisplay() async {
        let service = Service()
        let localClock = service.clock.addingTimeInterval(3600)
        let tasks = BridgeTaskViewModel(service: service, persistence: BridgeTaskMemoryPersistence(), enabled: { true }, now: { localClock })
        await tasks.refresh()
        await tasks.start(title: "授时验证")
        #expect(service.requests[0].occurredAt == service.clock)
        #expect(tasks.elapsed(tasks.sessions[0], at: localClock.addingTimeInterval(10)) == 10)
    }
}
