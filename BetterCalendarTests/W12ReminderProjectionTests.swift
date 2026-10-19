//
//  W12ReminderProjectionTests.swift
//  BetterCalendarTests
//
//  W12（SPEC §19.13 Q5，Jason 2026-10-18）：提醒事项 = BetterCalendar 的原生展示面（无独立提醒数据库）。
//  全部走内存假列表（不碰真提醒事项 / 日历）；时间从固定时刻派生，不用 Date.now。
//  「两台设备」= 两个 ReminderProjector 共用同一份假列表（模拟 iCloud 同步好的提醒）与同一份账本（模拟 iCloud 设置同步）。
//

import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

private let cal = Calendar.current
/// 固定基准：2026-10-20（周二）。
private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
}
private let fixedNow = at(20, 13)

/// 内存假提醒列表（BetterCalendar 那本 + 你自己的列表）。apply 的语义贴 EventKit 薄层：按 itemID 定位、keepTime 不碰时间。
actor FakeReminderList: ReminderListAccess {
    nonisolated var listName: String { "BetterCalendar · 测试" }
    var items: [ReminderSnapshot] = []
    var reach = ReminderListReach(sourceName: "iCloud", syncsAcrossDevices: true)
    var exists = true
    var readError: ReminderAccessError?
    var own: [OwnReminder] = []
    var ownReadError: ReminderAccessError?
    private(set) var applied: [ReminderListChanges] = []
    private var seq = 0

    func readList() throws -> ReminderListRead {
        if let readError { throw readError }
        return exists ? .list(items: items, reach: reach) : .missing(reach: reach)
    }

    func apply(_ c: ReminderListChanges) throws {
        applied.append(c)
        if !c.creates.isEmpty { exists = true }
        for u in c.updates {
            guard let i = items.firstIndex(where: { $0.itemID == u.itemID }) else { throw ReminderAccessError.writeFailed("找不到") }
            items[i].title = u.draft.title; items[i].notes = u.draft.notes; items[i].priority = u.draft.priority
            items[i].url = ReminderStamp.url(for: u.draft)
            if !u.keepTime { items[i].due = u.draft.due; items[i].leadMinutes = u.draft.due == nil ? nil : u.draft.leadMinutes }
        }
        for d in c.creates {
            seq += 1
            items.append(ReminderSnapshot(url: ReminderStamp.url(for: d), isCompleted: false, title: d.title, notes: d.notes,
                                          priority: d.priority, due: d.due, leadMinutes: d.due == nil ? nil : d.leadMinutes,
                                          creationDate: fixedNow.addingTimeInterval(Double(seq)), externalID: "x\(seq)", itemID: "item-\(seq)"))
        }
        for id in c.completes {
            if let i = items.firstIndex(where: { $0.itemID == id }) { items[i].isCompleted = true; items[i].completionDate = fixedNow }
        }
        items.removeAll { c.deletes.contains($0.itemID ?? "") }
    }

    func readOwnOpenReminders(requestAccess: Bool) throws -> [OwnReminder] {
        if let ownReadError { throw ownReadError }
        return own
    }

    // —— 测试里扮演「Jason 在提醒事项里动手」——
    func setOwnReadError(_ e: ReminderAccessError?) { ownReadError = e }
    func setItems(_ v: [ReminderSnapshot]) { items = v }
    func setReadError(_ e: ReminderAccessError?) { readError = e }
    func setExists(_ v: Bool) { exists = v }
    func setReach(_ r: ReminderListReach) { reach = r }
    func setOwn(_ v: [OwnReminder]) { own = v }
    func userRetime(_ key: String, to due: Date) {
        if let i = items.firstIndex(where: { ReminderStamp.key($0.url) == key }) { items[i].due = due }
    }
    func userRename(_ key: String, to title: String) {
        if let i = items.firstIndex(where: { ReminderStamp.key($0.url) == key }) { items[i].title = title }
    }
    func userDelete(_ key: String) { items.removeAll { ReminderStamp.key($0.url) == key } }
    func userComplete(_ key: String, at date: Date) {
        if let i = items.firstIndex(where: { ReminderStamp.key($0.url) == key }) { items[i].isCompleted = true; items[i].completionDate = date }
    }
    func item(_ key: String) -> ReminderSnapshot? { items.first { ReminderStamp.key($0.url) == key } }
    func touchedItemIDs() -> Set<String> {
        Set(applied.flatMap { $0.updates.map(\.itemID) + $0.deletes + $0.completes })
    }
}

