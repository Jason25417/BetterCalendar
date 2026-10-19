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
    func deletedPlannedIDs(on day: Date) throws -> Set<UUID>
}

extension PlanReading {
    func deletedPlannedIDs(on day: Date) throws -> Set<UUID> { [] }
}

/// 写角色（GRANT UPDATE）：持有者=HomeViewModel（确认写入）+ ReconcileService（0.20 双向同步回流）。
@MainActor
protocol PlanWriting: AnyObject {
    func replacePlanned(_ blocks: [ScheduledBlock], on day: Date) throws
    /// 按 ID 就地更新单块的 时间/标题（逻辑日归桶随 start 自动跟走）。值没变 = 不保存（不制造同步噪声）。
    /// reason = 真实调用方（P4.0-8：日志按它写，不再把所有写入都记成「对账回流」）。
    func updatePlanned(id: UUID, start: Date, end: Date, title: String, reason: PlanWriteReason) throws
    /// 追加若干块（逻辑日归桶随 start 自动落位）。
    func insertPlanned(_ blocks: [ScheduledBlock], reason: PlanWriteReason) throws
    /// 按 ID 删除若干块（进回收站，可恢复）。
    func deletePlanned(ids: [UUID], reason: PlanWriteReason) throws
    /// 钉住 / 取消钉住（P4 Q6 图钉）：until = 截止时刻（nil = 取消）。不改内容、不升版本（图钉不是日历上的内容）。
    func setPinned(ids: [UUID], until: Date?) throws
    /// 给刚因「你在日历里删了」而进回收站的计划块写回执（P4.1，随 iCloud 同步；Mac 据此转交给智能体）。
    func recordCalendarDeletion(id: UUID, receipt: CalendarDeletionReceipt) throws
}

/// 计划块写入的真实来源（P4.0-8）：PlanStore 日志据此标注。曾经所有写入都叫「对账回流」，
/// 协调器顺延、单件入线、溢出硬执行在日志里全像日历对账，排查 B10 时被它误导过。
nonisolated enum PlanWriteReason: String, Sendable {
    case unspecified = "未标注来源"
    case calendarReconcile = "日历对账回流"
    case timelineCoordinator = "时间线协调器"
    case undo = "一键撤销"
    case spill = "溢出硬执行"
    case poolAdmit = "单件入线"
    case agentApproval = "智能体批准的改动"
    case userEdit = "你在 App 里的改动"

    /// 是不是「你的操作」（含你批准的提案）——P4 冲突裁决：你的操作 ＞ 批准过的提案 ＞ 自动调整（原则 8）。
    var isUsersOwn: Bool {
        switch self {
        case .calendarReconcile, .userEdit, .agentApproval, .undo, .unspecified: true
        case .timelineCoordinator, .spill, .poolAdmit: false
        }
    }
}

extension PlanWriteReason {
    /// PlanBlock.syncSource 读回（未知/旧数据 = unspecified，按「你的操作」保守对待）。
    init(stored: String?) {
        self = PlanWriteReason.allStored.first { $0.rawValue == stored } ?? .unspecified
    }
    static let allStored: [PlanWriteReason] = [.unspecified, .calendarReconcile, .timelineCoordinator, .undo,
                                               .spill, .poolAdmit, .agentApproval, .userEdit]
}

extension ScheduledBlock {
    /// 图钉的截止（P4 Q6「当天有效」）：块所在逻辑日的结束（下一个 4:00）。
    static func pinExpiry(forStart start: Date) -> Date {
        DayContext.logicalWindow(forLabel: DayContext.logicalStartOfDay(start)).end
    }
}

extension PlanWriting {
    func recordCalendarDeletion(id: UUID, receipt: CalendarDeletionReceipt) throws {}
    func updatePlanned(id: UUID, start: Date, end: Date, title: String) throws {
        try updatePlanned(id: id, start: start, end: end, title: title, reason: .unspecified)
    }
    func insertPlanned(_ blocks: [ScheduledBlock]) throws { try insertPlanned(blocks, reason: .unspecified) }
    func deletePlanned(ids: [UUID]) throws { try deletePlanned(ids: ids, reason: .unspecified) }
}

