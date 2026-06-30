//
//  ReflectionContextProvider.swift
//  BetterCalendar
//
//  反思层「第一方情境」（R1b）：用当天的计划/完成数据（PlanComparing）生成写作引子。
//  这是日记相对一般日记 App 的最大差异点——打开就看到"今天做成了什么"当素材，是邀请不是问责。
//  原生信号（照片/HealthKit/JournalingSuggestions）留 R4，按平台叠加。
//

import Foundation

@MainActor
final class ReflectionContextProvider {
    private let calendarStore: CalendarStore
    private let comparer: PlanComparing

    init(calendarStore: CalendarStore, comparer: PlanComparing) {
        self.calendarStore = calendarStore
        self.comparer = comparer
    }

    /// 当天写作引子（来自计划×实际对比）；当天没做成什么则返回 nil（不硬塞）。
    func todayPrompt(_ now: Date = .now) async -> String? {
        let planned = ((try? await calendarStore.read(kind: .planned)) ?? [])
            .filter { DayContext.isSameLogicalDay($0.start, now) }
        let actual = ((try? await calendarStore.read(kind: .actual)) ?? [])
            .filter { DayContext.isSameLogicalDay($0.start, now) }
        let c = comparer.compare(planned: planned, actual: actual)
        guard c.accomplishedCount > 0 else { return nil }
        var s = "今天做成 \(c.accomplishedCount) 件"
        if c.bonusCount > 0 { s += "（含 \(c.bonusCount) 件计划外）" }
        let m = c.effectiveMinutes
        if m > 0 { s += m >= 60 ? " · 有效投入 \(m / 60) 小时 \(m % 60) 分" : " · 有效投入 \(m) 分钟" }
        return s
    }
}
