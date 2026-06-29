//
//  ScheduleParsing.swift
//  BetterCalendar
//
//  自然语言 → 结构化计划。原型期实现 = 云端 Claude（ClaudeScheduleParser，待接）。
//  现用 StubScheduleParser 兜底，保证离线/未配 key 也能跑。
//  缝是 async throws，方便日后换成网络实现。
//

import Foundation

protocol ScheduleParsing {
    func parse(_ text: String, referenceDate: Date) async throws -> ParsedPlan
}
