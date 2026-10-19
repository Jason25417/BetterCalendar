//
//  CalendarStore.swift
//  BetterCalendar
//
//  写/读「带色日历」。生产唯一实现 = EventKitCalendarStore（真 Apple 日历）；测试注入 FakeCalendarStore（测试 target）。
//  铁律（P4.0）：实现只能删/改**带 BetterCalendar 章**的事件；无章事件是用户的，永不删改（决定逻辑见 CalendarSyncPlanner）。
//  P4.1（2026-10-19）角色拆分：只读 `CalendarReading` 给所有人；能写的 `CalendarProjecting` **只注入给
//  CalendarSyncEngine**（全 App 唯一的日历写者）。`CalendarStore` = 两者合一，只有组装点和引擎拿得到
//  （架构守卫单测 `calendarWriteCapabilityStaysInEngine` 锁住）。
//

import Foundation

/// 只读角色：读 BetterCalendar 自家日历的画面、读你的日历（已占用 / 关联 / 智能体上下文）。
protocol CalendarReading: AnyObject {
    func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft]
    /// 读某时间窗内与之相交的事件（P4.0-5：对账/投影按自己的扫描范围读，不受 read(kind:) 的「此刻前后 7 天」限制）。
    func read(kind: PlanCalendarKind, in window: DateInterval) async throws -> [CalendarEventDraft]

    /// 某日历日**系统里已有**的安排（排除本 App 自建日历），给排程当"已占用"上下文。
    /// 默认空（假日历/开发期不看系统）。
    func existingEvents(on day: Date) async -> [BusySlot]

    /// 只读（SPEC §19 A2，给智能体上下文）：时间窗内系统日历里的事件（排除本 App 自建日历），**含全天事件**。
    /// 与 existingEvents 的区别：不弹权限、失败**抛错**（开发期失败必须可见），并带日历名。默认空（测试替身）。
    func systemEvents(in window: DateInterval) async throws -> [SystemCalendarEvent]

    /// 你的日历事件（P4 Q4，只读）：时间窗内**你的**事件——所有非 BetterCalendar 的事件日历，
    /// 再加上误存进 BetterCalendar 自家日历、但不带章的事件（无章 = 不是我们写的 = 你的）。含全天（带标记）。
    /// 用途：作为「已占用」参与排布、与计划块关联（不复制、不写、不删）。不弹权限；失败抛错（开发期可见）。默认空。
    func externalEvents(in window: DateInterval) async throws -> [SystemCalendarEvent]

    /// 你的事件日历名（设置页「排布时当作已占用的日历」用；不含 BetterCalendar 自家日历）。默认空。
    func userCalendarTitles() async -> [String]
}

/// 写角色：**只有 CalendarSyncEngine 持有**（P4.1 单一写者）。其他模块改 PlanStore，再请引擎刷新。
protocol CalendarProjecting: AnyObject {
    func write(_ drafts: [CalendarEventDraft]) async throws
    /// 清空某一类（如橙色预览日终消失）——只清带章事件。
    func clear(kind: PlanCalendarKind) async throws

    /// 权威对齐（重构 P2，引擎专用）：把窗口内该 kind 的事件与 drafts 对齐——
    /// 按 blockID 匹配（仅 claimsUnstamped 草稿可认领同 标题+起始 的无章事件并补章），改的改、缺的建、多的（带章的）删；
    /// **drafts 为空 = 清空窗口**（与 write 的"空数组早退"相反，语义是"这个窗口就该是这样"）。
    /// 归属按事件 start ∈ [window.start, window.end)（半开区间），跨界重叠事件不误删。
    func apply(_ drafts: [CalendarEventDraft], kind: PlanCalendarKind, window: DateInterval) async throws
}

/// 读写合一（EventKitCalendarStore / 测试替身的实现目标）。生产里只有组装点与 CalendarSyncEngine 见到这个类型。
protocol CalendarStore: CalendarReading, CalendarProjecting {}

extension CalendarReading {
    /// 默认：在 read(kind:) 结果里按时间窗过滤（测试替身用；EventKit 实现直接按窗口查询）。
    func read(kind: PlanCalendarKind, in window: DateInterval) async throws -> [CalendarEventDraft] {
        try await read(kind: kind).filter { $0.start < window.end && $0.end > window.start }
    }
    func existingEvents(on day: Date) async -> [BusySlot] { [] }
    func systemEvents(in window: DateInterval) async throws -> [SystemCalendarEvent] { [] }
    func externalEvents(in window: DateInterval) async throws -> [SystemCalendarEvent] { [] }
    func userCalendarTitles() async -> [String] { [] }
}

extension CalendarStore {
    /// 退役一本自家日历里的 BetterCalendar 事件（P4 Q1：橙色预览日历退役）：时间窗内**只删带章的**，
    /// 无章事件（你的）原样留下并返回给调用方提示你挪走。**不删日历本身**。
    func retireStampedEvents(kind: PlanCalendarKind, in window: DateInterval) async throws -> CalendarRetirement {
        let before = try await read(kind: kind, in: window)
        let stamped = before.filter { $0.blockID != nil }
        if !stamped.isEmpty { try await apply([], kind: kind, window: window) }   // 对齐空清单 = 只删带章（CalendarSyncPlanner 铁律①）
        return CalendarRetirement(removed: stamped, foreignRemaining: before.filter { $0.blockID == nil })
    }
}

/// 退役清扫的结果（留底用：删了哪些带章事件；还剩哪些你的事件需要你挪走）。
nonisolated struct CalendarRetirement: Sendable {
    var removed: [CalendarEventDraft]
    var foreignRemaining: [CalendarEventDraft]
}

/// 系统日历里的一条事件（只读副本，来源=系统日历；BetterCalendar 自建的绿/蓝/橙日历不在内）。
nonisolated struct SystemCalendarEvent: Sendable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarTitle: String
    /// 事件外部标识（P4 Q4 关联用；跨设备稳定）。重复事件的每一次共用同一个，配合日期区分。
    var externalID: String? = nil
    /// 这件你的事件是误存在 BetterCalendar 自家日历里的（无章）。
    var inBetterCalendar: Bool = false
}
