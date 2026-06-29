//
//  ICSExporting.swift
//  BetterCalendar
//
//  计划块 → 标准 ICS(VEVENT) 文本，用于可移植导出/分享。
//

import Foundation

protocol ICSExporting {
    func ics(for drafts: [CalendarEventDraft]) -> String
}
