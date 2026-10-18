//
//  CalendarSyncPlanner.swift
//  BetterCalendar
//
//  日历差量对齐的「决定」部分（P4.0 止血，2026-10-18）：纯函数、零 EventKit。
//  EventKitCalendarStore 只负责把 EKEvent 变成快照、再按这里给出的清单执行增删改。
//  抽出来的原因：下面三条铁律必须能用假数据单测锁住（测试不能碰真日历）——
//  ① 永不删除、永不修改没有 BetterCalendar 章的事件（P4.0-1 / B1）：哪怕它落在我们自己的日历里，
//     也是用户的东西（真机：一个重复课程系列被误删 12 次）；
//  ② 不再按「标题＋起始分钟」认领无章事件（D2）：只有用户明确选了「加进计划」的那一件，
//     草稿才带 claimsUnstamped 去认领并补章；
//  ③ 同一个章出现多份时，保留哪一份是**确定性**的（P4.0-2 / B8）：按创建时间最早、再按外部标识
//     排序——Mac 和 iPhone 算出来一样，不会各删一份、结果两份都没了。
//

import Foundation

/// 日历里一个现有事件的只读快照（实现无关；EventKit 侧负责填）。
nonisolated struct CalendarEventSnapshot: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var notes: String?
    var hasAlarm: Bool = false
    /// 事件 URL 章里的块 id；nil = 不是 BetterCalendar 写的（用户的事件）。
    var blockID: UUID?
    /// 同章去重的确定性排序键（两台设备看到的值相同：随 iCloud 日历同步）。
    var creationDate: Date?
    var externalID: String?
    /// 章 v2（CalendarStamp）：旧章/无章 = nil。
    var stampVersion: Int64? = nil
    var stampHash: String? = nil
}

/// 对齐清单：执行方按 index 回指原事件数组。
nonisolated struct CalendarSyncPlan: Sendable {
    struct Update: Sendable {
        var index: Int
        var draft: CalendarEventDraft
        /// 需要（补）盖章：仅用户明确「加进计划」的无章事件被认领时为 true。
        var stamp: Bool
    }
    var updates: [Update] = []
    var creates: [CalendarEventDraft] = []
    /// 只会是带章事件的 index（铁律①）。
    var deletes: [Int] = []
    /// 范围内、没被认领的无章事件——原样保留（执行方只记日志）。
    var keptForeign: [Int] = []
    /// 无章草稿：BetterCalendar 不写无章事件。能对上现有无章事件的=原样不动；对不上的被丢弃（记日志）。
    var droppedUnstampedDrafts: [CalendarEventDraft] = []
}

