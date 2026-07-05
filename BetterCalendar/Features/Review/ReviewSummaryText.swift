//
//  ReviewSummaryText.swift
//  BetterCalendar
//
//  Positive, shareable day summary. It mirrors the review UI: lead with what
//  got done, keep gaps out of the default share text.
//

import Foundation

enum ReviewSummaryText {
    static func make(comparison: DayComparison,
                     activeDayCount: Int,
                     mvpTitle: String?,
                     mvpNote: String?) -> String {
        var lines: [String] = []
        // 去对比化：分享面也只庆祝"做成 N 件"，不单标计划外（那几件已数进 N、在下方清单里）
        lines.append("今天做成 \(comparison.accomplishedCount) 件")
        lines.append("有效投入 \(hm(comparison.effectiveMinutes))"
                    + (activeDayCount > 0 ? " · 已活跃使用 \(activeDayCount) 天" : ""))

        if let mvpTitle, !mvpTitle.isEmpty {
            lines.append("")
            lines.append("今日最有价值：\(mvpTitle)")
            let note = (mvpNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { lines.append(note) }
        }

        let accomplished = comparison.accomplished
        if !accomplished.isEmpty {
            lines.append("")
            lines.append("做成了什么：")
            for item in accomplished {
                let minutes = item.actualMinutes.map { " · \(hm($0))" } ?? ""
                lines.append("- \(item.displayTitle)\(minutes)")
            }
        }

        lines.append("")
        lines.append("来自 BetterCalendar")
        return lines.joined(separator: "\n")
    }

    static func hm(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时"
        }
        return "\(minutes) 分钟"
    }
}
