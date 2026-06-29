//
//  CalendarStore.swift
//  BetterCalendar
//
//  写/读「带色日历」。开发期实现 = FakeCalendarStore（写进 App 内 + 画预览，不碰系统）。
//  逻辑稳了再换 EventKitCalendarStore（写真实绿/蓝日历，需 full access）。
//

import Foundation

protocol CalendarStore: AnyObject {
    func write(_ drafts: [CalendarEventDraft]) async throws
    func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft]
}