nonisolated enum CalendarSyncPlanner {
    /// 时间差小于它视为没变（与历史实现一致：30 秒）。
    static let timeTolerance: TimeInterval = 30

    /// 范围内（事件 start ∈ [lo, hi)）该日历的事件与 drafts 对齐。
    /// 匹配：带章草稿按章找现有事件（同章多份时：单草稿→确定性保留者；多草稿→先按内容精确配对）；
    /// 找不到且草稿 claimsUnstamped → 认领一个同「标题＋起始分钟」的无章事件并补章；否则新建。
    /// 删除：只删**带章**且没被配上的事件，且 start 必须在范围内（跨界的邻日事件不动）。
    static func plan(existing: [CalendarEventSnapshot], drafts: [CalendarEventDraft],
                     from lo: Date, to hi: Date) -> CalendarSyncPlan {
        var plan = CalendarSyncPlan()
        var copiesByID: [UUID: [Int]] = [:]
        var unstampedByKey: [String: [Int]] = [:]
        for (i, e) in existing.enumerated() {
            if let bid = e.blockID { copiesByID[bid, default: []].append(i) }
            else { unstampedByKey[claimKey(e.title, e.start), default: []].append(i) }
        }
        for (bid, idx) in copiesByID {
            copiesByID[bid] = idx.sorted { keeperPrecedes(existing[$0], $0, existing[$1], $1) }
        }
        let draftsPerID = Dictionary(grouping: drafts.compactMap(\.blockID), by: { $0 }).mapValues(\.count)
        var matched = Set<Int>()

        for d in drafts {
            guard let bid = d.blockID else {
                // 无章草稿（读回再合并写回的副本）：对得上就原样不动，对不上就不写——BetterCalendar 只写带章事件
                if let i = unstampedByKey[claimKey(d.title, d.start)]?.first(where: { !matched.contains($0) }) {
                    matched.insert(i)
                } else {
                    plan.droppedUnstampedDrafts.append(d)
                }
                continue
            }
            let candidates = (copiesByID[bid] ?? []).filter { !matched.contains($0) }
            var target: Int?
            var stamp = false
            if (draftsPerID[bid] ?? 0) > 1 {
                // 同章多草稿（投影把对方设备的事件原样带过来）：先按内容精确配对，保证原样保留不互相覆盖
                target = candidates.first { sameContent(existing[$0], d) } ?? candidates.first
            } else {
                target = candidates.first   // 确定性保留者（两端一致）
            }
            if target == nil, d.claimsUnstamped,
               let i = unstampedByKey[claimKey(d.title, d.start)]?.first(where: { !matched.contains($0) }) {
                target = i; stamp = true
            }
            guard let i = target else { plan.creates.append(d); continue }
            matched.insert(i)
            if stamp || needsUpdate(existing[i], d) {
                plan.updates.append(.init(index: i, draft: d, stamp: stamp))
            }
        }

        for (i, e) in existing.enumerated() where !matched.contains(i) && e.start >= lo && e.start < hi {
            if e.blockID != nil { plan.deletes.append(i) } else { plan.keptForeign.append(i) }
        }
        return plan
    }

    /// 同章多份时谁是保留者（确定性）：创建时间早者先；再按外部标识字典序；都缺时退回原始顺序。
    static func keeperPrecedes(_ a: CalendarEventSnapshot, _ ai: Int,
                               _ b: CalendarEventSnapshot, _ bi: Int) -> Bool {
        let ca = a.creationDate ?? .distantFuture, cb = b.creationDate ?? .distantFuture
        if ca != cb { return ca < cb }
        switch (a.externalID, b.externalID) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return ai < bi
        }
    }

    /// 同章多份的保留者（对账 diff 与写入共用同一条规则）。
    static func keeper(_ copies: [CalendarEventDraft]) -> CalendarEventDraft? {
        copies.enumerated().min { l, r in
            keeperPrecedes(snapshot(l.element), l.offset, snapshot(r.element), r.offset)
        }?.element
    }

    static func snapshot(_ d: CalendarEventDraft) -> CalendarEventSnapshot {
        CalendarEventSnapshot(title: d.title, start: d.start, end: d.end, notes: d.notes,
                              hasAlarm: d.alarmLeadMinutes != nil, blockID: d.blockID,
                              creationDate: d.creationDate, externalID: d.externalID,
                              stampVersion: d.stampVersion, stampHash: d.stampHash)
    }

    static func claimKey(_ title: String, _ start: Date) -> String {
        "\(title)#\(Int(start.timeIntervalSinceReferenceDate / 60))"
    }

    private static func sameContent(_ e: CalendarEventSnapshot, _ d: CalendarEventDraft) -> Bool {
        e.title == d.title && abs(e.start.timeIntervalSince(d.start)) < timeTolerance
            && abs(e.end.timeIntervalSince(d.end)) < timeTolerance
    }

    private static func needsUpdate(_ e: CalendarEventSnapshot, _ d: CalendarEventDraft) -> Bool {
        !sameContent(e, d) || (e.notes ?? "") != (d.notes ?? "")
            || e.hasAlarm != (d.alarmLeadMinutes != nil)   // 普通块不弹提醒；固定块挂会前提醒
            // 章 v2：草稿带新版本/指纹而事件上的章不同（旧章补章、版本更新后重盖）→ 改章。不带 v2 的草稿（蓝色等）不动章。
            || (d.stampHash != nil && (e.stampHash != d.stampHash || e.stampVersion != d.stampVersion))
    }
}
