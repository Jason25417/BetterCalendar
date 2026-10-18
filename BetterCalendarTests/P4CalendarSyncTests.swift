//
//  P4CalendarSyncTests.swift
//  BetterCalendarTests
//
//  P4.0 止血（P4-日历双向同步-调查与设计.md §5）：日历写入决定 / 对账判定 / 指纹淘汰 / 端到端（假日历 SimulatedEventKitCalendar × 内存库）。
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

// MARK: - P4.0-1 / P4.0-2：写入决定（纯函数）

@MainActor
@Suite struct P4CalendarPlannerTests {
    private let lo = at(20, 4), hi = at(21, 4)

    private func snap(_ title: String, _ start: Date, _ end: Date, bid: UUID? = nil,
                      created: Date? = nil, ext: String? = nil) -> CalendarEventSnapshot {
        CalendarEventSnapshot(title: title, start: start, end: end, blockID: bid, creationDate: created, externalID: ext)
    }

    private func draft(_ title: String, _ start: Date, _ end: Date, bid: UUID?,
                       claims: Bool = false) -> CalendarEventDraft {
        CalendarEventDraft(title: title, start: start, end: end, kind: .planned, blockID: bid, claimsUnstamped: claims)
    }

    /// B1：自家日历里不带章的事件（用户的重复课程某一次）——清空、对齐、同名同时刻的新块都不能删它、改它。
    @Test func unstampedEventsAreNeverDeletedOrTouched() {
        let stale = UUID()
        let existing = [snap("STAT 4194", at(20, 8), at(20, 9, 15)),
                        snap("旧块", at(20, 9), at(20, 10), bid: stale)]
        let clearAll = CalendarSyncPlanner.plan(existing: existing, drafts: [], from: lo, to: hi)
        #expect(clearAll.deletes == [1], "只删带章的旧块")
        #expect(clearAll.keptForeign == [0])
        #expect(clearAll.updates.isEmpty)

        // 计划里恰好有同名同时刻的块（D2 旧行为会把用户的课「认领」成我们的、日后再删）
        let same = draft("STAT 4194", at(20, 8), at(20, 9, 15), bid: UUID())
        let p = CalendarSyncPlanner.plan(existing: existing, drafts: [same], from: lo, to: hi)
        #expect(p.updates.isEmpty, "绝不认领/修改用户的事件")
        #expect(p.creates.count == 1)
        #expect(p.deletes == [1])
    }

    /// D2：只有用户明确「加进计划」的那件（claimsUnstamped）才认领并补章。
    @Test func claimsOnlyWhenUserAdopted() {
        let existing = [snap("牙医", at(20, 15), at(20, 16))]
        let id = UUID()
        let p = CalendarSyncPlanner.plan(existing: existing,
                                         drafts: [draft("牙医", at(20, 15), at(20, 16), bid: id, claims: true)],
                                         from: lo, to: hi)
        #expect(p.creates.isEmpty)
        #expect(p.updates.count == 1)
        #expect(p.updates.first?.index == 0 && p.updates.first?.stamp == true)
    }

    /// BetterCalendar 只写带章事件：读回合并写回的无章副本对得上就原样不动，对不上也不新建。
    @Test func unstampedDraftsAreNeverWritten() {
        let existing = [snap("你的事件", at(20, 11), at(20, 12))]
        let echo = draft("你的事件", at(20, 11), at(20, 12), bid: nil)
        let orphan = draft("已被你删掉的事件", at(20, 13), at(20, 14), bid: nil)
        let p = CalendarSyncPlanner.plan(existing: existing, drafts: [echo, orphan], from: lo, to: hi)
        #expect(p.updates.isEmpty && p.creates.isEmpty && p.deletes.isEmpty)
        #expect(p.droppedUnstampedDrafts.map(\.title) == ["已被你删掉的事件"])
    }

