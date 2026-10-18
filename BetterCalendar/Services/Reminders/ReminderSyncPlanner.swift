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
//

import Foundation

/// 提醒的身份章。块提醒 = 块章 `bettercalendar://block/<UUID>`；
/// 待办池截止提醒没有块 id → 按标题的稳定章 `bettercalendar://reminder/pool/<hash>`（P4.0-9：此前无章，每确认一次多一条）。
nonisolated enum ReminderStamp {
    static func url(for draft: ReminderDraft) -> URL? {
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

    /// 是不是 BetterCalendar 写的（任何 bettercalendar:// 章）。
    static func isOurs(_ url: URL?) -> Bool { url?.scheme == "bettercalendar" }
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
}

nonisolated struct ReminderSyncPlan: Sendable {
    var updates: [(index: Int, draft: ReminderDraft)] = []
    var creates: [ReminderDraft] = []
    /// 只会是带章、未完成的提醒。
    var deletes: [Int] = []
}

nonisolated enum ReminderSyncPlanner {
    /// - scope：这次确认「负责」的块 id（确认涉及的逻辑日上、确认前后的所有块）——其中不再需要提醒的才删。
    /// - now：已过截止、仍未完成的带章旧提醒顺手清掉（与旧行为一致的子集）。
    static func plan(existing: [ReminderSnapshot], drafts: [ReminderDraft],
                     scope: Set<UUID>, now: Date) -> ReminderSyncPlan {
        var plan = ReminderSyncPlan()
        var copies: [String: [Int]] = [:]
        for (i, r) in existing.enumerated() where ReminderStamp.isOurs(r.url) {
            copies[r.url!.absoluteString, default: []].append(i)
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
            guard let stamp = ReminderStamp.url(for: d)?.absoluteString, handledStamps.insert(stamp).inserted
            else { continue }   // 同章草稿只处理一次（两个同名池任务不写两条）
            let list = copies[stamp] ?? []
            guard !list.isEmpty else { plan.creates.append(d); continue }
            matched.formUnion(list)
            if list.contains(where: { existing[$0].isCompleted }) { continue }   // 你已打勾完成：不重建、不改
            let keeper = list[0]
            if needsUpdate(existing[keeper], d) { plan.updates.append((keeper, d)) }
            plan.deletes.append(contentsOf: list.dropFirst())   // 同章重复的未完成副本收敛成一条
        }
        for (i, r) in existing.enumerated() where !matched.contains(i) && !r.isCompleted && ReminderStamp.isOurs(r.url) {
            let inScope = EventKitCalendarStore.blockID(from: r.url).map(scope.contains) ?? false
            let expired = r.due.map { $0 < now } ?? false
            if inScope || expired { plan.deletes.append(i) }
        }
        return plan
    }

    private static func minute(_ d: Date?) -> Int? { d.map { Int($0.timeIntervalSinceReferenceDate / 60) } }

    private static func needsUpdate(_ r: ReminderSnapshot, _ d: ReminderDraft) -> Bool {
        let wantLead = d.due == nil ? nil : d.leadMinutes
        return r.title != d.title || (r.notes ?? "") != (d.notes ?? "") || r.priority != d.priority
            || minute(r.due) != minute(d.due) || r.leadMinutes != wantLead
            || r.url != ReminderStamp.url(for: d)
    }
}