/// 收集日志与你的操作（Sendable）。
actor Collector {
    var logs: [String] = []
    var ops: [ReminderUserOp] = []
    func log(_ level: String, _ m: String) { logs.append("[\(level)] " + m) }
    func add(_ o: [ReminderUserOp]) { ops += o }
}

@MainActor @Suite struct W12ReminderProjectionTests {
    let ledgerStore = ReminderProjectionLedgerStore(defaults: UserDefaults(suiteName: "bc-test-w12-" + UUID().uuidString)!)

    func projector(_ list: FakeReminderList, device: String = "mac", collector: Collector = Collector()) -> ReminderProjector {
        ReminderProjector(access: list, ledgerStore: ledgerStore, deviceId: device, clock: { fixedNow },
                          opsSink: { ops in await collector.add(ops) },
                          log: { level, m in await collector.log(level, m) })
    }

    func blockDraft(_ id: UUID, due: Date, title: String = "交报告") -> ReminderDraft {
        ReminderDraft(title: title, due: due, priority: 1, notes: nil, leadMinutes: 30, blockID: id)
    }
    func key(_ d: ReminderDraft) -> String { ReminderStamp.key(ReminderStamp.url(for: d))! }

    // MARK: 投影范围 = 最小集

    /// 只投截止时间：带 DDL 的计划块 + 带 DDL 的待办池条目。计划块本身（没截止）、固定块、没截止的待办都不投。
    @Test func projectionSetIsDeadlinesOnly() {
        let withDDL = EditableBlock(title: "写周报", start: at(21, 9), end: at(21, 10), deadline: at(21, 17))
        let plain = EditableBlock(title: "跑步", start: at(21, 10), end: at(21, 11))
        let meeting = EditableBlock(title: "组会", start: at(21, 14), end: at(21, 15), isFixed: true)
        let pending = [ParsedLongTask(title: "交论文", deadline: at(30, 23), totalMinutes: 120),
                       ParsedLongTask(title: "学日语", deadline: nil, cadenceMinutesPerWeek: 300)]
        let (drafts, pastDue) = HomeViewModel.reminderProjection(blocks: [withDDL, plain, meeting], pending: pending,
                                                                 leadMinutes: 10, now: fixedNow)
        #expect(Set(drafts.map(\.title)) == ["写周报", "交论文"] && drafts.count == 2)
        #expect(drafts.first { $0.title == "写周报" }?.blockID == withDDL.id)
        #expect(drafts.first { $0.title == "交论文" }?.blockID == nil)   // 待办池截止：标题章
        #expect(pastDue.isEmpty)
    }

    // MARK: 你改时间 → 不改回

    @Test func userTimeChangeSurvivesSync() async throws {
        let list = FakeReminderList(), c = Collector(), p = projector(list, collector: c)
        let id = UUID(), d = blockDraft(id, due: at(21, 17))
        try await p.sync([d], scope: [id], now: fixedNow)
        #expect(await list.item(key(d))?.due == at(21, 17))
        await list.userRetime(key(d), to: at(21, 15))            // Jason 在提醒事项里改到 15:00
        try await p.sync([d], scope: [id], now: fixedNow)          // 同一份计划再确认一次
        #expect(await list.item(key(d))?.due == at(21, 15))       // 没被改回
        let retimed = await c.ops.filter { $0.kind == .retimed }
        #expect(retimed.count == 1 && retimed[0].line.contains("截止时间不变"))
        // BetterCalendar 这边截止变了、标题也变了：时间仍按你的，标题跟着 BetterCalendar
        try await p.sync([blockDraft(id, due: at(21, 18), title: "交终版报告")], scope: [id], now: fixedNow)
        let now = try #require(await list.item(key(d)))
        #expect(now.due == at(21, 15) && now.title == "交终版报告")
        let entry = try #require(try ledgerStore.load().entries[key(d)])
        #expect(entry.userTime && entry.dismissedAt == nil)
        #expect(await c.ops.filter { $0.kind == .retimed }.count == 1)   // 不重复记
    }

