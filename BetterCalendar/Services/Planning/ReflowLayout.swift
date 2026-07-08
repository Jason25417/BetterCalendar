//
//  ReflowLayout.swift
//  BetterCalendar
//
//  re-flow 的「铺时间」纯逻辑（确定、可单测）：给定弹性块的执行顺序 + 固定块，
//  从 startTime 起把弹性块依次铺开、保各自时长；固定块锚在原时间不动；
//  弹性块若撞上固定块则顺延到该固定块之后。
//  Naive 与 LLM 两种 reflow 共用——区别只在「弹性块用什么顺序」（Naive=按原时间，LLM=智能重排）。
//

import Foundation

enum ReflowLayout {
    static func layOut(flexible: [ScheduledBlock], fixed: [ScheduledBlock],
                       from startTime: Date) -> [ScheduledBlock] {
        var cursor = startTime
        var result = fixed                    // 固定块原样锚住
        // 并行组绑定（0.22）：同 parallel 组的弹性块合并为一个「槽」（槽长=组内最长时长），
        // 槽整体排定后组内各块**同一起点、各自时长**——reflow/微调不再拆散并行组。
        var slots: [[ScheduledBlock]] = []
        var seenGroups = Set<String>()
        for b in flexible {
            if let g = b.parallelGroup {
                guard !seenGroups.contains(g) else { continue }   // 已并入槽
                seenGroups.insert(g)
                slots.append(flexible.filter { $0.parallelGroup == g })
            } else {
                slots.append([b])
            }
        }
        for slot in slots {
            let slotDur = slot.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0
            var s = cursor
            var e = s.addingTimeInterval(slotDur)
            // 撞任一固定块就顺延到其后（可能连撞几个，循环到不撞为止；固定块有限，必收敛）
            var moved = true
            while moved {
                moved = false
                for f in fixed where s < f.end && e > f.start {
                    s = f.end
                    e = s.addingTimeInterval(slotDur)
                    moved = true
                }
            }
            for b in slot {
                var nb = b
                nb.start = s
                nb.end = s.addingTimeInterval(b.end.timeIntervalSince(b.start))
                result.append(nb)
            }
            cursor = e
        }
        return result.sorted { $0.start < $1.start }
    }

    // conflict 检测已退役（0.23 B）：溢出语义改为候补（ReflowLayoutV2.layOut 直接产出 deferred）。
}