// MARK: - 蓝色实际（真相源，蓝对账 0.27 起）
// 蓝色实际从「日历即真相」升级为「PlanStore(.actual) 即真相、日历是投影」——与绿色对称，
// 复用同一个 PlanBlock 表（kind 区分）、同一套 stamp+投影去重。实际块**复用对应计划块的 UUID**
// （同 UUID 换幕布：橙随下次预览消失、蓝带同章出现）；计划外 bonus 用自己的新 UUID。

/// 蓝色实际（真相）只读：执行页 / 复盘 / 对账 读回。
@MainActor
protocol ActualReading: AnyObject {
    func actualBlocks(on day: Date) throws -> [ActualBlock]
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
    /// P4：记下的 / 正在做 / 被动推断（只记数据不画蓝）。
    var state: ActualState = .recorded
}

@MainActor
final class PlanStore: PlanReading, PlanWriting, ActualReading, ActualWriting, CalendarDeletionReceiptReading {
    private let context: ModelContext
    /// 本机写者标识（P4 Q8 作者宽限）：写进 PlanBlock.syncWriter。
    let writerID: String
    private let now: () -> Date

    init(context: ModelContext? = nil, writerID: String? = nil, now: @escaping () -> Date = { .now }) {
        self.context = context ?? SharedModelContainer.shared.mainContext
        self.writerID = writerID ?? FocusFollow.deviceID
        self.now = now
    }

    /// 真改动盖版本（P4 Q7/Q8）：版本 = max(现在毫秒, 旧版本+1)——单调，且另一台设备的旧版本永远小于本机新写的。
    private func stampWrite(_ row: PlanBlock, _ reason: PlanWriteReason) {
        let ms = Int64((now().timeIntervalSince1970 * 1000).rounded())
        row.syncVersion = max(ms, row.syncVersion + 1)
        row.syncWriter = writerID
        row.syncSource = reason.rawValue
    }

    private static func scheduled(_ b: PlanBlock) -> ScheduledBlock {
        ScheduledBlock(id: b.id, title: b.title, start: b.start, end: b.end,
                       isFixed: b.isFixed, isAnchor: b.isAnchor, timingStyle: b.timingStyle,
                       priority: b.priority, deadline: b.deadline, linkedTaskID: b.linkedTaskID,
                       labels: b.labels, pinnedUntil: b.pinnedUntil, syncVersion: b.syncVersion,
                       syncWriter: b.syncWriter, syncSource: b.syncSource)
    }

    /// 读回某**逻辑日**的「计划」块（重构 2026-07-07：跨午夜块归前一逻辑日，"睡前看书 00:30"不再被拆到次日）。
    /// day = 逻辑日标签（该日零点，或当日 ≥4 点的任意时刻）。⚠️ 凌晨 0–4 点的**时刻**须先
    /// DayContext.logicalStartOfDay 转标签再传（0 点标签会被 startOfDay 原样当作那一天）。
    func plannedBlocks(on day: Date) throws -> [ScheduledBlock] {
        let label = Calendar.current.startOfDay(for: day)
        let result = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { !$0.isInTrash && $0.kind == .planned && DayContext.logicalStartOfDay($0.start) == label }
            .sorted { $0.start < $1.start }
            .map(Self.scheduled)
        DevLog.shared.info("PlanStore", "读到 \(result.count) 计划块 @ \(Self.dayStr(day))")
        return result
    }

    func deletedPlannedIDs(on day: Date) throws -> Set<UUID> {
        let label = Calendar.current.startOfDay(for: day)
        let rows = try context.fetch(FetchDescriptor<PlanBlock>()).filter { $0.kind == .planned }
        let active = Set(rows.filter { !$0.isInTrash }.map(\.id))
        return Set(rows.filter { $0.isInTrash && DayContext.logicalStartOfDay($0.start) == label }
            .map(\.id)).subtracting(active)
    }

