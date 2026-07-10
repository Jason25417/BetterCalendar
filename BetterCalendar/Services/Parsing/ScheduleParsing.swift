//
//  ScheduleParsing.swift
//  BetterCalendar
//
//  自然语言 → 结构化计划。实现：FoundationModelsScheduleParser（链头：端侧/云端取舍）→
//  ClaudeScheduleParser（云端）→ FailedScheduleParser（终端干净失败态，0.26 起无本地垃圾兜底）。
//  缝是 async throws，实现无关。
//

import Foundation

protocol ScheduleParsing {
    func parse(_ text: String, referenceDate: Date) async throws -> ParsedPlan
    /// 带上下文（目标日已有日程/到期提醒）；默认忽略（Stub 等本地兜底）。
    func parse(_ text: String, referenceDate: Date, context: ParseContext) async throws -> ParsedPlan
}

extension ScheduleParsing {
    func parse(_ text: String, referenceDate: Date, context: ParseContext) async throws -> ParsedPlan {
        try await parse(text, referenceDate: referenceDate)
    }
}