    /// B8：同章两份，两台设备遍历顺序不同，也必须删同一份（保留创建最早的）——不会各删一份、两份都没了。
    @Test func duplicateStampKeeperIsDeterministicAcrossDevices() {
        let id = UUID()
        let older = snap("写作", at(20, 9), at(20, 10), bid: id, created: at(19, 8), ext: "zzz")
        let newer = snap("写作", at(20, 9), at(20, 10), bid: id, created: at(19, 9), ext: "aaa")
        let want = draft("写作", at(20, 10), at(20, 11), bid: id)
        let macOrder = [older, newer], phoneOrder = [newer, older]
        let mac = CalendarSyncPlanner.plan(existing: macOrder, drafts: [want], from: lo, to: hi)
        let phone = CalendarSyncPlanner.plan(existing: phoneOrder, drafts: [want], from: lo, to: hi)
        #expect(mac.updates.map { macOrder[$0.index].externalID } == ["zzz"])
        #expect(phone.updates.map { phoneOrder[$0.index].externalID } == ["zzz"])
        #expect(mac.deletes.map { macOrder[$0].externalID } == ["aaa"])
        #expect(phone.deletes.map { phoneOrder[$0].externalID } == ["aaa"])

        // 创建时间相同 → 按外部标识字典序（两端一致）
        let a = snap("写作", at(20, 9), at(20, 10), bid: id, created: at(19, 8), ext: "b-2")
        let b = snap("写作", at(20, 9), at(20, 10), bid: id, created: at(19, 8), ext: "b-1")
        let tie1 = CalendarSyncPlanner.plan(existing: [a, b], drafts: [want], from: lo, to: hi)
        let tie2 = CalendarSyncPlanner.plan(existing: [b, a], drafts: [want], from: lo, to: hi)
        #expect(tie1.deletes.map { [a, b][$0].externalID } == ["b-2"])
        #expect(tie2.deletes.map { [b, a][$0].externalID } == ["b-2"])
    }

    /// 原样保留（投影把另一台设备的同章多份带过来）：多草稿按内容精确配对，谁也不改、谁也不删。
    @Test func passThroughOfDuplicatesKeepsEveryCopy() {
        let id = UUID()
        let x = snap("写作", at(20, 9), at(20, 10), bid: id, created: at(19, 8), ext: "x")
        let y = snap("写作", at(20, 14), at(20, 15), bid: id, created: at(19, 9), ext: "y")
        let p = CalendarSyncPlanner.plan(existing: [x, y],
                                         drafts: [draft("写作", at(20, 14), at(20, 15), bid: id),
                                                  draft("写作", at(20, 9), at(20, 10), bid: id)],
                                         from: lo, to: hi)
        #expect(p.updates.isEmpty && p.deletes.isEmpty && p.creates.isEmpty)
    }

    /// 跨界事件（起点在范围外、只是和范围相交）不归本范围，不删。
    @Test func eventStartingBeforeRangeIsNotDeleted() {
        let p = CalendarSyncPlanner.plan(existing: [snap("跨夜", at(20, 2), at(20, 5), bid: UUID())],
                                         drafts: [], from: lo, to: hi)
        #expect(p.deletes.isEmpty)
    }
}

// MARK: - P4.0-2 / P4.0-6：对账判定（纯函数）

@MainActor
@Suite struct P4ReconcileDiffTests {
    private func ev(_ b: ScheduledBlock, _ s: Date, _ e: Date, created: Date? = nil, ext: String? = nil) -> CalendarEventDraft {
        CalendarEventDraft(title: b.title, start: s, end: e, kind: .planned, blockID: b.id,
                           creationDate: created, externalID: ext)
    }
    private func tup(_ b: ScheduledBlock) -> String {
        ProjectionFingerprints.tuple(start: b.start, end: b.end, title: b.title)
    }

    /// B8：同章两份不再「最后一个赢」——有一份与真相一致就是一致（不把旧副本当手改），与顺序无关。
    @Test func duplicateCopiesNeverMisreadAsUserEdit() {
        let b = ScheduledBlock(title: "复习", start: at(21, 9), end: at(21, 10))
        let fp = [b.id.uuidString: tup(b)]
        let current = ev(b, b.start, b.end), stale = ev(b, at(21, 11), at(21, 12))
        for events in [[current, stale], [stale, current]] {
            let plan = ReconcileService.diff(truth: [b], events: events, fingerprint: fp)
            #expect(plan.updates.isEmpty && plan.conflicts.isEmpty)
            #expect(plan.needsRepaint, "投影按确定性规则收敛成一份")
        }
        // 两份内容各不相同、都不等于真相：判不清就挂起，不猜
        let x = ev(b, at(21, 11), at(21, 12)), y = ev(b, at(21, 13), at(21, 14))
        for events in [[x, y], [y, x]] {
            let plan = ReconcileService.diff(truth: [b], events: events, fingerprint: fp)
            #expect(plan.updates.isEmpty)
            #expect(plan.conflicts == [b.id])
        }
    }

