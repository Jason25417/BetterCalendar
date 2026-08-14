//
//  ResidualSample.swift
//  BetterCalendar
//
//  残差样本（E4/P1d，SPEC §14.2）：一块「最初估计 vs 实际发生」的原始记录。
//  只存原始量（倍率/对数在聚合层 L3 再算），带来源标记 live/recall（v1 不降权，攒数据后回放分析）。
//  隐私：与 PlanBlock 同级（计划块级数据），随 SwiftData 主容器 CloudKit 同步；聚合画像才是本地-only。
//  ⚠️ 新 @Model：发 TestFlight 前须 CloudKit Console Deploy schema。
//

import Foundation
import SwiftData

@Model
final class ResidualSample {
    var dayLabel: Date = Date.now       // 所属逻辑日
    var blockID: UUID = UUID()          // 对应计划块（=实际块 id，换幕布机制）
    var title: String = ""
    var labels: [String] = []           // 活动标签（分桶键之一）
    var linkedTaskID: UUID?             // 长期任务归属（最细分桶键）
    var isFixed: Bool = false
    var isAnchor: Bool = false
    var plannedStart: Date = Date.now   // 快照里的最初估计
    var plannedMinutes: Int = 0
    var actualStart: Date = Date.now
    var actualMinutes: Int = 0
    var sourceRaw: String = "live"      // live=有计时会话的测量值 / recall=复盘补记的回忆值
    var createdAt: Date = Date.now

    init(dayLabel: Date, blockID: UUID, title: String, labels: [String] = [],
         linkedTaskID: UUID? = nil, isFixed: Bool = false, isAnchor: Bool = false,
         plannedStart: Date, plannedMinutes: Int, actualStart: Date, actualMinutes: Int,
         source: Source) {
        self.dayLabel = dayLabel
        self.blockID = blockID
        self.title = title
        self.labels = labels
        self.linkedTaskID = linkedTaskID
        self.isFixed = isFixed
        self.isAnchor = isAnchor
        self.plannedStart = plannedStart
        self.plannedMinutes = plannedMinutes
        self.actualStart = actualStart
        self.actualMinutes = actualMinutes
        self.sourceRaw = source.rawValue
    }

    enum Source: String, Sendable { case live, recall }
    var source: Source { Source(rawValue: sourceRaw) ?? .live }
}
