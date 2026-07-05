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
    /// 清空某一类（如橙色预览日终消失）。
    func clear(kind: PlanCalendarKind) async throws
    /// 清空**某一天**某一类（删光当天所有块并确认写入时用：write 空数组会早退、不会清，得靠它）。
    func clear(kind: PlanCalendarKind, on day: Date) async throws

    /// 某日历日**系统里已有**的安排（排除本 App 自建日历），给排程当"已占用"上下文。
    /// 默认空（假日历/开发期不看系统）。
    func existingEvents(on day: Date) async -> [BusySlot]
}

extension CalendarStore {
    func existingEvents(on day: Date) async -> [BusySlot] { [] }
}
