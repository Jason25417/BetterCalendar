//
//  CloudJSON.swift
//  BetterCalendar
//
//  从 LLM 文本里抠出 JSON + 宽松日期解析。
//

import Foundation

enum JSONText {
    /// 去掉可能的 ```json 围栏，并截取第一个 { 到最后一个 } 之间。
    static func extractObject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if let fence = t.range(of: "```", options: .backwards) { t = String(t[..<fence.lowerBound]) }
        }
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a <= b {
            t = String(t[a...b])
        }
        // 修 LLM 常犯的尾逗号（[1,2,] / {..,}）——JSONSerialization 严格、不容忍，常致「JSON 解码失败」
        t = t.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 云端流式（0.20.1）：从**尚未生成完**的部分 JSON 里，抠出 `arrayKey` 数组中已经**完整闭合**的
    /// 顶层对象（花括号配平 + 字符串/转义感知——标题里出现 { } " 不会骗过扫描）。纯函数、可单测。
    /// 供"边生成边冒块"：每收到一段 delta 重扫，把新完整块喂给 LiveDraft。
    static func completeArrayObjects(in partial: String, arrayKey: String = "\"blocks\"") -> [String] {
        guard let keyRange = partial.range(of: arrayKey),
              let bracket = partial[keyRange.upperBound...].firstIndex(of: "[") else { return [] }
        var objects: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var objStart: String.Index?
        var i = partial.index(after: bracket)
        while i < partial.endIndex {
            let c = partial[i]
            if escaped { escaped = false }
            else if c == "\\" && inString { escaped = true }
            else if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "{" {
                    if depth == 0 { objStart = i }
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0, let s = objStart {
                        objects.append(String(partial[s...i]))
                        objStart = nil
                    }
                } else if c == "]" && depth == 0 {
                    break   // 数组闭合，后面是别的字段
                }
            }
            i = partial.index(after: i)
        }
        return objects
    }
}

enum DateParsing {
    private static let formats = [
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",   // 纯日期（2026-07-20 跑分实锤：L1「GRE 改到 11 月 8 号考」→ 模型给 "2026-11-08"，
                        // 原来解析不出 → 整条修改被当空值丢弃 → App 里静默无反应）。解析到当日 00:00。
    ]

    /// 截止日专用：纯日期（"2026-11-08"）解析到**当天 23:59**——DDL 语义是「那天结束前」，
    /// 落 00:00 会让整个截止日当天都被判成「已过期」、提前一天触发温和三选（不制造无谓压力）。
    /// 带时分的照常按字面解析。
    static func parseDeadline(_ raw: String?) -> Date? {
        guard let d = parse(raw) else { return nil }
        guard let s = raw?.trimmingCharacters(in: .whitespaces), isDateOnly(s) else { return d }
        let cal = Calendar.current
        return cal.date(bySettingHour: 23, minute: 59, second: 0, of: d) ?? d
    }

    /// 只有年月日、没有时间部分（宽松判定：不含 ':' 且不含 'T'）。
    private static func isDateOnly(_ s: String) -> Bool {
        !s.contains(":") && !s.uppercased().contains("T")
    }

    static func parse(_ raw: String?) -> Date? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        for f in formats {
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}
