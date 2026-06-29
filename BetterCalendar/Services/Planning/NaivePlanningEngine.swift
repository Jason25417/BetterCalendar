//
//  NaivePlanningEngine.swift
//  BetterCalendar
//
//  朴素本地兜底：要紧事排前、其余按开始时间。措辞走正反馈 / 前向口径。
//  真正的细腻决策以后由 LLMPlanningEngine 接管。
//

import Foundation

struct NaivePlanningEngine: PlanningEngine {
    func arrange(_ blocks: [ScheduledBlock], now: Date) async throws -> PlanDecision {
        let ordered = blocks.sorted { a, b in
            if a.priority != b.priority { return a.priority == .important }
            return a.start < b.start
        }
        let importantCount = ordered.filter { $0.priority == .important }.count
        let note: String
        if ordered.isEmpty {
            note = "今天还没有安排，说点什么吧。"
        } else if importantCount > 0 {
            note = "从现在起，先把 \(importantCount) 件要紧事拿下，其余顺着来就好。"
        } else {
            note = "排好了 \(ordered.count) 件，按自己的节奏来。"
        }
        return PlanDecision(orderedBlocks: ordered, note: note)
    }
}
