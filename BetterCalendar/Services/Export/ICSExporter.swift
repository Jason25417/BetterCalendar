//
//  ICSExporter.swift
//  BetterCalendar
//
//  生成标准 ICS：UTC 时间、CRLF 换行、转义特殊字符。可被系统日历/其它 App 导入。
//

import Foundation

struct ICSExporter: ICSExporting {
    func ics(for drafts: [CalendarEventDraft]) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Jason//BetterCalendar//CN",
            "CALSCALE:GREGORIAN",
        ]
        let stamp = Self.utc(Date())
        for d in drafts {
            lines += [
                "BEGIN:VEVENT",
                "UID:\(UUID().uuidString)@bettercalendar",
                "DTSTAMP:\(stamp)",
                "DTSTART:\(Self.utc(d.start))",
                "DTEND:\(Self.utc(d.end))",
                "SUMMARY:\(Self.escape(d.title))",
                "END:VEVENT",
            ]
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func utc(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