    /// B4：块被拖到另一天——按章在扫描范围里找到，就是改时间（回流），不是删除。
    @Test func crossDayDragIsAnUpdateNotADeletion() {
        let b = ScheduledBlock(title: "整理笔记", start: at(21, 9), end: at(21, 10))
        let moved = ev(b, at(22, 9), at(22, 10))
        let plan = ReconcileService.diff(truth: [b], events: [], fingerprint: [b.id.uuidString: tup(b)],
                                         elsewhere: [moved])
        #expect(plan.deletions.isEmpty)
        #expect(plan.updates == [ReconcileService.Update(id: b.id, start: at(22, 9), end: at(22, 10), title: "整理笔记")])
    }

    /// 拖进本日的块归原来那天处理：本日不为它重画（否则投影可能把它当垃圾）；我们自己画在这里的旧画面才重画清掉。
    @Test func destinationDayLeavesMovedInBlockToItsOwner() {
        let b = ScheduledBlock(title: "整理笔记", start: at(21, 9), end: at(21, 10))
        let here = ev(b, at(22, 9), at(22, 10))
        let userMoved = ReconcileService.diff(truth: [], events: [here], fingerprint: [:], ownedElsewhere: [b.id])
        #expect(!userMoved.needsRepaint)
        let ourStale = ReconcileService.diff(truth: [], events: [here],
                                             fingerprint: [b.id.uuidString: ReconcileService.tuple(here)],
                                             ownedElsewhere: [b.id])
        #expect(ourStale.needsRepaint)
    }
}

// MARK: - P4.0-3：指纹按日期淘汰

@MainActor
@Suite struct P4FingerprintRetentionTests {
    private let now = at(20, 13)
    private func key(_ offset: Int) -> String {
        DayContext.dayKey(now.addingTimeInterval(Double(offset) * 86400))
    }

    /// B6：超过 40 天后不再随机丢——今天/明天永远在，30 天以外的才淘汰。
    @Test func pruneKeepsRecentDaysAndDropsOldOnes() {
        var all: [String: [String: String]] = [:]
        for d in -60...10 { all[key(d)] = ["x": "\(d)"] }
        let kept = ProjectionFingerprints.pruned(all, around: now)
        #expect(kept[key(0)] != nil && kept[key(1)] != nil && kept[key(7)] != nil)
        #expect(kept[key(-30)] != nil)
        #expect(kept[key(-31)] == nil && kept[key(-60)] == nil)
        #expect(kept.count == 41)   // -30…10
    }

    @Test func setPrunesInjectedStoreAndKeepsWrittenDay() throws {
        let defaults = try #require(UserDefaults(suiteName: "bc-p4-fp-\(UUID().uuidString)"))
        let old = Dictionary(uniqueKeysWithValues: (40...90).map { (key(-$0), ["x": "old"]) })
        defaults.set(old, forKey: "projection.fingerprints")
        let label = DayContext.logicalDay(offset: 1, from: now)
        ProjectionFingerprints.set(label, ["b": "t"], defaults: defaults, now: now)
        #expect(ProjectionFingerprints.get(label, defaults: defaults) == ["b": "t"])
        let stored = defaults.dictionary(forKey: "projection.fingerprints") ?? [:]
        #expect(stored.count == 1, "旧键全部按日期淘汰")
    }
}

// MARK: - 端到端（假日历 × 内存库 × 投影 × 对账）

@MainActor
@Suite struct P4CalendarIntegrationTests {
    private let now = at(20, 13)

    private struct Fixture {
        let plan: PlanStore
        let calendar: SimulatedEventKitCalendar
        let projection: ProjectionService
        let reconcile: ReconcileService
        let defaults: UserDefaults
        let container: ModelContainer   // 保活
        func label(_ offset: Int) -> Date { DayContext.logicalDay(offset: offset, from: calendar.now) }
    }

