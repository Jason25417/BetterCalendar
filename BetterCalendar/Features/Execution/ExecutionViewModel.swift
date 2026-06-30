//
//  ExecutionViewModel.swift
//  BetterCalendar
//
//  menu bar 单键导航的大脑（Feature 层 VM，不新增协议；建在 CalendarStore 上）。
//  「记录 = 导航」：点 完成/下一件/换一件 顺手攒出蓝色「实际」日历——无感采集，替代手动回填。
//  状态机：空档 ⇄ 进行中某块 ⇄ 休息（休息=暂停当前块，不结束；回来继续同一件）。
//  实时性：进行中的块不落盘（避免半截事件）；**每块「完成/切走」时**把全量实际刷进蓝日历。
//

import Foundation
import Observation

@Observable
final class ExecutionViewModel {
    private let calendarStore: CalendarStore
    private let reschedule: RescheduleService

    /// 今日计划块（绿），按开始时间排序。
    private(set) var planned: [PlannedItem] = []
    /// 已记录的实际块（蓝日历的来源）。
    private(set) var done: [ActualRecord] = []
    /// 当前进行中的块（nil = 空档）。
    private(set) var active: ActiveBlock?
    /// 已选中、待开始的块（换一件后切到它，但要点「开始任务」才真正开始计时）。
    private(set) var selected: PlannedItem?
    /// 休息态（可发生在空档，或某块中途=暂停那块）。
    private(set) var isOnBreak = false
    private var breakStart: Date?

    private(set) var loaded = false
    var lastError: String?

    struct PlannedItem: Identifiable, Sendable {
        let id = UUID()
        var title: String
        var start: Date
        var end: Date
    }
    struct ActualRecord: Identifiable, Sendable {
        let id = UUID()
        var plannedID: UUID?
        var title: String
        var start: Date
        var end: Date
    }
    struct ActiveBlock {
        var plannedID: UUID?
        var title: String
        var start: Date
        var pausedTotal: TimeInterval = 0   // 休息累计（从已用时长里扣）
    }

    init(calendarStore: CalendarStore, reschedule: RescheduleService) {
        self.calendarStore = calendarStore
        self.reschedule = reschedule
    }

    // MARK: - 读取今日

