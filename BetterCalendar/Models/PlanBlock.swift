//
//  PlanBlock.swift
//  BetterCalendar
//
//  排程最小单位。priority(要紧事) 与 deadline(硬 DDL) 是两条正交的轴：
//  - priority：自己设的「今天最该做」，是温和 push 的对象。
//  - deadline：外部硬截止；不同于 isFixed（isFixed=在某时刻发生，如会议；deadline=必须某时刻前做完）。
//  labels 是预留的扩展接口：日后细化标签设计往这里加，不必改 schema。
//

import Foundation
import SwiftData

@Model
final class PlanBlock: RetainedRecord {
    var id: UUID = UUID()
    var title: String = ""
    var start: Date = Date.now
    var end: Date = Date.now
    var isFixed: Bool = false
    var isAnchor: Bool = false
    var kind: BlockKind = BlockKind.planned
    var timingStyle: TimingStyle = TimingStyle.light
    var priority: BlockPriority = BlockPriority.normal
    var deadline: Date?
    var labels: [String] = []       // 扩展接口
    var linkedTaskID: UUID?         // 精确归属：本块属于哪个未来任务(LongTask.id)；nil=不属于池任务（0.18.2）
    var completion: CompletionStatus?
    var deletedAt: Date?
    var deletionID: UUID?
    var restoredDeletionID: UUID?
    var deletionContext: Data?
    // —— P4（SPEC §19.13，2026-10-18）：CloudKit additive 字段，发 TestFlight 前须 Development 建出并 Deploy ——
    /// 图钉截止（Q6）：你亲手改过时间的块，当天之内自动调整一律绕开。nil = 没钉。
    var pinnedUntil: Date?
    /// 同步版本（Q7/Q8）：每次真改动 = max(现在毫秒, 旧值+1)。0 = 旧数据。
    var syncVersion: Int64 = 0
    /// 最后写入它的设备 id（作者宽限：别的设备暂不替它新建日历事件，防重复）。
    var syncWriter: String?
    /// 最后一次写入的来源（PlanWriteReason.rawValue）：判「你的改动 vs 自动调整」谁赢。
    var syncSource: String?
    /// 实际行状态（仅 kind=.actual）：nil = 记下的实际；"live" = 正在做（蓝色在长）；"auto" = 被动推断（固定块到点，不画蓝）。
    var actualState: String?

    init(id: UUID = UUID(),
         title: String,
         start: Date,
         end: Date,
         isFixed: Bool = false,
         isAnchor: Bool = false,
         kind: BlockKind = .planned,
         timingStyle: TimingStyle = .light,
         priority: BlockPriority = .normal,
         deadline: Date? = nil,
         labels: [String] = [],
         linkedTaskID: UUID? = nil,
         completion: CompletionStatus? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isFixed = isFixed
        self.isAnchor = isAnchor
        self.kind = kind
        self.timingStyle = timingStyle
        self.priority = priority
        self.deadline = deadline
        self.labels = labels
        self.linkedTaskID = linkedTaskID
        self.completion = completion
    }
}
