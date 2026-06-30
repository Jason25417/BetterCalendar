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

    /// 读回某逻辑日的「计划」块（带 isFixed/priority/timingStyle，reflow 要用）。
    func plannedBlocks(on day: Date) throws -> [ScheduledBlock] {
        try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.kind == .planned && DayContext.isSameLogicalDay($0.start, day) }
            .sorted { $0.start < $1.start }
            .map { ScheduledBlock(id: $0.id, title: $0.title, start: $0.start, end: $0.end,
                                  isFixed: $0.isFixed, timingStyle: $0.timingStyle,
                                  priority: $0.priority, deadline: $0.deadline) }
    }

    /// 覆盖写某逻辑日的「计划」块（确认 / 晨间再排即替换当天）。
    func replacePlanned(_ blocks: [ScheduledBlock], on day: Date) throws {
        let stale = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.kind == .planned && DayContext.isSameLogicalDay($0.start, day) }
        for old in stale { context.delete(old) }
        for b in blocks {
            context.insert(PlanBlock(id: b.id, title: b.title, start: b.start, end: b.end,
                                     isFixed: b.isFixed, kind: .planned,
                                     timingStyle: b.timingStyle, priority: b.priority,
                                     deadline: b.deadline))
        }
        try context.save()
    }
}
