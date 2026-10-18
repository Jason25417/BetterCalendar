//
//  ReminderProjection.swift
//  BetterCalendar
//
//  W12（SPEC §19.13 Q5，Jason 2026-10-18 定）：提醒事项 = BetterCalendar 自己东西的**原生展示面**，不是第二个真相源，
//  也没有独立的提醒数据库。BetterCalendar 只保留一本提醒列表当展示容器（和它自己的日历一样）。
//  投影范围 = 最小集（只投「有时间点、必须在 App 外找到你」的东西，没时间点的一律不投）：
//    (a) 计划块 / 待办池条目上的截止时间（HomeViewModel.confirm → ReminderStore.sync）；
//    (b) 一次性的「几点提醒我」（你说的，或你批准的智能体提案）——两台设备都会响。
//  不投：计划块本身（日历里已有，再投会重复响）、没截止的待办/长期事项、实际/计时/日记/复盘/对话、内部数据。
//
//  你在提醒事项里的操作 = 你的操作（原则 8：你的操作 > 你批准的提案 > 自动调整），BetterCalendar 跟上并记下、绝不改回：
//    - 打勾 → 对应的事算做成了（块：已有 completedBlockIDs 路径；待办池截止：标完成）；
//    - 改时间 → 当成新的提醒时刻（截止时间不变），下次同步不改回；
//    - 删除 →「不用提醒我了」：只去掉这件事的提醒，这件事本身保留；下次同步不重建；
//    - 你自己的列表 / 没章的提醒：只读，从不修改。
//  本文件全是纯数据与纯函数（零 EventKit），可单测。
//

import Foundation

/// 投影的种类（由章决定）。
nonisolated enum ReminderProjectionKind: String, Codable, Sendable {
    /// 计划块的截止时间
    case block
    /// 待办池条目的截止时间
    case pool
    /// 一次性的「几点提醒我」
    case ask
}

/// 账本里的一条：BetterCalendar 上次写进提醒事项的样子 + 你在提醒事项里对它做过什么。
nonisolated struct ReminderProjectionEntry: Codable, Equatable, Sendable {
    var kind: ReminderProjectionKind
    // —— BetterCalendar 上次写进去的样子（三方比较的「基线」）——
    var title: String
    var notes: String?
    var priority: Int
    /// 截止的墙上时间键（yyyyMMddHHmm，按写入设备的本地日历）。用墙上时间而不是绝对时刻：提醒的截止是「浮动时间」，
    /// 两台设备时区不同也读出同一个墙上时间，不会误判成「你改了时间」。
    var dueKey: String?
    var lead: Int?
    /// 截止的绝对时刻（只用于清理旧账与给人看）。
    var dueAt: Date?
    var writtenBy: String
    /// 见过它的设备（读到过）。只有亲眼见过、现在又读不到，才算你删了——没同步过来不算。
    var seenBy: [String] = []
    var updatedAt: Date
    // —— 你在提醒事项里的操作 ——
    /// 你改过时间：之后时间按你的（不改回）。
    var userTime = false
    var userDueKey: String? = nil
    var userLead: Int? = nil
    var userDueAt: Date? = nil
    /// 你改过标题 / 备注 / 优先级：之后保留你的写法。
    var userText = false
    /// 你删掉了 =「不用提醒我了」。
    var dismissedAt: Date? = nil
    /// 你打勾完成了。
    var completedAt: Date? = nil
    /// BetterCalendar 自己收回的（不再需要 / 过期 / 撤销）——不是你删的。
    var retiredAt: Date? = nil

    static func written(_ d: ReminderDraft, kind: ReminderProjectionKind, by device: String, at now: Date) -> ReminderProjectionEntry {
        var e = ReminderProjectionEntry(kind: kind, title: d.title, notes: d.notes, priority: d.priority,
                                        dueKey: ReminderProjection.wallKey(d.due), lead: d.due == nil ? nil : d.leadMinutes,
                                        dueAt: d.due, writtenBy: device, updatedAt: now)
        e.markSeen(device)
        return e
    }

    /// 记下 BetterCalendar 这次写进去的样子（时间保持你的那部分不覆盖基线）。
    mutating func recordWrite(_ d: ReminderDraft, keepTime: Bool, at now: Date) {
        title = d.title; notes = d.notes; priority = d.priority
        if !keepTime { dueKey = ReminderProjection.wallKey(d.due); lead = d.due == nil ? nil : d.leadMinutes; dueAt = d.due }
        updatedAt = now
    }

    mutating func markSeen(_ device: String) {
        guard !device.isEmpty, !seenBy.contains(device) else { return }
        seenBy.append(device)
    }

    /// 你现在定的提醒时刻（改过就是你的，否则是 BetterCalendar 写的）。
    var effectiveDueAt: Date? { userTime ? userDueAt : dueAt }
}

/// 投影账本：章（规范键）→ 条目。随 iCloud 设置同步（SettingsSync 白名单），两台设备看到同一份「你删过 / 改过什么」。
nonisolated struct ReminderProjectionLedger: Codable, Equatable, Sendable {
    var entries: [String: ReminderProjectionEntry] = [:]

    /// 旧账清理：提醒时刻过去 3 天、或 BetterCalendar 收回 3 天以上的条目删掉（账本要小：iCloud 设置有容量上限）。
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-3 * 86_400)
        entries = entries.filter { _, e in
            if let r = e.retiredAt, r < cutoff { return false }
            if let due = e.effectiveDueAt { return due >= cutoff }
            return e.updatedAt >= now.addingTimeInterval(-30 * 86_400)
        }
    }

    /// 你在提醒事项里删掉的（给智能体看：别再提议同一个提醒，除非你开口）。
    var dismissed: [ReminderProjectionEntry] { entries.values.filter { $0.dismissedAt != nil }.sorted { ($0.dismissedAt ?? .distantPast) > ($1.dismissedAt ?? .distantPast) } }
    /// 你在提醒事项里改过时间、还没删的。
    var retimed: [ReminderProjectionEntry] { entries.values.filter { $0.userTime && $0.dismissedAt == nil && $0.retiredAt == nil }.sorted { $0.updatedAt > $1.updatedAt } }
}

