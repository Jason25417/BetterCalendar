//
//  JournalEntry.swift
//  BetterCalendar
//
//  反思层（日记）的数据预留。功能全部后做（见里程碑 R 系列 / M9）；
//  现在只把它放进 schema + CloudKit 容器，因为数据层事后 retrofit 很贵、预留很便宜。
//  记"主观轨"（感受/想法/心情/照片），与计划-实际的"客观轨"互补，绝不重复记"做了什么"。
//

import Foundation
import SwiftData

@Model
final class JournalEntry {
    var id: UUID = UUID()
    var date: Date = Date.now      // 关到某一天（与 PlanDay.date 对齐）
    var linkedPlanDayDate: Date?   // 关回当天 → 取"今天做成了什么"当写作素材
    var body: String = ""          // 正文（富文本/Markdown 待 R 系列定）
    var mood: String?
    var tags: [String] = []
    var photoRefs: [String] = []   // 图片文件名/相对路径；文件存 App 容器，不塞进 DB
    var source: JournalSource = JournalSource.written
    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now

    init(id: UUID = UUID(),
         date: Date,
         linkedPlanDayDate: Date? = nil,
         body: String = "",
         mood: String? = nil,
         tags: [String] = [],
         photoRefs: [String] = [],
         source: JournalSource = .written,
         createdAt: Date = .now,
         modifiedAt: Date = .now) {
        self.id = id
        self.date = date
        self.linkedPlanDayDate = linkedPlanDayDate
        self.body = body
        self.mood = mood
        self.tags = tags
        self.photoRefs = photoRefs
        self.source = source
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
