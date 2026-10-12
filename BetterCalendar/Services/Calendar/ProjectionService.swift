//
//  ProjectionService.swift
//  BetterCalendar
//
//  单一真相源投影（重构 P2，2026-07-07 Jason 拍板）：**PlanStore = 计划唯一真相；Apple 日历 = 只读投影**。
//  - 所有改计划的路径统一「先写 PlanStore → project(label:)」；除本服务外**不得**写绿/橙计划事件。
//  - 常规日 → 投绿色(planned)；已「开始今天」(实时模式) → 绿色不投（淡出）、投橙色(preview)，
//    PlanStore 一动不动（完整计划永远在，供复盘对比）。
//  - 匹配按 blockID（事件 URL 章，随 iCloud 同步跨设备一致）；无章存量事件自动认领补章=零成本迁移。
//  - 日历里的手改不回流（反向同步已下线；日后按 ID 重做对账再开）。
//

import Foundation
import EventKit   // 仅启动对账前查权限用（避免冷启动弹权限框），不在此直接读写事件

@MainActor
final class ProjectionService {
    private let planStore: PlanReading   // 只读角色：投影只读真相、只写画面（这就是它可随时安全重跑的原因）
    private let calendarStore: CalendarStore
    private let startedDays: StartedDayStore?

    init(planStore: PlanReading, calendarStore: CalendarStore, startedDays: StartedDayStore? = nil) {
        self.planStore = planStore
        self.calendarStore = calendarStore
        self.startedDays = startedDays
    }

    /// 把某逻辑日的 PlanStore 投影到日历。label = 逻辑日标签（该日零点）。
    /// 会前提醒规则收口在此：仅固定块（会议/外部承诺）挂 lead 提醒（原则4「仅固定块提醒」）。
    func project(label: Date, restoring: ScheduledBlock? = nil) async throws {
        let window = DayContext.logicalWindow(forLabel: label)
        var blocks = try planStore.plannedBlocks(on: label)
        if let restoring { blocks.append(restoring) }
        let deletedIDs = try planStore.deletedPlannedIDs(on: label)
        var drafts = blocks.map { b in
            CalendarEventDraft(title: b.title, start: b.start, end: b.end, kind: .planned,
                               alarmLeadMinutes: b.isFixed ? MeetingSettings.leadMinutes : nil,
                               blockID: b.id)
        }
        // 多设备安全（0.35.0，修 TestFlight 反馈#5「双端画回死循环」）：带章、但**本机真相和
        // 本机指纹都不认识**的事件 = 多半是另一台设备刚写的（它的 PlanStore 真相还在 CloudKit
        // 路上）——原样保留（pass-through 进对齐清单），绝不清；真相到了按同 ID 自动接管。
        // 本机指纹认识而真相已删的照清（本机删计划的正常收敛不受影响）。
        drafts.append(contentsOf: try await foreignStampedEvents(
            kind: .planned, window: window,
            knownIDs: Set(blocks.map(\.id)).union(deletedIDs), fingerprint: ProjectionFingerprints.get(label)))
        if startedDays?.isStarted(label) ?? false {
            // 实时模式（绿色淡出，§5.10 原则6.4）：绿色清空、整日计划投橙色
            try await calendarStore.apply([], kind: .planned, window: window)
            try await calendarStore.apply(drafts.map { var d = $0; d.kind = .preview; return d },
                                          kind: .preview, window: window)
            ProjectionFingerprints.set(label, [:])   // 实时日绿色为空：清指纹（该日不参与对账）
        } else {
            try await calendarStore.apply(drafts, kind: .planned, window: window)
            // 非实时日不碰橙色：橙色的另一位作者是执行层的「全天连续 reflow 预览」，归它管
            // 指纹：记下这次成功写下的画面（0.20 对账用它分辨"自己写的"vs"用户手改的"）
            ProjectionFingerprints.set(label, Dictionary(uniqueKeysWithValues: blocks.map {
                ($0.id.uuidString, ProjectionFingerprints.tuple(start: $0.start, end: $0.end, title: $0.title))
            }))
        }
        DevLog.shared.info("投影", "\(Self.dayStr(label)) → \(drafts.count) 块（\(startedDays?.isStarted(label) ?? false ? "实时→橙" : "绿")）")
    }

    /// 启动对账（存量补章/自愈，2026-07-07 Jason 报"老事件没补章"后加）：
    /// 把 逻辑今天…+N-1 天 逐日投影一遍——无章存量事件被认领补章、任何漂移被真相源纠正。
    /// **过去的日子不动**（不审计历史；老历史事件无章无害——只有会被再投影的日子才需要章）。
    /// 只在 真日历后端 且 已授权 时跑：不让冷启动弹权限框（权限首次确认写入时才请求）。
    /// skipping：有待确认「日历新建」的日子先不投影（投影会把无主新建事件清掉，问都没问——0.20.2）。
    func projectUpcomingWindow(days: Int = 8, skipping: Set<Date> = []) async {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }   // 后端恒真日历（假日历族已删）
        for offset in 0..<days {
            let label = DayContext.logicalDay(offset: offset)
            if skipping.contains(Calendar.current.startOfDay(for: label)) { continue }
            do { try await project(label: label) }
            catch {
                DevLog.shared.warn("投影", "启动对账 +\(offset) 天失败：\(error.localizedDescription)")
            }
        }
        DevLog.shared.info("投影", "启动对账完成：今天…+\(days - 1) 天已按真相源对齐/补章"
                           + (skipping.isEmpty ? "" : "（\(skipping.count) 天有待确认新建，暂缓）"))
    }

    /// 窗口内「带章但本机不认识」的事件（另一台设备的写入）——投影对齐时原样保留。
    /// ⚠️ 这里读日历不是把它当数据源（真相仍是 PlanStore），是对齐前查画面上有什么——
    /// 已在真相源守卫单测白名单登记（ProjectionService.swift）。
    private func foreignStampedEvents(kind: PlanCalendarKind, window: DateInterval,
                                      knownIDs: Set<UUID>, fingerprint: [String: String]) async throws -> [CalendarEventDraft] {
        let existing = try await calendarStore.read(kind: kind)
        return existing.filter { e in
            guard window.contains(e.start), let bid = e.blockID else { return false }   // 无章走既有新建策略
            return !knownIDs.contains(bid) && fingerprint[bid.uuidString] == nil
        }
    }

    private static func dayStr(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }
}
