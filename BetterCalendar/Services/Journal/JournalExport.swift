//
//  JournalExport.swift
//  BetterCalendar
//
//  日记导出（M9/R5）：全部条目 → 一份 markdown 文本（日期/心情/标签/正文），按时间正序。
//  纯函数、可单测；照片只标数量（文件在 App 容器/云端，文本导出不内嵌二进制）。
//

import Foundation

enum JournalExport {
    static func markdown(_ entries: [JournalEntry]) -> String {
        var out = ["# BetterCalendar 日记", ""]
        for e in entries.sorted(by: { $0.date < $1.date }) {
            var header = "## " + e.date.formatted(date: .long, time: .omitted)
            if let mood = e.mood, !mood.isEmpty { header += " \(mood)" }
            out.append(header)
            if !e.tags.isEmpty {
                out.append(e.tags.map { "#\($0)" }.joined(separator: " "))
            }
            if !e.body.isEmpty {
                out.append("")
                out.append(e.body)
            }
            if !e.photoRefs.isEmpty {
                out.append("")
                out.append("（含 \(e.photoRefs.count) 张照片）")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
