//
//  PlanDay.swift
//  BetterCalendar
//
//  一天的元数据。真正的事件存系统日历；这里只存「我们的视角」。
//

import Foundation
import SwiftData

@Model
final class PlanDay {
    var date: Date = Date.now
    var plannedStartAnchor: Date?
    var actualStartTime: Date?
    var source: String = "manual"

    init(date: Date, plannedStartAnchor: Date? = nil,
         actualStartTime: Date? = nil, source: String = "manual") {
        self.date = date
        self.plannedStartAnchor = plannedStartAnchor
        self.actualStartTime = actualStartTime
        self.source = source
    }
}
