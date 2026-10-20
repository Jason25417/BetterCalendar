//
//  W32EscalationTests.swift
//  BetterCalendarTests
//
//  W32（Jason 2026-10-19/20）：越级审批你的东西 + 智能体写日记 + 删待办 / 长期事项。
//  全部用内存数据：你的日程 / 提醒 = 内存假写者（绝不碰真 EventKit）；事项 / 日记 = 内存 SwiftData（cloudKitDatabase: .none）；
//  时钟注入（不用 Date.now）；开关用注入的闭包（不读写真 UserDefaults）；规则存储用一次性 suite。
//

import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import BetterCalendar

/// 内存里的「你的日程 / 提醒」（行为同 EventKitYourItemsWriter 的契约：按外部标识 + 开始定位、找不到抛 notFound）。
nonisolated final class FakeYourItems: YourItemsWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [YourEventSnapshot] = []
    private var _reminders: [String: YourReminderSnapshot] = [:]
    private(set) var writes = 0
    var events: [YourEventSnapshot] { lock.withLock { _events } }
    var reminders: [String: YourReminderSnapshot] { lock.withLock { _reminders } }

    func seed(_ e: YourEventSnapshot) { lock.withLock { _events.append(e) } }
    func seed(_ r: YourReminderSnapshot) { lock.withLock { _reminders[r.externalID] = r } }
    /// 模拟 Jason 在苹果日历里亲手改了标题。
    func userRetitle(_ id: String, _ title: String) { lock.withLock { if let i = _events.firstIndex(where: { $0.ref.externalID == id }) { _events[i].title = title } } }

    private func index(_ ref: YourEventRef) throws -> Int {
        guard let i = _events.firstIndex(where: { $0.ref.externalID == ref.externalID && $0.start == ref.occurrenceStart }) else {
            throw YourItemsError.notFound("日历里找不到这条日程")
        }
        return i
    }
    func event(_ ref: YourEventRef) async throws -> YourEventSnapshot { try lock.withLock { _events[try index(ref)] } }
    func apply(_ edit: YourEventEdit) async throws -> YourEventSnapshot {
        try lock.withLock {
            let i = try index(edit.ref)
            var e = _events[i]
            if let t = edit.title { e.title = t }
            if let n = edit.notes { e.notes = n.isEmpty ? nil : n }
            if let s = edit.start { e.start = s }
            if let x = edit.end { e.end = x }
            e.ref.occurrenceStart = e.start
            _events[i] = e; writes += 1
            return e
        }
    }
    func delete(_ ref: YourEventRef) async throws { try lock.withLock { _events.remove(at: try index(ref)); writes += 1 } }
    func recreate(_ s: YourEventSnapshot) async throws -> YourEventSnapshot {
        lock.withLock {
            var e = s
            e.ref.externalID = "re-" + s.ref.externalID   // 重建 = 新条目（新标识），内容一致
            _events.append(e); writes += 1
            return e
        }
    }
    func reminder(_ id: String) async throws -> YourReminderSnapshot {
        try lock.withLock { guard let r = _reminders[id] else { throw YourItemsError.notFound("提醒事项里找不到这条提醒") }; return r }
    }
    func apply(_ edit: YourReminderEdit) async throws -> YourReminderSnapshot {
        try lock.withLock {
            guard var r = _reminders[edit.externalID] else { throw YourItemsError.notFound("提醒事项里找不到这条提醒") }
            if let t = edit.title { r.title = t }
            if let d = edit.due {
                r.absoluteAlarms = r.absoluteAlarms.map { a in r.due.map { abs(a.timeIntervalSince($0)) < 1 } == true ? d : a }
                r.due = d
            }
            if let done = edit.done { r.isCompleted = done }
            _reminders[edit.externalID] = r; writes += 1
            return r
        }
    }
}

