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
    private let planStore: PlanStore
    private let calendarStore: CalendarStore
    private let startedDays: StartedDayStore?

    init(planStore: PlanStore, calendarStore: CalendarStore, startedDays: StartedDayStore? = nil) {
        self.planStore = planStore
        self.calendarStore = calendarStore
        self.startedDays = startedDays
    }

    /// 把某逻辑日的 PlanStore 投影到日历。label = 逻辑日标签（该日零点）。
    /// 会前提醒规则收口在此：仅固定块（会议/外部承诺）挂 lead 提醒（原则4「仅固定块提醒」）。
    func project(label: Date) async throws {
        let window = DayContext.logicalWindow(forLabel: label)
        let blocks = try planStore.plannedBlocks(on: label)
        let drafts = blocks.map { b in
            CalendarEventDraft(title: b.title, start: b.start, end: b.end, kind: .planned,
                               alarmLeadMinutes: b.isFixed ? MeetingSettings.leadMinutes : nil,
                               blockID: b.id)
        }
        if startedDays?.isStarted(label) ?? false {
            // 实时模式（绿色淡出，§5.10 原则6.4）：绿色清空、整日计划投橙色
            try await calendarStore.apply([], kind: .planned, window: window)
            try await calendarStore.apply(drafts.map { var d = $0; d.kind = .preview; return d },
                                          kind: .preview, window: window)
        } else {
            try await calendarStore.apply(drafts, kind: .planned, window: window)
            // 非实时日不碰橙色：橙色的另一位作者是执行层的「全天连续 reflow 预览」，归它管
        }
        DevLog.shared.info("投影", "\(Self.dayStr(label)) → \(drafts.count) 块（\(startedDays?.isStarted(label) ?? false ? "实时→橙" : "绿")）")
    }

    /// 启动对账（存量补章/自愈，2026-07-07 Jason 报"老事件没补章"后加）：
    /// 把 逻辑今天…+N-1 天 逐日投影一遍——无章存量事件被认领补章、任何漂移被真相源纠正。
    /// **过去的日子不动**（不审计历史；老历史事件无章无害——只有会被再投影的日子才需要章）。
    /// 只在 真日历后端 且 已授权 时跑：不让冷启动弹权限框（权限首次确认写入时才请求）。
    func projectUpcomingWindow(days: Int = 8) async {
        guard CalendarSettings.backend == .eventKit,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        for offset in 0..<days {
            do { try await project(label: DayContext.logicalDay(offset: offset)) }
            catch {
                DevLog.shared.warn("投影", "启动对账 +\(offset) 天失败：\(error.localizedDescription)")
            }
        }
        DevLog.shared.info("投影", "启动对账完成：今天…+\(days - 1) 天已按真相源对齐/补章")
    }

    private static func dayStr(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }
}
