//
//  DayContext.swift
//  BetterCalendar
//
//  「逻辑日」地基：让跨天逻辑（排程 / 复盘 / streak / reflow）统一、对用户无感、且可注入时间测试。
//
//  两个核心约定：
//  1) **日界线 = 凌晨 4 点**（可调）：凌晨熬夜时，心智上的"今天"还没翻篇。
//     用户凌晨 1 点说"明天 9 点开会"，他的"明天"=日历今天上午——把日界线推到 4 点，
//     "逻辑今天"=日历昨天，"明天"自然落到日历今天，与心智对齐。
//  2) **默认排哪天**（智能猜 + 可改）：晚上打开默认排"明天"（前一晚规划），白天/凌晨默认排"今天"。
//     默认通常猜对 → 无感；猜错时 UI 给一个可点的目标日期标签一键改。
//

import Foundation

enum DayContext {
    /// 日界线小时：本地时间 [0:00, 4:00) 仍算「前一天」。
    static let dayBoundaryHour = 4
    /// 晚上从几点起默认排「明天」（前一晚规划场景）。
    static let eveningStartHour = 18

    private static var cal: Calendar { Calendar.current }

    /// 给定时刻所属「逻辑日」的零点（日历日，已含凌晨 4 点偏移）。
    static func logicalStartOfDay(_ now: Date) -> Date {
        let base = cal.startOfDay(for: now)
        let hour = cal.component(.hour, from: now)
        return hour < dayBoundaryHour ? cal.date(byAdding: .day, value: -1, to: base)! : base
    }

    /// 两个时刻是否属同一逻辑日（复盘/streak 判断"是今天的事"用）。
    static func isSameLogicalDay(_ a: Date, _ b: Date) -> Bool {
        logicalStartOfDay(a) == logicalStartOfDay(b)
    }

    /// 某逻辑日（label = 该日零点，logicalStartOfDay 的返回值）的时间窗：[label 4:00, 次日 4:00)。
    /// 块/事件归属 = start 落在窗内（半开区间）。投影/日历谓词用；PlanStore 归桶用 logicalStartOfDay 等值即可。
    static func logicalWindow(forLabel label: Date) -> DateInterval {
        let base = cal.startOfDay(for: label)
        let start = cal.date(byAdding: .hour, value: dayBoundaryHour, to: base) ?? base
        let nextBase = cal.date(byAdding: .day, value: 1, to: base) ?? base
        let end = cal.date(byAdding: .hour, value: dayBoundaryHour, to: nextBase) ?? start
        return DateInterval(start: start, end: end)
    }

    /// 智能默认排哪天（重构后按**逻辑日**，用户以逻辑日生活）：
    /// 晚上(≥18) → 明天；白天 → 今天；凌晨(0–4) → **逻辑今天**（=日历昨天，心智上的"今天"还没翻篇——
    /// 此时排"现在到3点"落在逻辑今天的桶里，与所选目标日一致；说"明天9点开会"解析仍会落到日历今天=逻辑明天的桶）。
    static func defaultTargetDay(_ now: Date = .now) -> Date {
        let hour = cal.component(.hour, from: now)
        if hour < dayBoundaryHour { return logicalStartOfDay(now) }
        let today = cal.startOfDay(for: now)
        return hour >= eveningStartHour ? (cal.date(byAdding: .day, value: 1, to: today) ?? today) : today
    }

    /// 逻辑日的可排尾界 = 次日日界线（凌晨 4 点）。块结束超过它＝真排不下（reflow 冲突判定）。
    static func endOfPlannableDay(_ now: Date = .now) -> Date {
        let nextDayStart = cal.date(byAdding: .day, value: 1, to: logicalStartOfDay(now)) ?? now
        return nextDayStart.addingTimeInterval(TimeInterval(dayBoundaryHour * 3600))
    }

    /// 逻辑今天偏移 offset 天的标签（offset=-1 昨天 / 0 今天 / 1 明天 / 2 后天）。
    /// 「选哪天排」的今天/明天标签用它：白天与日历日一致；凌晨 0–4 点「今天」=逻辑今天（日历昨天），
    /// 与 defaultTargetDay / PlanStore 逻辑日归桶对齐（用户以逻辑日生活）。
    static func logicalDay(offset: Int, from now: Date = .now) -> Date {
        let base = logicalStartOfDay(now)
        return cal.date(byAdding: .day, value: offset, to: base) ?? base
    }

    /// 逻辑日的稳定字符串键（yyyy-MM-dd），用于 streak 等按天去重。
    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: logicalStartOfDay(date))
    }
}