    // MARK: 你删除 →「不用提醒我了」，不重建，事情本身保留

    @Test func userDeleteIsNotRecreatedAndItemKept() async throws {
        let list = FakeReminderList(), c = Collector()
        let mac = projector(list, device: "mac", collector: c), phone = projector(list, device: "phone", collector: c)
        let id = UUID(), d = blockDraft(id, due: at(21, 17))
        let pool = ReminderDraft(title: "交论文", due: at(30, 23), priority: 5, notes: "未来任务截止", leadMinutes: 130)
        try await mac.sync([d, pool], scope: [id], now: fixedNow)
        #expect(await list.items.count == 2)
        await list.userDelete(key(d)); await list.userDelete(key(pool))
        try await mac.sync([d, pool], scope: [id], now: fixedNow)
        #expect(await list.items.isEmpty)                                         // 没重建
        let dismissed = await c.ops.filter { $0.kind == .dismissed }
        #expect(dismissed.count == 2 && dismissed.allSatisfy { $0.line.contains("这件事本身还在") })
        // 另一台设备确认同样的计划：账本已同步 → 也不重建
        try await phone.sync([d, pool], scope: [id], now: fixedNow)
        #expect(await list.items.isEmpty)
        // 事情本身保留：「不用提醒」只记账，不会去动待办（只有打勾才会标完成）
        let fakePool = FakePool()
        let recorder = ReminderOpsRecorder(ledger: MemoryOperationLedger(), deviceId: "mac", pool: fakePool, now: { fixedNow })
        recorder.record(dismissed)
        #expect(fakePool.completed.isEmpty)
        let book = try ledgerStore.load()
        #expect(book.entries[key(d)]?.dismissedAt != nil && book.entries[key(pool)]?.dismissedAt != nil)
    }

    /// 写过、但这台设备从没见过、现在也读不到（还没同步过来）：不重建、也不当成删除。
    @Test func unseenOnThisDeviceIsHeldBackNotDismissed() async throws {
        let macList = FakeReminderList(), phoneList = FakeReminderList(), c = Collector()
        let id = UUID(), d = blockDraft(id, due: at(21, 17))
        try await projector(macList, device: "mac", collector: c).sync([d], scope: [id], now: fixedNow)
        try await projector(phoneList, device: "phone", collector: c).sync([d], scope: [id], now: fixedNow)   // 手机上还没同步过来
        #expect(await phoneList.items.isEmpty)                                   // 不重建（避免同步到达后变两条）
        let entry = try #require(try ledgerStore.load().entries[key(d)])
        #expect(entry.dismissedAt == nil)                                        // 也不当成你删了
        #expect(await c.ops.isEmpty)
        #expect(await c.logs.contains { $0.contains("先不重建") })
    }

    // MARK: 读失败 ≠ 删除

    @Test func readFailureIsNeverTreatedAsDelete() async throws {
        let list = FakeReminderList(), c = Collector(), p = projector(list, collector: c)
        let id = UUID(), d = blockDraft(id, due: at(21, 17))
        try await p.sync([d], scope: [id], now: fixedNow)
        for failure in [ReminderAccessError.readFailed("系统没能读出"), .notAuthorized("没权限")] {
            await list.setReadError(failure)
            await #expect(throws: ReminderAccessError.self) { try await p.sync([d], scope: [id], now: fixedNow) }
            let report = await p.followUserChanges(now: fixedNow)
            #expect(report.error != nil && report.ops.isEmpty)
        }
        #expect(await c.logs.contains { $0.hasPrefix("[error]") && $0.contains("没有把任何提醒当成你删的") })   // 失败可见
        await list.setReadError(nil)
        #expect(try ledgerStore.load().entries[key(d)]?.dismissedAt == nil)
        // 列表找不到（被改名 / 删了整本）：也不判你删了什么，写过的先不重建
        await list.setExists(false)
        try await p.sync([d], scope: [id], now: fixedNow)
        #expect(try ledgerStore.load().entries[key(d)]?.dismissedAt == nil)
        #expect(await list.applied.last?.creates.isEmpty == true)
        #expect(await c.ops.isEmpty)
    }

    // MARK: 打勾 = 做成了

