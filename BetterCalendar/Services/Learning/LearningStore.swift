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
        let d = FetchDescriptor<ResidualSample>()
        return (try? context.fetch(d))?.filter { $0.dayLabel == dayLabel } ?? []
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
