//
//  PlanStore.swift
//  BetterCalendar
//
//  计划块的「真相源」（M5 起步决策 2026-06-30）：reflow 需要读回 isFixed/priority 等元数据，
//  而日历事件读回丢了这些 → 计划块元数据存 SwiftData `PlanBlock`，日历只画事件。
//  注入 ModelContext（默认全局共享库；测试传内存库不污染真库）。为 M7 iCloud 同步铺路。
//

import Foundation
import SwiftData

@MainActor
final class PlanStore {
    private let context: ModelContext

    init(context: ModelContext? = nil) {
        self.context = context ?? SharedModelContainer.shared.mainContext
    }

    /// 读回某**逻辑日**的「计划」块（重构 2026-07-07：跨午夜块归前一逻辑日，"睡前看书 00:30"不再被拆到次日）。
    /// day = 逻辑日标签（该日零点，或当日 ≥4 点的任意时刻）。⚠️ 凌晨 0–4 点的**时刻**须先
    /// DayContext.logicalStartOfDay 转标签再传（0 点标签会被 startOfDay 原样当作那一天）。
    func plannedBlocks(on day: Date) throws -> [ScheduledBlock] {
        let label = Calendar.current.startOfDay(for: day)
        let result = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.kind == .planned && DayContext.logicalStartOfDay($0.start) == label }
            .sorted { $0.start < $1.start }
            .map { ScheduledBlock(id: $0.id, title: $0.title, start: $0.start, end: $0.end,
                                  isFixed: $0.isFixed, isAnchor: $0.isAnchor, timingStyle: $0.timingStyle,
                                  priority: $0.priority, deadline: $0.deadline, linkedTaskID: $0.linkedTaskID) }
        DevLog.shared.info("PlanStore", "读到 \(result.count) 计划块 @ \(Self.dayStr(day))")
        return result
    }

    /// 覆盖写某**逻辑日**的「计划」块（确认 / 晨间再排即替换当天）。day 语义同 plannedBlocks。
    func replacePlanned(_ blocks: [ScheduledBlock], on day: Date) throws {
        let label = Calendar.current.startOfDay(for: day)
        let stale = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.kind == .planned && DayContext.logicalStartOfDay($0.start) == label }
        for old in stale { context.delete(old) }
        for b in blocks {
            context.insert(PlanBlock(id: b.id, title: b.title, start: b.start, end: b.end,
                                     isFixed: b.isFixed, isAnchor: b.isAnchor, kind: .planned,
                                     timingStyle: b.timingStyle, priority: b.priority,
                                     deadline: b.deadline, linkedTaskID: b.linkedTaskID))
        }
        try context.save()
        DevLog.shared.info("PlanStore", "写入 \(blocks.count) 计划块 @ \(Self.dayStr(day))")
    }

    private static func dayStr(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }
}
