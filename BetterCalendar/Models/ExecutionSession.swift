//
//  ExecutionSession.swift
//  BetterCalendar
//
//  一次执行陪伴会话（取代 PomodoroSession：番茄钟只是 timingStyle 的一档）。
//  起止顺手并入「实际」/ 有效投入统计。
//

import Foundation
import SwiftData

@Model
final class ExecutionSession {
    var blockID: UUID?
    var title: String = ""            // 块标题（blockID 可能失效，标题让统计可读）
    var start: Date = Date.now
    var end: Date?
    var timingStyle: TimingStyle = TimingStyle.light
    var completedCount: Int?          // 番茄钟：完成的工作段数（非番茄 nil）
    var interruptions: Int = 0        // 中途休息次数

    init(blockID: UUID? = nil, start: Date = .now, end: Date? = nil,
         timingStyle: TimingStyle = .light, completedCount: Int? = nil,
         interruptions: Int = 0) {
        self.blockID = blockID
        self.start = start
        self.end = end
        self.timingStyle = timingStyle
        self.completedCount = completedCount
        self.interruptions = interruptions
    }
}