    /// 覆盖写某**逻辑日**的「计划」块（确认 / 晨间再排即替换当天）。day 语义同 plannedBlocks。
    func replacePlanned(_ blocks: [ScheduledBlock], on day: Date) throws {
        let label = Calendar.current.startOfDay(for: day)
        let allRows = try context.fetch(FetchDescriptor<PlanBlock>())
        let stale = allRows.filter { !$0.isInTrash && $0.kind == .planned && DayContext.logicalStartOfDay($0.start) == label }
        let deletedIDs = Set(allRows.filter { $0.isInTrash && $0.kind == .planned }.map(\.id))
        let activeIDs = Set(allRows.filter { !$0.isInTrash && $0.kind == .planned }.map(\.id))
        guard !blocks.contains(where: { deletedIDs.contains($0.id) && !activeIDs.contains($0.id) }) else {
            throw DataArchiveError.invalid("计划仍在回收站，请先恢复；不会自动重新创建")
        }
        let wanted = Set(blocks.map(\.id))
        var byID = Dictionary(stale.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let removed = stale.filter { !wanted.contains($0.id) }
        for b in blocks {
            let row: PlanBlock
            if let existing = byID[b.id] {
                row = existing
                if row.title != b.title || row.start != b.start || row.end != b.end { stampWrite(row, .userEdit) }
            } else {
                row = PlanBlock(id: b.id, title: b.title, start: b.start, end: b.end)
                context.insert(row); byID[b.id] = row
                stampWrite(row, .userEdit)
            }
            row.title = b.title; row.start = b.start; row.end = b.end
            row.isFixed = b.isFixed; row.isAnchor = b.isAnchor
            row.timingStyle = b.timingStyle; row.priority = b.priority
            row.deadline = b.deadline; row.labels = b.labels; row.linkedTaskID = b.linkedTaskID
        }
        try RetainedDeletion.save(removed, in: context)
        DevLog.shared.info("PlanStore", "写入 \(blocks.count) 计划块 @ \(Self.dayStr(day))")
    }

    /// 按 ID 就地更新：只动 时间/标题（固定/★/计时方式日历没有对应概念、保持库值）。
    /// 值没变就不保存（B10 防线：无效保存也会触发 NSPersistentStoreRemoteChange 和 CloudKit 导出）。
    func updatePlanned(id: UUID, start: Date, end: Date, title: String, reason: PlanWriteReason) throws {
        guard let block = try context.fetch(FetchDescriptor<PlanBlock>())
            .first(where: { !$0.isInTrash && $0.id == id && $0.kind == .planned }) else { return }
        guard block.start != start || block.end != end || block.title != title else { return }
        block.start = start; block.end = end; block.title = title
        stampWrite(block, reason)
        try context.save()
        DevLog.shared.info("PlanStore", "\(reason.rawValue)：更新「\(title)」→ \(Self.dayStr(start))")
    }

    /// 追加块（日历新建经确认后入库 / 单件入线等；默认弹性/轻计时/普通优先级）。
    func insertPlanned(_ blocks: [ScheduledBlock], reason: PlanWriteReason) throws {
        guard !blocks.isEmpty else { return }
        let allRows = try context.fetch(FetchDescriptor<PlanBlock>()).filter { $0.kind == .planned }
        let activeIDs = Set(allRows.filter { !$0.isInTrash }.map(\.id))
        let deletedIDs = Set(allRows.filter { $0.isInTrash }.map(\.id))
        guard !blocks.contains(where: { deletedIDs.contains($0.id) && !activeIDs.contains($0.id) }) else {
            throw DataArchiveError.invalid("计划仍在回收站，请先恢复")
        }
        for b in blocks where !activeIDs.contains(b.id) {
            let row = PlanBlock(id: b.id, title: b.title, start: b.start, end: b.end,
                                isFixed: b.isFixed, isAnchor: b.isAnchor, kind: .planned,
                                timingStyle: b.timingStyle, priority: b.priority,
                                deadline: b.deadline, labels: b.labels, linkedTaskID: b.linkedTaskID)
            stampWrite(row, reason)
            context.insert(row)
        }
        try context.save()
        DevLog.shared.info("PlanStore", "\(reason.rawValue)：新增 \(blocks.count) 块")
    }

    /// 按 ID 删除（进回收站）。
    func deletePlanned(ids: [UUID], reason: PlanWriteReason) throws {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let victims = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { !$0.isInTrash && $0.kind == .planned && idSet.contains($0.id) }
        try RetainedDeletion.save(victims, in: context)
        DevLog.shared.info("PlanStore", "\(reason.rawValue)：删除 \(victims.count) 块")
    }

    func setPinned(ids: [UUID], until: Date?) throws {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let rows = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { !$0.isInTrash && $0.kind == .planned && idSet.contains($0.id) && $0.pinnedUntil != until }
        guard !rows.isEmpty else { return }
        for r in rows { r.pinnedUntil = until }
        try context.save()
        DevLog.shared.info("PlanStore", until == nil ? "取消图钉 \(rows.count) 块" : "图钉 \(rows.count) 块（当天有效）")
    }

    /// P4.1：回执写进这次删除的那一行（同 id 多行时取最近删的那行），并记下它属于哪一次删除。
    func recordCalendarDeletion(id: UUID, receipt: CalendarDeletionReceipt) throws {
        guard let row = try context.fetch(FetchDescriptor<PlanBlock>())
            .filter({ $0.isInTrash && $0.kind == .planned && $0.id == id })
            .max(by: { ($0.deletedAt ?? .distantPast) < ($1.deletedAt ?? .distantPast) }),
              let deletion = row.deletionID else { return }
        var r = receipt
        r.deletionID = deletion
        guard let data = r.encoded() else { throw DataArchiveError.invalid("删除回执编码失败") }
        row.deletionContext = data
        try context.save()
    }

    /// 回收站里带有效回执的计划块（回执的 deletionID 必须等于行上当前这次删除；恢复过的不算）。
    func calendarDeletionReceipts() throws -> [CalendarDeletionRecord] {
        try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { $0.isInTrash && $0.kind == .planned && $0.deletionContext != nil }
            .compactMap { row in
                guard let r = CalendarDeletionReceipt.decode(row.deletionContext), r.deletionID == row.deletionID else { return nil }
                return CalendarDeletionRecord(block: Self.scheduled(row), receipt: r)
            }
    }

    // MARK: - 蓝色实际（真相源）

    /// 读回某**逻辑日**的实际块（蓝色）。day 语义同 plannedBlocks（4 点日界线、凌晨须先转标签）。
    func actualBlocks(on day: Date) throws -> [ActualBlock] {
        let label = Calendar.current.startOfDay(for: day)
        return try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { !$0.isInTrash && $0.kind == .actual && DayContext.logicalStartOfDay($0.start) == label }
            .sorted { $0.start < $1.start }
            .map { ActualBlock(id: $0.id, title: $0.title, start: $0.start, end: $0.end,
                               state: ActualState(stored: $0.actualState)) }
    }

    /// 某计划块的完成闩（读 planned 行的 completion；kind 过滤避免撞同 UUID 的实际行）。

    /// 某逻辑日被清掉完成的计划块 id（tombstone）——一次批量读，供 loadToday 用 Set 查跳过。
    func clearedPlannedIDs(on day: Date) throws -> Set<UUID> {
        let label = Calendar.current.startOfDay(for: day)
        return Set(try context.fetch(FetchDescriptor<PlanBlock>())
            .filter { !$0.isInTrash && $0.kind == .planned && $0.completion == .missed
                      && DayContext.logicalStartOfDay($0.start) == label }
            .map { $0.id })
    }

    /// 按 id 幂等 upsert 实际块。同 id 只更新时间/标题，不新增行（防每次 flush 堆重复实际）。
    func upsertActuals(_ blocks: [ActualBlock]) throws {
        guard !blocks.isEmpty else { return }
        let allRows = try context.fetch(FetchDescriptor<PlanBlock>()).filter { $0.kind == .actual }
        let existing = allRows.filter { !$0.isInTrash }
        let deletedIDs = Set(allRows.filter { $0.isInTrash }.map(\.id))
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for b in blocks {
            if deletedIDs.contains(b.id), byID[b.id] == nil {
                DevLog.shared.warn("PlanStore", "已删除的实际记录保持在回收站，不自动重建")
                continue
            }
            if let row = byID[b.id] {
                row.title = b.title; row.start = b.start; row.end = b.end
                row.actualState = b.state.stored
            } else {
                let row = PlanBlock(id: b.id, title: b.title, start: b.start, end: b.end, kind: .actual)
                row.actualState = b.state.stored
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
            .filter { !$0.isInTrash && $0.kind == .actual && idSet.contains($0.id) }
        try RetainedDeletion.save(victims, in: context)
        DevLog.shared.info("PlanStore", "实际块删除 \(victims.count) 项（真相源）")
    }

    /// 置/清计划块的完成闩（原则7：自动完成先斩，用户手动改回永远赢；nil=清回未决定）。
    func latchCompletion(plannedID: UUID, _ status: CompletionStatus?) throws {
        guard let block = try context.fetch(FetchDescriptor<PlanBlock>())
            .first(where: { !$0.isInTrash && $0.id == plannedID && $0.kind == .planned }) else { return }
        block.completion = status
        try context.save()
    }

    private static func dayStr(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }
}
