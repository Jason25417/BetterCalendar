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

    /// 读回某天（**日历日**，非逻辑日——day 可能是 0 点，逻辑日会错配到前一天）的「计划」块。
    func plannedBlocks(on day: Date) throws -> [ScheduledBlock] {
        let cal = Calendar.current
        let result = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.kind == .planned && cal.isDate($0.start, inSameDayAs: day) }
            .sorted { $0.start < $1.start }
            .map { ScheduledBlock(id: $0.id, title: $0.title, start: $0.start, end: $0.end,
                                  isFixed: $0.isFixed, isAnchor: $0.isAnchor, timingStyle: $0.timingStyle,
                                  priority: $0.priority, deadline: $0.deadline) }
        DevLog.shared.info("PlanStore", "读到 \(result.count) 计划块 @ \(Self.dayStr(day))")
        return result
    }

    /// 覆盖写某天（日历日）的「计划」块（确认 / 晨间再排即替换当天）。
    func replacePlanned(_ blocks: [ScheduledBlock], on day: Date) throws {
        let cal = Calendar.current
        let stale = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.kind == .planned && cal.isDate($0.start, inSameDayAs: day) }
        for old in stale { context.delete(old) }
        for b in blocks {
            context.insert(PlanBlock(id: b.id, title: b.title, start: b.start, end: b.end,
                                     isFixed: b.isFixed, isAnchor: b.isAnchor, kind: .planned,
                                     timingStyle: b.timingStyle, priority: b.priority,
                                     deadline: b.deadline))
        }
        try context.save()
        DevLog.shared.info("PlanStore", "写入 \(blocks.count) 计划块 @ \(Self.dayStr(day))")
    }

    private static func dayStr(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }
}