    @Test func checkOffMarksDone() async throws {
        let list = FakeReminderList(), c = Collector(), p = projector(list, collector: c)
        let id = UUID(), d = blockDraft(id, due: at(21, 17))
        let pool = ReminderDraft(title: "交论文", due: at(30, 23), priority: 5, notes: nil, leadMinutes: 130)
        try await p.sync([d, pool], scope: [id], now: fixedNow)
        // 计划块：今天勾掉 → completedBlockIDs（ExecutionViewModel 据此画蓝，见 reconcileDeletionTombstonesAndStaysDeleted）
        await list.userComplete(key(d), at: fixedNow)
        #expect(await p.completedBlockIDs() == [id])
        // 待办池截止：今天勾掉 → 你的操作 → 对应待办标完成，操作留底记「你（在提醒事项里）」
        await list.userComplete(key(pool), at: fixedNow)
        let report = await p.followUserChanges(now: fixedNow)
        let done = report.ops.filter { $0.kind == .completed }
        #expect(done.count == 2)
        let fakePool = FakePool(), ledger = MemoryOperationLedger()
        ReminderOpsRecorder(ledger: ledger, deviceId: "mac", pool: fakePool, now: { fixedNow }).record(done)
        #expect(fakePool.completed == [key(pool)])
        #expect(ledger.values.allSatisfy { $0.actor == .user && $0.event == "reminder.completed" })
        #expect(ledger.values.contains { $0.detail.contains("算做成了") })
        // 真待办：LongTaskStore 按章找到在途、带截止的那件
        let c2 = try ModelContainer(for: LongTask.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let tasks = LongTaskStore(context: c2.mainContext)
        tasks.add(title: "交论文", deadline: at(30, 23))
        #expect(tasks.completePoolItem(stampKey: key(pool)) == "交论文")
        #expect(tasks.active().isEmpty && tasks.doneItems().map(\.title) == ["交论文"])
        // App 里完成后回勾：不会被误当成「你在提醒事项里勾的」
        let id2 = UUID(), d2 = blockDraft(id2, due: at(22, 17), title: "写周报")
        try await p.sync([d2], scope: [id2], now: fixedNow)
        await p.markCompleted(blockIDs: [id2])
        #expect(await p.followUserChanges(now: fixedNow).ops.isEmpty)
    }

    // MARK: 「几点提醒我」→ 带章的原生提醒；撤销删掉它

    func executor(_ list: FakeReminderList, scheduler: FakeLocalScheduler) -> ProposalActionExecutor {
        let e = ProposalActionExecutor(items: nil, deviceId: "phone", now: { fixedNow })
        e.askReminders = projector(list, device: "phone")
        e.notifications = scheduler
        e.knownDevices = { [KnownDevice(id: "mac", label: "Jason 的 Mac", platform: "macOS", seenAt: fixedNow)] }
        return e
    }

    @Test func rememberMeCreatesStampedNativeReminderAndUndoRemovesIt() async throws {
        let list = FakeReminderList(), scheduler = FakeLocalScheduler()
        let e = executor(list, scheduler: scheduler)
        let rid = UUID(), fire = at(21, 8)
        let prepared = try await e.prepare(.reminder(id: rid, title: "赶大巴", body: "带学生卡", fireAt: fire, deviceId: "mac"))
        #expect(prepared.requiredDeviceId == nil)   // device 只为兼容保留，不再固定执行设备
        #expect(prepared.changes?.contains { $0.field.contains("会出现在提醒事项里，各台设备（iPhone / iPad / Mac）都会响") } == true)
        let outcome = try await e.perform(prepared.action)
        let r = try #require(await list.item(ReminderStamp.key(ReminderStamp.askURL(rid))!))
        #expect(r.url == ReminderStamp.askURL(rid) && r.due == fire && r.leadMinutes == 0 && r.notes == "带学生卡")
        #expect(outcome.note.contains("各台设备（iPhone / iPad / Mac）都会响") && scheduler.scheduled.isEmpty)
        let undo = try #require(outcome.undo?.action)
        #expect(outcome.undo?.deviceId == nil)       // 任一台有提醒事项的设备都能撤
        _ = try await e.perform(undo)
        #expect(await list.items.isEmpty)
        // 确认时清理不碰「几点提醒我」（它不是从计划算出来的）
        let rid2 = UUID()
        let o2 = try await e.perform(.reminder(id: rid2, title: "喝水", body: nil, fireAt: at(21, 9), deviceId: nil))
        try await projector(list, device: "phone").sync([], scope: [], now: at(22, 9))   // 过了时刻也留着
        #expect(await list.items.count == 1)
        // 你在提醒事项里改过它 → 撤销不删（按你的为准）
        await list.userRetime(ReminderStamp.key(ReminderStamp.askURL(rid2))!, to: at(21, 10))
        await #expect(throws: ProposalExecutionError.self) { _ = try await e.perform(o2.undo!.action!) }
        #expect(await list.items.count == 1)
    }

    /// 冒烟 2026-10-18 bug A：执行成功但回报没落地 → App 重启后对同一提案再执行一次。要幂等：不报「已过」、不重写、按已完成回报。
    @Test func reexecutingARemindMeAfterLostReportIsIdempotent() async throws {
        let list = FakeReminderList(), scheduler = FakeLocalScheduler()
        let e = executor(list, scheduler: scheduler)
        let rid = UUID(), fire = at(21, 8)
        let first = try await e.perform(.reminder(id: rid, title: "喝水", body: nil, fireAt: fire, deviceId: nil))
        #expect(await list.items.count == 1)
        let late = ProposalActionExecutor(items: nil, deviceId: "phone", now: { fire.addingTimeInterval(3600) })   // 时刻已过
        late.askReminders = projector(list, device: "phone"); late.notifications = scheduler
        let again = try await late.perform(.reminder(id: rid, title: "喝水", body: nil, fireAt: fire, deviceId: nil))
        #expect(await list.items.count == 1 && scheduler.scheduled.isEmpty)
        #expect(again.note.contains("已写进提醒事项") && again.undo?.action == first.undo?.action)
        // 没写过的、时刻已过的：照旧拒绝补发
        await #expect(throws: ProposalExecutionError.self) {
            _ = try await late.perform(.reminder(id: UUID(), title: "别的", body: nil, fireAt: fire, deviceId: nil))
        }
    }