    /// 从日历读回今日 计划 + 已采集实际，重建状态（菜单每次打开都刷新）。
    func loadToday() async {
        do {
            let p = try await calendarStore.read(kind: .planned)
            let a = try await calendarStore.read(kind: .actual)
            planned = p.filter { DayContext.isSameLogicalDay($0.start, .now) }
                       .sorted { $0.start < $1.start }
                       .map { PlannedItem(title: $0.title, start: $0.start, end: $0.end) }
            // 已采集的实际（菜单之前攒的 / 回填的）→ 同步进 done，避免重复呈现为「未做」
            let collected = a.filter { DayContext.isSameLogicalDay($0.start, .now) }
                             .map { ActualRecord(plannedID: nil, title: $0.title,
                                                 start: $0.start, end: $0.end) }
            // 进行中的 active 不动；done 用读回的为准（菜单是唯一在写实际的入口，安全）
            if active == nil { done = collected }
            loaded = true
        } catch {
            lastError = error.localizedDescription
            DevLog.shared.warn("执行", "读取今日计划/实际失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 派生状态（给 UI）

    func isDone(_ item: PlannedItem) -> Bool {
        done.contains { TitleMatch.similarity($0.title, item.title) >= 0.6 }
    }

    /// 还没做、也不是当前块/待开始块的计划块。
    var remaining: [PlannedItem] {
        planned.filter { $0.id != active?.plannedID && $0.id != selected?.id && !isDone($0) }
    }

    /// 建议的下一件 = 最早的剩余块（计划写入时已按策略排过序）。
    var nextSuggested: PlannedItem? { remaining.first }

    var doneCount: Int { planned.filter { isDone($0) }.count }

    /// 当前块已用时长（休息期间冻结、并扣掉休息累计）。实时算，由 UI 的 TimelineView 每秒刷新。
    var currentElapsed: TimeInterval {
        guard let a = active else { return 0 }
        let endRef = isOnBreak ? (breakStart ?? .now) : .now
        return max(0, endRef.timeIntervalSince(a.start) - a.pausedTotal)
    }

    /// 当前这次休息已进行多久（仅休息中有意义）。
    var breakElapsed: TimeInterval {
        guard isOnBreak, let bs = breakStart else { return 0 }
        return max(0, Date.now.timeIntervalSince(bs))
    }

    // MARK: - 动作

    /// 真正开始某块（计时从现在起）。空档的「开始：下一件」/「开始任务」走这里。
    func startBlock(_ item: PlannedItem) async {
        await recordActiveIfAny()
        active = ActiveBlock(plannedID: item.id, title: item.title, start: .now)
        selected = nil
        isOnBreak = false
        breakStart = nil
        refreshPreview()
    }

    /// 换一件：结束当前 → 把目标设为「待开始」（**不立即开始**）；要再点「开始任务」才计时。
    func switchTo(_ item: PlannedItem) async {
        await recordActiveIfAny()
        active = nil
        selected = item
        refreshPreview()
    }

    /// 开始之前「换一件」选中的那件。
    func startSelected() async {
        guard let s = selected else { return }
        await startBlock(s)
    }

    /// 完成当前块 → 落盘 → 回到空档（不自动开下一件，由你按「下一件」）。
    func completeCurrent() async {
        await recordActiveIfAny()
        active = nil
        refreshPreview()
    }

    /// 单按钮 toggle：开始休息 ⇄ 结束休息。休息=暂停（保留当前块），结束后回来继续同一件。
    func toggleBreak() async {
        if isOnBreak {
            if let bs = breakStart, active != nil {
                active?.pausedTotal += Date.now.timeIntervalSince(bs)
            }
            isOnBreak = false
            breakStart = nil
        } else {
            isOnBreak = true
            breakStart = .now
        }
    }

    // MARK: - 落盘

    private func recordActiveIfAny() async {
        guard let a = active else { return }
        // 收尾休息（若正暂停）：先把这段休息计入 pausedTotal
        if isOnBreak, let bs = breakStart {
            active?.pausedTotal += Date.now.timeIntervalSince(bs)
            isOnBreak = false
            breakStart = nil
        }
        // 工程债5：实际块时长 = 净投入（扣掉中途休息），休息不计入有效投入。
        // 日历块写 [start, start+净]，结束时间会比墙钟早 pausedTotal——以"有效投入"为准。
        let paused = active?.pausedTotal ?? 0
        let effective = max(0, Date.now.timeIntervalSince(a.start) - paused)
        done.append(ActualRecord(plannedID: a.plannedID, title: a.title,
                                 start: a.start, end: a.start.addingTimeInterval(effective)))
        await flushActuals()
    }

    /// 把全量 done 覆盖写进蓝色「实际」日历（write 按 kind 覆盖当天，幂等）。
    private func flushActuals() async {
        let drafts = done.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .actual)
        }
        guard !drafts.isEmpty else { return }
        do {
            try await calendarStore.write(drafts)
            DevLog.shared.info("执行", "实际日历已更新：\(drafts.count) 项")
        } catch {
            lastError = error.localizedDescription
            DevLog.shared.error("执行", "写入实际日历失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 橙色预览（全天连续 re-flow）

    /// 完成 / 开始某块后，把剩余从此刻重排、写橙色预览。后台跑，不挡按钮。
    private func refreshPreview() {
        Task { await updatePreview() }
    }

    /// 剩余（既非已完成、也非正在做）从此刻 reflow → 橙色预览（当前时刻右侧）；无剩余则清空橙色（日终消失）。
    private func updatePreview() async {
        do {
            let now0 = Date.now
            var preview: [ScheduledBlock] = []
            // ① 正在做的：从现在起 → 预测结束（计划时长 − 已投入），让橙色「当前时刻」就是这件事
            if let a = active, let p = planned.first(where: { $0.id == a.plannedID }) {
                let remain = max(60, p.end.timeIntervalSince(p.start) - currentElapsed)
                preview.append(ScheduledBlock(title: a.title, start: now0,
                                              end: now0.addingTimeInterval(remain)))
            }
            // ② 之后接着排剩余（排除已做 + 正在做），从①的预测结束起
            var excluded = done.map(\.title)
            if let a = active { excluded.append(a.title) }
            let restFrom = preview.last?.end ?? now0
            preview += try await reschedule.continuousReflow(excludeTitles: excluded, now: restFrom)

            if preview.isEmpty {
                try await calendarStore.clear(kind: .preview)
            } else {
                try await calendarStore.write(preview.map {
                    CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .preview)
                })
            }
        } catch {
            lastError = error.localizedDescription
            DevLog.shared.warn("reflow", "更新橙色预览失败：\(error.localizedDescription)")
        }
    }
}
