//
//  W34CapabilityTests.swift
//  BetterCalendarTests
//
//  W34（Jason 2026-10-21）：智能体上报的「删不了」——删你的提醒（含重复 = 整个系列）、重复提醒标完成这一次、
//  删重复日程（只这一次 / 这一次及以后）、给长期事项加阶段。全部内存数据（假写者 + 内存 SwiftData），时钟注入。
//

import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

@MainActor @Suite struct W34CapabilityTests {
    let base = W32EscalationTests()

    // MARK: 删重复日程

    @Test func deleteOneOccurrenceOfARecurringEventUndoesAsStandaloneEvent() async throws {
        let r = try base.rig()
        let rec = base.meeting(r.clock, id: "stat-3301", facts: YourEventFacts(isRecurring: true))
        r.your.seed(rec)
        // 越级：没写理由一律拒收
        await #expect(throws: ProposalExecutionError.self) {
            _ = try await r.center.prepare(base.draft(.yourEventDelete(ref: rec.ref, expectedRevision: nil), escalation: nil))
        }
        let prepared = try await r.center.prepare(base.draft(.yourEventDelete(ref: rec.ref, expectedRevision: nil)))
        #expect(prepared.headline?.hasPrefix("删除重复日程「组会」的这一次") == true)
        guard case let .yourEventDelete(_, _, span) = prepared.action else { Issue.record("种类变了"); return }
        #expect(span == .thisOccurrence)   // 默认只这一次
        #expect(prepared.changes.contains { $0.isConsequence && $0.field.contains("不再算已占用") && $0.field.contains("不会回到重复系列") })