    @Test func localSourceFallbackIsVisible() async throws {
        let list = FakeReminderList(), scheduler = FakeLocalScheduler()
        await list.setReach(ReminderListReach(sourceName: "在我的 iPhone 上", syncsAcrossDevices: false))
        let e = executor(list, scheduler: scheduler)
        let outcome = try await e.perform(.reminder(id: UUID(), title: "交表", body: nil, fireAt: at(21, 8), deviceId: nil))
        #expect(await list.items.isEmpty)                         // 只在本机的列表：不写
        #expect(scheduler.scheduled.count == 1)                   // 改用本机通知
        #expect(outcome.note.contains("没写进提醒事项") && outcome.note.contains("在我的 iPhone 上") && outcome.note.contains("只在这台设备上"))
        #expect(outcome.undo?.deviceId == "phone")                // 本机通知只能在这台撤
        // 没有提醒事项权限：同样改用本机通知并写明
        await list.setReach(ReminderListReach(sourceName: "iCloud", syncsAcrossDevices: true))
        await list.setReadError(.notAuthorized("没有提醒事项的完整权限"))
        let o2 = try await e.perform(.reminder(id: UUID(), title: "交表", body: nil, fireAt: at(21, 8), deviceId: nil))
        #expect(o2.note.contains("没有提醒事项权限") && scheduler.scheduled.count == 2)
        // 其它失败（系统读不到）：不降级，直接报出来
        await list.setReadError(.readFailed("系统没能读出"))
        await #expect(throws: ProposalExecutionError.self) {
            _ = try await e.perform(.reminder(id: UUID(), title: "交表", body: nil, fireAt: at(21, 8), deviceId: nil))
        }
    }

    // MARK: 你自己的提醒：只读，从不修改

    @Test func ownListsAndUnstampedRemindersUntouched() async throws {
        let list = FakeReminderList(), c = Collector(), p = projector(list, collector: c)
        let mine = ReminderSnapshot(url: nil, isCompleted: false, title: "买牛奶", notes: nil, priority: 0, due: at(19, 9),
                                    leadMinutes: nil, itemID: "mine")
        let foreign = ReminderSnapshot(url: URL(string: "https://example.com/x"), isCompleted: false, title: "别的 App 的",
                                       notes: nil, priority: 0, due: at(18, 9), leadMinutes: nil, itemID: "foreign")
        await list.setItems([mine, foreign])
        await list.setOwn([OwnReminder(title: "取快递", due: at(21, 18), hasTime: true, list: "家里")])
        let id = UUID()
        try await p.sync([blockDraft(id, due: at(21, 17))], scope: [id], now: fixedNow)
        _ = await p.followUserChanges(now: fixedNow)
        _ = try await p.ownOpenReminders()
        _ = await p.dueReminders(on: at(21, 0))
        let touched = await list.touchedItemIDs()
        #expect(!touched.contains("mine") && !touched.contains("foreign"))
        let after = await list.items
        #expect(after.contains(mine) && after.contains(foreign))
        #expect(await p.dueReminders(on: at(21, 0)) == ["取快递"])
    }

    // MARK: 智能体上下文：你的提醒（只读，截断）+ 你删掉 / 改过时间的

    @Test func agentContextIncludesOwnRemindersReadOnlyTruncated() async throws {
        let list = FakeReminderList()
        await list.setOwn((0..<35).map { OwnReminder(title: "提醒 \($0)", due: at(21, 8).addingTimeInterval(Double($0) * 60), hasTime: true, list: "工作") }
                          + [OwnReminder(title: "没截止的", due: nil, hasTime: false, list: "家里")])
        var book = ReminderProjectionLedger()
        var gone = ReminderProjectionEntry.written(blockDraft(UUID(), due: at(21, 17), title: "交报告"), kind: .block, by: "mac", at: fixedNow)
        gone.dismissedAt = fixedNow
        book.entries["block/x"] = gone
        let gatherer = AgentContextGatherer(planStore: nil, actualStore: nil, longTasks: nil, calendarStore: nil, journalStore: nil,
                                            reminderStore: projector(list), reminderLedger: { book },
                                            running: { .init() }, journalAllowed: { false })
        let input = await gatherer.gather(now: fixedNow)
        #expect(input.ownReminders.items.count == 36 && input.ownReminders.items.first?.title == "提醒 0")
        #expect(input.ownReminders.items.last?.title == "没截止的")   // 有截止的在前
        let snap = AgentBridgeContext.snapshot(input)
        let reminders = try #require(snap["reminders"] as? [String: Any])
        #expect(reminders["source"] as? String == "系统提醒事项（只读）")
        #expect((reminders["items"] as? [[String: Any]])?.count == AgentContextLimits.ownReminders)
        #expect(reminders["truncated"] as? Bool == true && reminders["total"] as? Int == 36)
        #expect((reminders["truncatedNote"] as? String)?.contains("共 36 条") == true)
        let bc = try #require(snap["bcReminders"] as? [String: Any])
        #expect((bc["dismissed"] as? [[String: Any]])?.first?["title"] as? String == "交报告")
        #expect((bc["note"] as? String)?.contains("别再提议同一个提醒") == true)
        // 读失败：显式写进上下文，不当成「没有」
        await list.setOwnReadError(.notAuthorized("还没允许 BetterCalendar 使用提醒事项"))
        let broken = await gatherer.gather(now: fixedNow)
        #expect(broken.ownReminders.error?.contains("还没允许") == true && broken.ownReminders.items.isEmpty)
    }
}

/// 假待办池（记下被标完成的章）。
@MainActor final class FakePool: PoolDeadlineCompleting {
    var completed: [String] = []
    func completePoolItem(stampKey: String) -> String? { completed.append(stampKey); return "交论文" }
}

/// 假本机通知排程（本地兜底用）。
@MainActor final class FakeLocalScheduler: ProposalNotificationScheduling {
    var alarmsSupported = false
    var scheduled: [UUID: Date] = [:]
    func scheduleReminder(id: UUID, title: String, body: String, fireAt: Date) async throws -> String { scheduled[id] = fireAt; return "rev" }
    func cancelReminder(id: UUID, expectedRevision: String?) async throws { scheduled[id] = nil }
    func scheduleAlarm(id: UUID, title: String, fireAt: Date) async throws {}
    func cancelAlarm(id: UUID) async throws {}
}
