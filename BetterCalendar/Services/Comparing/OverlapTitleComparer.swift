//
//  OverlapTitleComparer.swift
//  BetterCalendar
//
//  PlanComparing 的本地启发式实现。贪心地为每个计划块挑最佳实际块匹配：
//  - 匹配分 = 标题相似 与 时间重叠 的较优者（标题为主、时间为辅）。
//    → 标题相似可跨时间匹配（块被挪动）；时间重叠可跨标题匹配（健身→跑步 内容变更）。
//  - 匹配上后按 实际/计划 时长比 → partial(<0.8) / done / over(>1.25)。
//  - 没匹配上的计划块 = missed(未做)；剩下的实际块 = extra(计划外 bonus)。
//

import Foundation

struct OverlapTitleComparer: PlanComparing {
    private let matchThreshold = 0.34   // 低于此分视为没匹配上
    private let doneLow = 0.8
    private let doneHigh = 1.25

    func compare(planned: [CalendarEventDraft], actual: [CalendarEventDraft]) -> DayComparison {
        var pool = actual                       // 尚未匹配的实际块
        var items: [ComparedItem] = []

        // ① 按章精确配对（0.20.2）：计划块与"为它记的实际"带同一 UUID（执行层盖的章）——
        //    同名两块不混、改名不丢。先把 ID 能对上的全配掉，剩下的才进启发式。
        var unmatched: [CalendarEventDraft] = []
        for p in planned.sorted(by: { $0.start < $1.start }) {
            if let bid = p.blockID, let i = pool.firstIndex(where: { $0.blockID == bid }) {
                items.append(matchedItem(planned: p, actual: pool.remove(at: i)))
            } else {
                unmatched.append(p)
            }
        }

        // ② 启发式兜底（无章老数据 / 标题相近的内容变更）：原贪心逻辑不变
        for p in unmatched {
            let pMin = minutes(p)
            var bestIdx: Int?
            var bestScore = 0.0
            for (i, a) in pool.enumerated() {
                let s = score(p, a)
                if s > bestScore { bestScore = s; bestIdx = i }
            }

            if let i = bestIdx, bestScore >= matchThreshold {
                items.append(matchedItem(planned: p, actual: pool.remove(at: i)))
            } else {
                items.append(ComparedItem(status: .missed, plannedTitle: p.title,
                                          actualTitle: nil, plannedMinutes: pMin,
                                          actualMinutes: nil, anchor: p.start))
            }
        }

        for a in pool {   // 计划里没有、却真做了的 = bonus
            items.append(ComparedItem(status: .extra, plannedTitle: nil, actualTitle: a.title,
                                      plannedMinutes: nil, actualMinutes: minutes(a), anchor: a.start))
        }

        items.sort { $0.anchor < $1.anchor }
        return DayComparison(items: items)
    }

    /// 配上对后的归类（ID 配对与启发式共用）：按 实际/计划 时长比 → partial/done/over。
    private func matchedItem(planned p: CalendarEventDraft, actual a: CalendarEventDraft) -> ComparedItem {
        let pMin = minutes(p)
        let aMin = minutes(a)
        let ratio = pMin > 0 ? Double(aMin) / Double(pMin) : 1
        let status: CompletionStatus =
            ratio < doneLow ? .partial : (ratio > doneHigh ? .over : .done)
        return ComparedItem(status: status, plannedTitle: p.title,
                            actualTitle: a.title, plannedMinutes: pMin,
                            actualMinutes: aMin, anchor: a.start)
    }

    private func score(_ p: CalendarEventDraft, _ a: CalendarEventDraft) -> Double {
        let sim = TitleMatch.similarity(p.title, a.title)
        let ov = overlapFraction(p, a)
        return max(sim, 0.6 * ov + 0.4 * sim)
    }

    private func overlapFraction(_ p: CalendarEventDraft, _ a: CalendarEventDraft) -> Double {
        let lo = max(p.start, a.start)
        let hi = min(p.end, a.end)
        let ov = max(0, hi.timeIntervalSince(lo))
        let denom = min(p.end.timeIntervalSince(p.start), a.end.timeIntervalSince(a.start))
        return denom > 0 ? ov / denom : 0
    }

    private func minutes(_ d: CalendarEventDraft) -> Int {
        max(0, Int(d.end.timeIntervalSince(d.start) / 60))
    }
}
