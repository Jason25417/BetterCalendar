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
    var start: Date
    var end: Date?
    var timingStyle: TimingStyle
    var completedCount: Int?
    var interruptions: Int

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
