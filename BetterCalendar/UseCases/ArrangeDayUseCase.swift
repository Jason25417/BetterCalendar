//
//  ArrangeDayUseCase.swift
//  BetterCalendar
//
//  用例层：把「自然语言 → 解析 → 排程 → 写日历」编排成一个动作。
//  把业务逻辑从 UI 抽走，GUI 按钮与 App Intent 都能调同一个用例。
//

import Foundation

struct ArrangeDayUseCase {
    let parser: ScheduleParsing
    let planner: PlanningEngine
    let calendarStore: CalendarStore

    func callAsFunction(text: String, now: Date = .now) async throws -> PlanDecision {
        let parsed = try await parser.parse(text, referenceDate: now)
        let scheduled: [ScheduledBlock] = parsed.blocks.compactMap { pb in
            guard let start = pb.start, let end = pb.end else { return nil }
            return ScheduledBlock(title: pb.title, start: start, end: end,
                                  isFixed: pb.isFixed, timingStyle: pb.timingStyle,
                                  priority: pb.priority, deadline: pb.deadline)
        }
        let decision = try await planner.arrange(scheduled, now: now)
        let drafts = decision.orderedBlocks.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .planned)
        }
        try await calendarStore.write(drafts)
        return decision
    }
}
