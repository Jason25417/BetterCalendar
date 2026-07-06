//
//  StubScheduleParser.swift
//  BetterCalendar
//
//  本地兜底解析（云端失败时用）：按标点切句 → 每句抽出**真实时长**(N小时/半小时/N分钟, 含"1。5小时")、
//  识别**作息锚点**(午饭/晚饭/早饭/午休/通勤) → 从 9:00 顺排，用抽到的时长而非死板 1 小时。
//  不做智能排序/并行/re-flow（那些云端接管），但比"每句1小时"可用得多。
//

import Foundation

struct StubScheduleParser: ScheduleParsing {
    func parse(_ text: String, referenceDate: Date) async throws -> ParsedPlan {
        let pieces = text
            .split(whereSeparator: { "，,、\n;；。".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }

        let cal = Calendar.current
        var cursor = cal.date(bySettingHour: 9, minute: 0, second: 0, of: referenceDate) ?? referenceDate
        var blocks: [ParsedBlock] = []
        for piece in pieces {
            let minutes = Self.extractMinutes(piece) ?? 60
            let end = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            let anchor = Self.anchorKeywords.contains { piece.contains($0) }
            blocks.append(ParsedBlock(title: piece, start: cursor, end: end,
                                      durationMinutes: minutes, isAnchor: anchor))
            cursor = end
        }
        return ParsedPlan(blocks: blocks)
    }

    private static let anchorKeywords = ["午饭", "晚饭", "早饭", "午休", "午睡", "通勤", "睡觉"]

    /// 从一句话抽出时长（分钟）：半小时→30；「N(个)小时/钟头」→N×60（含中文数字与"1。5"小数）；「N分钟」→N。抽不到 nil。
    static func extractMinutes(_ s: String) -> Int? {
        let t = s.replacingOccurrences(of: "。", with: ".")   // 中文句号常被当小数点（"1。5小时"）→ 归一化
        if t.contains("个半小时") {   // "一个半小时"=90、"两个半小时"=150
            return Int(((number(before: "个半小时", in: t) ?? 1) + 0.5) * 60)
        }
        if s.contains("半小时") || s.contains("半个小时") { return 30 }
        if let h = number(before: "小时", in: t) ?? number(before: "钟头", in: t) { return Int((h * 60).rounded()) }
        if let m = number(before: "分钟", in: t) { return Int(m.rounded()) }
        return nil
    }

    private static let cnDigit: [Character: Double] = [
        "一": 1, "两": 2, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "半": 0.5]

    /// 找 unit 前紧邻的数字（阿拉伯 1/1.5，或中文 一/两/三…半）。
    private static func number(before unit: String, in s: String) -> Double? {
        guard let r = s.range(of: unit) else { return nil }
        let head = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)   // "20 分钟"里数字与单位间的空格
        let trimmed = head.hasSuffix("个") ? String(head.dropLast()) : head   // "3个小时"里的"个"
        var num = ""
        for ch in trimmed.reversed() {
            if ch.isNumber || ch == "." || cnDigit[ch] != nil { num.insert(ch, at: num.startIndex) }
            else { break }
        }
        guard !num.isEmpty else { return nil }
        if let d = Double(num) { return d }                          // 阿拉伯：3 / 1.5
        if num.count == 1, let d = cnDigit[num.first!] { return d }  // 中文单字：一/两/半
        return nil
    }
}
