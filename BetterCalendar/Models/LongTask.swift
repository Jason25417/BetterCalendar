//
//  LongTask.swift
//  BetterCalendar
//
//  「在途」（M10，2026-07-04 定）：跨日的长期事项池 = reflow 的跨日延伸 + 排程大脑的记忆。
//  统一两类场景：远期 DDL 任务（有 deadline）与长线作业（有 cadence 投入节奏），不强迫用户区分。
//  反需求（产品哲学）：无子任务/层级/进度百分比/「逾期」红标——DDL 过了走温和三选（排上/改期/放下）。
//  CloudKit 约束：非 optional 带默认值、枚举默认完全限定、无 unique。
//

import Foundation
import SwiftData

enum LongTaskStatus: String, Codable, CaseIterable, Sendable {
    case active     // 在途
    case done       // 做成了
    case shelved    // 先放下（体面出口，不是失败）
}

/// 一池两区（E5a，I1 裁定 2026-08-15）：同一张表两个分区。
/// longterm=长期区（郑重收进来的长线事项，无删除只改状态）；
/// todo=待办区（小愿望+溢出顺延物，轻量条目：重字段全空、无检查点；丢弃=从当前列表移除，原记录进入回收站）。
enum PoolZone: String, Sendable {
    case longterm
    case todo
}

@Model
final class LongTask: RetainedRecord {
    var id: UUID = UUID()
    var title: String = ""
    var note: String = ""
    var deadline: Date?                  // 远期硬截止（可无）
    var cadenceMinutesPerWeek: Int?      // 长线投入节奏，如每周 300 分钟（可无）
    var totalMinutes: Int?               // 总量（"共9单元40min"→360；"共150小时"→9000）；可无=只显已投入
    var unitMinutes: Int?                // 单元时长（有则进度按单元数显示，如 3/9）
    var status: LongTaskStatus = LongTaskStatus.active
    var createdAt: Date = Date.now
    var doneAt: Date?
    var modifiedAt: Date = Date.now
    var deletedAt: Date?
    var deletionID: UUID?
    var restoredDeletionID: UUID?
    var deletionContext: Data?
    // 一池两区（E5a）。CloudKit additive：带默认值，老数据自动落长期区。存字符串保兼容。
    // ⚠️ 命名：不能叫 `zone`——CoreData 属性名禁撞 NSObject 方法名（-zone），SwiftData 直接 EXC_BREAKPOINT。
    var zoneRaw: String = PoolZone.longterm.rawValue
    /// 族（§14.3 闭集）：setup 计价与学习层分桶单位；归属到本任务的块经继承拿它（FamilyResolver 第一级）。
    var family: String?
    /// 溢出来源逻辑日（nil=手动收的愿望）：待办区晨间露脸判据（昨日溢出晨间必露一次脸）。
    var spilledFromDay: Date?
    /// 检查点（#40，2026-07-15 M10 管辖域修订后放开的「有限一层」）：只此一层、只有顺序、
    /// 无各自 DDL（检查点无期限红线）。CloudKit 约束：关系 optional。空=沿用计数/时长型进度。
    @Relationship(deleteRule: .cascade, inverse: \LongTaskCheckpoint.task)
    var checkpoints: [LongTaskCheckpoint]? = []

    init(id: UUID = UUID(), title: String, note: String = "",
         deadline: Date? = nil, cadenceMinutesPerWeek: Int? = nil,
         totalMinutes: Int? = nil, unitMinutes: Int? = nil,
         status: LongTaskStatus = .active,
         createdAt: Date = .now, doneAt: Date? = nil, modifiedAt: Date = .now,
         zone: PoolZone = .longterm, family: String? = nil, spilledFromDay: Date? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.deadline = deadline
        self.cadenceMinutesPerWeek = cadenceMinutesPerWeek
        self.totalMinutes = totalMinutes
        self.unitMinutes = unitMinutes
        self.status = status
        self.createdAt = createdAt
        self.doneAt = doneAt
        self.modifiedAt = modifiedAt
        self.zoneRaw = zone.rawValue
        self.family = family
        self.spilledFromDay = spilledFromDay
    }

    /// 类型安全的分区读取（存储层是字符串，未知值兜底长期区）。
    var poolZone: PoolZone { PoolZone(rawValue: zoneRaw) ?? .longterm }

    /// 检查点按手排顺序（order）返回。
    var sortedCheckpoints: [LongTaskCheckpoint] {
        (checkpoints ?? []).filter { !$0.isInTrash }.sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }
    /// 「下一个」＝第一个未勾的检查点（排进今天的块副标题、L3 建议都用它）。
    var nextCheckpoint: LongTaskCheckpoint? {
        sortedCheckpoints.first { $0.doneAt == nil }
    }
}

/// 检查点（#40）：命名阶段——「第 3 章 测度论」这种。铁律：无嵌套（下面没有子项）、
/// 无期限（只有顺序，绝不带各自 DDL）、无百分比（进度口径=已推进 m/n 计数）。
/// CloudKit 约束：非 optional 带默认值、关系 optional、无 unique。
@Model
final class LongTaskCheckpoint: RetainedRecord {
    var id: UUID = UUID()
    var title: String = ""
    var estimatedMinutes: Int?      // 可选预估时长（排进今天时作块长参考）
    var doneAt: Date?               // 勾选盖章（nil=未推进到）
    var order: Int = 0              // 手排顺序（拖动重排写它）
    var createdAt: Date = Date.now
    var task: LongTask?
    var deletedAt: Date?
    var deletionID: UUID?
    var restoredDeletionID: UUID?
    var deletionContext: Data?

    init(id: UUID = UUID(), title: String, estimatedMinutes: Int? = nil, doneAt: Date? = nil,
         order: Int = 0, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.estimatedMinutes = estimatedMinutes
        self.doneAt = doneAt
        self.order = order
        self.createdAt = createdAt
    }
}
