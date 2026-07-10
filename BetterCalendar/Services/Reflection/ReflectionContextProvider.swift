//
//  ReflectionContextProvider.swift
//  BetterCalendar
//
//  反思层「第一方情境」（R1b）：用当天的计划/完成数据（PlanComparing）生成写作引子。
//  这是日记相对一般日记 App 的最大差异点——打开就看到"今天做成了什么"当素材，是邀请不是问责。
//  数据源 = PlanStore 真相源（0.26.15 补迁移：日历只是投影——实时模式下绿色从日历淡出、
//  蓝色有 EventKit 缓存竞态，从日历读会把做成的事全算成"计划外"/漏算；这里跟上 A2/绿淡出的口径）。
//  原生信号（照片/HealthKit/JournalingSuggestions）留 R4，按平台叠加。
//

import Foundation

@MainActor
final class ReflectionContextProvider {
    private let planStore: PlanReading & ActualReading
    private let comparer: PlanComparing

    init(planStore: PlanReading & ActualReading, comparer: PlanComparing) {
        self.planStore = planStore
        self.comparer = comparer
    }

    /// 当天写作引子（来自计划×实际对比）；当天没做成什么则返回 nil（不硬塞）。
    func todayPrompt(_ now: Date = .now) async -> String? {
        let label = DayContext.logicalStartOfDay(now)
        let plannedBlocks = (try? planStore.plannedBlocks(on: label)) ?? []
        // 锚点（午饭/通勤）不进对比——同复盘口径，否则做成件数被作息灌水
        let anchorTitles = plannedBlocks.filter(\.isAnchor).map(\.title)
        func keep(_ title: String) -> Bool {
            !anchorTitles.contains { TitleMatch.similarity($0, title) >= 0.6 }
        }
        let planned = plannedBlocks.filter { !$0.isAnchor }.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .planned, blockID: $0.id)
        }
        let actual = ((try? planStore.actualBlocks(on: label)) ?? [])
            .filter { keep($0.title) }
            .map { CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .actual, blockID: $0.id) }
        let c = comparer.compare(planned: planned, actual: actual)
        guard c.accomplishedCount > 0 else { return nil }
        var s = "今天做成 \(c.accomplishedCount) 件"
        if c.bonusCount > 0 { s += "（含 \(c.bonusCount) 件计划外）" }
        let m = c.effectiveMinutes
        if m > 0 { s += m >= 60 ? " · 有效投入 \(m / 60) 小时 \(m % 60) 分" : " · 有效投入 \(m) 分钟" }
        return s
    }

    /// 自动日记正文（0.28，Jason 设想：15–30 秒最低闭环）——本地模板、瞬时、零出云。
    /// nil = 今天还没有做成记录（不硬塞、不写「0 件」）。
    func autoJournalText(_ now: Date = .now) async -> String? {
        AutoJournal.compose(comparison: todayComparison(now))
    }

    /// 当天对比（供引子/自动日记共用；口径同复盘：真相源 + 剥锚点）。
    private func todayComparison(_ now: Date) -> DayComparison {
        let label = DayContext.logicalStartOfDay(now)
        let plannedBlocks = (try? planStore.plannedBlocks(on: label)) ?? []
        let anchorTitles = plannedBlocks.filter(\.isAnchor).map(\.title)
        func keep(_ title: String) -> Bool {
            !anchorTitles.contains { TitleMatch.similarity($0, title) >= 0.6 }
        }
        let planned = plannedBlocks.filter { !$0.isAnchor }.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .planned, blockID: $0.id)
        }
        let actual = ((try? planStore.actualBlocks(on: label)) ?? [])
            .filter { keep($0.title) }
            .map { CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .actual, blockID: $0.id) }
        return comparer.compare(planned: planned, actual: actual)
    }
}

/// 自动日记文案（纯函数、可单测）：简短、基础、只鼓励——与手写明显区分（首行 🤖 标记；标签由调用方打）。
/// 羞辱铁律：没做成任何事 → 返回 nil（绝不生成「今天 0 件」）；内容只含做成的。
enum AutoJournal {
    static let encouragements = [
        "今天有在向前走。",
        "一天就这样被好好用过了。",
        "不求完美，已经完整。",
        "记下来了，就没白过。",
        "能收尾，就是好的一天。",
    ]

    static func compose(comparison c: DayComparison?, pick: Int? = nil) -> String? {
        guard let c, c.accomplishedCount > 0 else { return nil }
        var lines = ["🤖 自动日记"]
        let names = c.accomplished.map { $0.displayTitle + ($0.status == .extra ? "（计划外）" : "") }
        lines.append("今天做成 \(c.accomplishedCount) 件：" + names.joined(separator: "、") + "。")
        let m = c.effectiveMinutes
        if m > 0 { lines.append(m >= 60 ? "有效投入 \(m / 60) 小时 \(m % 60) 分。" : "有效投入 \(m) 分钟。") }
        let idx = (pick ?? Int.random(in: 0..<encouragements.count)) % encouragements.count
        lines.append(encouragements[abs(idx)])
        return lines.joined(separator: "\n")
    }
}
