//
//  LearningStore.swift
//  BetterCalendar
//
//  学习层采集端的存取与编排（E4/P1d）：
//  · 快照：该逻辑日第一次确认写入时存、之后不覆盖（「最初」语义）；
//  · 折算：启动兜底——把「有快照、无样本、已经过去」的逻辑日补折（幂等，最多回看 7 天）。
//    不接收尾流程：折「今天」必然不完整，正确时机=日子过完（次日启动）。
//

import Foundation
import SwiftData

@MainActor
final class LearningStore {
    private let context: ModelContext

    init(context: ModelContext? = nil) {
        self.context = context ?? SharedModelContainer.shared.mainContext
    }

    // MARK: 快照（save-once）

    /// 确认写入成功后调用：该日已有快照则不动（最初语义），否则存一份。
    func snapshotIfFirst(dayLabel: Date, blocks: [ScheduledBlock]) {
        guard snapshot(for: dayLabel) == nil else { return }
        let items = blocks.map { b in
            SnapshotItem(id: b.id, title: b.title, plannedStart: b.start,
                         plannedMinutes: max(0, Int(b.end.timeIntervalSince(b.start) / 60)),
                         isFixed: b.isFixed, isAnchor: b.isAnchor,
                         linkedTaskID: b.linkedTaskID, labels: b.labels,
                         priorityRaw: b.priority.rawValue)   // E5b：基线要认得 ★
        }
        context.insert(DayPlanSnapshot(dayLabel: dayLabel, items: items))
        try? context.save()
        DevLog.shared.info("学习层", "当日最初计划快照已存（\(items.count) 块）")
    }

    func snapshot(for dayLabel: Date) -> DayPlanSnapshot? {
        let d = FetchDescriptor<DayPlanSnapshot>()
        return (try? context.fetch(d))?.first { $0.dayLabel == dayLabel }
    }

    // MARK: 残差样本

    func samples(on dayLabel: Date) -> [ResidualSample] {
        Self.collapsed(allRows().filter { $0.dayLabel == dayLabel })
    }

    /// 全量样本（L3 聚合折算用；聚合器按 createdAt 游标自行取新）。
    func allSamples() -> [ResidualSample] {
        Self.collapsed(allRows())
    }

    private func allRows() -> [ResidualSample] {
        (try? context.fetch(FetchDescriptor<ResidualSample>())) ?? []
    }

    /// W27：补折是启动时自动跑的——两台设备在 CloudKit 送达前各折一遍，同一天同一块会有两份样本（学习层双计）。
    /// 身份 =（逻辑日, 块 id）：同身份只留最早折的那份（再按实际起点 / 时长 / 标题定序，两台设备选出同一份），
    /// 留最早的那份与聚合器 createdAt 游标一致：后到的副本不会被当成新样本再折一次。
    static func collapsed(_ rows: [ResidualSample]) -> [ResidualSample] {
        var best: [String: ResidualSample] = [:]
        var order: [String] = []
        for r in rows {
            let key = "\(r.dayLabel.timeIntervalSinceReferenceDate)|\(r.blockID.uuidString)"
            guard let cur = best[key] else { best[key] = r; order.append(key); continue }
            if precedes(r, cur) { best[key] = r }
        }
        if order.count < rows.count {
            DevLog.shared.info("学习层", "有 \(rows.count - order.count) 个残差样本是另一台设备同时折的同一块，按一份算")
        }
        return order.compactMap { best[$0] }
    }

    private static func precedes(_ a: ResidualSample, _ b: ResidualSample) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        if a.actualStart != b.actualStart { return a.actualStart < b.actualStart }
        if a.actualMinutes != b.actualMinutes { return a.actualMinutes < b.actualMinutes }
        return a.title < b.title
    }

    /// 启动兜底：补折过去 7 天里「有快照、无样本、已过去」的日子（幂等）。
    /// 返回补折的天数（观察窗/DevLog 用）。
    @discardableResult
    func foldPendingDays(planStore: PlanStore, sessionStore: ExecutionSessionStore,
                         now: Date = .now) -> Int {
        var folded = 0
        let today = DayContext.logicalStartOfDay(now)
        for offset in 1...7 {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: today) else { continue }
            guard let snap = snapshot(for: day), samples(on: day).isEmpty else { continue }
            let actuals = (try? planStore.actualBlocks(on: day)) ?? []
            guard !actuals.isEmpty else { continue }   // 整天未回填 → 整日剔除（准入规则），下次仍可补
            let sessionIDs = Set(sessionStore.sessions(onLogicalDay: day).compactMap(\.blockID))
            let foldedSamples = ResidualFolder.fold(dayLabel: day, snapshot: snap.items,
                                                    actuals: actuals, sessionBlockIDs: sessionIDs)
            guard !foldedSamples.isEmpty else { continue }
            for f in foldedSamples {
                context.insert(ResidualSample(
                    dayLabel: day, blockID: f.item.id, title: f.item.title,
                    labels: f.item.labels, linkedTaskID: f.item.linkedTaskID,
                    isFixed: f.item.isFixed, isAnchor: f.item.isAnchor,
                    plannedStart: f.item.plannedStart, plannedMinutes: f.item.plannedMinutes,
                    actualStart: f.actualStart, actualMinutes: f.actualMinutes,
                    source: f.source))
            }
            try? context.save()
            folded += 1
            DevLog.shared.info("学习层", "补折 \(DayContext.dayKey(day))：\(foldedSamples.count) 个残差样本")
        }
        return folded
    }
}
