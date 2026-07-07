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

// MARK: - 权限协议（架构修缮 2026-07-08：数据库课 GRANT 的类型系统等价物）
// 「谁能写计划」从文档约定升级为编译器保证：只读方拿 PlanReading，调不到 replacePlanned——违规连编译都过不了。

/// 只读角色（GRANT SELECT）：执行页 / 复盘页 / reflow / 投影 都只拿这个。
@MainActor
protocol PlanReading: AnyObject {
    func plannedBlocks(on day: Date) throws -> [ScheduledBlock]
}

/// 写角色（GRANT UPDATE）：持有者=HomeViewModel（确认写入）+ ReconcileService（0.20 双向同步回流）。
@MainActor
protocol PlanWriting: AnyObject {
    func replacePlanned(_ blocks: [ScheduledBlock], on day: Date) throws
    /// 按 ID 就地更新单块的 时间/标题（对账回流：日历手改 → 真相源；逻辑日归桶随 start 自动跟走）。
    func updatePlanned(id: UUID, start: Date, end: Date, title: String) throws
    /// 追加若干块（对账回流：日历里新建的日程经确认后入库；逻辑日归桶随 start 自动落位）。
    func insertPlanned(_ blocks: [ScheduledBlock]) throws
    /// 按 ID 删除若干块（对账回流：日历删除经用户确认后 → 真相源）。
    func deletePlanned(ids: [UUID]) throws
}

@MainActor
final class PlanStore: PlanReading, PlanWriting {
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

    /// 按 ID 就地更新（0.20 对账回流）：只动 时间/标题（固定/★/计时方式日历没有对应概念、保持库值）。
    func updatePlanned(id: UUID, start: Date, end: Date, title: String) throws {
        guard let block = try context.fetch(FetchDescriptor<PlanBlock>())
            .first(where: { $0.id == id && $0.kind == .planned }) else { return }
        block.start = start; block.end = end; block.title = title
        try context.save()
        DevLog.shared.info("PlanStore", "对账回流更新「\(title)」→ \(Self.dayStr(start))")
    }

    /// 追加块（0.20.2 对账回流：日历新建经确认后入库，默认弹性/轻计时/普通优先级）。
    func insertPlanned(_ blocks: [ScheduledBlock]) throws {
        guard !blocks.isEmpty else { return }
        for b in blocks {
            context.insert(PlanBlock(id: b.id, title: b.title, start: b.start, end: b.end,
                                     isFixed: b.isFixed, isAnchor: b.isAnchor, kind: .planned,
                                     timingStyle: b.timingStyle, priority: b.priority,
                                     deadline: b.deadline, linkedTaskID: b.linkedTaskID))
        }
        try context.save()
        DevLog.shared.info("PlanStore", "对账回流新增 \(blocks.count) 块（日历新建）")
    }

    /// 按 ID 删除（0.20 对账回流：日历删除经用户确认后落库）。
    func deletePlanned(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let victims = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.kind == .planned && idSet.contains($0.id) }
        for v in victims { context.delete(v) }
        try context.save()
        DevLog.shared.info("PlanStore", "对账回流删除 \(victims.count) 块")
    }

    private static func dayStr(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }
}
