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
    private let planStore: PlanStore
    private let reminderStore: ReminderStore
    private let liveActivity: ExecutionLiveActivity   // 灵动岛/锁屏实时计时（iOS 有实现，macOS no-op）
    private let sessionStore: ExecutionSessionStore?  // 执行会话落库（趋势统计数据源；nil=不记，测试用）

    /// 今日计划块（绿），按开始时间排序。
    private(set) var planned: [PlannedItem] = []
    /// 已记录的实际块（蓝日历的来源）。
    private(set) var done: [ActualRecord] = []
    /// 当前进行中的块（nil = 空档）。前台块：占用 menu bar + Live Activity + 计时风格控制。
    private(set) var active: ActiveBlock?
    /// 后台并行进行的块（不占 menu bar/前台、不显灵动岛，自己按墙钟计时、完成时自动记蓝色实际）。
    /// 支持「一次做多件」：前台一件精细计时，其余同时在后台慢慢跑。
    private(set) var background: [BackgroundRun] = []
    /// 已选中、待开始的块（换一件后切到它，但要点「开始任务」才真正开始计时）。
    private(set) var selected: PlannedItem?
    /// 休息态（可发生在空档，或某块中途=暂停那块）。
    private(set) var isOnBreak = false
    private var breakStart: Date?
    private var pomoSegStart: Date?   // 番茄钟当前段开始时刻（nil = 非番茄）
    private var pomoIsRest = false    // 当前番茄段是否休息段
    private var pomoWorkSegmentsDone = 0   // 本次会话完成的番茄工作段数（落 ExecutionSession）
    private var breakCount = 0             // 本次会话中途休息次数（落 ExecutionSession）

    private(set) var loaded = false
    var lastError: String?

    struct PlannedItem: Identifiable, Sendable {
        let id = UUID()
        var title: String
        var start: Date
        var end: Date
        var timingStyle: TimingStyle = .light
        var isFixed: Bool = false
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
        var timingStyle: TimingStyle = .light
    }
    /// 后台并行块：只记起点，按墙钟计时（不支持番茄/休息——那是前台块的精细玩法）。
    struct BackgroundRun: Identifiable, Sendable {
        let id = UUID()
        var plannedID: UUID?
        var title: String
        var start: Date
    }

    init(calendarStore: CalendarStore, reschedule: RescheduleService,
         planStore: PlanStore, reminderStore: ReminderStore,
         liveActivity: ExecutionLiveActivity, sessionStore: ExecutionSessionStore? = nil) {
        self.calendarStore = calendarStore
        self.reschedule = reschedule
        self.planStore = planStore
        self.reminderStore = reminderStore
        self.liveActivity = liveActivity
        self.sessionStore = sessionStore
    }

    // MARK: - 读取今日

    /// 重建今日状态：计划从**真相库**读（带 timingStyle 等元数据），实际从日历读。
    func loadToday() async {
        do {
            // 计划块从 PlanStore（带 isFixed/timingStyle），不从日历（日历丢元数据）
            let p = try planStore.plannedBlocks(on: DayContext.logicalStartOfDay(.now))
            let a = try await calendarStore.read(kind: .actual)
            planned = p.sorted { $0.start < $1.start }
                       .map { PlannedItem(title: $0.title, start: $0.start, end: $0.end,
                                          timingStyle: $0.timingStyle, isFixed: $0.isFixed) }
            // 已采集的实际（菜单之前攒的 / 回填的）→ 同步进 done，避免重复呈现为「未做」
            var merged = a.filter { DayContext.isSameLogicalDay($0.start, .now) }
                          .map { ActualRecord(plannedID: nil, title: $0.title,
                                              start: $0.start, end: $0.end) }
            let collectedCount = merged.count

            // 被动信号（M6b）：会议到点(过去的固定块=按计划发生) + 提醒打勾 → 自动并入实际
            let completed = await reminderStore.completedTitles()
            let now = Date.now
            for item in planned where !merged.contains(where: { TitleMatch.similarity($0.title, item.title) >= 0.6 }) {
                let meetingHappened = item.isFixed && item.end < now
                let reminderChecked = completed.contains { TitleMatch.similarity($0, item.title) >= 0.6 }
                if meetingHappened || reminderChecked {
                    merged.append(ActualRecord(plannedID: item.id, title: item.title,
                                               start: item.start, end: item.end))
                }
            }

            // 进行中的 active 不动；done 用合并后的为准
            if active == nil {
                done = merged
                if merged.count > collectedCount {
                    DevLog.shared.info("执行", "被动信号并入实际 \(merged.count - collectedCount) 件")
                    await flushActuals()
                }
            }
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

    /// 某块是否正在后台并行进行。
    func isRunningInBackground(_ item: PlannedItem) -> Bool {
        background.contains { $0.plannedID == item.id }
    }

    /// 还没做、也不是当前块/待开始块/后台并行块的计划块。
    var remaining: [PlannedItem] {
        planned.filter { $0.id != active?.plannedID && $0.id != selected?.id
                         && !isDone($0) && !isRunningInBackground($0) }
    }

    /// 后台某并行块已跑多久（按墙钟）。
    func backgroundElapsed(_ run: BackgroundRun) -> TimeInterval {
        max(0, Date.now.timeIntervalSince(run.start))
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

    /// 当前番茄钟段（仅 active 是番茄钟时；nil = 非番茄钟）。段满后停在满位、等点确定才切。
    /// 休息（手动 toggleBreak）期间**冻结**段内已用——与「休息=暂停当前块」契约一致；
    /// 休息结束时 toggleBreak 会把 pomoSegStart 后移相应时长，段内进度不被休息污染。
    var pomodoroPhase: PomodoroPhase? {
        guard let a = active, a.timingStyle == .pomodoro, let seg = pomoSegStart else { return nil }
        let endRef = isOnBreak ? (breakStart ?? .now) : .now
        let elapsed = max(0, endRef.timeIntervalSince(seg))
        let length = pomoIsRest ? PomodoroTimer.rest : PomodoroTimer.work
        return PomodoroPhase(kind: pomoIsRest ? .rest : .work, elapsedInPhase: elapsed, phaseLength: length)
    }

    /// 番茄钟段满后，点「确定」切下一段（工作 ⇄ 休息）。
    func confirmPomodoroNext() {
        if !pomoIsRest { pomoWorkSegmentsDone += 1 }   // 工作段→休息 = 完成一个工作段
        pomoIsRest.toggle()
        pomoSegStart = .now
        if let s = liveSnapshot() { liveActivity.update(s) }
    }

    /// 当前执行状态 → Live Activity 快照（无 active 则 nil）。
    private func liveSnapshot() -> LiveActivitySnapshot? {
        guard let a = active else { return nil }
        let mode: LiveActivityMode = a.timingStyle == .pomodoro ? .pomodoro : .light
        var phaseEndsAt: Date?
        if a.timingStyle == .pomodoro, let seg = pomoSegStart {
            phaseEndsAt = seg.addingTimeInterval(pomoIsRest ? PomodoroTimer.rest : PomodoroTimer.work)
        }
        return LiveActivitySnapshot(
            title: a.title,
            timerStart: Date.now.addingTimeInterval(-currentElapsed),
            pausedAt: isOnBreak ? (breakStart ?? .now) : nil,
            mode: mode, phaseEndsAt: phaseEndsAt, phaseIsRest: pomoIsRest)
    }

    /// active 块的计时风格（给 UI 决定显不显时长）。
    var activeStyle: TimingStyle? { active?.timingStyle }

    // MARK: - 动作

    /// 真正开始某块（计时从现在起）。空档的「开始：下一件」/「开始任务」走这里。
    func startBlock(_ item: PlannedItem) async {
        await recordActiveIfAny()
        active = ActiveBlock(plannedID: item.id, title: item.title, start: .now,
                             timingStyle: item.timingStyle)
        selected = nil
        isOnBreak = false
        breakStart = nil
        pomoSegStart = (item.timingStyle == .pomodoro) ? .now : nil   // 番茄钟从工作段起
        pomoIsRest = false
        pomoWorkSegmentsDone = 0
        breakCount = 0
        refreshPreview()
        if let s = liveSnapshot() { liveActivity.start(s) }
    }

    /// 换一件：结束当前 → 把目标设为「待开始」（**不立即开始**）；要再点「开始任务」才计时。
    func switchTo(_ item: PlannedItem) async {
        await recordActiveIfAny()
        active = nil
        pomoSegStart = nil
        selected = item
        refreshPreview()
        liveActivity.end()
    }

    /// 开始之前「换一件」选中的那件。
    func startSelected() async {
        guard let s = selected else { return }
        await startBlock(s)
    }

    /// 同时开始另一件（后台并行）：不动前台正在计时的块，这件在后台自己按墙钟跑。
    func startAlso(_ item: PlannedItem) {
        guard item.id != active?.plannedID,
              !isRunningInBackground(item) else { return }
        background.append(BackgroundRun(plannedID: item.id, title: item.title, start: .now))
        refreshPreview()   // 从橙色预览里剔除它（正在做，不该再出现在"从现在起"）
    }

    /// 完成一件后台并行任务 → 记 [start, now] 进蓝色实际 → 移出后台。
    func completeBackground(_ id: UUID) async {
        guard let i = background.firstIndex(where: { $0.id == id }) else { return }
        let run = background.remove(at: i)
        done.append(ActualRecord(plannedID: run.plannedID, title: run.title,
                                 start: run.start, end: .now))
        // 后台块也是一次会话（墙钟粗计时，不计段数/休息）
        sessionStore?.record(blockID: run.plannedID, title: run.title,
                             start: run.start, end: .now,
                             timingStyle: TimingStyle.none,
                             pomodoroWorkSegments: nil, interruptions: 0)
        await flushActuals()
        refreshPreview()
    }

    /// 完成当前块 → 落盘 → 回到空档（不自动开下一件，由你按「下一件」）。
    func completeCurrent() async {
        await recordActiveIfAny()
        active = nil
        pomoSegStart = nil
        refreshPreview()
        liveActivity.end()
    }

    /// 单按钮 toggle：开始休息 ⇄ 结束休息。休息=暂停（保留当前块），结束后回来继续同一件。
    func toggleBreak() async {
        if isOnBreak {
            if let bs = breakStart {
                let pause = Date.now.timeIntervalSince(bs)
                if active != nil { active?.pausedTotal += pause }
                // 番茄段起点同步后移，让「段内已用」把这段休息扣掉（休息=暂停，段不吃休息时间）
                if let seg = pomoSegStart { pomoSegStart = seg.addingTimeInterval(pause) }
            }
            isOnBreak = false
            breakStart = nil
        } else {
            isOnBreak = true
            breakStart = .now
            if active != nil { breakCount += 1 }   // 中途休息计入会话 interruptions
        }
        if let s = liveSnapshot() { liveActivity.update(s) }
    }

    /// 按标题把某块标完成（App Intent「标记完成」/ Claude Code 完成信号 §2.1 路径c）。
    /// 相似度 ≥0.6 的最佳匹配：前台块 → completeCurrent（保真计时）；后台并行块 → completeBackground；
    /// 其余计划块 → 按计划时段记实际（同「提醒打勾」被动信号口径）。返回匹配标题，nil=没找到。
    @discardableResult
    func markDone(titleLike title: String) async -> String? {
        if !loaded { await loadToday() }
        if let a = active, TitleMatch.similarity(a.title, title) >= 0.6 {
            let t = a.title
            await completeCurrent()
            return t
        }
        if let run = background.first(where: { TitleMatch.similarity($0.title, title) >= 0.6 }) {
            await completeBackground(run.id)
            return run.title
        }
        let candidates = planned.filter { !isDone($0) }
        guard let best = candidates.max(by: {
                  TitleMatch.similarity($0.title, title) < TitleMatch.similarity($1.title, title) }),
              TitleMatch.similarity(best.title, title) >= 0.6 else {
            DevLog.shared.warn("执行", "标记完成：今日计划里没找到匹配「\(title)」的块")
            return nil
        }
        done.append(ActualRecord(plannedID: best.id, title: best.title,
                                 start: best.start, end: best.end))
        await flushActuals()
        // 同步等预览更新（不 fire-and-forget）：Intent 返回时状态已就绪；
        // 也避免游离 Task 活过调用方作用域（单测里曾撞已析构的内存库 → SwiftData trap）。
        await updatePreview()
        DevLog.shared.info("执行", "标记完成：\(best.title)（来自快捷指令/外部信号）")
        return best.title
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
        // 执行会话落库（M6b 细化）：净时长 + 番茄段数 + 休息次数，给趋势统计铺数据
        sessionStore?.record(blockID: a.plannedID, title: a.title,
                             start: a.start, end: a.start.addingTimeInterval(effective),
                             timingStyle: a.timingStyle,
                             pomodoroWorkSegments: a.timingStyle == .pomodoro ? pomoWorkSegmentsDone : nil,
                             interruptions: breakCount)
        pomoWorkSegmentsDone = 0
        breakCount = 0
        await flushActuals()
    }

    /// 把 done 写进蓝色「实际」日历——**合并不覆盖**（工程债修复 2026-07-04）：
    /// 先读日历已有实际、与 done 做 union 再写，别处产生的实际（复盘回填/另一台设备）不会被删。
    private func flushActuals() async {
        let drafts = done.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .actual)
        }
        guard !drafts.isEmpty else { return }
        do {
            let existing = (try? await calendarStore.read(kind: .actual)) ?? []
            let merged = CalendarMerge.union(existing: existing, additions: drafts, kind: .actual)
            try await calendarStore.write(merged)
            DevLog.shared.info("执行", "实际日历已更新：本次 \(drafts.count) 项 · 合并后 \(merged.count) 项")
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
            // ② 之后接着排剩余（排除已做 + 前台正在做 + 后台并行），从①的预测结束起
            var excluded = done.map(\.title)
            if let a = active { excluded.append(a.title) }
            excluded.append(contentsOf: background.map(\.title))
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
