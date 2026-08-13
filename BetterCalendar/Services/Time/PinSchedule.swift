//
//  PinSchedule.swift
//  BetterCalendar
//
//  图钉体系（统一时间线 P1a，SPEC §13.A.15）：时间线上零长度的时刻标记。
//  「属于哪天」「收工线在哪」这类边界，从散落各处的现算收拢为**一份图钉数学**：
//  图钉序列在绝对时间轴上严格单调，逻辑日 = 相邻跨日图钉的半开区间，永不重叠、永不跳空
//  （跨时区出现 12/36 小时的日子是物理现实，区间照常成立、统计照常归桶——Jason 2026-07-30 裁）。
//  规则：结构图钉（跨日/收工/傍晚）由规则懒生成、不持久化；跨日钉**恒 4 点、不做设置**
//  （2026-07-10 裁决维持）；跨时区自动跟随系统时区 = 生成规则用 Calendar.current（非配置）。
//  DayContext / WorkHoursSettings 保持既有 API，内部数学迁到这里（一份数学，一处改）。
//  注：日历运算一律 calendar.date(byAdding:)，不用 addingTimeInterval——DST 切换日安全。
//

import Foundation

/// 图钉种类（v1 = 三种结构图钉；语义图钉——DDL/提醒——P1 后续批次挂内容时加）。
nonisolated enum PinKind: String, CaseIterable, Sendable {
    case dayBoundary    // 跨日图钉：每天凌晨 4 点（逻辑日边界）
    case workEnd        // 收工图钉：WorkHoursSettings.windDownHour（用户契约）
    case eveningStart   // 傍晚图钉：收尾信号最早时刻（收工 −5h，夹 16:00–20:00）
}

/// 一根图钉：零长度的时刻标记。
nonisolated struct Pin: Equatable, Sendable, Comparable {
    let kind: PinKind
    let time: Date
    static func < (lhs: Pin, rhs: Pin) -> Bool { lhs.time < rhs.time }
}

nonisolated enum PinSchedule {
    /// 跨日图钉小时（恒 4——2026-07-10 裁决：定死、不做设置；图钉只是把它物化成对象）。
    static let dayBoundaryHour = 4

    private static var cal: Calendar { Calendar.current }

    // MARK: - 跨日图钉

    /// ≤ t 的最近一根跨日图钉（= t 所属逻辑日的 4 点起点）。
    static func dayBoundary(atOrBefore t: Date) -> Date {
        let todayPin = boundaryPin(onCalendarDay: t)
        if t >= todayPin { return todayPin }
        let yesterday = cal.date(byAdding: .day, value: -1, to: t) ?? t
        return boundaryPin(onCalendarDay: yesterday)
    }

    /// > t 的下一根跨日图钉。
    static func dayBoundary(after t: Date) -> Date {
        let prev = dayBoundary(atOrBefore: t)
        let nextDay = cal.date(byAdding: .day, value: 1, to: prev) ?? prev
        return boundaryPin(onCalendarDay: nextDay)
    }

    /// t 所在的逻辑日区间 [前钉, 后钉)。
    static func dayInterval(containing t: Date) -> DateInterval {
        DateInterval(start: dayBoundary(atOrBefore: t), end: dayBoundary(after: t))
    }

    /// 某逻辑日标签（该日历日零点）对应的区间 [label 4:00, 次日 4:00)。
    static func dayInterval(forLabel label: Date) -> DateInterval {
        let next = cal.date(byAdding: .day, value: 1, to: label) ?? label
        return DateInterval(start: boundaryPin(onCalendarDay: label),
                            end: boundaryPin(onCalendarDay: next))
    }

    /// 某日历日上的跨日钉时刻（该日 4:00）。
    private static func boundaryPin(onCalendarDay d: Date) -> Date {
        let base = cal.startOfDay(for: d)
        return cal.date(byAdding: .hour, value: dayBoundaryHour, to: base) ?? base
    }

    // MARK: - 收工 / 傍晚图钉（位置吃 WorkHoursSettings 的用户契约）

    /// 某逻辑日的收工图钉——纯函数版（hour 显式传入；单测零全局状态、将来多规则并存用）。
    /// hour=24 自然落到次日零点。
    static func workEnd(forLabel label: Date, hour: Int) -> Date {
        let base = cal.startOfDay(for: label)
        return cal.date(byAdding: .hour, value: hour, to: base) ?? base
    }

    /// 便利版：hour = WorkHoursSettings.windDownHour（用户契约）。
    static func workEnd(forLabel label: Date) -> Date {
        workEnd(forLabel: label, hour: WorkHoursSettings.windDownHour)
    }

    /// 某逻辑日的傍晚图钉——纯函数版（收工 −5h，夹 16:00–20:00；算式原样迁自 WorkHoursSettings）。
    static func eveningStart(forLabel label: Date, windDownHour: Int) -> Date {
        let derived = cal.date(byAdding: .hour, value: -5,
                               to: workEnd(forLabel: label, hour: windDownHour)) ?? label
        let floor16 = cal.date(bySettingHour: 16, minute: 0, second: 0, of: derived) ?? derived
        let cap20 = cal.date(bySettingHour: 20, minute: 0, second: 0, of: derived) ?? derived
        return min(max(derived, floor16), cap20)
    }

    /// 便利版：读用户契约。
    static func eveningStart(forLabel label: Date) -> Date {
        eveningStart(forLabel: label, windDownHour: WorkHoursSettings.windDownHour)
    }

    // MARK: - 序列查询（排布窗口 / 引擎观察窗用）

    /// 区间内全部图钉，升序；半开区间 [start, end)。
    static func pins(in interval: DateInterval,
                     kinds: Set<PinKind> = Set(PinKind.allCases)) -> [Pin] {
        var out: [Pin] = []
        var day = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: interval.start) ?? interval.start)
        let stop = cal.date(byAdding: .day, value: 2, to: interval.end) ?? interval.end
        while day < stop {
            if kinds.contains(.dayBoundary) {
                out.append(Pin(kind: .dayBoundary, time: boundaryPin(onCalendarDay: day)))
            }
            if kinds.contains(.workEnd) {
                out.append(Pin(kind: .workEnd, time: workEnd(forLabel: day)))
            }
            if kinds.contains(.eveningStart) {
                out.append(Pin(kind: .eveningStart, time: eveningStart(forLabel: day)))
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out.filter { $0.time >= interval.start && $0.time < interval.end }.sorted()
    }
}