/// 你在提醒事项里做的一次操作（给日志 / 操作留底的一句白话）。
nonisolated struct ReminderUserOp: Equatable, Sendable {
    enum Kind: String, Sendable { case completed, retimed, edited, dismissed }
    var kind: Kind
    var stamp: String
    var projection: ReminderProjectionKind
    var title: String
    var line: String
    /// 打勾完成的时刻（只有 completed 有）。
    var completedAt: Date? = nil
}

nonisolated enum ReminderProjection {
    /// 墙上时间键（本地日历的年月日时分）。
    static func wallKey(_ d: Date?) -> String? {
        guard let d else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return String(format: "%04d%02d%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 「10月19日 08:00」。
    static func when(_ d: Date?) -> String {
        guard let d else { return "不带时间" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }
}

/// 跟上你在提醒事项里的操作（纯函数）：输入 = 这次读到的本列表 + 账本；输出 = 新账本 + 白话操作。
/// 前提：**读取成功**（读失败时上层不调用——绝不把读失败当成你删了）。
nonisolated enum ReminderFollowPlanner {
    static func follow(existing: [ReminderSnapshot], ledger: ReminderProjectionLedger, deviceId: String,
                       now: Date) -> (ledger: ReminderProjectionLedger, ops: [ReminderUserOp]) {
        var book = ledger
        var ops: [ReminderUserOp] = []
        var byKey: [String: [ReminderSnapshot]] = [:]
        for r in existing { if let k = ReminderStamp.key(r.url) { byKey[k, default: []].append(r) } }
        for key in ledger.entries.keys.sorted() {
            guard var e = book.entries[key], e.dismissedAt == nil, e.retiredAt == nil else { continue }
            let copies = byKey[key] ?? []
            guard !copies.isEmpty else {
                // 读得到列表、却没有这条：只有这台设备亲眼见过（或亲手写的）才算你删了；没见过 = 可能还没同步过来，先不下结论
                guard e.seenBy.contains(deviceId) || e.writtenBy == deviceId else { continue }
                if e.completedAt != nil {
                    e.retiredAt = now   // 勾完后清掉的：不算「不用提醒」，安静收账
                } else {
                    e.dismissedAt = now
                    ops.append(ReminderUserOp(kind: .dismissed, stamp: key, projection: e.kind, title: e.title,
                                              line: "你在提醒事项里删掉了「\(e.title)」的提醒：之后不再提醒，这件事本身还在"))
                }
                e.updatedAt = now
                book.entries[key] = e
                continue
            }
            e.markSeen(deviceId)
            let r = copies.first { !$0.isCompleted } ?? copies[0]
            if let done = copies.first(where: \.isCompleted), e.completedAt == nil {
                e.completedAt = done.completionDate ?? now
                ops.append(ReminderUserOp(kind: .completed, stamp: key, projection: e.kind, title: e.title,
                                          line: "你在提醒事项里勾掉了「\(e.title)」", completedAt: done.completionDate ?? now))
            }
            if !r.isCompleted {
                let dueKey = ReminderProjection.wallKey(r.due)
                let lead = r.due == nil ? nil : r.leadMinutes
                let base = e.userTime ? (e.userDueKey, e.userLead) : (e.dueKey, e.lead)
                if dueKey != base.0 || lead != base.1 {
                    e.userTime = true; e.userDueKey = dueKey; e.userLead = lead; e.userDueAt = r.due
                    ops.append(ReminderUserOp(kind: .retimed, stamp: key, projection: e.kind, title: e.title,
                                              line: "你在提醒事项里把「\(e.title)」的提醒改到了 \(ReminderProjection.when(r.due))：之后按你的时间提醒"
                                                + (e.kind == .ask ? "" : "，截止时间不变")))
                }
                let textDiffers = r.title != e.title || (r.notes ?? "") != (e.notes ?? "") || r.priority != e.priority
                if textDiffers, !e.userText {
                    e.userText = true
                    ops.append(ReminderUserOp(kind: .edited, stamp: key, projection: e.kind, title: e.title,
                                              line: "你在提醒事项里改了「\(e.title)」的内容：之后保留你的写法"))
                }
            }
            book.entries[key] = e
        }
        return (book, ops)
    }
}

/// 账本的存取：UserDefaults 里存 JSON 字符串（plist 类型，可进 iCloud 设置同步；SettingsSync 白名单含 `key`）。
nonisolated struct ReminderProjectionLedgerStore: @unchecked Sendable {
    static let key = "reminder.projection.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// 读不出（格式坏了）→ 抛错，由调用方可见地报出来（不静默当成空账本）。
    func load() throws -> ReminderProjectionLedger {
        guard let s = defaults.string(forKey: Self.key), let data = s.data(using: .utf8) else { return ReminderProjectionLedger() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReminderProjectionLedger.self, from: data)
    }

    func save(_ ledger: ReminderProjectionLedger) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(ledger), let s = String(data: data, encoding: .utf8) else { return }
        if defaults.string(forKey: Self.key) != s { defaults.set(s, forKey: Self.key) }
    }
}
