//
//  EventKitReminderStore.swift
//  BetterCalendar
//
//  真 Apple「提醒事项」的**薄读写层**（M3 起；W12 拆薄）：只负责把 EKReminder ↔ 快照/草稿互转、读写 BetterCalendar
//  自己那本列表、只读你自己的列表。要不要建/改/删、你的操作怎么跟，全在 ReminderProjector + 纯函数里（可单测）。
//  ⚠️ 只写标准字段（标题/备注/截止/优先级/提醒时刻/URL 章）；子任务/标签/旗标等私有 ReminderKit 不可写。需提醒事项 full access。
//  ⚠️ 读失败必须抛错（W12）：系统读不到时绝不返回空数组——空数组会被当成「你把提醒都删了」。
//

import Foundation
import EventKit

/// 一本提醒列表在哪个账户里、会不会同步到别的设备。
nonisolated struct ReminderListReach: Equatable, Sendable {
    var sourceName: String
    /// 本地账户（「在我的 Mac 上 / 在我的 iPhone 上」）= false：只在这台设备上。
    var syncsAcrossDevices: Bool
}

/// 读 BetterCalendar 那本列表的结果：列表不存在 ≠ 列表是空的。
nonisolated enum ReminderListRead: Sendable {
    /// 列表还不存在（或被改名 / 删掉）。reach = 新建时会落在哪个账户（nil = 找不到可写的账户）。
    case missing(reach: ReminderListReach?)
    case list(items: [ReminderSnapshot], reach: ReminderListReach)

    var items: [ReminderSnapshot] { if case let .list(items, _) = self { items } else { [] } }
    var found: Bool { if case .list = self { true } else { false } }
    var reach: ReminderListReach? {
        switch self {
        case let .missing(reach): reach
        case let .list(_, reach): reach
        }
    }
}

nonisolated struct ReminderItemUpdate: Sendable {
    var itemID: String
    var draft: ReminderDraft
    /// 不碰截止与提醒时刻（你在提醒事项里改过时间）。
    var keepTime: Bool
}

/// 一次写回 BetterCalendar 列表的改动（按 itemID 定位）。
nonisolated struct ReminderListChanges: Sendable {
    var updates: [ReminderItemUpdate] = []
    var creates: [ReminderDraft] = []
    var deletes: [String] = []
    var completes: [String] = []
    var isEmpty: Bool { updates.isEmpty && creates.isEmpty && deletes.isEmpty && completes.isEmpty }
    var count: Int { updates.count + creates.count + deletes.count + completes.count }
}

nonisolated enum ReminderAccessError: Error, LocalizedError, Equatable {
    case notAuthorized(String)
    case readFailed(String)
    case writeFailed(String)
    var errorDescription: String? {
        switch self {
        case let .notAuthorized(why), let .readFailed(why), let .writeFailed(why): why
        }
    }
}

/// 提醒事项的薄读写缝（生产 = EventKitReminderStore；测试 = 内存假列表）。
nonisolated protocol ReminderListAccess: AnyObject, Sendable {
    /// BetterCalendar 那本列表的名字（给人看）。
    var listName: String { get }
    /// 读 BetterCalendar 那本列表（含已完成）。没权限 / 系统读不到 → 抛错（绝不返回空冒充）。
    func readList() async throws -> ReminderListRead
    /// 写回改动；有新建且列表不存在时才建列表。
    func apply(_ changes: ReminderListChanges) async throws
    /// 你自己列表里没完成的提醒（只读，从不修改）。requestAccess = false 时不弹权限框（没授权 → 抛错）。
    func readOwnOpenReminders(requestAccess: Bool) async throws -> [OwnReminder]
}

