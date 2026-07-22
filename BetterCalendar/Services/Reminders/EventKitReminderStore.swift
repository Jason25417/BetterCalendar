//
//  EventKitReminderStore.swift
//  BetterCalendar
//
//  真 Apple「提醒事项」后端（M3）：把★要紧事写成标准 VTODO（标题/备注/截止/优先级/提前提醒）。
//  ⚠️ 只写标准字段；子任务/标签/旗标等私有 ReminderKit 不可写。需提醒事项 full access。
//

import Foundation
import EventKit

// actor（2026-07-22 修启动卡死，同 EventKitCalendarStore）：EventKit 同步 API 脱离主线程。
actor EventKitReminderStore: ReminderStore {
    // 懒加载（2026-07-21，同 EventKitCalendarStore）：init 不同步创建 EKEventStore（TCC 阻塞会挂 test host）。
    private lazy var store = EKEventStore()
    private static let listTitle = "BetterCalendar · 要紧事 (Dev)"

    func write(_ drafts: [ReminderDraft]) async throws {
        try await ensureAccess()
        guard !drafts.isEmpty else { return }
        let list = try reminderList()   // 专用列表，可明确找到、可整本删
        // 覆盖：先清掉本列表里旧的未完成提醒，避免多次确认重复累积
        for r in await existingReminders(in: list) where !r.isCompleted {
            try? store.remove(r, commit: false)
        }
        for d in drafts {
            let r = EKReminder(eventStore: store)
            r.calendar = list
            r.title = d.title
            r.notes = d.notes
            r.priority = d.priority
            r.url = d.blockID.flatMap(EventKitCalendarStore.stampURL)   // 身份章：完成信号按 ID 匹配
            if let due = d.due {
                r.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: due)
                if let lead = d.leadMinutes {
                    r.addAlarm(EKAlarm(relativeOffset: TimeInterval(-lead * 60)))   // 到期前 N 分钟
                }
            }
            try store.save(r, commit: false)
        }
        try store.commit()
        await DevLog.shared.info("提醒", "写入提醒事项 \(drafts.count) 项 → 「\(Self.listTitle)」列表")
    }

    /// 找/建专用提醒列表（同日历的 Dev 专用思路）。
    private func reminderList() throws -> EKCalendar {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == Self.listTitle }) {
            return existing
        }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = Self.listTitle
        cal.source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first
        guard cal.source != nil else { throw CalendarError(message: "找不到可写的提醒源") }
        try store.saveCalendar(cal, commit: true)
        return cal
    }

    /// 「被动完成」信号（0.25.4 根治）：**今天打勾完成 且 带本 App 身份章**的提醒 → 返回其 blockID。
    /// 双闸门：①按 blockID 精确匹配（不按标题——同名任务不再串）②只认今天完成（不翻旧账）。
    /// 无章老提醒不参与（0.25.4 前写的没盖章，宁可漏认、绝不误认；下次确认写入会补章）。
    /// 老 bug 全貌：曾返回列表里所有历史已完成提醒的标题，date-blind + title-fuzzy——今天排同名任务
    /// 就匹配往日打勾的旧提醒 → 什么都没干被自动标完成、写蓝色实际、删了每次打开又重建（违 §5.13）。
    func completedBlockIDs() async -> Set<UUID> {
        do { try await ensureAccess() } catch { return [] }
        guard let list = store.calendars(for: .reminder).first(where: { $0.title == Self.listTitle })
        else { return [] }
        let ids = (await existingReminders(in: list))
            .filter { $0.isCompleted
                && ($0.completionDate.map { DayContext.isSameLogicalDay($0, .now) } ?? false) }
            .compactMap { EventKitCalendarStore.blockID(from: $0.url) }
        return Set(ids)
    }

    /// App 内完成 → 回勾对应提醒事项（双向：App→提醒事项）。按身份章 blockID 精确匹配本 App 列表里的提醒。
    /// 幂等：已完成的跳过、不重复 commit。无对应提醒的 id 静默忽略。
    func markCompleted(blockIDs: Set<UUID>) async {
        guard !blockIDs.isEmpty else { return }
        do { try await ensureAccess() } catch { return }
        guard let list = store.calendars(for: .reminder).first(where: { $0.title == Self.listTitle })
        else { return }
        var changed = false
        for r in await existingReminders(in: list) where !r.isCompleted {
            guard let bid = EventKitCalendarStore.blockID(from: r.url), blockIDs.contains(bid) else { continue }
            r.isCompleted = true
            try? store.save(r, commit: false)
            changed = true
        }
        if changed {
            try? store.commit()
            await DevLog.shared.info("提醒", "回勾完成的提醒事项（App→提醒事项）")
        }
    }

    /// 某日历日到期、未完成的提醒（排除本 App 自建列表）——给排程当上下文。
    func dueReminders(on day: Date) async -> [String] {
        do { try await ensureAccess() } catch { return [] }
        let others = store.calendars(for: .reminder).filter { $0.title != Self.listTitle }
        guard !others.isEmpty else { return [] }
        let all: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: store.predicateForReminders(in: others)) {
                cont.resume(returning: $0 ?? [])
            }
        }
        let cal = Calendar.current
        return all.filter { r in
            guard !r.isCompleted, let comps = r.dueDateComponents,
                  let due = cal.date(from: comps) else { return false }
            return cal.isDate(due, inSameDayAs: day)
        }.compactMap(\.title)
    }

    private func existingReminders(in list: EKCalendar) async -> [EKReminder] {
        let pred = store.predicateForReminders(in: [list])
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { cont.resume(returning: $0 ?? []) }
        }
    }

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await store.requestFullAccessToReminders()
            if !granted { throw CalendarError(message: "提醒事项权限被拒绝") }
        default:
            throw CalendarError(message: "无提醒事项 full access（系统设置 → 隐私与安全性 → 提醒事项 开启）")
        }
    }
}