        let p = try await base.approve(r, base.draft(.yourEventDelete(ref: rec.ref, expectedRevision: nil), escalation: "Jason 说明天这节不去"))
        #expect(p.state == .applied && r.your.events.isEmpty && r.your.lastDeleteSpan == .thisOccurrence)
        #expect(p.undoHint?.contains("独立日程") == true)
        #expect(await r.center.undo(p.id))
        let back = try #require(r.your.events.first)
        #expect(back.title == rec.title && back.start == rec.start && back.recurrence == nil)
    }

    @Test func deleteThisAndFutureOccurrencesUndoRebuildsTheSeries() async throws {
        let r = try base.rig()
        let rec = base.meeting(r.clock, id: "cse-2421", facts: YourEventFacts(isRecurring: true))
        r.your.seed(rec)
        let p = try await base.approve(r, base.draft(.yourEventDelete(ref: rec.ref, expectedRevision: nil, span: .futureEvents),
                                                     escalation: "Jason 说这门课以后都不去了"))
        #expect(p.headline?.contains("这一次及以后") == true && r.your.lastDeleteSpan == .futureEvents)
        #expect(p.undoHint?.contains("重复规则") == true)
        #expect(await r.center.undo(p.id))
        #expect(r.your.events.first?.recurrence?.isEmpty == false)
    }

    @Test func spanIsDroppedForNonRecurringEvents() async throws {
        let r = try base.rig()
        let single = base.meeting(r.clock)
        r.your.seed(single)
        let prepared = try await r.center.prepare(base.draft(.yourEventDelete(ref: single.ref, expectedRevision: nil, span: .futureEvents)))
        guard case let .yourEventDelete(_, _, span) = prepared.action else { Issue.record("种类变了"); return }
        #expect(span == nil && prepared.headline?.hasPrefix("删除你的日程「组会」") == true)
    }

    @Test func oldYourEventDeleteRecordsWithoutSpanStillDecode() throws {
        let ref = YourEventRef(externalID: "E1", occurrenceStart: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(ProposalAction.yourEventDelete(ref: ref, expectedRevision: "r1"))
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("span"))   // = 0.72 写出的旧记录
        #expect(try JSONDecoder().decode(ProposalAction.self, from: data) == .yourEventDelete(ref: ref, expectedRevision: "r1", span: nil))
    }

    // MARK: 删提醒 / 重复提醒标完成

    func homework(_ r: W32EscalationTests.Rig, recurring: Bool = true) -> YourReminderSnapshot {
        YourReminderSnapshot(externalID: "cse-hw", title: "CSE 2421 homework", notes: "Carmen", due: base.at(20, 0, r.clock), hasTime: true,
                             isCompleted: false, listTitle: "提醒", absoluteAlarms: [base.at(20, 0, r.clock)],
                             facts: YourReminderFacts(isRecurring: recurring), recurrence: recurring ? [YourRecurrenceRule(frequency: 0)] : nil)
    }

    @Test func deleteRecurringReminderDeletesTheSeriesAndUndoRecreatesIt() async throws {
        let r = try base.rig()
        let hw = homework(r)
        r.your.seed(hw)
        let prepared = try await r.center.prepare(base.draft(.yourReminderDelete(externalID: "cse-hw", expectedRevision: nil)))
        #expect(prepared.headline == "删除你的提醒「CSE 2421 homework」（重复提醒，整个系列）")
        #expect(prepared.changes.first?.isEscalationSubject == true)
        #expect(prepared.changes.contains { $0.isConsequence && $0.field.contains("子任务") && $0.field.contains("以前各次的完成记录") })
        #expect(ProposalAction.yourReminderDelete(externalID: "x", expectedRevision: nil).isDestructive)

        let p = try await base.approve(r, base.draft(.yourReminderDelete(externalID: "cse-hw", expectedRevision: nil), escalation: "Jason 说这门作业交完了，删掉"))
        #expect(p.state == .applied && r.your.reminders.isEmpty)
        #expect(p.undoHint?.contains("重建") == true)
        #expect(await r.center.undo(p.id))
        let back = try #require(r.your.reminders["re-cse-hw"])
        #expect(back.title == hw.title && back.notes == hw.notes && back.due == hw.due && back.recurrence == hw.recurrence)
    }

    @Test func reminderDeleteIsNeverAutoApproved() async throws {
        let suite = "bc.w34.rules.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rules = PreauthRuleStore(defaults: defaults)
        let r = try base.rig(gate: PreauthRuleGate(store: rules), rules: rules)
        r.your.seed(homework(r))
        let a = ProposalAction.yourReminderDelete(externalID: "cse-hw", expectedRevision: nil)
        for scope in PreauthScope.allCases { rules.upsert(origin: .agent, action: a, scope: scope, effect: .allow, deviceId: "mac", sourceProposalId: nil) }
        let p = try #require(await r.center.submit(base.draft(a)))
        #expect(p.state == .pending && p.preauth == nil && r.your.writes == 0)
    }

    @Test func completingARecurringReminderIsAllowedButStatesItCannotBeUndone() async throws {
        let r = try base.rig()
        r.your.seed(homework(r))
        let edit = YourReminderEdit(externalID: "cse-hw", done: true)
        let prepared = try await r.center.prepare(base.draft(.yourReminderEdit(edit)))
        #expect(prepared.headline == "标完成你的重复提醒「CSE 2421 homework」这一次")
        #expect(prepared.changes.contains { $0.isConsequence && $0.field.contains("下一次照常出现") && $0.field.contains("不能一键撤销") })
        let p = try await base.approve(r, base.draft(.yourReminderEdit(edit)))
        #expect(p.state == .applied && p.undoAction == nil)
        #expect(p.undoUnavailableReason?.contains("没法原样撤销") == true)
        // 不重复的提醒标完成照旧可撤销
        r.your.seed(homework(r, recurring: false))
        var single = homework(r, recurring: false); single.externalID = "ieee"; r.your.seed(single)
        let q = try await base.approve(r, base.draft(.yourReminderEdit(YourReminderEdit(externalID: "ieee", done: true))))
        #expect(q.undoAction != nil)
    }

    // MARK: 给长期事项加阶段

    @Test func checkpointCreateInsertsAtPositionAndUndoTrashesIt() async throws {
        let r = try base.rig()
        let task = r.items.add(title: "通识课作业")
        r.items.addCheckpoint(to: task, title: "选题")
        r.items.addCheckpoint(to: task, title: "初稿")
        let cp = UUID()
        let action = ProposalAction.checkpointCreate(itemId: task.id, checkpointId: cp, title: " 研究之后的学习节奏 ", estimatedMinutes: 45,
                                                     position: 1, expectedRevision: nil)
        // 普通审批：不必写越级理由
        let prepared = try await r.center.prepare(base.draft(action, escalation: nil))
        #expect(prepared.headline == "给长期事项「通识课作业」加阶段「研究之后的学习节奏」")
        #expect(prepared.changes.contains(ProposalChange(field: "新阶段", before: nil, after: "研究之后的学习节奏（约 45 分钟）")))
        #expect(prepared.changes.contains { $0.isConsequence && $0.field.contains("插在「初稿」之前") })
        #expect(action.ownership == .betterCalendar && action.alwaysAsks && !action.isDestructive)

        let p = try await base.approve(r, base.draft(action, escalation: nil))
        #expect(p.state == .applied)
        #expect(task.sortedCheckpoints.map(\.title) == ["选题", "研究之后的学习节奏", "初稿"])
        #expect(task.sortedCheckpoints[1].id == cp && task.sortedCheckpoints[1].estimatedMinutes == 45)
        #expect(p.undoHint?.contains("回收站") == true)
        #expect(await r.center.undo(p.id))
        #expect(task.sortedCheckpoints.map(\.title) == ["选题", "初稿"])
    }

    @Test func checkpointCreateRefusesTodosAndIsNeverPreauthorized() async throws {
        let suite = "bc.w34.cp.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rules = PreauthRuleStore(defaults: defaults)
        let r = try base.rig(gate: PreauthRuleGate(store: rules), rules: rules)
        let todo = UUID()
        try r.items.createTodo(id: todo, title: "买牛奶", note: "", at: r.clock.now)
        do {
            _ = try await r.center.prepare(base.draft(.checkpointCreate(itemId: todo, checkpointId: UUID(), title: "x", estimatedMinutes: nil,
                                                                        position: nil, expectedRevision: nil), escalation: nil))
            Issue.record("待办区不能加阶段")
        } catch { #expect(error.localizedDescription.contains("待办区")) }

        let task = r.items.add(title: "论文")
        let a = ProposalAction.checkpointCreate(itemId: task.id, checkpointId: UUID(), title: "引言", estimatedMinutes: nil, position: nil, expectedRevision: nil)
        for scope in PreauthScope.allCases { rules.upsert(origin: .agent, action: a, scope: scope, effect: .allow, deviceId: "mac", sourceProposalId: nil) }
        let p = try #require(await r.center.submit(base.draft(a, escalation: nil)))
        #expect(p.state == .pending && p.preauth == nil)
        #expect(PreauthPolicy.lowRiskReason(p) != nil)
    }

    // MARK: 桥接格式

    @Test func bridgeParsesW34Kinds() throws {
        let pid = UUID(), item = UUID()
        let del = try AgentBridgeIO.action(from: ["kind": "yourEventDelete", "eventId": "E1", "occurrenceStart": "2026-10-21T11:30:00-04:00",
                                                 "span": "futureEvents"], proposalId: pid)
        guard case let .yourEventDelete(ref, _, span) = del else { Issue.record("种类"); return }
        #expect(ref.externalID == "E1" && span == .futureEvents)
        #expect(throws: AgentBridgeError.self) {
            try AgentBridgeIO.action(from: ["kind": "yourEventDelete", "eventId": "E1", "occurrenceStart": "2026-10-21T11:30:00-04:00", "span": "all"], proposalId: pid)
        }
        #expect(try AgentBridgeIO.action(from: ["kind": "yourReminderDelete", "reminderId": "R1"], proposalId: pid)
                == .yourReminderDelete(externalID: "R1", expectedRevision: nil))
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.action(from: ["kind": "yourReminderDelete", "reminderId": "R1", "done": true], proposalId: pid) }
        let cp = try AgentBridgeIO.action(from: ["kind": "checkpointCreate", "itemId": item.uuidString, "title": "阶段", "estimateMinutes": 30,
                                                "position": 0], proposalId: pid)
        #expect(cp == .checkpointCreate(itemId: item, checkpointId: pid, title: "阶段", estimatedMinutes: 30, position: 0, expectedRevision: nil))
        #expect(throws: AgentBridgeError.self) {
            try AgentBridgeIO.action(from: ["kind": "checkpointCreate", "itemId": item.uuidString, "title": "阶段", "position": -1], proposalId: pid)
        }
        #expect(throws: AgentBridgeError.self) {
            try AgentBridgeIO.action(from: ["kind": "checkpointCreate", "itemId": item.uuidString, "title": "阶段", "estimateMinutes": 0], proposalId: pid)
        }
        for k in ["yourReminderRecreate"] { #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.action(from: ["kind": k], proposalId: pid) } }
    }

    @Test func recurrenceRuleLabelsAndRoundTrips() throws {
        let weekly = YourRecurrenceRule(frequency: 1, interval: 1, daysOfTheWeek: [.init(dayOfWeek: 3)])
        #expect(weekly.label == "每周")
        #expect(YourRecurrenceRule(frequency: 0, interval: 2).label == "每 2 天")
        #expect(YourRecurrenceRule(frequency: 2, occurrenceCount: 5).label == "每月，共 5 次")
        let data = try JSONEncoder().encode(weekly)
        #expect(try JSONDecoder().decode(YourRecurrenceRule.self, from: data) == weekly)
    }
}
