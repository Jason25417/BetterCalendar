//
//  DevW34SelfTest.swift
//  BetterCalendar
//
//  开发期自测种子（仅 DEBUG，正式版不编译）：W34 发版前自测用。
//  · 测试数据只建在本机「本地」账户（On My Mac / 本机，不随 iCloud 同步）里一本「【BC 自测】W34」日历 / 提醒列表，
//    长期事项、待办只建在 Dev 版自己的数据里；标题一律带【自测】。清理只删这些（按名字 + 本地账户双重核对）。
//  · 提案走真实路径：桥接解析（AgentBridgeIO.action）→ ProposalCenter.submit（prepare / 越级 / 预授权 / 批量都一样），
//    发起者 = 智能体，执行设备 = 本机（测试日历只在本机）。
//  触发：启动带 BC_DEV_SEED_W34=1（iOS 模拟器用 SIMCTL_CHILD_BC_DEV_SEED_W34=1）；BC_DEV_CLEAN_W34=1 = 只清理。
//  Mac 另可用分布式通知 com.jason.BetterCalendar.dev.proposal.w34seed / w34clean（见 DevProposalHooks）。
//

#if DEBUG
import EventKit
import Foundation

@MainActor enum DevW34SelfTest {
    static let containerTitle = "【BC 自测】W34"
    static let label = "BetterCalendar 智能体（自测）"

