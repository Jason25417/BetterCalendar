//
//  ReminderSyncPlanner.swift
//  BetterCalendar
//
//  提醒事项按章差量写入的「决定」部分（P4.0-9，2026-10-18）：纯函数、零 EventKit，可单测。
//  修 B9：旧实现每次确认先删掉专用列表里**所有**未完成提醒再整批重写——别的日子的提醒、你在提醒事项里
//  改过的、你手动加进这个列表的都会被删。现在：
//  · 只碰带 BetterCalendar 章的提醒（无章=你的，永不删改）；
//  · 按章配对：有就就地更新（不删重建），没有才新建；你已打勾完成的不再重建；
//  · 删除只限两种：这次确认负责的块（scope）里已经不需要提醒的；或已经过了截止时间、还没完成的旧提醒。
//    别的日子的提醒原样保留。
//  W12（SPEC §19.13 Q5，原则 8「谁的东西谁做主」）：提醒事项只是 BetterCalendar 的原生展示面。你在提醒事项里的操作是你的：
//  · 你改了时间 → 之后按你的时间提醒，下次同步绝不改回（截止时间本身不变）；你改了文字也一样保留；
//  · 你删了 →「不用提醒我了」：不再重建（这件事本身保留）；
//  · 判断依据 = 投影账本（ReminderProjectionLedger：BetterCalendar 上次写进去的样子，随 iCloud 设置同步）。
//    「读失败」不会走到这里：读不到时上层直接报错、不调用本函数（绝不把读失败当成你删了）。
//

import Foundation

/// 提醒的身份章。块提醒 = 块章 `bettercalendar://block/<UUID>`；
/// 待办池截止提醒没有块 id → 按标题的稳定章 `bettercalendar://reminder/pool/<hash>`（P4.0-9：此前无章，每确认一次多一条）；
/// W12「几点提醒我」→ `bettercalendar://reminder/ask/<提醒 id>`（审批卡上那条提醒的 id，撤销按它找回）。
nonisolated enum ReminderStamp {
    static func url(for draft: ReminderDraft) -> URL? {
        if let stamp = draft.stamp { return stamp }
        if let bid = draft.blockID { return EventKitCalendarStore.stampURL(bid) }
        return poolURL(title: draft.title)
    }

    static func poolURL(title: String) -> URL? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // FNV-1a 64：跨进程/跨设备稳定（Swift 的 hashValue 每次启动随机，不能用）
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return URL(string: "bettercalendar://reminder/pool/\(String(hash, radix: 16))")
    }

    /// W12：「几点提醒我」的章（id = 提案里那条提醒的 id）。
    static func askURL(_ id: UUID) -> URL? {
        URL(string: "bettercalendar://reminder/ask/\(id.uuidString)")
    }

    /// 是不是 BetterCalendar 写的（任何 bettercalendar:// 章）。
    static func isOurs(_ url: URL?) -> Bool { url?.scheme == "bettercalendar" }

    /// 配对用的规范键：块章忽略 v2 查询参数（与日历章同一套解析）；其余 = host + path。非本 App 的 URL → nil。
    static func key(_ url: URL?) -> String? {
        guard let url, isOurs(url) else { return nil }
        if let bid = EventKitCalendarStore.blockID(from: url) { return "block/" + bid.uuidString }
        return (url.host ?? "") + url.path
    }

    /// 这条章是哪一类投影。
    static func kind(_ url: URL?) -> ReminderProjectionKind? {
        guard let k = key(url) else { return nil }
        if k.hasPrefix("block/") { return .block }
        if k.hasPrefix("reminder/pool/") { return .pool }
        if k.hasPrefix("reminder/ask/") { return .ask }
        return nil
    }

    /// 「几点提醒我」章 → 提醒 id。
    static func askID(from url: URL?) -> UUID? {
        guard let k = key(url), k.hasPrefix("reminder/ask/") else { return nil }
        return UUID(uuidString: String(k.dropFirst("reminder/ask/".count)))
    }
}

/// 现有提醒的只读快照（EventKit 侧负责填）。
nonisolated struct ReminderSnapshot: Equatable, Sendable {
    var url: URL?
    var isCompleted: Bool
    var title: String
    var notes: String?
    var priority: Int
    var due: Date?
    /// 第一条提醒的提前分钟（nil = 无提醒）。
    var leadMinutes: Int?
    var creationDate: Date?
    var externalID: String?
    /// W12：本机定位这条提醒用的 id（EventKit calendarItemIdentifier）；写回 / 删除按它找。
    var itemID: String? = nil
    /// W12：打勾完成的时刻（只认今天打勾的完成信号）。
    var completionDate: Date? = nil
}

nonisolated struct ReminderSyncPlan: Sendable {
    var updates: [(index: Int, draft: ReminderDraft)] = []
    var creates: [ReminderDraft] = []
    /// 只会是带章、未完成的提醒。
    var deletes: [Int] = []
    /// W12：这些更新不碰时间（你在提醒事项里改过时间 → 截止与提醒时刻保持你的）。
    var keepTime: Set<Int> = []
    /// W12：同步后的投影账本（nil = 调用方没给账本，按 P4.0-9 旧规则）。
    var ledger: ReminderProjectionLedger? = nil
    /// W12：这次读到的、你在提醒事项里做过的操作（给日志 / 操作留底写一句白话）。
    var userOps: [ReminderUserOp] = []
    /// W12：写过、但这台设备从没见过、现在也读不到的（可能还没同步过来，也可能你删了）——这次先不重建、也不当成删除。
    var heldBack: [String] = []
}

