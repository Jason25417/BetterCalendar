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
        var isLoose: Bool = false   // 解析到"想松散"的显式意图 → 标目标日松散（§5.12）
    }

    /// referenceDate = 解析相对时间的基准日（排哪天就传哪天）；now = 排序用的此刻；
    /// pool = 「在途」摘要（M10-2，LLM 可据此给建议块；空 = 不建议）。
    func full(text: String, referenceDate: Date = .now, now: Date = .now,
              pool: [LongTaskBrief] = [], context: ParseContext = ParseContext()) async throws -> Outcome {
        let parsed = try await parser.parse(text, referenceDate: referenceDate, context: context)
        let scheduled: [ScheduledBlock] = parsed.blocks.compactMap { pb in
            guard let start = pb.start, let end = pb.end else { return nil }
            let (s, e) = Self.clampToDay(start: start, end: end, referenceDate: referenceDate)
            // 锚点标题兜底（0.22.2，Jason 报模型漏标「午饭」）：明显的作息标题强制 isAnchor=true；只加不减
            let anchor = pb.isAnchor || Self.isObviousAnchor(pb.title)
            return ScheduledBlock(title: pb.title, start: s, end: e,
                                  isFixed: pb.isFixed, isAnchor: anchor, timingStyle: pb.timingStyle,
                                  priority: pb.priority, deadline: pb.deadline, labels: pb.labels)
        }
        let decision = try await planner.arrange(scheduled, pool: pool, now: now)
        return Outcome(decision: decision, longTasks: parsed.longTasks, isLoose: parsed.isLoose)
    }

    /// 把块钉到"目标日"那天（保留时分）——杀日期漂移（"明天"被读成次日 7/7、LLM 年份幻觉如 2025 等），
    /// 否则块落到别的日子、今天读回来是空的（menu bar 空档 / 开始今天无计划块）。
    /// 凌晨(<6点)的块=睡前跨午夜，落**次日**；其余落参考日。纯函数、可单测。
    static func clampToDay(start: Date, end: Date, referenceDate: Date) -> (Date, Date) {
        let cal = Calendar.current
        let sc = cal.dateComponents([.hour, .minute], from: start)
        let hour = sc.hour ?? 0
        let base = hour < 6 ? (cal.date(byAdding: .day, value: 1, to: referenceDate) ?? referenceDate) : referenceDate
        let s = cal.date(bySettingHour: hour, minute: sc.minute ?? 0, second: 0, of: base) ?? start
        return (s, s.addingTimeInterval(max(0, end.timeIntervalSince(start))))
    }

    /// 明显的作息锚点标题（模型漏标时的确定性兜底；只加不减——模型标了的照样是）。纯函数、可单测。
    static func isObviousAnchor(_ title: String) -> Bool {
        let anchors = ["午饭", "晚饭", "早饭", "午餐", "晚餐", "早餐", "吃饭", "午休", "通勤", "睡觉", "洗漱"]
        return anchors.contains { title.contains($0) }
    }

    /// 兼容旧调用（复盘回填等只要决策）。
    func callAsFunction(text: String, referenceDate: Date = .now, now: Date = .now) async throws -> PlanDecision {
        try await full(text: text, referenceDate: referenceDate, now: now).decision
    }
}
