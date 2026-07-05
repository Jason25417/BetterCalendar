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
final class PlanBlock {
    var id: UUID = UUID()
    var title: String = ""
    var start: Date = Date.now
    var end: Date = Date.now
    var isFixed: Bool = false
    var isAnchor: Bool = false
    var category: String = ""
    var kind: BlockKind = BlockKind.planned
    var timingStyle: TimingStyle = TimingStyle.light
    var priority: BlockPriority = BlockPriority.normal
    var deadline: Date?
    var assignedBy: AssignedBy = AssignedBy.selfAssigned
    var labels: [String] = []       // 扩展接口
    var linkedTaskID: UUID?         // 精确归属：本块属于哪个未来任务(LongTask.id)；nil=不属于池任务（0.18.2）
    var externalEventID: String?
    var completion: CompletionStatus?

    init(id: UUID = UUID(),
         title: String,
         start: Date,
         end: Date,
         isFixed: Bool = false,
         isAnchor: Bool = false,
         category: String = "",
         kind: BlockKind = .planned,
         timingStyle: TimingStyle = .light,
         priority: BlockPriority = .normal,
         deadline: Date? = nil,
         assignedBy: AssignedBy = .selfAssigned,
         labels: [String] = [],
         linkedTaskID: UUID? = nil,
         externalEventID: String? = nil,
         completion: CompletionStatus? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isFixed = isFixed
        self.isAnchor = isAnchor
        self.category = category
        self.kind = kind
        self.timingStyle = timingStyle
        self.priority = priority
        self.deadline = deadline
        self.assignedBy = assignedBy
        self.labels = labels
        self.linkedTaskID = linkedTaskID
        self.externalEventID = externalEventID
        self.completion = completion
    }
}