nonisolated enum ReminderSyncPlanner {
    /// - scope：这次确认「负责」的块 id（确认涉及的逻辑日上、确认前后的所有块）——其中不再需要提醒的才删。
    /// - now：已过截止、仍未完成的带章旧提醒顺手清掉（与旧行为一致的子集）。
    /// - ledger（W12）：投影账本；nil = 不知道上次写了什么，按 P4.0-9 旧规则（就地更新、缺了就建）。
    /// - listFound（W12）：列表是否找到了。没找到（不存在 / 被改名）时不判断你删了什么，写过的也先不重建。
    static func plan(existing: [ReminderSnapshot], drafts: [ReminderDraft],
                     scope: Set<UUID>, now: Date,
                     ledger: ReminderProjectionLedger? = nil, deviceId: String = "",
                     listFound: Bool = true) -> ReminderSyncPlan {
        var plan = ReminderSyncPlan()
        // W12 第一步：先跟上你在提醒事项里的操作（打勾 / 改时间 / 改文字 / 删除）
        var book = ledger
        if let l = ledger, listFound {
            let followed = ReminderFollowPlanner.follow(existing: existing, ledger: l, deviceId: deviceId, now: now)
            book = followed.ledger
            plan.userOps = followed.ops
        }
        var copies: [String: [Int]] = [:]
        for (i, r) in existing.enumerated() {
            guard let k = ReminderStamp.key(r.url) else { continue }
            copies[k, default: []].append(i)
        }
        for (k, idx) in copies {
            copies[k] = idx.sorted { a, b in
                CalendarSyncPlanner.keeperPrecedes(
                    CalendarEventSnapshot(title: "", start: .distantPast, end: .distantPast,
                                          creationDate: existing[a].creationDate, externalID: existing[a].externalID), a,
                    CalendarEventSnapshot(title: "", start: .distantPast, end: .distantPast,
                                          creationDate: existing[b].creationDate, externalID: existing[b].externalID), b)
            }
        }
        var matched = Set<Int>()
        var handledStamps = Set<String>()
        for d in drafts {
            guard let stampURL = ReminderStamp.url(for: d), let stamp = ReminderStamp.key(stampURL),
                  handledStamps.insert(stamp).inserted
            else { continue }   // 同章草稿只处理一次（两个同名池任务不写两条）
            let list = copies[stamp] ?? []
            matched.formUnion(list)
            let kind = ReminderStamp.kind(stampURL) ?? .block
            let entry = book?.entries[stamp]
            // 你在提醒事项里删过 =「不用提醒我了」：不重建、不改（这件事本身在 BetterCalendar 里照旧）
            if entry?.dismissedAt != nil { continue }
            guard !list.isEmpty else {
                // 写过、还在账上，现在却读不到——这台设备从没见过（还没同步过来？）或列表没找到：先不重建，也不当成删除
                if let entry, entry.retiredAt == nil {
                    plan.heldBack.append(entry.title)
                    continue
                }
                plan.creates.append(d)
                if book != nil { book?.entries[stamp] = .written(d, kind: kind, by: deviceId, at: now) }
                continue
            }
            if list.contains(where: { existing[$0].isCompleted }) { continue }   // 你已打勾完成：不重建、不改
            let keeper = list[0]
            // 你改过的部分保留你的（时间 / 文字），其余跟着 BetterCalendar 走
            var merged = d
            let keep = entry?.userTime == true
            if entry?.userText == true {
                merged.title = existing[keeper].title
                merged.notes = existing[keeper].notes
                merged.priority = existing[keeper].priority
            }
            if needsUpdate(existing[keeper], merged, keepTime: keep) {
                plan.updates.append((keeper, merged))
                if keep { plan.keepTime.insert(keeper) }
            }
            plan.deletes.append(contentsOf: list.dropFirst())   // 同章重复的未完成副本收敛成一条
            if book != nil {
                // 账上没有（升级前写的 / 账本还没同步到）= 不知道上次写了什么：按旧规则采用这次写的样子
                var e = entry ?? .written(d, kind: kind, by: deviceId, at: now)
                e.recordWrite(merged, keepTime: keep, at: now)
                e.retiredAt = nil
                e.markSeen(deviceId)
                book?.entries[stamp] = e
            }
        }
        for (i, r) in existing.enumerated() where !matched.contains(i) && !r.isCompleted && ReminderStamp.isOurs(r.url) {
            let key = ReminderStamp.key(r.url)
            let entry = key.flatMap { book?.entries[$0] }
            // 「几点提醒我」不随确认清理（不是从计划算出来的；过了时刻也留着，像普通提醒一样等你勾）
            if ReminderStamp.kind(r.url) == .ask { continue }
            // 你改过时间的 = 你定的提醒时刻：不因计划变化被收回，只在过了你的时刻后清理
            let inScope = entry?.userTime == true ? false
                : (EventKitCalendarStore.blockID(from: r.url).map(scope.contains) ?? false)
            let expired = r.due.map { $0 < now } ?? false
            if inScope || expired {
                plan.deletes.append(i)
                if let key, let e = book?.entries[key], e.dismissedAt == nil {
                    book?.entries[key]?.retiredAt = now   // BetterCalendar 自己收回的：不是你删的
                }
            }
        }
        if var b = book { b.prune(now: now); plan.ledger = b }
        return plan
    }

    static func minute(_ d: Date?) -> Int? { d.map { Int(($0.timeIntervalSinceReferenceDate / 60).rounded(.down)) } }

    private static func needsUpdate(_ r: ReminderSnapshot, _ d: ReminderDraft, keepTime: Bool) -> Bool {
        let wantLead = d.due == nil ? nil : d.leadMinutes
        let timeDiffers = !keepTime && (minute(r.due) != minute(d.due) || r.leadMinutes != wantLead)
        return r.title != d.title || (r.notes ?? "") != (d.notes ?? "") || r.priority != d.priority
            || timeDiffers || r.url != ReminderStamp.url(for: d)
    }
}
