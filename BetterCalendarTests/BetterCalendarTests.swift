//
//  BetterCalendarTests.swift
//  BetterCalendarTests
//
//  用假实现测 ViewModel/逻辑——协议是测试缝。
//

import Testing
import Foundation
@testable import BetterCalendar

@MainActor
struct PlanningTests {

    @Test func importantBlocksGoFirst() async throws {
        let planner = NaivePlanningEngine()
        let now = Date()
        let normal = ScheduledBlock(title: "普通",
                                    start: now,
                                    end: now.addingTimeInterval(3600),
                                    priority: .normal)
        let important = ScheduledBlock(title: "要紧",
                                       start: now.addingTimeInterval(7200),
                                       end: now.addingTimeInterval(10800),
                                       priority: .important)
        let decision = try await planner.arrange([normal, important], now: now)
        #expect(decision.orderedBlocks.first?.priority == .important)
        #expect(decision.orderedBlocks.count == 2)
    }

    @Test func fakeCalendarCapturesWrites() async throws {
        let store = FakeCalendarStore()
        let now = Date()
        try await store.write([
            CalendarEventDraft(title: "测试", start: now,
                               end: now.addingTimeInterval(3600), kind: .planned)
        ])
        let planned = try await store.read(kind: .planned)
        #expect(planned.count == 1)
        #expect(planned.first?.title == "测试")
    }

    @Test func arrangeDayUseCaseReturnsBlocks() async throws {
        let useCase = ArrangeDayUseCase(parser: StubScheduleParser(),
                                        planner: NaivePlanningEngine())
        let decision = try await useCase(text: "写代码，开会，健身")
        #expect(decision.orderedBlocks.count == 3)
    }
}
