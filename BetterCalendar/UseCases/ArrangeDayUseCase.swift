//
//  ArrangeDayUseCase.swift
//  BetterCalendar
//
//  用例层：自然语言 → 解析 → 排程，返回决策。
//  注意：**不写日历**——写入交给「确认」步骤（先让用户预览微调）。
//

import Foundation

struct ArrangeDayUseCase {
    let parser: ScheduleParsing
    let planner: PlanningEngine

    /// referenceDate = 解析相对时间的基准日（排哪天就传哪天）；now = 排序用的此刻。
    func callAsFunction(text: String, referenceDate: Date = .now, now: Date = .now) async throws -> PlanDecision {
        let parsed = try await parser.parse(text, referenceDate: referenceDate)
        let scheduled: [ScheduledBlock] = parsed.blocks.compactMap { pb in
            guard let start = pb.start, let end = pb.end else { return nil }
            return ScheduledBlock(title: pb.title, start: start, end: end,
                                  isFixed: pb.isFixed, timingStyle: pb.timingStyle,
                                  priority: pb.priority, deadline: pb.deadline)
        }
        return try await planner.arrange(scheduled, now: now)
    }
}