    private func make() throws -> Fixture {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let fixed = now
        let plan = PlanStore(context: container.mainContext, writerID: "mac", now: { fixed })
        let defaults = try #require(UserDefaults(suiteName: "bc-p4-int-\(UUID().uuidString)"))
        let calendar = SimulatedEventKitCalendar(now: now)
        let projection = ProjectionService(planStore: plan, calendarStore: calendar,
                                           fingerprintDefaults: defaults, now: { fixed })
        let reconcile = ReconcileService(planReader: plan, planWriter: plan, calendarStore: calendar,
                                         projection: projection, defaults: defaults,
                                         now: { fixed }, calendarAuthorized: { true })
        return Fixture(plan: plan, calendar: calendar, projection: projection, reconcile: reconcile,
                       defaults: defaults, container: container)
    }

    /// B1（真机事故的回归）：用户的课程系列误存进 BetterCalendar 的绿/橙/蓝日历——
    /// 投影对齐、清空、蓝色合并写入，哪条路径都不能删它、改它、复制它。
    @Test func userEventsInOwnCalendarsSurviveEveryWritePath() async throws {
        let f = try make()
        for d in 20...22 {
            f.calendar.seed(.planned, "STAT 4194", at(d, 8), at(d, 9, 15))
            f.calendar.seed(.preview, "STAT 4194", at(d, 8), at(d, 9, 15))
        }
        f.calendar.seed(.actual, "Career Fair", at(20, 10), at(20, 12))
        let today = f.label(0)
        let a = ScheduledBlock(title: "写作", start: at(20, 10), end: at(20, 11))
        let clash = ScheduledBlock(title: "STAT 4194", start: at(20, 8), end: at(20, 9, 15))   // 同名同时刻
        try f.plan.replacePlanned([a, clash], on: today)
        try await f.projection.project(label: today)
        try f.plan.replacePlanned([], on: today)
        try await f.projection.project(label: today)            // 清空当天计划
        try await f.calendar.clear(kind: .preview)              // 旧执行页清橙
        try await f.calendar.clear(kind: .planned)
        _ = await f.projection.retirePreviewCalendar()          // P4 Q1 退役清扫
        for _ in 0..<2 {                                        // 蓝色：读回 ∪ 新增 再写（执行页 flushActuals 同款）
            let existing = try await f.calendar.read(kind: .actual)
            let done = CalendarEventDraft(title: "写作", start: at(20, 10), end: at(20, 10, 50), kind: .actual, blockID: a.id)
            try await f.calendar.write(CalendarMerge.union(existing: existing, additions: [done], kind: .actual))
        }
        let userGreen = f.calendar.events(.planned).filter { $0.blockID == nil }
        let userOrange = f.calendar.events(.preview).filter { $0.blockID == nil }
        #expect(userGreen.count == 3 && userGreen.allSatisfy { $0.title == "STAT 4194" && cal.component(.hour, from: $0.start) == 8 })
        #expect(userOrange.count == 3)
        #expect(f.calendar.events(.actual).filter { $0.blockID == nil }.map(\.title) == ["Career Fair"], "不删、不复制")
        #expect(f.calendar.events(.actual).filter { $0.blockID == a.id }.count == 1)
        #expect(f.calendar.events(.planned).filter { $0.blockID != nil }.isEmpty)
    }

    /// B4：在日历里把一块拖到后一天 / 前一天——采纳为改时间：不删、不留幽灵、只剩一份；挪过的块成图钉（Q6）。
    @Test func dragToAnotherDayIsAdoptedAsMoveAndPinned() async throws {
        let f = try make()
        let fwd = ScheduledBlock(title: "整理笔记", start: at(21, 9), end: at(21, 10))
        let back = ScheduledBlock(title: "跑步", start: at(23, 18), end: at(23, 19))
        try f.plan.replacePlanned([fwd], on: f.label(1))
        try f.plan.replacePlanned([back], on: f.label(3))
        try await f.projection.project(label: f.label(1))
        try await f.projection.project(label: f.label(3))
        let fwdEvent = try #require(f.calendar.events(.planned).first { $0.blockID == fwd.id })
        let backEvent = try #require(f.calendar.events(.planned).first { $0.blockID == back.id })
        f.calendar.edit(fwdEvent.externalID, start: at(22, 9), end: at(22, 10))    // 拖到后一天
        f.calendar.edit(backEvent.externalID, start: at(22, 18), end: at(22, 19))  // 拖到前一天

        await f.reconcile.reconcileWindow()

        let day2 = try f.plan.plannedBlocks(on: f.label(2))
        #expect(Set(day2.map(\.id)) == [fwd.id, back.id], "两块都落到新的一天")
        #expect(day2.first { $0.id == fwd.id }?.start == at(22, 9))
        #expect(day2.first { $0.id == back.id }?.start == at(22, 18))
        #expect(day2.allSatisfy { $0.isPinned(at: now) }, "你亲手挪过 = 图钉")
        #expect(day2.first?.pinnedUntil == DayContext.logicalWindow(forLabel: f.label(2)).end, "当天有效")
        #expect(try f.plan.plannedBlocks(on: f.label(1)).isEmpty && f.plan.plannedBlocks(on: f.label(3)).isEmpty)
        #expect(f.calendar.events(.planned).filter { $0.blockID == fwd.id }.count == 1, "同一个章只有一份")
        #expect(f.calendar.events(.planned).filter { $0.blockID == back.id }.count == 1)
    }

