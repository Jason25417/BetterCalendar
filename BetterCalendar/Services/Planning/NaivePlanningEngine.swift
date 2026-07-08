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

    /// 本地 reflow（0.23 B 起 V2）：弹性块按原时间顺序从 startTime 起铺；固定块锚住、撞了顺延；
    /// **收工线硬执法**——放不进 线+宽限 的整块进候补（★与晚间自排块豁免，见 ReflowLayoutV2）。
    func reflow(_ blocks: [ScheduledBlock], from startTime: Date, now: Date) async throws -> PlanDecision {
        let sorted = blocks.sorted { $0.start < $1.start }
        let laid = ReflowLayoutV2.layOut(flexible: sorted.filter { !$0.isFixed },
                                         fixed: sorted.filter { $0.isFixed },
                                         from: startTime,
                                         windDown: WorkHoursSettings.effectiveWindDown(from: startTime),
                                         graceMinutes: WorkHoursSettings.graceMinutes)
        let note = laid.scheduled.isEmpty ? "今天到这儿就挺好。" : "从现在起这样安排，轻松收尾。"
        return PlanDecision(orderedBlocks: laid.scheduled, note: note, deferred: laid.deferred)
    }
}
