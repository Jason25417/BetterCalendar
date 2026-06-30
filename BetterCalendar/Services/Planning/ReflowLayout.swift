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
        for b in flexible {
            let dur = b.end.timeIntervalSince(b.start)
            var s = cursor
            var e = s.addingTimeInterval(dur)
            // 撞任一固定块就顺延到其后（可能连撞几个，循环到不撞为止；固定块有限，必收敛）
            var moved = true
            while moved {
                moved = false
                for f in fixed where s < f.end && e > f.start {
                    s = f.end
                    e = s.addingTimeInterval(dur)
                    moved = true
                }
            }
            var nb = b
            nb.start = s
            nb.end = e
            result.append(nb)
            cursor = e
        }
        return result.sorted { $0.start < $1.start }
    }

    /// 检测排不下：弹性块结束超过逻辑日尾界 → 取溢出最多的那块作冲突。
    static func conflict(in blocks: [ScheduledBlock], now: Date) -> ReflowConflict? {
        let deadline = DayContext.endOfPlannableDay(now)
        guard let over = blocks.filter({ !$0.isFixed && $0.end > deadline })
            .max(by: { $0.end < $1.end }) else { return nil }
        return ReflowConflict(blockTitle: over.title,
                              overflowMinutes: Int(over.end.timeIntervalSince(deadline) / 60))
    }
}
