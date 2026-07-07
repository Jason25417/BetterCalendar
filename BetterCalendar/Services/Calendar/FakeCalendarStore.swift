//
//  FakeCalendarStore.swift
//  BetterCalendar
//
//  开发期假日历：把「本要写进系统日历」的草稿存内存、供 GUI 预览（CalendarPreviewView）。
//  好处：测试不污染真日历；这个预览正好就是 SPEC 要的「可视化预览」UI，可复用。
//

import Foundation
import Observation

@Observable
final class FakeCalendarStore: CalendarStore {
    private(set) var captured: [CalendarEventDraft] = []

    func write(_ drafts: [CalendarEventDraft]) async throws {
        let kinds = Set(drafts.map(\.kind))
        captured.removeAll { kinds.contains($0.kind) }   // 同类型替换（确认即覆盖当天计划）
        captured.append(contentsOf: drafts)
    }

    func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft] {
        captured.filter { $0.kind == kind }
    }

    func clear(kind: PlanCalendarKind) async throws {
        captured.removeAll { $0.kind == kind }
    }

    func clear(kind: PlanCalendarKind, on day: Date) async throws {
        captured.removeAll { $0.kind == kind && Calendar.current.isDate($0.start, inSameDayAs: day) }
    }

    /// 权威对齐（投影用）：窗口内该 kind 替换为 drafts（空=清空窗口）。归属按 start ∈ [lo, hi)。
    func apply(_ drafts: [CalendarEventDraft], kind: PlanCalendarKind, window: DateInterval) async throws {
        captured.removeAll { $0.kind == kind && $0.start >= window.start && $0.start < window.end }
        captured.append(contentsOf: drafts)
    }

    func clear() {
        captured.removeAll()
    }
}
