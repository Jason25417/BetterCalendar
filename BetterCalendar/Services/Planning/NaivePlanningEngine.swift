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

    /// 本地 reflow：弹性块按原时间顺序，从 startTime 起铺；固定块锚住、撞了顺延。
    func reflow(_ blocks: [ScheduledBlock], from startTime: Date, now: Date) async throws -> PlanDecision {
        let sorted = blocks.sorted { $0.start < $1.start }
        let laid = ReflowLayout.layOut(flexible: sorted.filter { !$0.isFixed },
                                       fixed: sorted.filter { $0.isFixed },
                                       from: startTime)
        let note = laid.isEmpty ? "今天到这儿就挺好。" : "从现在起这样安排，轻松收尾。"
        return PlanDecision(orderedBlocks: laid, note: note,
                            conflict: ReflowLayout.conflict(in: laid, now: now))
    }
}
