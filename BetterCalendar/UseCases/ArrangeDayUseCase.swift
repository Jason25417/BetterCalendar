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

    /// 完整产出：当日排程决策 + 识别到的长期事项提案（M10「在途」）。
    struct Outcome {
        var decision: PlanDecision
        var longTasks: [ParsedLongTask] = []
    }

    /// referenceDate = 解析相对时间的基准日（排哪天就传哪天）；now = 排序用的此刻；
    /// pool = 「在途」摘要（M10-2，LLM 可据此给建议块；空 = 不建议）。
    func full(text: String, referenceDate: Date = .now, now: Date = .now,
              pool: [LongTaskBrief] = [], context: ParseContext = ParseContext()) async throws -> Outcome {
        let parsed = try await parser.parse(text, referenceDate: referenceDate, context: context)
        let scheduled: [ScheduledBlock] = parsed.blocks.compactMap { pb in
            guard let start = pb.start, let end = pb.end else { return nil }
            return ScheduledBlock(title: pb.title, start: start, end: end,
                                  isFixed: pb.isFixed, timingStyle: pb.timingStyle,
                                  priority: pb.priority, deadline: pb.deadline)
        }
        let decision = try await planner.arrange(scheduled, pool: pool, now: now)
        return Outcome(decision: decision, longTasks: parsed.longTasks)
    }

    /// 兼容旧调用（复盘回填等只要决策）。
    func callAsFunction(text: String, referenceDate: Date = .now, now: Date = .now) async throws -> PlanDecision {
        try await full(text: text, referenceDate: referenceDate, now: now).decision
    }
}
