//
//  EditableBlock.swift
//  BetterCalendar
//
//  草稿块（可编辑的中间态，与不可变的 ScheduledBlock 互转）。
//  原住 HomeViewModel.swift；2026-07-08 架构修缮挪进 Models——
//  Services 层的 DraftSnapshotStore 也消费它，模型类型放 Features 构成反向依赖。
//

import Foundation

struct EditableBlock: Identifiable {
    var id: UUID
    var title: String
    var start: Date
    var end: Date
    var isFixed: Bool
    var isAnchor: Bool = false
    var timingStyle: TimingStyle
    var priority: BlockPriority
    var deadline: Date?   // 硬 DDL（≠isFixed）：必须在此之前做完；LLM 解析给出，提醒 due 优先用它
    var fromPool: Bool = false   // 来自「未来任务」的建议块（M10-2：UI 标来源，删除零成本）
    var linkedTaskID: UUID?      // 精确归属：本块属于哪个未来任务（0.18.2：自动匹配 + 草稿行可手动改）
    var labels: [String] = []    // 扩展标签（0.22：并行组 "parallel:<组名>"）

    init(from b: ScheduledBlock) {
        id = b.id; title = b.title; start = b.start; end = b.end
        isFixed = b.isFixed; isAnchor = b.isAnchor; timingStyle = b.timingStyle; priority = b.priority
        deadline = b.deadline; linkedTaskID = b.linkedTaskID; labels = b.labels
    }
    init(title: String, start: Date, end: Date,
         isFixed: Bool = false, isAnchor: Bool = false,
         timingStyle: TimingStyle = .light, priority: BlockPriority = .normal,
         deadline: Date? = nil, linkedTaskID: UUID? = nil) {
        id = UUID(); self.title = title; self.start = start; self.end = end
        self.isFixed = isFixed; self.isAnchor = isAnchor; self.timingStyle = timingStyle; self.priority = priority
        self.deadline = deadline; self.linkedTaskID = linkedTaskID
    }
    var scheduled: ScheduledBlock {
        ScheduledBlock(id: id, title: title, start: start, end: end,
                       isFixed: isFixed, isAnchor: isAnchor, timingStyle: timingStyle, priority: priority,
                       deadline: deadline, linkedTaskID: linkedTaskID, labels: labels)
    }

    static let parallelPrefix = ScheduledBlock.parallelPrefix
    var parallelGroup: String? { labels.first { $0.hasPrefix(Self.parallelPrefix) } }
}
