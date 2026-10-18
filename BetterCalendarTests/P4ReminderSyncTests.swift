//
//  P4ReminderSyncTests.swift
//  BetterCalendarTests
//
//  P4.0-9：提醒事项按章差量写入（ReminderSyncPlanner 纯函数）。
//  不碰真日历/提醒事项；时间全部从固定时刻派生，不用 Date.now。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

private let cal = Calendar.current
/// 固定基准：2026-10-20（周二）。
private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
}

// MARK: - P4.0-9：提醒按章差量（纯函数）

@MainActor
@Suite struct P4ReminderPlannerTests {
    private let now = at(20, 13)
    private func stamped(_ id: UUID, due: Date?, done: Bool = false, created: Date? = nil,
                         title: String = "交报告") -> ReminderSnapshot {
        ReminderSnapshot(url: EventKitCalendarStore.stampURL(id), isCompleted: done, title: title, notes: nil,
                         priority: 1, due: due, leadMinutes: 30, creationDate: created, externalID: nil)
    }
    private func draft(_ id: UUID?, due: Date?, title: String = "交报告") -> ReminderDraft {
        ReminderDraft(title: title, due: due, priority: 1, notes: nil, leadMinutes: 30, blockID: id)
    }

    /// B9：确认另一天，不删前一天的提醒；也不删你自己加进这个列表的提醒。
    @Test func confirmingAnotherDayKeepsOtherReminders() {
        let d = UUID(), e = UUID()
        let mine = ReminderSnapshot(url: nil, isCompleted: false, title: "买牛奶", notes: nil, priority: 0,
                                    due: at(19, 9), leadMinutes: nil)
        let p = ReminderSyncPlanner.plan(existing: [stamped(d, due: at(21, 17)), mine],
                                         drafts: [draft(e, due: at(22, 17))], scope: [e], now: now)
        #expect(p.deletes.isEmpty)
        #expect(p.creates.map(\.blockID) == [e])
    }

    /// 已有的就地更新（不删重建）；你已打勾完成的不再重建。
    @Test func matchedRemindersUpdateInPlaceAndCompletedStayDone() {
        let e = UUID(), done = UUID()
        let p = ReminderSyncPlanner.plan(existing: [stamped(e, due: at(21, 17)), stamped(done, due: at(21, 18), done: true)],
                                         drafts: [draft(e, due: at(21, 18)), draft(done, due: at(21, 18))],
                                         scope: [e, done], now: now)
        #expect(p.updates.map(\.index) == [0])
        #expect(p.creates.isEmpty && p.deletes.isEmpty)
    }

    /// 只删两种：这次确认负责的块里不再需要提醒的；已过截止仍未完成的带章旧提醒。其余一律保留。
    @Test func cleanupLimitedToScopeAndExpired() {
        let inScope = UUID(), expired = UUID(), future = UUID()
        let mineExpired = ReminderSnapshot(url: nil, isCompleted: false, title: "你的旧提醒", notes: nil, priority: 0,
                                           due: at(18, 9), leadMinutes: nil)
        let p = ReminderSyncPlanner.plan(existing: [stamped(inScope, due: at(22, 9)), stamped(expired, due: at(19, 9)),
                                                    stamped(future, due: at(25, 9)), mineExpired],
                                         drafts: [], scope: [inScope], now: now)
        #expect(Set(p.deletes) == [0, 1])
    }

    /// 待办池截止提醒有了稳定的章：同一件不重复写（此前无章，每确认一次多一条）。
    @Test func poolRemindersHaveStableStamp() {
        let first = draft(nil, due: at(30, 23), title: "交论文")
        let again = draft(nil, due: at(30, 23), title: " 交论文 ")
        #expect(ReminderStamp.url(for: first) == ReminderStamp.url(for: again))
        #expect(ReminderStamp.url(for: first) != ReminderStamp.url(for: draft(nil, due: nil, title: "交作业")))
        let fresh = ReminderSyncPlanner.plan(existing: [], drafts: [first, again], scope: [], now: now)
        #expect(fresh.creates.count == 1)
        let existing = ReminderSnapshot(url: ReminderStamp.url(for: first), isCompleted: false, title: "交论文",
                                        notes: nil, priority: 1, due: at(30, 23), leadMinutes: 30)
        let second = ReminderSyncPlanner.plan(existing: [existing], drafts: [first], scope: [], now: now)
        #expect(second.creates.isEmpty && second.updates.isEmpty && second.deletes.isEmpty)
    }

    /// 同章重复的未完成提醒收敛成一条（确定性：留创建最早的）。
    @Test func duplicateRemindersConverge() {
        let e = UUID()
        let p = ReminderSyncPlanner.plan(existing: [stamped(e, due: at(21, 17), created: at(19, 9)),
                                                    stamped(e, due: at(21, 17), created: at(19, 8))],
                                         drafts: [draft(e, due: at(21, 17))], scope: [e], now: now)
        #expect(p.deletes == [0])
        #expect(p.updates.isEmpty && p.creates.isEmpty)
    }
}
