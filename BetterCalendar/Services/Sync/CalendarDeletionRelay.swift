//
//  CalendarDeletionRelay.swift
//  BetterCalendar
//
//  P4.1（2026-10-19）：iPhone 先发现「你在日历里删了块」时，智能体也要知道。
//  为什么需要它：只有 Mac 写桥接事件（bridge/ 在 Mac 上）。iPhone 先对账时会照办（移出时间线、收进待办区），
//  但 calendar_user_deleted 事件发不出去；等 Mac 再对账，块在真相里已经删了，Mac 什么也看不出来。
//  做法（不新增 CloudKit 记录类型）：发现删除的设备把一张「回执」写进被删计划块自己的 `deletionContext`
//  （PlanBlock 已有、随 CloudKit 同步的字段，回收站机制本来就用它存删除上下文）；Mac 收到 CloudKit 导入后，
//  由本中继把还没转交过的回执写成一次 calendar_user_deleted 事件。
//  去重：按块 id 记「已转交」（Mac 本机 UserDefaults，plist 类型）；Mac 自己先发现的删除当场发事件并记一笔，
//  之后看到同一块的回执（自己的或另一台设备并发写的）不再重复发。
//  回执带上它所属那次删除的 deletionID：块被恢复后又因别的原因删掉时，旧回执不会被误当成新的日历删除。
//

import Foundation

/// 「你在日历里删了这块」的回执（写进被删计划块的 deletionContext，随 iCloud 同步）。
nonisolated struct CalendarDeletionReceipt: Codable, Equatable, Sendable {
    static let currentKind = "calendar_user_deleted"
    var kind: String = Self.currentKind
    var version: Int = 1
    /// 它属于哪一次删除（PlanStore 写入时填）；与行上的 deletionID 不同 = 过期回执，不认。
    var deletionID: UUID?
    var detectedAt: Date
    /// 发现删除的设备（给智能体的线索，如「iPhone」「Mac」）。
    var detectedBy: String
    var collectedToTodo: Bool

    func encoded() -> Data? {
        let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }

    /// 不是回执（空、照片归属数组、别的格式）→ nil。
    static func decode(_ data: Data?) -> CalendarDeletionReceipt? {
        guard let data else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970
        guard let r = try? d.decode(CalendarDeletionReceipt.self, from: data), r.kind == currentKind else { return nil }
        return r
    }
}

/// 回收站里带有效回执的计划块（块内容取自被删的那一行）。
struct CalendarDeletionRecord {
    let block: ScheduledBlock
    let receipt: CalendarDeletionReceipt
}

@MainActor
protocol CalendarDeletionReceiptReading: AnyObject {
    /// 仍在回收站、且回执属于当前这次删除的计划块。
    func calendarDeletionReceipts() throws -> [CalendarDeletionRecord]
}

/// Mac 侧中继：把另一台设备（或本机上一次运行）记下、还没转交的日历删除写成一次桥接事件。
@MainActor
final class CalendarDeletionRelay {
    private let source: CalendarDeletionReceiptReading
    private let defaults: UserDefaults
    private let now: () -> Date

    /// 只转交最近这么久发现的删除（新装的 Mac / 很久没开时，不把陈年旧删除一股脑倒给智能体）。
    static let lookback: TimeInterval = 72 * 3600
    /// 「已转交」记录保留多久（远大于 lookback，防止回执还在窗口里时记录先被淘汰）。
    static let memory: TimeInterval = 7 * 86400
    static let key = "calendarDeletion.relayed"

    init(source: CalendarDeletionReceiptReading, defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now }) {
        self.source = source
        self.defaults = defaults
        self.now = now
    }

    private var relayed: [String: Double] {
        get { defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    /// 记下「这些块的删除已经告诉过智能体了」（Mac 自己先发现、当场发事件时调）。
    func markRelayed(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let t = now().timeIntervalSince1970
        var all = relayed.filter { t - $0.value < Self.memory }
        for id in ids { all[id.uuidString] = t }
        relayed = all
    }

    /// 还没转交的删除（按发现时间排序）。读失败 → 记日志、返回空（下次再试，不丢回执：回执还在行上）。
    func pending() -> [CalendarUserDeletion] {
        let records: [CalendarDeletionRecord]
        do { records = try source.calendarDeletionReceipts() }
        catch {
            DevLog.shared.warn("对账", "读日历删除回执失败，这一轮不转交给智能体（下次再试）：\(error.localizedDescription)")
            return []
        }
        let done = relayed, t = now()
        return records
            .filter { done[$0.block.id.uuidString] == nil && t.timeIntervalSince($0.receipt.detectedAt) < Self.lookback }
            .sorted { $0.receipt.detectedAt < $1.receipt.detectedAt }
            .map { r in
                CalendarUserDeletion(block: r.block, label: DayContext.logicalStartOfDay(r.block.start),
                                     collectedToTodo: r.receipt.collectedToTodo, trimmedLive: false,
                                     detectedAt: r.receipt.detectedAt, detectedBy: r.receipt.detectedBy)
            }
    }

    /// 转交一轮：emit 返回 true（桥接已接通、事件已交出）才记「已转交」；false = 留着下次再试。
    @discardableResult
    func relay(emit: ([CalendarUserDeletion]) -> Bool) -> Int {
        let ds = pending()
        guard !ds.isEmpty, emit(ds) else { return 0 }
        markRelayed(ds.map(\.block.id))
        DevLog.shared.info("对账", "转交另一台设备发现的日历删除 \(ds.count) 件给智能体：\(ds.map { "「\($0.block.title)」" }.joined(separator: "、"))")
        return ds.count
    }
}
