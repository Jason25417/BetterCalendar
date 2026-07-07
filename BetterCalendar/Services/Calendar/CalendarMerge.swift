//
//  CalendarMerge.swift
//  BetterCalendar
//
//  「合并不覆盖」助手：把要写的实际块与日历里已有的做 union，
//  写入时不会把别处产生的事件删掉（menu bar × 复盘回填 × 另一台设备 三方并发都安全）。
//  同「标题 + 起始分钟」视为同一事件（与 EventKitCalendarStore 的差量 upsert 键一致）；
//  additions 覆盖同键（时长/备注可能更新过）。
//

import Foundation

enum CalendarMerge {
    static func eventKey(_ title: String, _ start: Date) -> String {
        "\(title)#\(Int(start.timeIntervalSinceReferenceDate / 60))"
    }

    /// existing（日历读回）∪ additions（本次要写）→ 去重后的完整写入集。
    /// kind 统一为目标日历（读回的 kind 已是目标，additions 若 kind 不同也强制归一）。
    /// blockID 章不丢：addition 覆盖同键时，addition 无章则保留 existing 的章。
    static func union(existing: [CalendarEventDraft], additions: [CalendarEventDraft],
                      kind: PlanCalendarKind) -> [CalendarEventDraft] {
        var byKey: [String: CalendarEventDraft] = [:]
        for e in existing {
            byKey[eventKey(e.title, e.start)] = CalendarEventDraft(
                title: e.title, start: e.start, end: e.end, kind: kind, notes: e.notes, blockID: e.blockID)
        }
        for a in additions {
            let k = eventKey(a.title, a.start)
            byKey[k] = CalendarEventDraft(
                title: a.title, start: a.start, end: a.end, kind: kind, notes: a.notes,
                blockID: a.blockID ?? byKey[k]?.blockID)
        }
        return byKey.values.sorted { $0.start < $1.start }
    }
}
