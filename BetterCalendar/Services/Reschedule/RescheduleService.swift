//
//  RescheduleService.swift
//  BetterCalendar
//
//  re-flow 编排：从真相源（PlanStore）读今日计划 → 委托 PlanningEngine 决策 → 产出预览（不写）。
//  写入交给上层：晨间确认后回写绿色；全天连续写橙色预览。
//

import Foundation

@MainActor
final class RescheduleService {
    private let planStore: PlanStore
    private let planner: PlanningEngine

    init(planStore: PlanStore, planner: PlanningEngine) {
        self.planStore = planStore
        self.planner = planner
    }

    /// 晨间「开始今天」：读今日计划 → （若有用户解法先应用）→ 从开工时刻 reflow → 决策（含排不下冲突）。
    func morningReflow(now: Date = .now, resolution: ReflowResolution? = nil) async throws -> PlanDecision {
        var blocks = try planStore.plannedBlocks(on: DayContext.logicalStartOfDay(now))
        guard !blocks.isEmpty else { return PlanDecision() }
        if let r = resolution { blocks = Self.apply(r, to: blocks, from: now) }
        return try await planner.reflow(blocks, from: now, now: now)
    }

    /// 应用用户对「排不下」的解法（在 reflow 之前预处理计划块）。
    static func apply(_ r: ReflowResolution, to blocks: [ScheduledBlock], from: Date) -> [ScheduledBlock] {
        switch r {
        case .skip(let title):
            return blocks.filter { $0.title != title }
        case .split(let title):
            return blocks.flatMap { b -> [ScheduledBlock] in
                guard !b.isFixed, b.title == title else { return [b] }
                let mid = b.start.addingTimeInterval(b.end.timeIntervalSince(b.start) / 2)
                return [ScheduledBlock(title: "\(b.title)(上)", start: b.start, end: mid,
                                       timingStyle: b.timingStyle, priority: b.priority),
                        ScheduledBlock(title: "\(b.title)(下)", start: mid, end: b.end,
                                       timingStyle: b.timingStyle, priority: b.priority)]
            }
        case .compress:
            let deadline = DayContext.endOfPlannableDay(from)
            let flexible = blocks.filter { !$0.isFixed }
            let totalFlex = flexible.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            guard totalFlex > 0 else { return blocks }
            let factor = min(1.0, max(0, deadline.timeIntervalSince(from)) / totalFlex)
            return blocks.map { b in
                guard !b.isFixed else { return b }
                var nb = b
                nb.end = b.start.addingTimeInterval(b.end.timeIntervalSince(b.start) * factor)
                return nb
            }
        }
    }

    /// 全天连续：剩余（标题未在 excludeTitles 里＝既非已完成、也非正在做）从此刻 reflow → 橙色预览块。
    func continuousReflow(excludeTitles: [String], now: Date = .now) async throws -> [ScheduledBlock] {
        let all = try planStore.plannedBlocks(on: DayContext.logicalStartOfDay(now))
        let remaining = all.filter { b in
            !excludeTitles.contains { TitleMatch.similarity($0, b.title) >= 0.6 }
        }
        guard !remaining.isEmpty else { return [] }
        return try await planner.reflow(remaining, from: now, now: now).orderedBlocks
    }

    /// 据当天计划算早晚提醒时间：首块前 15 分钟 / 末块后 30 分钟（原型期启发式，后续可换 LLM 精调）。
    static func reminderTimes(for blocks: [ScheduledBlock]) -> (morning: Date?, evening: Date?) {
        guard let firstStart = blocks.map(\.start).min(),
              let lastEnd = blocks.map(\.end).max() else { return (nil, nil) }
        return (firstStart.addingTimeInterval(-15 * 60), lastEnd.addingTimeInterval(30 * 60))
    }
}
