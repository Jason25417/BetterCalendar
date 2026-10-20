//
//  EventKitCalendarStore.swift
//  BetterCalendar
//
//  真 Apple 日历后端（M2）：把计划写进专用「计划」日历（绿）、读回。
//  专用日历名带「计划/实际」标识（名字见 AppChannel：日用版带历史后缀 (Dev)，Dev 版前缀 BetterCalendar Dev），可整本删、不污染你别的日历。
//  需日历 full access（首次写会弹权限）。
//

import Foundation
import EventKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct CalendarError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// actor（2026-07-22 修 build 151 启动卡死）：EventKit 的 events(matching:)/save/commit 都是同步阻塞 API，
// 此前 final class=MainActor 隔离 → 启动 startupSync 约 16 轮全库扫描全压主线程 → beachball。
// 改 actor 后跑协作线程池、脱离主线程；调用方已全 await 走协议，零改动透明获益。见 [[eventkit-store-actor-not-mainactor]]。
actor EventKitCalendarStore: CalendarStore {
    // 懒加载（2026-07-21）：EKEventStore() 在 init 同步创建会在某些 TCC 状态下阻塞——无头 test host 里
    // new 出这个 store（如路由测试）就挂死 runner（本次「test runner hung before connection」根因）。
    // 改 lazy → init 零副作用，仅真正 read/write（各自先 ensureAccess）时才建；生产行为等价。
    private lazy var store = EKEventStore()
    /// 本通道的三本自建日历（W17：名字由 AppChannel 决定；日用版仍是历史名「BetterCalendar · 计划 (Dev)」）。
    private let titles: [PlanCalendarKind: String] = EventKitCalendarStore.calendarTitles(for: .current)
    /// 同设备上另一个通道（日用版 ↔ Dev 版）的自建日历：读「你的日历」时整本跳过，两边互不当成对方的安排。
    private let siblingTitles: Set<String> = AppChannel.current.siblingCalendarTitles(EventKitCalendarStore.calendarLabels.map(\.1))

    nonisolated static let calendarLabels: [(PlanCalendarKind, String)] = [(.planned, "计划"), (.actual, "实际"), (.preview, "预览")]
    nonisolated static func calendarTitles(for channel: AppChannel) -> [PlanCalendarKind: String] {
        Dictionary(uniqueKeysWithValues: calendarLabels.map { ($0.0, channel.calendarTitle($0.1)) })
    }

    func write(_ drafts: [CalendarEventDraft]) async throws {
        try await EventKitWriteGuard.refuseIfTestHost("日历写入 \(drafts.count) 项")   // W23b：测试宿主里绝不写真日历
        try await ensureAccess()
        guard !drafts.isEmpty else { return }
        var changed = 0
        var notes: [String] = []
        for (kind, group) in Dictionary(grouping: drafts, by: \.kind) {
            let cal = try await calendar(for: kind)
            let cal0 = Calendar.current
            let lo = cal0.startOfDay(for: group.map(\.start).min() ?? Date())
            let hi = cal0.date(byAdding: .day, value: 1,
                               to: cal0.startOfDay(for: group.map(\.end).max() ?? Date())) ?? Date()
            let r = try syncEvents(group, calendar: cal, from: lo, to: hi)
            changed += r.changed; notes += r.notes
        }
        if changed > 0 { try store.commit() }
        for n in notes { await DevLog.shared.warn("日历", n) }
        await DevLog.shared.info("日历", "写真日历 \(drafts.count) 项 · 实际变更 \(changed)")
    }

    func apply(_ drafts: [CalendarEventDraft], kind: PlanCalendarKind, window: DateInterval) async throws {
        try await EventKitWriteGuard.refuseIfTestHost("日历对齐「\(titles[kind] ?? "?")」\(drafts.count) 项")   // W23b
        try await ensureAccess()
        // 空草稿 + 日历本就不存在 → 无事可清，别为了清空去创建日历
        if drafts.isEmpty, existingCalendar(for: kind) == nil { return }
        let cal = try await calendar(for: kind)
        let (changed, notes) = try syncEvents(drafts, calendar: cal, from: window.start, to: window.end)
        if changed > 0 { try store.commit() }
        for n in notes { await DevLog.shared.warn("日历", n) }
        await DevLog.shared.info("投影", "对齐「\(titles[kind] ?? "?")」\(drafts.count) 项 · 实际变更 \(changed)")
    }

    /// 差量对齐核心（write / apply 共用）：EKEvent → 快照 → `CalendarSyncPlanner` 决定 → 这里只执行。
    /// 铁律（P4.0 止血，决定逻辑与单测都在 CalendarSyncPlanner）：
    /// ① 只删带 BetterCalendar 章的事件——无章事件不是我们写的（例如用户在日历 App 里误存进本日历的课程），
    ///    永远不删、不改（此前真机：一个重复课程系列被删掉 12 次）；
    /// ② 不再按「标题＋起始」认领无章事件（D2），只有用户明确「加进计划」的那件才认领补章；
    /// ③ 同章多份按创建时间/外部标识确定性保留一份（两端一致，不会各删一份）。
    private func syncEvents(_ drafts: [CalendarEventDraft], calendar cal: EKCalendar,
                            from lo: Date, to hi: Date) throws -> (changed: Int, notes: [String]) {
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: [cal])
        let existing = store.events(matching: pred)
        let plan = CalendarSyncPlanner.plan(existing: existing.map(Self.snapshot), drafts: drafts,
                                            from: lo, to: hi)
        var changed = 0
        for u in plan.updates {
            let ev = existing[u.index], d = u.draft
            ev.title = d.title; ev.startDate = d.start; ev.endDate = d.end
            ev.notes = d.notes; ev.alarms = Self.alarms(lead: d.alarmLeadMinutes)   // 普通块 []；固定块会前提醒
            if let bid = d.blockID, let url = Self.stampURL(bid, d) { ev.url = url }
            try store.save(ev, span: .thisEvent, commit: false); changed += 1
        }
        for d in plan.creates {
            let ev = EKEvent(eventStore: store)
            ev.calendar = cal; ev.title = d.title
            ev.startDate = d.start; ev.endDate = d.end; ev.notes = d.notes
            ev.alarms = Self.alarms(lead: d.alarmLeadMinutes)
            ev.url = d.blockID.flatMap { Self.stampURL($0, d) }
            try store.save(ev, span: .thisEvent, commit: false); changed += 1
        }
        for i in plan.deletes {
            try? store.remove(existing[i], span: .thisEvent, commit: false); changed += 1
        }
        // 日志（开发期失败可见）交给调用方在 commit 之后 await 写，避免在暂存与提交之间让出 actor
        var notes = plan.keptForeign.map {
            "「\(cal.title)」里有一个不是 BetterCalendar 写的事件「\(existing[$0].title ?? "")」，已保留不删（建议挪到你自己的日历）"
        }
        if !plan.droppedUnstampedDrafts.isEmpty {
            notes.append("\(plan.droppedUnstampedDrafts.count) 条不带章的草稿没有写入（BetterCalendar 只写带章事件）")
        }
        return (changed, notes)
    }

    nonisolated private static func snapshot(_ ev: EKEvent) -> CalendarEventSnapshot {
        let stamp = CalendarStamp.parse(ev.url)
        return CalendarEventSnapshot(title: ev.title ?? "", start: ev.startDate, end: ev.endDate, notes: ev.notes,
                                     hasAlarm: !(ev.alarms ?? []).isEmpty, blockID: stamp?.blockID,
                                     creationDate: ev.creationDate, externalID: ev.calendarItemExternalIdentifier,
                                     stampVersion: stamp?.version, stampHash: stamp?.hash)
    }

    // MARK: - 盖章（重构 P1「稳定身份」）

    /// blockID → 事件 URL 章（bettercalendar://block/UUID）：随 iCloud 日历同步到所有设备，
    /// 任何设备匹配都按它；日后可注册 URL scheme 做 deep link（点事件跳回 App 对应块）。
    nonisolated static func stampURL(_ id: UUID) -> URL? {
        CalendarStamp(blockID: id).url
    }

    /// 带章 v2（P4）：草稿带版本/指纹就写 ?v=&h=，否则写旧章。
    nonisolated static func stampURL(_ id: UUID, _ d: CalendarEventDraft) -> URL? {
        CalendarStamp(blockID: id, version: d.stampVersion, hash: d.stampHash).url
    }

    /// 事件 URL → blockID（非本 App 的章 → nil；v2 章的查询参数不影响）。
    nonisolated static func blockID(from url: URL?) -> UUID? {
        CalendarStamp.parse(url)?.blockID
    }

    /// 会前提醒（⑤会议自动化）：lead 分钟前响一次；nil/负 → 无提醒（普通块）。
    nonisolated private static func alarms(lead: Int?) -> [EKAlarm] {
        guard let lead, lead >= 0 else { return [] }
        return [EKAlarm(relativeOffset: TimeInterval(-lead * 60))]
    }

    func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft] {
        let cal0 = Calendar.current
        let lo = cal0.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let hi = cal0.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return try await read(kind: kind, in: DateInterval(start: lo, end: max(lo, hi)))
    }

    /// 读某时间窗（P4.0-5）：对账/投影传自己的扫描范围，不再受「此刻前后 7 天」限制（第 7 天晚上的块曾被误报删除）。
    func read(kind: PlanCalendarKind, in window: DateInterval) async throws -> [CalendarEventDraft] {
        try await ensureAccess()
        guard let title = titles[kind],
              let cal = store.calendars(for: .event).first(where: { $0.title == title }) else { return [] }
        let pred = store.predicateForEvents(withStart: window.start, end: window.end, calendars: [cal])
        return store.events(matching: pred).map {
            let stamp = CalendarStamp.parse($0.url)
            return CalendarEventDraft(title: $0.title ?? "", start: $0.startDate, end: $0.endDate,
                               kind: kind, notes: $0.notes,
                               // 带回会前提醒：原样保留（pass-through）的事件不会被顺手抹掉提醒
                               alarmLeadMinutes: $0.alarms?.first.map { Int((-$0.relativeOffset / 60).rounded()) },
                               blockID: stamp?.blockID,
                               creationDate: $0.creationDate, externalID: $0.calendarItemExternalIdentifier,
                               stampVersion: stamp?.version, stampHash: stamp?.hash,
                               lastModified: $0.lastModifiedDate)
        }
    }

    func clear(kind: PlanCalendarKind) async throws {
        try await EventKitWriteGuard.refuseIfTestHost("日历清空「\(titles[kind] ?? "?")」")   // W23b
        try await ensureAccess()
        guard let cal = existingCalendar(for: kind) else { return }
        let cal0 = Calendar.current
        let lo = cal0.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let hi = cal0.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        // P4.0-1：清空 = 与空清单对齐，走同一个决定函数——只删带 BetterCalendar 章的事件；
        // 无章事件（用户误存进本日历的）永远不删。
        let (changed, notes) = try syncEvents([], calendar: cal, from: lo, to: hi)
        if changed > 0 { try store.commit() }
        for n in notes { await DevLog.shared.warn("日历", n) }
    }

    /// 清空某一天某一类（删光当天所有块后确认写入 → 清该日绿色事件；不碰别天）。

    /// 目标日系统里已有的安排（所有事件日历，排除本 App 的三本 Dev 日历）。
    /// 权限没给/读失败 → 空（上下文缺失不挡排程）。
    func existingEvents(on day: Date) async -> [BusySlot] {
        do { try await ensureAccess() } catch { return [] }
        let cal0 = Calendar.current
        let lo = cal0.startOfDay(for: day)
        guard let hi = cal0.date(byAdding: .day, value: 1, to: lo) else { return [] }
        let ours = Set(titles.values).union(siblingTitles)
        let others = store.calendars(for: .event).filter { !ours.contains($0.title) }
        guard !others.isEmpty else { return [] }
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: others)
        return store.events(matching: pred)
            .filter { !$0.isAllDay }   // 全天事件不占时段
            .map { BusySlot(title: $0.title ?? "（无标题）", start: $0.startDate, end: $0.endDate) }
    }

    /// 只读：时间窗内系统日历事件（排除本 App 自建日历，含全天）。不主动请求权限——
    /// 后台每 20 秒刷新的上下文不该弹授权框；没权限直接抛错，由调用方显式标进上下文 + DevLog。
    func systemEvents(in window: DateInterval) async throws -> [SystemCalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarError(message: "无日历 full access，读不到系统日历")
        }
        let ours = Set(titles.values).union(siblingTitles)
        let others = store.calendars(for: .event).filter { !ours.contains($0.title) }
        guard !others.isEmpty else { return [] }
        let pred = store.predicateForEvents(withStart: window.start, end: window.end, calendars: others)
        return store.events(matching: pred)
            .map { SystemCalendarEvent(title: $0.title ?? "（无标题）", start: $0.startDate, end: $0.endDate,
                                       isAllDay: $0.isAllDay, calendarTitle: $0.calendar?.title ?? "",
                                       externalID: $0.calendarItemExternalIdentifier,   // W32：越级提案定位用（跨设备）
                                       facts: YourEventFacts($0, inBetterCalendar: false)) }
            .sorted { $0.start < $1.start }
    }

    /// 你的日历事件（P4 Q4，只读、不弹权限）：非 BetterCalendar 日历的全部事件 + 自家日历里不带章的事件。
    func externalEvents(in window: DateInterval) async throws -> [SystemCalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarError(message: "无日历 full access，读不到你的日历")
        }
        let ours = Set(titles.values)
        let all = store.calendars(for: .event).filter { !siblingTitles.contains($0.title) }   // 另一个通道的整本跳过
        guard !all.isEmpty else { return [] }
        let pred = store.predicateForEvents(withStart: window.start, end: window.end, calendars: all)
        return store.events(matching: pred).compactMap { ev -> SystemCalendarEvent? in
            let inOurs = ours.contains(ev.calendar?.title ?? "")
            if inOurs, Self.blockID(from: ev.url) != nil { return nil }   // 带章 = BetterCalendar 自己写的，不是你的
            return SystemCalendarEvent(title: ev.title ?? "（无标题）", start: ev.startDate, end: ev.endDate,
                                       isAllDay: ev.isAllDay, calendarTitle: ev.calendar?.title ?? "",
                                       externalID: ev.calendarItemExternalIdentifier, inBetterCalendar: inOurs)
        }.sorted { $0.start < $1.start }
    }

    func userCalendarTitles() async -> [String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let ours = Set(titles.values).union(siblingTitles)
        return Array(Set(store.calendars(for: .event).map(\.title).filter { !ours.contains($0) })).sorted()
    }

    // MARK: - 权限 / 日历

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await store.requestFullAccessToEvents()
            if !granted { throw CalendarError(message: "日历权限被拒绝") }
        default:
            throw CalendarError(message: "无日历 full access（系统设置 → 隐私与安全性 → 日历 开启）")
        }
    }

    /// 该 kind 的专用日历（已存在才返回，不创建）。
    private func existingCalendar(for kind: PlanCalendarKind) -> EKCalendar? {
        guard let title = titles[kind] else { return nil }
        return store.calendars(for: .event).first { $0.title == title }
    }

    private func calendar(for kind: PlanCalendarKind) async throws -> EKCalendar {
        let title = titles[kind] ?? "BetterCalendar (Dev)"
        if let existing = store.calendars(for: .event).first(where: { $0.title == title }) {
            await migrateColorIfNeeded(existing, kind: kind)
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = title
        cal.cgColor = Self.color(kind)
        guard let source = writableSource() else { throw CalendarError(message: "找不到可写日历源") }
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        return cal
    }

    /// 换装批次 B（3A-v2）：老用户的绿/蓝/预览日历建于系统色时代——每 kind 一次性迁到令牌色。
    /// 只迁一次（打标记）：之后用户在日历 App 手改颜色，我们不再抢回来。
    private func migrateColorIfNeeded(_ cal: EKCalendar, kind: PlanCalendarKind) async {
        let flag = "ek.color.3Av2.\(kind)"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        cal.cgColor = Self.color(kind)
        do {
            try store.saveCalendar(cal, commit: true)
            await DevLog.shared.info("日历", "「\(cal.title)」颜色已迁移到经典皮肤 3A-v2")
        } catch {
            await DevLog.shared.warn("日历", "日历颜色迁移失败（不影响事件读写）：\(error.localizedDescription)")
        }
    }

    private func writableSource() -> EKSource? {
        if let icloud = store.sources.first(where: {
            $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud")
        }) { return icloud }
        if let calDAV = store.sources.first(where: { $0.sourceType == .calDAV }) { return calDAV }
        if let local = store.sources.first(where: { $0.sourceType == .local }) { return local }
        return store.defaultCalendarForNewEvents?.source
    }

    /// 3A-v2 语义色（换装批次 B，值同 ClassicHex）：EK 日历颜色是单值（日历 App 双模共用）→ 取 light 档。
    nonisolated private static func color(_ kind: PlanCalendarKind) -> CGColor {
        let hex: UInt32
        switch kind {
        case .planned: hex = ClassicHex.planned.light
        case .actual:  hex = ClassicHex.actual.light
        case .preview: hex = ClassicHex.preview.light
        }
        return CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                       green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