// actor（2026-07-22 修启动卡死，同 EventKitCalendarStore）：EventKit 同步 API 脱离主线程。
actor EventKitReminderStore: ReminderListAccess {
    // 懒加载（2026-07-21，同 EventKitCalendarStore）：init 不同步创建 EKEventStore（TCC 阻塞会挂 test host）。
    private lazy var store = EKEventStore()
    static let listTitle = "BetterCalendar · 要紧事 (Dev)"
    nonisolated var listName: String { Self.listTitle }

    func readList() async throws -> ReminderListRead {
        try await ensureAccess(request: true)
        guard let list = ourList() else { return .missing(reach: defaultSource().map(Self.reach)) }
        let items = try await fetch(store.predicateForReminders(in: [list]))
        return .list(items: items.map(Self.snapshot), reach: Self.reach(list.source))
    }

    func apply(_ changes: ReminderListChanges) async throws {
        guard !changes.isEmpty else { return }
        try await ensureAccess(request: true)
        let found = ourList()
        if found == nil, changes.creates.isEmpty { return }   // 列表不存在、又没东西要建：不为此建列表
        let list = try found ?? createList()
        func item(_ id: String) throws -> EKReminder {
            guard let r = store.calendarItem(withIdentifier: id) as? EKReminder,
                  r.calendar?.calendarIdentifier == list.calendarIdentifier else {
                throw ReminderAccessError.writeFailed("提醒事项里找不到要改的那条（可能刚被改动），这次没写")
            }
            return r
        }
        do {
            for u in changes.updates {
                let r = try item(u.itemID)
                Self.fill(r, with: u.draft, keepTime: u.keepTime)
                try store.save(r, commit: false)
            }
            for d in changes.creates {
                let r = EKReminder(eventStore: store)
                r.calendar = list
                Self.fill(r, with: d, keepTime: false)
                try store.save(r, commit: false)
            }
            for id in changes.completes {
                let r = try item(id)
                guard !r.isCompleted else { continue }
                r.isCompleted = true
                try store.save(r, commit: false)
            }
            for id in changes.deletes { try store.remove(try item(id), commit: false) }
            try store.commit()
        } catch {
            store.reset()   // 丢掉没提交的半截改动
            throw error
        }
    }

    func readOwnOpenReminders(requestAccess: Bool) async throws -> [OwnReminder] {
        try await ensureAccess(request: requestAccess)
        let others = store.calendars(for: .reminder).filter { $0.title != Self.listTitle }
        guard !others.isEmpty else { return [] }
        let items = try await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: others))
        return items.filter { !$0.isCompleted }.map { r in
            OwnReminder(title: r.title ?? "", due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        hasTime: r.dueDateComponents?.hour != nil, list: r.calendar?.title ?? "")
        }
    }

    // MARK: 内部

    /// 把草稿写进提醒（标题/备注/优先级/身份章/截止/提醒时刻）。keepTime = 不碰截止与提醒时刻（你改过的时间）。
    private static func fill(_ r: EKReminder, with d: ReminderDraft, keepTime: Bool) {
        r.title = d.title
        r.notes = d.notes
        r.priority = d.priority
        r.url = ReminderStamp.url(for: d)   // 身份章：完成信号/差量写入按章匹配
        guard !keepTime else { return }
        for a in r.alarms ?? [] { r.removeAlarm(a) }
        if let due = d.due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            if let lead = d.leadMinutes {
                r.addAlarm(EKAlarm(relativeOffset: TimeInterval(-lead * 60)))   // 到期前 N 分钟（0 = 准点）
            }
        } else {
            r.dueDateComponents = nil
        }
    }

    private static func snapshot(_ r: EKReminder) -> ReminderSnapshot {
        ReminderSnapshot(url: r.url, isCompleted: r.isCompleted, title: r.title ?? "", notes: r.notes,
                         priority: r.priority,
                         due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                         leadMinutes: r.alarms?.first.map { Int((-$0.relativeOffset / 60).rounded()) },
                         creationDate: r.creationDate, externalID: r.calendarItemExternalIdentifier,
                         itemID: r.calendarItemIdentifier, completionDate: r.completionDate)
    }

    private static func reach(_ source: EKSource) -> ReminderListReach {
        ReminderListReach(sourceName: source.title, syncsAcrossDevices: source.sourceType != .local)
    }

    private func ourList() -> EKCalendar? {
        store.calendars(for: .reminder).first(where: { $0.title == Self.listTitle })
    }

    private func defaultSource() -> EKSource? {
        store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first
    }

    /// 建专用提醒列表（同日历的 Dev 专用思路）：落在默认提醒账户（通常是 iCloud）。
    private func createList() throws -> EKCalendar {
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = Self.listTitle
        cal.source = defaultSource()
        guard cal.source != nil else { throw ReminderAccessError.writeFailed("找不到可写的提醒账户") }
        try store.saveCalendar(cal, commit: true)
        return cal
    }

    /// 系统返回 nil = 读失败（不是「没有提醒」）→ 抛错。
    private func fetch(_ predicate: NSPredicate) async throws -> [EKReminder] {
        let result: [EKReminder]? = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0) }
        }
        guard let result else { throw ReminderAccessError.readFailed("系统没能读出提醒事项（这次什么都没判断，稍后会再读）") }
        return result
    }

    private func ensureAccess(request: Bool) async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined where request:
            let granted = try await store.requestFullAccessToReminders()
            if !granted { throw ReminderAccessError.notAuthorized("提醒事项权限被拒绝") }
        case .notDetermined:
            throw ReminderAccessError.notAuthorized("还没允许 BetterCalendar 使用提醒事项")
        default:
            throw ReminderAccessError.notAuthorized("没有提醒事项的完整权限（系统设置 → 隐私与安全性 → 提醒事项 打开 BetterCalendar）")
        }
    }
}