    /// 建测试数据 + 发一组 W34 提案。结果（含每一步失败原因）写 DevLog 并 print。
    static func seed(center: ProposalCenter, items: LongTaskStore) async {
        var log: [String] = []
        let store = EKEventStore()
        func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
        func submit(_ a: [String: Any], title: String, reason: String, escalation: String?, labelSuffix: String = "", lifetime: TimeInterval = 3 * 3600) async {
            let id = UUID()
            do {
                let action = try AgentBridgeIO.action(from: a, proposalId: id, targetDevice: center.deviceId)
                let p = await center.submit(ProposalDraft(id: id, origin: .agent, originLabel: label + labelSuffix, targetDeviceId: center.deviceId,
                                                          title: title, changes: [], reason: reason, action: action, experiment: false,
                                                          lifetime: lifetime, escalation: escalation))
                log.append(p == nil ? "✗ \(title)：\(center.lastError ?? "?")" : "✓ \(title)")
            } catch { log.append("✗ \(title)：\(error.localizedDescription)") }
        }
        // —— 不碰 EventKit 的：Dev 自己的长期事项 / 待办（卡片、批量、作废、收起、加阶段）——
        do {
            let now = Date()
            let lt = items.add(title: "【自测】W34 长期事项")
            items.addCheckpoint(to: lt, title: "阶段 A")
            items.addCheckpoint(to: lt, title: "阶段 B")
            var todos: [UUID] = []
            for i in 1...5 {
                let id = UUID(); todos.append(id)
                try items.createTodo(id: id, title: "【自测】待办 \(i)", note: "", at: now)
            }
            log.append("Dev 数据：长期事项 1（2 个阶段）+ 待办 5")

            await submit(["kind": "checkpointCreate", "itemId": lt.id.uuidString, "title": "阶段 A½", "estimateMinutes": 45, "position": 1],
                         title: "加阶段", reason: "你说 A 和 B 之间还差一步", escalation: nil, labelSuffix: "·阶段")
            for id in todos.prefix(4) {
                await submit(["kind": "itemDelete", "itemId": id.uuidString], title: "删待办", reason: "你说这几条都做完了",
                             escalation: "你要求清掉这几条待办", labelSuffix: "·批量")
            }
            await submit(["kind": "itemDelete", "itemId": todos[4].uuidString], title: "删待办（2 分半后作废）", reason: "测有效期：放着不管",
                         escalation: "测试作废", labelSuffix: "·作废", lifetime: 150)
        } catch { log.append("✗ Dev 数据部分中止：\(error.localizedDescription)") }
        // —— 你的日程 / 提醒（只在本地账户的测试日历里；没有本地账户就跳过并说明）——
        do {
            try await requestAccess(store)
            let cal = try localCalendar(store, for: .event)
            let now = Date()
            func at(_ hours: Double) -> Date { Calendar.current.date(bySetting: .second, value: 0, of: now.addingTimeInterval(hours * 3600)) ?? now }
            func event(_ title: String, _ start: Date, count: Int?) throws -> EKEvent {
                let e = EKEvent(eventStore: store)
                e.calendar = cal; e.title = title; e.startDate = start; e.endDate = start.addingTimeInterval(30 * 60)
                e.notes = "BetterCalendar W34 自测数据，可删"
                if let count { e.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: count))] }
                try store.save(e, span: .futureEvents, commit: true)
                return e
            }
            let single = try event("【自测】单次日程", at(2), count: nil)
            let thisOnly = try event("【自测】重复课（只删这次）", at(3), count: 5)
            let future = try event("【自测】重复课（删这次及以后）", at(4), count: 6)
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: future.startDate)!
            log.append("日历「\(cal.title)」（\(cal.source.title)）：单次 1 + 重复 2（5 次 / 6 次）")

            let list = try localCalendar(store, for: .reminder)
            func reminder(_ title: String, dueIn hours: Double, daily: Bool) throws -> EKReminder {
                let r = EKReminder(eventStore: store)
                r.calendar = list; r.title = title; r.notes = "BetterCalendar W34 自测数据，可删"
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at(hours))
                r.addAlarm(EKAlarm(absoluteDate: at(hours)))
                if daily { r.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)] }
                try store.save(r, commit: true)
                return r
            }
            let r1 = try reminder("【自测】单次提醒", dueIn: 5, daily: false)
            let r2 = try reminder("【自测】每晚作业（删整个系列）", dueIn: 6, daily: true)
            let r3 = try reminder("【自测】每天喝水（只完成这次）", dueIn: 1, daily: true)
            log.append("提醒列表「\(list.title)」（\(list.source.title)）：单次 1 + 重复 2")

            // —— 提案（真实桥接格式 → 解析 → 提交）——
            await submit(["kind": "yourEventDelete", "eventId": single.calendarItemExternalIdentifier!, "occurrenceStart": iso(single.startDate)],
                         title: "删单次日程", reason: "你说这个不用去了", escalation: "你要求删掉这条日程", labelSuffix: "·单次")
            await submit(["kind": "yourEventDelete", "eventId": thisOnly.calendarItemExternalIdentifier!, "occurrenceStart": iso(thisOnly.startDate)],
                         title: "删重复课这一次", reason: "你说今天这节不去", escalation: "你要求只删今天这一节", labelSuffix: "·这次")
            await submit(["kind": "yourEventDelete", "eventId": future.calendarItemExternalIdentifier!, "occurrenceStart": iso(tomorrow), "span": "futureEvents"],
                         title: "删重复课明天起", reason: "你说这门课以后不上了", escalation: "你要求从明天起都删掉", labelSuffix: "·以后")
            for r in [r1, r2] {
                await submit(["kind": "yourReminderDelete", "reminderId": r.calendarItemExternalIdentifier!],
                             title: "删提醒", reason: "你说这几个提醒不用了", escalation: "你要求删掉这些提醒", labelSuffix: "·提醒")
            }
            await submit(["kind": "yourReminderEdit", "reminderId": r3.calendarItemExternalIdentifier!, "done": true],
                         title: "喝水标完成", reason: "你说今天喝过了", escalation: "你说今天这次已经做了", labelSuffix: "·完成")
        } catch {
            log.append("✗ 日程 / 提醒部分跳过：\(error.localizedDescription)")
        }
        let text = log.joined(separator: "\n")
        DevLog.shared.info("W34 自测种子", text)
        print("BC_DEV_SEED_W34\n" + text)
    }

    /// 不点界面的端到端走查（真 CloudKit 中转 + 真 Dev 数据）：批量卡勾 3 拒 1 → 加阶段 → 整批撤销 → 部分撤销提示。
    /// 记下「点下去到离开待确认」与「到 iCloud 回来」的耗时（乐观更新是否生效）。
    static func run(center: ProposalCenter, items: LongTaskStore) async {
        var log: [String] = []
        func ms(_ t: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(t) * 1000) }
        await center.refresh()
        let mine = center.pending.filter { $0.originLabel.hasPrefix(label) }
        guard let batch = ProposalBatching.groups(mine).first(where: { $0.isBatch && $0.family == .delete }) else {
            log.append("✗ 没找到待确认的批量卡（先跑 w34seed）"); return finish(log)
        }
        log.append("批量卡：\(batch.title)，成员 \(batch.proposals.map { $0.cardHeadline }.joined(separator: " / "))")
        let ids = batch.proposals.map(\.id)
        let t0 = Date()
        let task = Task { await center.decideBatch(approve: Array(ids.dropLast()), decline: [ids.last!]) }
        await Task.yield()
        let leftAt = ms(t0)
        let stillPending = center.pending.filter { ids.contains($0.id) }.count
        log.append("点下去 \(leftAt) 后：这一批在「待确认」里还剩 \(stillPending) 份（乐观更新：应为 0）")
        let done = await task.value
        log.append("iCloud 全部回来：\(ms(t0))，成功提交 \(done)/\(ids.count)")
        await center.refresh()
        log.append("状态：" + ids.map { id in center.proposals.first { $0.id == id }.map { "\($0.cardHeadline)=\(ProposalPresentation.compactStatus($0, at: .now))" } ?? "?" }.joined(separator: "，"))

        if let cp = mine.first(where: { if case .checkpointCreate = $0.action { true } else { false } }) {
            let t1 = Date()
            _ = await center.decide(cp.id, .approve)
            await center.refresh()
            let lt = items.active().first { $0.title == "【自测】W34 长期事项" }
            log.append("加阶段：\(ms(t1))，阶段现在 = \(lt?.sortedCheckpoints.map(\.title).joined(separator: " → ") ?? "?")；撤销说明：\(center.proposals.first { $0.id == cp.id }?.undoHint ?? "无")")
        }

        // 部分撤销：先手动从回收站恢复其中一项，再整批撤销 → 应只撤 2 项并写明
        let applied = ids.compactMap { id in center.proposals.first { $0.id == id && $0.state == .applied } }
        if let first = applied.first, case let .itemRestore(itemId, deletion)? = first.undoAction {
            do { try items.restore(id: itemId, deletionID: deletion, at: Date()); log.append("模拟你自己先恢复了「\(first.cardHeadline)」") }
            catch { log.append("✗ 手动恢复失败：\(error.localizedDescription)") }
        }
        center.clearError()
        let t2 = Date()
        let undone = await center.undoBatch(applied.map(\.id))
        log.append("整批撤销：\(ms(t2))，撤了 \(undone)/\(applied.count)；横幅 = \(center.lastError ?? "（无）")")
        log.append("待办现在：" + items.todoItems().filter { $0.title.hasPrefix("【自测】") }.map(\.title).sorted().joined(separator: "、"))
        finish(log)
    }

    private static func finish(_ log: [String]) {
        let text = log.joined(separator: "\n")
        DevLog.shared.info("W34 自测走查", text)
        print("BC_DEV_RUN_W34\n" + text)
    }

    /// 只删本机本地账户里名为「【BC 自测】W34」的日历 / 提醒列表，以及 Dev 数据里标题带【自测】的长期事项 / 待办（进回收站）。
    static func clean(items: LongTaskStore) async {
        var log: [String] = []
        let store = EKEventStore()
        for type in [EKEntityType.event, .reminder] {
            for c in store.calendars(for: type) where c.title == containerTitle && c.source.sourceType == .local {
                do { try store.removeCalendar(c, commit: true); log.append("删 \(type == .event ? "日历" : "提醒列表")「\(c.title)」") }
                catch { log.append("✗ 删「\(c.title)」：\(error.localizedDescription)") }
            }
        }
        for t in items.active() + items.todoItems() where t.title.hasPrefix("【自测】") {
            do { _ = try items.trash(id: t.id, at: Date()); log.append("回收站 ← \(t.title)") }
            catch { log.append("✗ \(t.title)：\(error.localizedDescription)") }
        }
        let text = log.isEmpty ? "没有要清理的" : log.joined(separator: "\n")
        DevLog.shared.info("W34 自测清理", text)
        print("BC_DEV_CLEAN_W34\n" + text)
    }

    private static func requestAccess(_ store: EKEventStore) async throws {
        guard try await store.requestFullAccessToEvents(), try await store.requestFullAccessToReminders() else {
            throw NSError(domain: "W34", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有日历 / 提醒事项的完整权限"])
        }
    }

    /// 本地账户里的测试日历 / 提醒列表（没有就建；本地账户不存在 = 拒绝，不退到 iCloud）。
    private static func localCalendar(_ store: EKEventStore, for type: EKEntityType) throws -> EKCalendar {
        if let c = store.calendars(for: type).first(where: { $0.title == containerTitle && $0.source.sourceType == .local }) { return c }
        guard let local = store.sources.first(where: { $0.sourceType == .local }) else {
            throw NSError(domain: "W34", code: 2, userInfo: [NSLocalizedDescriptionKey: "这台设备没有本地（不同步）账户，不在 iCloud 里建测试数据"])
        }
        let c = EKCalendar(for: type, eventStore: store)
        c.title = containerTitle; c.source = local
        do { try store.saveCalendar(c, commit: true) } catch {
            throw NSError(domain: "W34", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "本地账户建不了\(type == .event ? "日历" : "提醒列表")：\(error.localizedDescription)"])
        }
        return c
    }
}
#endif
