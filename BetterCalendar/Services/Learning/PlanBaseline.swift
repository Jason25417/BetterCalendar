//
//  PlanBaseline.swift
//  BetterCalendar
//
//  复盘/日记情境的「计划侧基线」（E5b/D11，SPEC §13.A.4 快照硬条件的兑现）：
//  直写绿之后真相源=活预报（全天被流动性算法在线维护、与实际趋同），拿它对比「计划 vs 实际」
//  会把偏差信息抹平——基线改用**当日最初快照**（DayPlanSnapshot，save-once）；
//  无快照的日子（老数据/没确认过）回退真相源，行为与旧版一致。
//

import Foundation

@MainActor
enum PlanBaseline {
    /// 某逻辑日的计划基线：快照优先、真相源兜底。
    static func plannedBlocks(on label: Date,
                              planStore: PlanReading?,
                              learning: LearningStore?) -> [ScheduledBlock] {
        if let snap = learning?.snapshot(for: label), !snap.items.isEmpty {
            return snap.items.map { item in
                ScheduledBlock(id: item.id, title: item.title,
                               start: item.plannedStart,
                               end: item.plannedStart.addingTimeInterval(TimeInterval(item.plannedMinutes) * 60),
                               isFixed: item.isFixed, isAnchor: item.isAnchor,
                               priority: item.priority,
                               linkedTaskID: item.linkedTaskID, labels: item.labels)
            }
        }
        return (try? planStore?.plannedBlocks(on: label)) ?? []
    }
}
