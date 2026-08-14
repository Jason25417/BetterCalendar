//
//  ResidualFolder.swift
//  BetterCalendar
//
//  残差折算器（E4/P1d，SPEC §14.2）：纯函数——快照 × 实际 × 会话 → 残差样本集。
//  样本准入（Jason 2026-08-01 确认）：
//  · 基准一律=快照的最初估计（reflow 改动不污染——这正是快照存在的意义）；
//  · 排除：自动完成的固定块（实际=照抄计划、倍率恒 1 的假样本——识别近似：isFixed 且无
//    计时会话且实际起止与计划完全一致）/ 无实际发生的块（结局记录待 E5 溢出裁决真实发生后补）
//    / 时长残缺；
//  · 不排除：复盘补记（source=recall 标记，v1 不降权）；中断不扣除（倍率自然吸收）。
//  v1 范围：只产「完成样本」的时长/时刻残差；spilled/abandoned 结局在 E5 后由裁决记录补。
//

import Foundation

nonisolated enum ResidualFolder {

    /// 折算一个逻辑日。sessionBlockIDs = 该日有计时会话的块 id 集（live/recall 判定）。
    static func fold(dayLabel: Date,
                     snapshot: [SnapshotItem],
                     actuals: [ActualBlock],
                     sessionBlockIDs: Set<UUID>) -> [FoldedSample] {
        var out: [FoldedSample] = []
        let actualByID = Dictionary(uniqueKeysWithValues: actuals.map { ($0.id, $0) })

        for item in snapshot {
            guard let actual = actualByID[item.id] else { continue }   // 无实际=溢出/未做，E5 后补结局
            let actualMinutes = Int(actual.end.timeIntervalSince(actual.start) / 60)
            guard item.plannedMinutes > 0, actualMinutes > 0 else { continue }   // 残缺剔除

            let hasSession = sessionBlockIDs.contains(item.id)
            // 自动完成的固定块（假样本）：isFixed、无会话、实际起止与计划完全一致
            if item.isFixed, !hasSession,
               abs(actual.start.timeIntervalSince(item.plannedStart)) < 60,
               actualMinutes == item.plannedMinutes {
                continue
            }

            out.append(FoldedSample(
                item: item,
                actualStart: actual.start,
                actualMinutes: actualMinutes,
                source: hasSession ? .live : .recall))
        }
        return out
    }

    /// 折算产物（转 @Model 前的纯值类型，方便单测）。
    struct FoldedSample: Equatable, Sendable {
        var item: SnapshotItem
        var actualStart: Date
        var actualMinutes: Int
        var source: ResidualSample.Source
    }
}
