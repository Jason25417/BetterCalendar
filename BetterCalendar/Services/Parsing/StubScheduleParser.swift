//
//  StubScheduleParser.swift
//  BetterCalendar
//
//  朴素本地解析（占位）：按 逗号/顿号/换行 切句，每句一个 1 小时块，从当天 9:00 顺排。
//  仅用于让骨架跑通；真正解析以后由 ClaudeScheduleParser 接管。
//

import Foundation

struct StubScheduleParser: ScheduleParsing {
    func parse(_ text: String, referenceDate: Date) async throws -> ParsedPlan {
        let pieces = text
            .split(whereSeparator: { "，,、\n;；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let cal = Calendar.current
        var cursor = cal.date(bySettingHour: 9, minute: 0, second: 0, of: referenceDate) ?? referenceDate
        var blocks: [ParsedBlock] = []
        for piece in pieces {
            let end = cursor.addingTimeInterval(3600)
            blocks.append(ParsedBlock(title: piece, start: cursor, end: end, durationMinutes: 60))
            cursor = end
        }
        return ParsedPlan(blocks: blocks)
    }
}
