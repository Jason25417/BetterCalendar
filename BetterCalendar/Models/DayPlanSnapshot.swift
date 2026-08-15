//
//  DayPlanSnapshot.swift
//  BetterCalendar
//
//  当日最初计划快照（E4/P1d，SPEC §13.A.4 最重硬条件 + §14.2 残差基准）：
//  该逻辑日**第一次确认写入**时存一份计划明细，之后同日再改再确认**不覆盖**——
//  「你最初怎么估的」永久保真。三用途共用一份：残差折算的基准（§14.2）、
//  复盘对比的基线（防绿随实际漂移≈蓝）、将来行为轨迹学习的训练信号（#47）。
//  明细存 JSON blob（快照是只读档案、不需按内部字段查询）——零关系、CloudKit additive 安全。
//  ⚠️ 新 @Model：发 TestFlight 前须 CloudKit Console Deploy schema。
//

import Foundation
import SwiftData

/// 快照里的一条计划块明细（Codable，序列化进 itemsJSON）。
nonisolated struct SnapshotItem: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var plannedStart: Date
    var plannedMinutes: Int
    var isFixed: Bool
    var isAnchor: Bool
    var linkedTaskID: UUID?
    var labels: [String]
    /// ★优先级（E5b 补，D11：快照接任复盘基线后 MIT 兑现红利需要它）。
    /// optional=旧 JSON blob 缺键解码为 nil（additive 安全）；nil 视为 normal。
    var priorityRaw: String? = nil

    var priority: BlockPriority { priorityRaw.flatMap { BlockPriority(rawValue: $0) } ?? .normal }
}

@Model
final class DayPlanSnapshot {
    var dayLabel: Date = Date.now      // 逻辑日标签（DayContext.logicalStartOfDay 的零点）
    var createdAt: Date = Date.now
    var itemsJSON: Data = Data()

    init(dayLabel: Date, createdAt: Date = .now, items: [SnapshotItem]) {
        self.dayLabel = dayLabel
        self.createdAt = createdAt
        self.itemsJSON = (try? JSONEncoder().encode(items)) ?? Data()
    }

    var items: [SnapshotItem] {
        (try? JSONDecoder().decode([SnapshotItem].self, from: itemsJSON)) ?? []
    }
}
