//
//  FakeCalendarStore.swift
//  BetterCalendarTests
//
//  测试替身假日历（2026-07-22 迁入测试 target——假日历族生产删除，Fake 仅供单测注入）：
//  把「本要写进系统日历」的草稿存内存供断言。
//

import Foundation
import Observation
@testable import BetterCalendar

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


    /// 权威对齐（投影用）：窗口内该 kind 替换为 drafts（空=清空窗口）。归属按 start ∈ [lo, hi)。
    func apply(_ drafts: [CalendarEventDraft], kind: PlanCalendarKind, window: DateInterval) async throws {
        captured.removeAll { $0.kind == kind && $0.start >= window.start && $0.start < window.end }
        captured.append(contentsOf: drafts)
    }

    func clear() {
        captured.removeAll()
    }
}