@MainActor @Suite struct W32EscalationTests {
    final class Clock { var now: Date
        init() { now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10))! }
    }
    final class Switches { var write = true; var read = true }

    struct Rig {
        let container: ModelContainer
        let clock: Clock
        let items: LongTaskStore
        let journal: JournalStore
        let your: FakeYourItems
        let switches: Switches
        let center: ProposalCenter
        let executor: ProposalActionExecutor
    }

    func rig(gate: (any ProposalGate)? = nil, rules: PreauthRuleStore? = nil) throws -> Rig {
        let container = try ModelContainer(for: DataArchiveStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let clock = Clock(), switches = Switches()
        let items = LongTaskStore(context: container.mainContext)
        let journal = JournalStore(context: container.mainContext)
        let your = FakeYourItems()
        let executor = ProposalActionExecutor(items: items, deviceId: "mac", now: { clock.now })
        executor.yourItems = your
        executor.journal = journal
        executor.journalWriteAllowed = { switches.write }
        executor.journalReadAllowed = { switches.read }
        let center = ProposalCenter(transport: InMemoryProposalTransport(), gate: gate ?? AskAlwaysGate(), rules: rules, executor: executor,
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(),
                                    deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        return Rig(container: container, clock: clock, items: items, journal: journal, your: your, switches: switches,
                   center: center, executor: executor)
    }

    func at(_ h: Int, _ m: Int = 0, _ c: Clock) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: c.now)! }

    func meeting(_ c: Clock, id: String = "ev-1", facts: YourEventFacts = YourEventFacts()) -> YourEventSnapshot {
        YourEventSnapshot(ref: YourEventRef(externalID: id, occurrenceStart: at(14, 0, c)), title: "组会", start: at(14, 0, c), end: at(15, 0, c),
                          isAllDay: false, notes: "带电脑", location: "Dreese 260", url: nil, calendarTitle: "工作", sourceTitle: "iCloud",
                          timeZone: "America/New_York", alarmOffsets: [-600], facts: facts)
    }

    func draft(_ action: ProposalAction, escalation: String? = "Jason 说组会改到四点了") -> ProposalDraft {
        ProposalDraft(origin: .agent, originLabel: "BetterCalendar 智能体", targetDeviceId: "mac", title: "W32 测试",
                      changes: [], reason: "测试", action: action, experiment: false, escalation: escalation)
    }

    func approve(_ r: Rig, _ d: ProposalDraft) async throws -> Proposal {
        let p = try #require(await r.center.submit(d))
        await r.center.decide(p.id, .approve)
        await r.center.refresh()
        return try #require(r.center.proposals.first { $0.id == p.id })
    }

    // MARK: A 你的日程

    @Test func yourEventEditRequiresEscalationNamesTheEventAndUndoRestoresExactly() async throws {
        let r = try rig()
        let original = meeting(r.clock)
        r.your.seed(original)
        let edit = YourEventEdit(ref: original.ref, title: "组会（改期）", start: at(16, 0, r.clock), notes: "")
        // 没写越级理由 → 拒收，原因点名是他的日程
        await #expect(throws: ProposalExecutionError.self) { _ = try await r.center.prepare(draft(.yourEventEdit(edit), escalation: nil)) }
        do { _ = try await r.center.prepare(draft(.yourEventEdit(edit), escalation: nil)) } catch {
            #expect(error.localizedDescription.contains("改的是你自己设的日程：《组会》") && error.localizedDescription.contains("越级"))
        }
        let p = try await approve(r, draft(.yourEventEdit(edit)))
        #expect(p.changes.first?.isEscalationSubject == true)
        #expect(p.changes.first?.field.contains("改的是你自己设的日程：《组会》（日历「工作」）") == true)
        #expect(p.changes.contains(ProposalChange(field: "日程标题", before: "组会", after: "组会（改期）")))
        #expect(p.changes.contains { $0.field.contains("时间") && $0.before?.contains("14:00") == true && $0.after?.contains("16:00–17:00") == true })
        #expect(p.state == .applied)
        let changed = try #require(r.your.events.first)
        #expect(changed.title == "组会（改期）" && changed.start == at(16, 0, r.clock) && changed.end == at(17, 0, r.clock) && changed.notes == nil)
        #expect(await r.center.undo(p.id))
        let back = try #require(r.your.events.first)
        #expect(back.title == original.title && back.start == original.start && back.end == original.end && back.notes == original.notes)
        #expect(back.revision == original.revision)   // 原样改回
    }

    @Test func yourThingsAreNeverAutoApprovedByPreauthRules() async throws {
        let suite = "bc.w32.rules.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rules = PreauthRuleStore(defaults: defaults)
        let r = try rig(gate: PreauthRuleGate(store: rules), rules: rules)
        let ev = meeting(r.clock)
        r.your.seed(ev)
        r.your.seed(YourReminderSnapshot(externalID: "rem-1", title: "交表", due: at(18, 0, r.clock), hasTime: true, isCompleted: false, listTitle: "提醒"))
        let task = UUID()
        try r.items.createTodo(id: task, title: "买牛奶", note: "", at: r.clock.now)
        let actions: [ProposalAction] = [
            .yourEventEdit(YourEventEdit(ref: ev.ref, title: "组会 2")),
            .yourEventDelete(ref: ev.ref, expectedRevision: nil),
            .yourReminderEdit(YourReminderEdit(externalID: "rem-1", done: true)),
            .itemDelete(id: task, expectedRevision: nil),
        ]
        for a in actions {
            for scope in PreauthScope.allCases {
                rules.upsert(origin: .agent, action: a, scope: scope, effect: .allow, deviceId: "mac", sourceProposalId: nil)
                rules.upsert(origin: .agent, action: a, scope: scope, effect: .allowAndInform, deviceId: "mac", sourceProposalId: nil)
            }
            #expect(a.ownership == .yours)
            let p = try #require(await r.center.submit(draft(a)))
            #expect(p.state == .pending && p.preauth == nil, "\(a.kind) 被规则自动放行了")
            #expect(r.center.cannotRemember(p, effect: .allow) != nil)
            // 即使没有越级理由也拦（PreauthPolicy 第二道：ownership == .yours）
            var bare = p; bare.escalation = nil
            #expect(PreauthPolicy.evaluate(bare, rules: rules.rules).route == .ask)
            await r.center.decide(p.id, .decline)
        }
        #expect(r.your.writes == 0)
    }

    @Test func yourEventConflictWhenJasonChangedItAfterTheProposal() async throws {
        let r = try rig()
        let ev = meeting(r.clock)
        r.your.seed(ev)
        let p = try #require(await r.center.submit(draft(.yourEventEdit(YourEventEdit(ref: ev.ref, title: "智能体的标题")))))
        r.your.userRetitle("ev-1", "我自己改的")
        await r.center.decide(p.id, .approve); await r.center.refresh()
        let latest = try #require(r.center.proposals.first { $0.id == p.id })
        #expect(latest.state == .failed && latest.resultNote?.contains("被改过") == true)
        #expect(r.your.events.first?.title == "我自己改的" && r.your.writes == 0)
    }

    @Test func refusedYourEventsExplainWhy() async throws {
        let r = try rig()
        let cases: [(YourEventFacts, String)] = [
            (YourEventFacts(organizerIsOther: true, organizerName: "Gregory"), "「Gregory」发来的邀请"),
            (YourEventFacts(hasOtherAttendees: true), "其他参与者"),
            (YourEventFacts(calendarWritable: false), "只读日历"),
            (YourEventFacts(inBetterCalendar: true), "BetterCalendar 自己的日历"),
        ]
        for (i, (facts, why)) in cases.enumerated() {
            let ev = meeting(r.clock, id: "ev-\(i)", facts: facts)
            r.your.seed(ev)
            for a in [ProposalAction.yourEventEdit(YourEventEdit(ref: ev.ref, title: "x")), .yourEventDelete(ref: ev.ref, expectedRevision: nil)] {
                do { _ = try await r.center.prepare(draft(a)); Issue.record("应拒收：\(why)") } catch {
                    #expect(error.localizedDescription.contains(why), "\(error.localizedDescription)")
                }
            }
        }
        // 全天日程不改时间；重复日程不删
        var allDay = meeting(r.clock, id: "ev-allday"); allDay.isAllDay = true
        r.your.seed(allDay)
        do { _ = try await r.center.prepare(draft(.yourEventEdit(YourEventEdit(ref: allDay.ref, start: at(9, 0, r.clock))))); Issue.record("全天应拒收") }
        catch { #expect(error.localizedDescription.contains("全天")) }
        let recurring = meeting(r.clock, id: "ev-rec", facts: YourEventFacts(isRecurring: true))
        r.your.seed(recurring)
        do { _ = try await r.center.prepare(draft(.yourEventDelete(ref: recurring.ref, expectedRevision: nil))); Issue.record("重复日程删除应拒收") }
        catch { #expect(error.localizedDescription.contains("重复日程")) }
        #expect(r.your.writes == 0)
    }

    @Test func recurringEditStatesScopeDefaultingToThisOccurrence() async throws {
        let r = try rig()
        let rec = meeting(r.clock, id: "ev-rec", facts: YourEventFacts(isRecurring: true))
        let single = meeting(r.clock, id: "ev-single")
        r.your.seed(rec); r.your.seed(single)
        let a = try await r.center.prepare(draft(.yourEventEdit(YourEventEdit(ref: rec.ref, title: "组会 B")))).changes
        #expect(a.contains { $0.field == "重复日程：只改这一次" })
        let b = try await r.center.prepare(draft(.yourEventEdit(YourEventEdit(ref: rec.ref, span: .futureEvents, title: "组会 B")))).changes
        #expect(b.contains { $0.field == "重复日程：这一次及以后的都改" })
        let c = try await r.center.prepare(draft(.yourEventEdit(YourEventEdit(ref: single.ref, span: .futureEvents, title: "组会 B"))))
        guard case let .yourEventEdit(e) = c.action else { Issue.record("种类变了"); return }
        #expect(e.span == .thisOccurrence)   // 不重复的日程没有「以后」
    }

    @Test func deleteYourEventThenUndoRecreatesSameContent() async throws {
        let r = try rig()
        let ev = meeting(r.clock)
        r.your.seed(ev)
        let p = try await approve(r, draft(.yourEventDelete(ref: ev.ref, expectedRevision: nil), escalation: "Jason 说这个组会取消了，让我删掉"))
        #expect(p.state == .applied && r.your.events.isEmpty)
        #expect(p.changes.first?.field.contains("删的是你自己设的日程：《组会》") == true)
        #expect(p.undoHint?.contains("原样重建") == true)
        #expect(await r.center.undo(p.id))
        let back = try #require(r.your.events.first)
        #expect(back.title == ev.title && back.start == ev.start && back.end == ev.end && back.notes == ev.notes
                && back.location == ev.location && back.calendarTitle == ev.calendarTitle && back.alarmOffsets == ev.alarmOffsets)
    }

    // MARK: A 你的提醒

    @Test func yourReminderRetimeMovesItsAlarmAndUndoRestores() async throws {
        let r = try rig()
        let due = at(18, 0, r.clock)
        let original = YourReminderSnapshot(externalID: "rem-1", title: "交表", due: due, hasTime: true, isCompleted: false,
                                            listTitle: "提醒", absoluteAlarms: [due])
        r.your.seed(original)
        let p = try await approve(r, draft(.yourReminderEdit(YourReminderEdit(externalID: "rem-1", title: "交报销表", due: at(20, 0, r.clock)))))
        #expect(p.changes.first?.field.contains("改的是你自己的提醒：《交表》") == true)
        let changed = try #require(r.your.reminders["rem-1"])
        #expect(changed.title == "交报销表" && changed.due == at(20, 0, r.clock) && changed.absoluteAlarms == [at(20, 0, r.clock)])
        #expect(await r.center.undo(p.id))
        #expect(r.your.reminders["rem-1"] == original)
    }

    @Test func refusedYourRemindersExplainWhy() async throws {
        let r = try rig()
        r.your.seed(YourReminderSnapshot(externalID: "rec", title: "每天喝水", due: at(9, 0, r.clock), hasTime: true, isCompleted: false,
                                         listTitle: "提醒", facts: YourReminderFacts(isRecurring: true)))
        r.your.seed(YourReminderSnapshot(externalID: "bc", title: "要紧事", due: nil, hasTime: false, isCompleted: false,
                                         listTitle: "BetterCalendar · 要紧事 (Dev)", facts: YourReminderFacts(inBetterCalendarList: true)))
        r.your.seed(YourReminderSnapshot(externalID: "nodue", title: "想法", due: nil, hasTime: false, isCompleted: false, listTitle: "提醒"))
        let cases: [(YourReminderEdit, String)] = [
            (YourReminderEdit(externalID: "rec", done: true), "重复提醒"),
            (YourReminderEdit(externalID: "bc", title: "x"), "BetterCalendar 自己的提醒列表"),
            (YourReminderEdit(externalID: "nodue", due: at(12, 0, r.clock)), "没有截止时间"),
        ]
        for (edit, why) in cases {
            do { _ = try await r.center.prepare(draft(.yourReminderEdit(edit))); Issue.record("应拒收：\(why)") }
            catch { #expect(error.localizedDescription.contains(why), "\(error.localizedDescription)") }
        }
        #expect(r.your.writes == 0)
    }

    // MARK: W32c 删待办 / 长期事项 / 阶段

    @Test func deleteLongTermItemWithCheckpointsGoesToTrashAndUndoRestoresAll() async throws {
        let r = try rig()
        let task = r.items.add(title: "测度论")
        r.items.addCheckpoint(to: task, title: "第 1 章")
        r.items.addCheckpoint(to: task, title: "第 2 章")
        let id = task.id
        let p = try await approve(r, draft(.itemDelete(id: id, expectedRevision: nil), escalation: "Jason 说这门不学了，让我删掉"))
        #expect(p.changes.first?.field.contains("删的是你的长期事项：《测度论》") == true)
        #expect(p.changes.contains { $0.before?.contains("连同它的 2 个阶段") == true })
        #expect(p.state == .applied)
        #expect(try r.items.task(id: id)?.isInTrash == true && r.items.active().isEmpty)
        #expect(await r.center.undo(p.id))
        let back = try #require(try r.items.task(id: id))
        #expect(!back.isInTrash && back.sortedCheckpoints.map(\.title) == ["第 1 章", "第 2 章"] && r.items.active().count == 1)
        // 删除类 + 你的东西：没有越级理由一律拒收
        await #expect(throws: ProposalExecutionError.self) { _ = try await r.center.prepare(draft(.itemDelete(id: id, expectedRevision: nil), escalation: nil)) }
    }

    @Test func deleteTodoAndCheckpointThenUndo() async throws {
        let r = try rig()
        let todo = UUID()
        try r.items.createTodo(id: todo, title: "买牛奶", note: "", at: r.clock.now)
        let p = try await approve(r, draft(.itemDelete(id: todo, expectedRevision: nil), escalation: "Jason 说已经买了，删掉"))
        #expect(p.changes.first?.field.contains("删的是你的待办：《买牛奶》") == true)
        #expect(r.items.todoItems().isEmpty)
        #expect(await r.center.undo(p.id))
        #expect(r.items.todoItems().map(\.title) == ["买牛奶"])

        let task = r.items.add(title: "论文")
        let cp = try #require(r.items.addCheckpoint(to: task, title: "引言"))
        let q = try await approve(r, draft(.checkpointDelete(itemId: task.id, checkpointId: cp.id, expectedRevision: nil), escalation: "Jason 说引言不要了"))
        #expect(q.changes.first?.field.contains("删的是你长期事项《论文》里的阶段：《引言》") == true)
        #expect(task.sortedCheckpoints.isEmpty)
        #expect(await r.center.undo(q.id))
        #expect(task.sortedCheckpoints.map(\.title) == ["引言"])
    }

    // MARK: B 日记

    @Test func journalAppendIsGatedBySwitchCreatesAgentTextAndUndoTrashesIt() async throws {
        let r = try rig()
        r.switches.write = false
        let d = draft(.journalAppend(day: r.clock.now, text: "今天把组会挪到了四点。", newEntryID: UUID(), expectedRevision: nil), escalation: nil)
        do { _ = try await r.center.prepare(d); Issue.record("开关关着应拒收") } catch { #expect(error.localizedDescription.contains("允许智能体提议写日记")) }
        r.switches.write = true
        let p = try await approve(r, d)
        #expect(p.state == .applied && p.escalation == nil)   // 加一段 = 普通审批（不碰你写的字）
        guard case let .journalAppend(_, _, newID, _) = p.action else { Issue.record("种类变了"); return }
        let entry = try #require(try r.journal.entry(id: newID))
        #expect(JournalAuthorship.segments(entry.body) == [.init(text: "今天把组会挪到了四点。", byAgent: true)])
        #expect(r.journal.search("组会").count == 1 && r.journal.search("bc:agent").isEmpty)   // 搜索不搜标记
        #expect(await r.center.undo(p.id))
        #expect(try r.journal.entry(id: newID)?.isInTrash == true)
    }

    @Test func journalAppendToExistingKeepsJasonsTextAndUndoRestoresBody() async throws {
        let r = try rig()
        let mine = UUID()
        try r.journal.create(id: mine, day: Calendar.current.startOfDay(for: r.clock.now), body: "早上跑了步。", at: r.clock.now)
        let p = try await approve(r, draft(.journalAppend(day: r.clock.now, text: "下午写完了引言。", newEntryID: UUID(), expectedRevision: nil), escalation: nil))
        let body = try #require(try r.journal.entry(id: mine)?.body)
        #expect(JournalAuthorship.segments(body) == [.init(text: "早上跑了步。\n\n", byAgent: false), .init(text: "下午写完了引言。", byAgent: true)])
        #expect(await r.center.undo(p.id))
        #expect(try r.journal.entry(id: mine)?.body == "早上跑了步。")
    }

    @Test func journalEditIsEscalationNeedsReadSwitchAndUndoRestores() async throws {
        let r = try rig()
        let id = UUID()
        try r.journal.create(id: id, day: Calendar.current.startOfDay(for: r.clock.now), body: "今天很累，不想动。", at: r.clock.now)
        let edit = ProposalAction.journalEdit(entryID: id, find: "不想动", replace: "休息了一下", expectedRevision: nil)
        #expect(edit.ownership == .yours)
        await #expect(throws: ProposalExecutionError.self) { _ = try await r.center.prepare(draft(edit, escalation: nil)) }
        r.switches.read = false
        do { _ = try await r.center.prepare(draft(edit, escalation: "Jason 让我改")); Issue.record("读开关关着应拒收") }
        catch { #expect(error.localizedDescription.contains("读最近日记")) }
        r.switches.read = true
        let p = try await approve(r, draft(edit, escalation: "Jason 让我把这句改得温和些"))
        #expect(p.changes.first?.field.contains("改的是你自己写的日记") == true)
        #expect(p.changes.contains(ProposalChange(field: "日记原文", before: "不想动", after: "休息了一下")))
        let body = try #require(try r.journal.entry(id: id)?.body)
        #expect(JournalAuthorship.plainText(body) == "今天很累，休息了一下。")
        #expect(JournalAuthorship.segments(body).contains(.init(text: "休息了一下", byAgent: true)))
        #expect(await r.center.undo(p.id))
        #expect(try r.journal.entry(id: id)?.body == "今天很累，不想动。")
        // 原文出现不止一次 / 找不到 → 拒收
        try r.journal.setBody(id: id, body: "好好好", at: r.clock.now)
        do { _ = try await r.center.prepare(draft(.journalEdit(entryID: id, find: "好", replace: "坏", expectedRevision: nil))); Issue.record("应拒收") }
        catch { #expect(error.localizedDescription.contains("出现了 3 次")) }
    }

    @Test func journalUndoRefusesWhenJasonWroteMoreAfterwards() async throws {
        let r = try rig()
        let id = UUID()
        try r.journal.create(id: id, day: Calendar.current.startOfDay(for: r.clock.now), body: "早上。", at: r.clock.now)
        let p = try await approve(r, draft(.journalAppend(day: r.clock.now, text: "智能体的一段", newEntryID: UUID(), expectedRevision: nil), escalation: nil))
        let body = try #require(try r.journal.entry(id: id)?.body)
        try r.journal.setBody(id: id, body: body + "\n晚上我又写了一句。", at: r.clock.now)
        #expect(await r.center.undo(p.id) == false)
        #expect(try r.journal.entry(id: id)?.body.hasSuffix("晚上我又写了一句。") == true)   // 不覆盖他后来写的
    }

    @Test func authorshipMarkersRoundTripAndJasonsEditMakesItHis() {
        let marked = JournalAuthorship.appending("智能体写的", to: "我写的")
        #expect(JournalAuthorship.plainText(marked) == "我写的\n\n智能体写的")
        #expect(JournalAuthorship.hasAgentText(marked))
        // 他改了智能体段落里的一个字 → 指纹对不上 → 整段算他的（照常字体），标记失效但文字不丢
        let edited = marked.replacingOccurrences(of: "智能体写的", with: "智能体写得好")
        #expect(!JournalAuthorship.hasAgentText(edited))
        #expect(JournalAuthorship.plainText(edited) == "我写的\n\n智能体写得好")
        // 残缺的标记（删掉了一半）也不显示
        let broken = "前" + JournalAuthorship.mark("中").replacingOccurrences(of: JournalAuthorship.closeTag, with: "") + "后"
        #expect(JournalAuthorship.plainText(broken) == "前中后")
        // 渲染：智能体段落用固定字体（衬线斜体），你的不用
        let rendered = JournalBody.rendered(marked, format: "markdown")
        let fonts = rendered.runs.map(\.font)
        #expect(fonts.contains { $0 == JournalAuthorship.agentFont } && fonts.contains { $0 == nil })
    }

    // MARK: 桥接解析 / 工具 schema / 上下文 / 架构

    @Test func bridgeParsesNewKindsStrictly() throws {
        let pid = UUID()
        let ev = try AgentBridgeIO.action(from: ["kind": "yourEventEdit", "eventId": "E1", "occurrenceStart": "2026-10-20T14:00:00-04:00",
                                                "span": "futureEvents", "title": "组会", "start": "2026-10-20T16:00:00-04:00"], proposalId: pid)
        guard case let .yourEventEdit(e) = ev else { Issue.record("种类"); return }
        #expect(e.ref.externalID == "E1" && e.span == .futureEvents && e.title == "组会" && e.end == nil)
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.action(from: ["kind": "yourEventEdit", "eventId": "E1", "occurrenceStart": "2026-10-20T14:00:00-04:00"], proposalId: pid) }
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.action(from: ["kind": "yourEventEdit", "eventId": "E1", "occurrenceStart": "2026-10-20T14:00:00-04:00", "span": "all", "title": "x"], proposalId: pid) }
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.action(from: ["kind": "yourEventDelete", "eventId": "E1", "occurrenceStart": "2026-10-20T14:00:00-04:00", "title": "x"], proposalId: pid) }
        let rem = try AgentBridgeIO.action(from: ["kind": "yourReminderEdit", "reminderId": "R1", "done": true], proposalId: pid)
        #expect(rem == .yourReminderEdit(YourReminderEdit(externalID: "R1", done: true)))
        let item = UUID(), cp = UUID()
        #expect(try AgentBridgeIO.action(from: ["kind": "itemDelete", "itemId": item.uuidString], proposalId: pid) == .itemDelete(id: item, expectedRevision: nil))
        #expect(try AgentBridgeIO.action(from: ["kind": "checkpointDelete", "itemId": item.uuidString, "checkpointId": cp.uuidString], proposalId: pid)
                == .checkpointDelete(itemId: item, checkpointId: cp, expectedRevision: nil))
        let j = try AgentBridgeIO.action(from: ["kind": "journalAppend", "day": "2026-10-20", "text": "一段"], proposalId: pid)
        guard case let .journalAppend(_, text, newID, _) = j else { Issue.record("种类"); return }
        #expect(text == "一段" && newID == pid)   // 新日记 id = 提案 id（重复导入幂等）
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.action(from: ["kind": "journalEdit", "entryId": item.uuidString, "find": "x"], proposalId: pid) }
        // 只作撤销的逆操作不能由智能体提
        for k in ["yourEventRecreate", "itemRestore", "checkpointRestore", "journalRestore"] {
            #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.action(from: ["kind": k], proposalId: pid) }
        }
    }

    @Test func builtinToolSchemaListsTheNewKinds() throws {
        let data = try BuiltinAgentToolbox.loadDefinitions()
        let list = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let propose = try #require(list.first { ($0["function"] as? [String: Any])?["name"] as? String == "propose_change" })
        let params = try #require((propose["function"] as? [String: Any])?["parameters"] as? [String: Any])
        let props = try #require(params["properties"] as? [String: Any])
        let action = try #require(props["action"] as? [String: Any])
        let kinds = try #require(((action["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String])
        for k in ["yourEventEdit", "yourEventDelete", "yourReminderEdit", "itemDelete", "checkpointDelete", "journalAppend", "journalEdit"] {
            #expect(kinds.contains(k), "\(k)")
        }
        #expect(!kinds.contains("yourEventRecreate") && !kinds.contains("journalRestore"))
    }

    @Test func contextExposesStableIdsAndEditability() throws {
        var input = AgentContextInput(now: Clock().now)
        let c = Clock()
        input.calendar.items = [
            .init(title: "组会", start: at(14, 0, c), end: at(15, 0, c), calendar: "工作", externalID: "E1", facts: YourEventFacts()),
            .init(title: "别人的会", start: at(16, 0, c), end: at(17, 0, c), calendar: "工作", externalID: "E2",
                  facts: YourEventFacts(organizerIsOther: true, organizerName: "Gregory")),
        ]
        input.ownReminders.items = [.init(title: "交表", due: nil, list: "提醒", externalID: "R1", facts: YourReminderFacts())]
        input.journalAllowed = true
        input.journalWriteAllowed = true
        let jid = UUID()
        input.journal.items = [.init(day: c.now, body: "x", mood: nil, modifiedAt: c.now, id: jid, revision: "rev")]
        let ctx = AgentBridgeContext.snapshot(input)
        let events = try #require((ctx["calendar"] as? [String: Any])?["events"] as? [[String: Any]])
        #expect(events[0]["eventId"] as? String == "E1" && events[0]["editable"] as? Bool == true && events[0]["occurrenceStart"] != nil)
        #expect(events[1]["editable"] as? Bool == false && (events[1]["notEditableReason"] as? String)?.contains("Gregory") == true)
        let reminders = try #require((ctx["reminders"] as? [String: Any])?["items"] as? [[String: Any]])
        #expect(reminders[0]["reminderId"] as? String == "R1" && reminders[0]["editable"] as? Bool == true)
        let journal = try #require(ctx["journal"] as? [String: Any])
        #expect(journal["writeAllowed"] as? Bool == true)
        let entries = try #require(journal["entries"] as? [[String: Any]])
        #expect(entries[0]["id"] as? String == jid.uuidString && entries[0]["revision"] as? String == "rev")
        #expect(JSONSerialization.isValidJSONObject(ctx))
    }

    @Test func actionTargetsListCheckpointIds() throws {
        let container = try ModelContainer(for: DataArchiveStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let items = LongTaskStore(context: container.mainContext)
        let task = items.add(title: "测度论")
        let cp = try #require(items.addCheckpoint(to: task, title: "第 1 章"))
        let targets = AgentBridgeContext.actionTargets(longTasks: items, timer: nil)
        let rows = try #require(targets["items"] as? [[String: Any]])
        let cps = try #require(rows.first?["checkpoints"] as? [[String: Any]])
        #expect(cps.first?["id"] as? String == cp.id.uuidString && cps.first?["title"] as? String == "第 1 章")
    }

    /// 架构守卫：「你的」日程 / 提醒的写者只交给审批执行器（+ 组装点、定义文件）；它自己不拿日历投影的写角色。
    @Test func yourItemsWriterStaysInApprovalExecutor() throws {
        let appRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BetterCalendar")
        let allowed: Set<String> = ["YourItems.swift", "EventKitYourItemsWriter.swift", "ProposalActionExecutor.swift", "AppContainer.swift"]
        let pattern = try NSRegularExpression(pattern: #"(?<![A-Za-z])(YourItemsWriting|EventKitYourItemsWriter)(?![A-Za-z])"#)
        var offenders: [String] = []
        var writerCode = ""
        for case let url as URL in FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            let code = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                .joined(separator: "\n")
            if url.lastPathComponent == "EventKitYourItemsWriter.swift" { writerCode = code }
            if !allowed.contains(url.lastPathComponent), pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "这些文件拿到了「你的东西」写者：\(offenders)")
        #expect(!writerCode.isEmpty && !writerCode.contains("CalendarProjecting") && !writerCode.contains("CalendarSyncEngine"))
        #expect(writerCode.contains("refuseIfTestHost"))
    }

    @Test func journalWriteSwitchSyncsAndDefaultsOff() {
        #expect(SettingsSync.syncedKeys.contains(AgentJournalSettings.key))
        #expect(UserDefaults.standard.object(forKey: AgentJournalSettings.key) == nil || AgentJournalSettings.allowWrite == false)
    }
}
