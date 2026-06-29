//
//  BetterCalendarTests.swift
//  BetterCalendarTests
//
//  自动化测试：覆盖可单测的逻辑（解析/JSON/日期/回退/路由/映射）。
//  EventKit 真日历需权限+GUI，不在此自动测——见冒烟测试表。
//

import Testing
import Foundation
@testable import BetterCalendar

@MainActor
struct LogicTests {

    // MARK: 工具

    @Test func dateParsingHandlesFormatsAndEmpty() {
        #expect(DateParsing.parse("2026-06-30 09:00") != nil)
        #expect(DateParsing.parse("2026-06-30T09:00:00") != nil)
        #expect(DateParsing.parse("2026-06-30T09:00:00Z") != nil)
        #expect(DateParsing.parse("") == nil)
        #expect(DateParsing.parse(nil) == nil)
        #expect(DateParsing.parse("不是日期") == nil)
    }

    @Test func jsonExtractStripsFenceAndSurroundingText() {
        #expect(JSONText.extractObject("```json\n{\"a\":1}\n```") == "{\"a\":1}")
        #expect(JSONText.extractObject("前缀 {\"a\":1} 后缀") == "{\"a\":1}")
        #expect(JSONText.extractObject("{\"a\":1}") == "{\"a\":1}")
    }

    // MARK: 本地排程

    @Test func naivePlannerPutsImportantFirst() async throws {
        let planner = NaivePlanningEngine()
        let now = Date()
        let normal = ScheduledBlock(title: "普通", start: now,
                                    end: now.addingTimeInterval(3600), priority: .normal)
        let important = ScheduledBlock(title: "要紧", start: now.addingTimeInterval(7200),
                                       end: now.addingTimeInterval(10800), priority: .important)
        let decision = try await planner.arrange([normal, important], now: now)
        #expect(decision.orderedBlocks.first?.priority == .important)
        #expect(decision.orderedBlocks.count == 2)
    }

    // MARK: 假日历

    @Test func fakeCalendarReplacesSameKind() async throws {
        let store = FakeCalendarStore()
        let now = Date()
        try await store.write([CalendarEventDraft(title: "A", start: now,
                                                  end: now.addingTimeInterval(3600), kind: .planned)])
        try await store.write([CalendarEventDraft(title: "B", start: now,
                                                  end: now.addingTimeInterval(3600), kind: .planned)])
        let planned = try await store.read(kind: .planned)
        #expect(planned.count == 1)              // 同类替换，不累积
        #expect(planned.first?.title == "B")
    }

    // MARK: 云端失败 → 回退本地（用无 key 客户端模拟失败）

    @Test func parserFallsBackToLocalWhenNoKey() async throws {
        let noKey = AnthropicClient(apiKey: { nil }, useCloud: { true })
        let parser = ClaudeScheduleParser(client: noKey, fallback: StubScheduleParser())
        let plan = try await parser.parse("写代码，开会", referenceDate: Date())
        #expect(plan.blocks.count == 2)          // 回退本地桩按逗号切
    }

    @Test func plannerFallsBackToLocalWhenNoKey() async throws {
        let noKey = AnthropicClient(apiKey: { nil }, useCloud: { true })
        let planner = LLMPlanningEngine(client: noKey, fallback: NaivePlanningEngine())
        let now = Date()
        let block = ScheduledBlock(title: "x", start: now, end: now.addingTimeInterval(3600))
        let decision = try await planner.arrange([block], now: now)
        #expect(decision.orderedBlocks.count == 1)
    }

    @Test func refinerKeepsDraftOnFailureOrEmptyCommand() async throws {
        let noKey = AnthropicClient(apiKey: { nil }, useCloud: { true })
        let refiner = ClaudePlanRefiner(client: noKey)
        let now = Date()
        let block = ScheduledBlock(title: "x", start: now, end: now.addingTimeInterval(3600))
        let onFailure = try await refiner.refine([block], command: "把x挪到下午", now: now)
        #expect(onFailure.count == 1)            // 云端失败 → 原样
        let onEmpty = try await refiner.refine([block], command: "  ", now: now)
        #expect(onEmpty.count == 1)              // 空指令 → 原样
    }

    // MARK: 草稿映射

    @Test func editableBlockRoundTrips() {
        let now = Date()
        let sb = ScheduledBlock(title: "读书", start: now, end: now.addingTimeInterval(1800),
                                isFixed: true, priority: .important)
        let eb = EditableBlock(from: sb)
        #expect(eb.title == "读书")
        #expect(eb.isFixed)
        #expect(eb.priority == .important)
        let back = eb.scheduled
        #expect(back.id == sb.id)
        #expect(back.priority == .important)
        #expect(back.isFixed)
    }

    // MARK: 日历后端路由

    @Test func routingWritesToFakeWhenBackendFake() async throws {
        CalendarSettings.backend = .fake
        let fake = FakeCalendarStore()
        let routing = RoutingCalendarStore(fake: fake, eventKit: EventKitCalendarStore())
        let now = Date()
        try await routing.write([CalendarEventDraft(title: "T", start: now,
                                                    end: now.addingTimeInterval(3600), kind: .planned)])
        #expect(fake.captured.count == 1)        // 路由到假日历
    }
}
