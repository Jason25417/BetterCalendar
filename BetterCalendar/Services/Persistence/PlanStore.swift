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

// MARK: - 蓝色实际（真相源，蓝对账 0.27 起）
// 蓝色实际从「日历即真相」升级为「PlanStore(.actual) 即真相、日历是投影」——与绿色对称，
// 复用同一个 PlanBlock 表（kind 区分）、同一套 stamp+投影去重。实际块**复用对应计划块的 UUID**
// （同 UUID 换幕布：橙随下次预览消失、蓝带同章出现）；计划外 bonus 用自己的新 UUID。

/// 蓝色实际（真相）只读：执行页 / 复盘 / 对账 读回。
@MainActor
protocol ActualReading: AnyObject {
    func actualBlocks(on day: Date) throws -> [ActualBlock]
    /// 某计划块的完成闩（nil=尚未决定，固定块可自动完成；一旦置值=已决定，永不再推断）。
    func completionLatch(plannedID: UUID) throws -> CompletionStatus?
    /// 某逻辑日被用户「清掉完成」的计划块 id（tombstone=completion .missed）——一次批量读，
    /// 供 loadToday 跳过自动重推断（对账删除后不再重建=stick）。绝不逐项在循环里 fetch。
    func clearedPlannedIDs(on day: Date) throws -> Set<UUID>
}

/// 蓝色实际（真相）写：执行层 flushActuals + 对账 ReconcileService。
@MainActor
protocol ActualWriting: AnyObject {
    /// 按 id 幂等 upsert 实际块（已存在则更新时间/标题，否则插入）。
    func upsertActuals(_ blocks: [ActualBlock]) throws
    /// 按 id 删除实际块（对账：用户在日历删蓝块经确认后 → 真相源）。
    func deleteActuals(ids: [UUID]) throws
    /// 置/清某计划块的完成闩：自动完成或用户手动改回都走这里，nil 代表清回「未决定」。
    func latchCompletion(plannedID: UUID, _ status: CompletionStatus?) throws
}

/// 蓝色实际块 DTO（真相层，无排程元数据；priority/isFixed 等属计划块，不搬到实际）。
struct ActualBlock: Sendable, Identifiable, Equatable {
    let id: UUID        // = 对应计划块 id（换幕布）；计划外 bonus = 自身新 id
    let title: String
    let start: Date
    let end: Date
}

@MainActor
final class PlanStore: PlanReading, PlanWriting, ActualReading, ActualWriting {
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
                                  priority: $0.priority, deadline: $0.deadline, linkedTaskID: $0.linkedTaskID,
                                  labels: $0.labels) }
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
                                     deadline: b.deadline, labels: b.labels, linkedTaskID: b.linkedTaskID))
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
                                     deadline: b.deadline, labels: b.labels, linkedTaskID: b.linkedTaskID))
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

    // MARK: - 蓝色实际（真相源）

    /// 读回某**逻辑日**的实际块（蓝色）。day 语义同 plannedBlocks（4 点日界线、凌晨须先转标签）。
    func actualBlocks(on day: Date) throws -> [ActualBlock] {
        let label = Calendar.current.startOfDay(for: day)
        return try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.kind == .actual && DayContext.logicalStartOfDay($0.start) == label }
            .sorted { $0.start < $1.start }
            .map { ActualBlock(id: $0.id, title: $0.title, start: $0.start, end: $0.end) }
    }

    /// 某计划块的完成闩（读 planned 行的 completion；kind 过滤避免撞同 UUID 的实际行）。
    func completionLatch(plannedID: UUID) throws -> CompletionStatus? {
        try context.fetch(FetchDescriptor<PlanBlock>())
            .first(where: { $0.id == plannedID && $0.kind == .planned })?.completion
    }

    /// 某逻辑日被清掉完成的计划块 id（tombstone）——一次批量读，供 loadToday 用 Set 查跳过。
    func clearedPlannedIDs(on day: Date) throws -> Set<UUID> {
        let label = Calendar.current.startOfDay(for: day)
        return Set(try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.kind == .planned && $0.completion == .missed
                      && DayContext.logicalStartOfDay($0.start) == label }
            .map { $0.id })
    }

    /// 按 id 幂等 upsert 实际块。同 id 只更新时间/标题，不新增行（防每次 flush 堆重复实际）。
    func upsertActuals(_ blocks: [ActualBlock]) throws {
        guard !blocks.isEmpty else { return }
        let existing = try context.fetch(FetchDescriptor<PlanBlock>()).filter { $0.kind == .actual }
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for b in blocks {
            if let row = byID[b.id] {
                row.title = b.title; row.start = b.start; row.end = b.end
            } else {
                let row = PlanBlock(id: b.id, title: b.title, start: b.start, end: b.end, kind: .actual)
                context.insert(row); byID[b.id] = row
            }
        }
        try context.save()
        DevLog.shared.info("PlanStore", "实际块 upsert \(blocks.count) 项（真相源）")
    }

    /// 按 id 删除实际块（只删 .actual 行，绝不误删同 UUID 的计划行）。
    func deleteActuals(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let victims = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.kind == .actual && idSet.contains($0.id) }
        for v in victims { context.delete(v) }
        try context.save()
        DevLog.shared.info("PlanStore", "实际块删除 \(victims.count) 项（真相源）")
    }

    /// 置/清计划块的完成闩（原则7：自动完成先斩，用户手动改回永远赢；nil=清回未决定）。
    func latchCompletion(plannedID: UUID, _ status: CompletionStatus?) throws {
        guard let block = try context.fetch(FetchDescriptor<PlanBlock>())
            .first(where: { $0.id == plannedID && $0.kind == .planned }) else { return }
        block.completion = status
        try context.save()
    }

    private static func dayStr(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }
}
