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

    // 晨间 reflow（morningReflow）与「排不下」三选解法（apply/ReflowResolution）已退役（0.23 A，SPEC §11 ①）：
    // 首次开始一件事即进实时模式，重排统一走下方的全天连续 reflow；溢出语义改为候补（模块 B）。

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
