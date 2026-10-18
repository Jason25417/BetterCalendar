//
//  ReminderProjector.swift
//  BetterCalendar
//
//  W12（SPEC §19.13 Q5）：提醒事项投影的协调者——生产唯一的 ReminderStore 实现。
//  决定全在纯函数（ReminderSyncPlanner / ReminderFollowPlanner），读写走薄缝 ReminderListAccess（生产 = EventKit），
//  这里只负责：读 → 决定 → 写 → 记账本 → 把你的操作写成白话交给 opsSink（日志 / 操作留底 / 待办标完成）。
//  铁律：
//    - 读失败（没权限 / 系统读不到）= 这次什么都不判断，可见地报出来；绝不当成「你删了」。
//    - 你自己的列表、没章的提醒：只读，从不修改。
//    - 「几点提醒我」写进 BetterCalendar 的列表；列表只在本机（本地账户）时不写，交给执行器改用本机通知并写明。
//

import Foundation

actor ReminderProjector: ReminderStore, AskReminderProjecting {
    private let access: any ReminderListAccess
    private let ledgerStore: ReminderProjectionLedgerStore
    private let deviceId: String
    private let clock: @Sendable () -> Date
    /// 你在提醒事项里的操作（白话）交给组装点：写日志 + 操作留底 + 待办池截止「勾掉 = 做成了」。
    private let opsSink: (@Sendable ([ReminderUserOp]) async -> Void)?
    /// 日志（生产 = DevLog；测试可收集断言）。level：info / warn / error。
    private let log: @Sendable (_ level: String, _ message: String) async -> Void

    init(access: any ReminderListAccess, ledgerStore: ReminderProjectionLedgerStore = ReminderProjectionLedgerStore(),
         deviceId: String, clock: @escaping @Sendable () -> Date = { Date() },
         opsSink: (@Sendable ([ReminderUserOp]) async -> Void)? = nil,
         log: @escaping @Sendable (_ level: String, _ message: String) async -> Void = ReminderProjector.devLog) {
        self.access = access; self.ledgerStore = ledgerStore; self.deviceId = deviceId
        self.clock = clock; self.opsSink = opsSink; self.log = log
    }

    static let devLog: @Sendable (String, String) async -> Void = { level, message in
        await MainActor.run {
            switch level {
            case "error": DevLog.shared.error("提醒", message)
            case "warn": DevLog.shared.warn("提醒", message)
            default: DevLog.shared.info("提醒", message)
            }
        }
    }

    // MARK: ReminderStore

    func write(_ drafts: [ReminderDraft]) async throws {
        try await sync(drafts, scope: [], now: clock())
    }

    /// 按章差量写入（P4.0-9）+ 跟上你的操作（W12）。读不到列表 → 抛错（确认页可见），什么都不写、不判断。
    func sync(_ drafts: [ReminderDraft], scope: Set<UUID>, now: Date) async throws {
        let read: ReminderListRead
        do { read = try await access.readList() } catch {
            await log("error", "读不到提醒事项，这次没有同步提醒（也没有把任何提醒当成你删的）：\(error.localizedDescription)")
            throw error
        }
        if drafts.isEmpty, !read.found { return }   // 没东西要写、列表也不存在：别为此建列表
        let ledger = await loadLedger()
        if !read.found, !ledger.entries.isEmpty {
            await log("warn", "没找到 BetterCalendar 的提醒列表「\(access.listName)」（可能被删掉或改了名）：之前写过的提醒这次不重建")
        }
        let existing = read.items
        let plan = ReminderSyncPlanner.plan(existing: existing, drafts: drafts, scope: scope, now: now,
                                            ledger: ledger, deviceId: deviceId, listFound: read.found)
        var changes = ReminderListChanges()
        for u in plan.updates {
            guard let id = existing[u.index].itemID else { continue }
            changes.updates.append(ReminderItemUpdate(itemID: id, draft: u.draft, keepTime: plan.keepTime.contains(u.index)))
        }
        changes.creates = plan.creates
        changes.deletes = plan.deletes.compactMap { existing[$0].itemID }
        do { try await access.apply(changes) } catch {
            await log("error", "提醒事项没写成：\(error.localizedDescription)")
            throw error
        }
        if let l = plan.ledger { ledgerStore.save(l) }
        await deliver(plan.userOps)
        if !plan.heldBack.isEmpty {
            await log("info", "这些提醒写过、但这台设备还没见过、现在也读不到（可能还没同步过来，或你删了）：先不重建——" + plan.heldBack.joined(separator: "、"))
        }
        await log("info", "提醒事项「\(access.listName)」：新建 \(plan.creates.count) · 更新 \(plan.updates.count) · 移除 \(plan.deletes.count)"
                  + (plan.keepTime.isEmpty ? "" : "（\(plan.keepTime.count) 条保留你改的时间）"))
    }

    /// 「被动完成」信号（0.25.4 根治）：**今天打勾完成 且 带本 App 身份章**的提醒 → 返回其 blockID。
    /// 双闸门：①按 blockID 精确匹配（不按标题——同名任务不再串）②只认今天完成（不翻旧账）。读失败 = 空集 + 可见警告。
    func completedBlockIDs() async -> Set<UUID> {
        let read: ReminderListRead
        do { read = try await access.readList() } catch {
            await log("warn", "读不到提醒事项，这次没看打勾：\(error.localizedDescription)")
            return []
        }
        let now = clock()
        return Set(read.items
            .filter { $0.isCompleted && ($0.completionDate.map { DayContext.isSameLogicalDay($0, now) } ?? false) }
            .compactMap { EventKitCalendarStore.blockID(from: $0.url) })
    }

    /// App 内完成 → 回勾对应提醒事项（双向：App→提醒事项）。账本同时记下「是 BetterCalendar 勾的」，免得之后误当成你勾的。
    func markCompleted(blockIDs: Set<UUID>) async {
        guard !blockIDs.isEmpty else { return }
        let read: ReminderListRead
        do { read = try await access.readList() } catch {
            await log("warn", "读不到提醒事项，没能把做完的事同步勾掉：\(error.localizedDescription)")
            return
        }
        let targets = read.items.filter { r in
            !r.isCompleted && (EventKitCalendarStore.blockID(from: r.url).map(blockIDs.contains) ?? false)
        }
        guard !targets.isEmpty else { return }
        do { try await access.apply(ReminderListChanges(completes: targets.compactMap(\.itemID))) } catch {
            await log("warn", "没能把做完的事在提醒事项里勾掉：\(error.localizedDescription)")
            return
        }
        var ledger = await loadLedger()
        let now = clock()
        for r in targets { if let k = ReminderStamp.key(r.url) { ledger.entries[k]?.completedAt = now } }
        ledgerStore.save(ledger)
        await log("info", "回勾完成的提醒事项（App→提醒事项）\(targets.count) 条")
    }

    /// 跟上你在提醒事项里的操作（打勾 / 改时间 / 改文字 / 删除）。读失败 = 这次不判断（report.error）。
    func followUserChanges(now: Date) async -> ReminderFollowReport {
        let read: ReminderListRead
        do { read = try await access.readList() } catch {
            let message = "读不到提醒事项，这次没跟进你在提醒事项里的改动：\(error.localizedDescription)"
            await log("warn", message)
            return ReminderFollowReport(error: message)
        }
        guard read.found else { return ReminderFollowReport() }
        let ledger = await loadLedger()
        guard !ledger.entries.isEmpty else { return ReminderFollowReport() }
        let followed = ReminderFollowPlanner.follow(existing: read.items, ledger: ledger, deviceId: deviceId, now: now)
        if followed.ledger != ledger { ledgerStore.save(followed.ledger) }
        await deliver(followed.ops)
        return ReminderFollowReport(ops: followed.ops)
    }

    /// 某日历日到期、未完成的提醒标题（你自己的列表）——给排程当上下文。读失败 = 空 + 可见警告。
    func dueReminders(on day: Date) async -> [String] {
        do {
            return try await access.readOwnOpenReminders(requestAccess: true)
                .filter { $0.due.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
                .map(\.title)
        } catch {
            await log("warn", "读不到你的提醒事项，排程这次没参考它：\(error.localizedDescription)")
            return []
        }
    }

    /// 你自己列表里没完成的提醒（只读，不弹权限框）：有截止的按时间在前，没截止的在后。
    func ownOpenReminders() async throws -> [OwnReminder] {
        try await access.readOwnOpenReminders(requestAccess: false).sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): a < b
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): $0.title < $1.title
            }
        }
    }

    // MARK: AskReminderProjecting（「几点提醒我」）

    static func askRevision(title: String, fireAt: Date?) -> String {
        ProposalRevision.hash(["ask", title, ReminderProjection.wallKey(fireAt) ?? "-"])
    }

    func addAskReminder(id: UUID, title: String, body: String?, fireAt: Date) async throws -> AskReminderReceipt {
        let read: ReminderListRead
        do { read = try await access.readList() } catch let ReminderAccessError.notAuthorized(why) {
            throw AskReminderError.noAccess(why)
        } catch {
            throw AskReminderError.failed("读提醒事项失败：\(error.localizedDescription)")
        }
        guard let reach = read.reach else { throw AskReminderError.failed("找不到可以写提醒的账户") }
        guard reach.syncsAcrossDevices else { throw AskReminderError.thisDeviceOnly(sourceName: reach.sourceName) }
        guard let stamp = ReminderStamp.askURL(id), let key = ReminderStamp.key(stamp) else { throw AskReminderError.failed("提醒 id 无效") }
        if let same = read.items.first(where: { ReminderStamp.key($0.url) == key }) {   // 幂等：执行重放不写第二条
            return AskReminderReceipt(revision: Self.askRevision(title: same.title, fireAt: same.due), sourceName: reach.sourceName)
        }
        let draft = ReminderDraft(title: title, due: fireAt, priority: 0, notes: body, leadMinutes: 0, stamp: stamp)
        do { try await access.apply(ReminderListChanges(creates: [draft])) } catch {
            throw AskReminderError.failed("没写进提醒事项：\(error.localizedDescription)")
        }
        let now = clock()
        var ledger = await loadLedger()
        ledger.entries[key] = .written(draft, kind: .ask, by: deviceId, at: now)
        ledger.prune(now: now)
        ledgerStore.save(ledger)
        await log("info", "已写进提醒事项「\(access.listName)」（\(reach.sourceName)）：\(ReminderProjection.when(fireAt))「\(title)」")
        return AskReminderReceipt(revision: Self.askRevision(title: title, fireAt: fireAt), sourceName: reach.sourceName)
    }

    func removeAskReminder(id: UUID, expectedRevision: String?) async throws -> String {
        let read: ReminderListRead
        do { read = try await access.readList() } catch {
            throw AskReminderError.failed("读不到提醒事项，没有撤销：\(error.localizedDescription)")
        }
        guard let key = ReminderStamp.key(ReminderStamp.askURL(id)) else { throw AskReminderError.failed("提醒 id 无效") }
        var ledger = await loadLedger()
        let copies = read.items.filter { ReminderStamp.key($0.url) == key }
        guard let r = copies.first(where: { !$0.isCompleted }) ?? copies.first else {
            if ledger.entries[key]?.dismissedAt != nil { return "你已经在提醒事项里删掉了这条提醒" }
            throw AskReminderError.conflict("这台设备的提醒事项里找不到这条提醒（可能还没同步过来，或已经被删掉），没有撤销")
        }
        if r.isCompleted { throw AskReminderError.conflict("你已经在提醒事项里勾掉了这条提醒，没有删") }
        if let expectedRevision, Self.askRevision(title: r.title, fireAt: r.due) != expectedRevision {
            throw AskReminderError.conflict("你在提醒事项里改过这条提醒（标题或时间），按你的为准，没有删")
        }
        do { try await access.apply(ReminderListChanges(deletes: copies.compactMap(\.itemID))) } catch {
            throw AskReminderError.failed("没能从提醒事项里删掉：\(error.localizedDescription)")
        }
        ledger.entries[key]?.retiredAt = clock()
        ledgerStore.save(ledger)
        await log("info", "撤销：已从提醒事项里删掉「\(r.title)」")
        return "已从提醒事项里删掉这条提醒"
    }

    // MARK: 内部

    /// 账本读不出（格式坏了）→ 可见报错并从空账本重来（删过的提醒可能被重建一次——所以必须报出来）。
    private func loadLedger() async -> ReminderProjectionLedger {
        do { return try ledgerStore.load() } catch {
            await log("error", "提醒投影账本读不出（\(error.localizedDescription)）：从头记起，你之前删过 / 改过的提醒这次可能认不出来")
            return ReminderProjectionLedger()
        }
    }

    private func deliver(_ ops: [ReminderUserOp]) async {
        guard !ops.isEmpty else { return }
        for op in ops { await log("info", op.line) }
        await opsSink?(ops)
    }
}