    /// B5：第 7 天晚上的块（晚于「此刻＋7 天」）不再被误报成删除。
    @Test func lateSeventhDayBlockIsNotMisreadAsDeleted() async throws {
        let f = try make()
        let late = ScheduledBlock(title: "夜读", start: at(27, 23, 30), end: at(27, 23, 55))
        try f.plan.replacePlanned([late], on: f.label(7))
        try await f.projection.project(label: f.label(7))
        await f.reconcile.reconcileWindow()
        #expect(try f.plan.plannedBlocks(on: f.label(7)).map(\.id) == [late.id])
    }

    /// B7：一块判不清（旧章、指纹与两边都对不上），只挂起那一块——同一天别的手改照常回流；挂起的块画面原样保留。
    @Test func oneConflictHoldsOnlyThatBlock() async throws {
        let f = try make()
        let day = f.label(1)
        let a = ScheduledBlock(title: "A", start: at(21, 9), end: at(21, 10))
        let b = ScheduledBlock(title: "B", start: at(21, 14), end: at(21, 15))
        try f.plan.replacePlanned([a, b], on: day)
        try await f.projection.project(label: day)
        // A：一个旧章事件（无 v2），本机指纹又是第三个版本 → 判不清
        let ea = try #require(f.calendar.events(.planned).first { $0.blockID == a.id })
        f.calendar.delete(ea.externalID)
        f.calendar.seed(.planned, "A", at(21, 11), at(21, 12), blockID: a.id)
        var prints = ProjectionFingerprints.get(day, defaults: f.defaults)
        prints[a.id.uuidString] = ProjectionFingerprints.tuple(start: at(21, 9, 30), end: at(21, 10, 30), title: "A")
        ProjectionFingerprints.set(day, prints, defaults: f.defaults, now: now)
        let eb = try #require(f.calendar.events(.planned).first { $0.blockID == b.id })
        f.calendar.edit(eb.externalID, start: at(21, 16), end: at(21, 17))   // 日历里改了 B → 正常手改

        for _ in 0..<2 {
            await f.reconcile.reconcileWindow()
            let truth = try f.plan.plannedBlocks(on: day)
            #expect(truth.first { $0.id == b.id }?.start == at(21, 16), "B 照常回流")
            #expect(truth.first { $0.id == a.id }?.start == at(21, 9), "A 的真相不被猜着改")
            #expect(f.calendar.events(.planned).first { $0.blockID == a.id }?.start == at(21, 11), "A 的画面原样保留")
        }
    }

    /// Q4：日历里新建（无章）的事件 = 你的：不复制成计划块、不删、不弹窗；App 里提示一句（可收起）。
    @Test func userEventInGreenCalendarIsNeitherCopiedNorDeleted() async throws {
        let f = try make()
        f.calendar.seed(.planned, "牙医", at(21, 15), at(21, 16))
        await f.reconcile.reconcileWindow()
        await f.reconcile.reconcileWindow()
        #expect(try f.plan.plannedBlocks(on: f.label(1)).isEmpty, "不复制")
        #expect(f.calendar.events(.planned).filter { $0.title == "牙医" && $0.blockID == nil }.count == 1, "不删")
        #expect(f.reconcile.calendarNotice?.contains("不是 BetterCalendar 写的") == true)
        f.reconcile.dismissCalendarNotice()
        await f.reconcile.reconcileWindow()
        #expect(f.reconcile.calendarNotice == nil, "收起后同样的情况不再提示")
    }
}
