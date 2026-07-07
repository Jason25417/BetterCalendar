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
    private let planStore: PlanReading   // 只读角色：reflow 只产预览/草稿，永不写计划真相
    private let planner: PlanningEngine

    init(planStore: PlanReading, planner: PlanningEngine) {
        self.planStore = planStore
        self.planner = planner
    }

    /// 晨间「开始今天」：读 day（用户看的目标日）的计划 →（若有用户解法先应用）→ 从开工时刻 reflow。
    func morningReflow(day: Date, now: Date = .now, resolution: ReflowResolution? = nil) async throws -> PlanDecision {
        var blocks = try planStore.plannedBlocks(on: day)
        guard !blocks.isEmpty else {
            DevLog.shared.warn("reflow", "开始今天：该日无计划块——先「确认写入」才有真相源可重排")
            return PlanDecision()
        }
        if let r = resolution { blocks = Self.apply(r, to: blocks, from: now) }
        let flexCount = blocks.filter { !$0.isFixed }.count
        if flexCount == 0 {
            DevLog.shared.warn("reflow", "开始今天：\(blocks.count) 块全是固定块，reflow 不移动固定块（任务别标固定）")
        }
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

    /// 全天连续：剩余（既非已完成、也非正在做/并行中）从此刻 reflow → 橙色预览块。
    /// 排除按 **ID 优先**（重构：完成/进行中的记录带块 id）；excludeTitles 只兜无章老记录（标题相似 ≥0.6）。
    func continuousReflow(excludeIDs: Set<UUID> = [], excludeTitles: [String] = [],
                          now: Date = .now) async throws -> [ScheduledBlock] {
        let all = try planStore.plannedBlocks(on: DayContext.logicalStartOfDay(now))
        let remaining = all.filter { b in
            !excludeIDs.contains(b.id)
                && !excludeTitles.contains { TitleMatch.similarity($0, b.title) >= 0.6 }
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
