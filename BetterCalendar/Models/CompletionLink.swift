//
//  CompletionLink.swift
//  BetterCalendar
//
//  预先设计块 × 实际块的匹配结果。status=extra 即计划外 bonus。
//

import Foundation
import SwiftData

@Model
final class CompletionLink {
    var plannedBlockID: UUID
    var actualBlockID: UUID?
    var status: CompletionStatus

    init(plannedBlockID: UUID, actualBlockID: UUID? = nil, status: CompletionStatus) {
        self.plannedBlockID = plannedBlockID
        self.actualBlockID = actualBlockID
        self.status = status
    }
}
