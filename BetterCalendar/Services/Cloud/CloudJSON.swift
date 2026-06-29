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
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DateParsing {
    private static let formats = [
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm",
    ]

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
