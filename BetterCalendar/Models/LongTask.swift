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

@Model
final class LongTask {
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

    init(id: UUID = UUID(), title: String, note: String = "",
         deadline: Date? = nil, cadenceMinutesPerWeek: Int? = nil,
         totalMinutes: Int? = nil, unitMinutes: Int? = nil,
         status: LongTaskStatus = .active,
         createdAt: Date = .now, doneAt: Date? = nil, modifiedAt: Date = .now) {
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
    }
}
