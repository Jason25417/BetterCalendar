//
//  TimelineCoordinator.swift
//  BetterCalendar
//
//  时间线协调器（E5b，设计=E5+P-技术设计方案.md D1/D7/D10/D12）：统一时间线引擎的生产宿主。
//  职责四件：算（事件驱动 → FluidLayoutEngine 纯函数重算）· 写（位移超阈值才落绿真相源，节流）·
//  标（发布软溢出派生态，不落库——沿「候补」先例）· 记（每次真写落变更痕迹）。
//
//  影子期契约（D7，E5f 翻闸前）：
//  · 只在**已开工的实时日**动真相（startedDays 闸）——未开工日子的绿仍只由确认/对账写；
//  · 不调 projection（实时日绿色本来清空、画面归 updatePreview 橙色链）——翻闸后才接管投影；
//  · 三层分频（§14.1）：计算=事件驱动+分钟兜底（搭执行层 1s 守护 ticker，不新增定时器）；
//    执行=位移 ≥10 分钟或顺序变化才写；呈现=写后发 planChangedExternally（带自家标记防自激）。
//  手改冷却（D12）：对账回流/亲手编辑的块 30 分钟内映射为钉死——用户最后动作赢（对账合同延伸）。
//

import Foundation
import Observation

/// 时长校准（D4，§14.3）：占线宽度 = 标称 × 倍率；标称呈现不动（绝不顶嘴）。
/// v1=全局默认表（计划谬误基率：中位低估 20–40% → 出厂带余量）；L5 后按桶替换。
nonisolated enum DurationCalibration {
    static let defaultMultiplier = 1.25
}

@MainActor
@Observable
final class TimelineCoordinator {
    /// 执行层写回阈值（分钟）：小于它的抖动只更新内存态，不碰真相源与日历（防同步风暴+漂移不安感）。
    static let writeThresholdMinutes = 10
    /// 手改冷却窗（分钟）：窗内该块映射为钉死，别的块绕它走。
    static let manualHoldMinutes = 30
    /// App 内亲手编辑/确认写入后发（HomeViewModel confirm 一行 post）——Coordinator 借此重算。
    static let planEdited = Notification.Name("bc.timeline.planEdited")

    // MARK: 依赖（组装点注入）
    private let planStore: PlanReading & PlanWriting & ActualReading
    private let startedDays: StartedDayStore
    private let traces: ChangeTraceStore
    weak var progress: (any ExecutionProgressReading)?
    /// 时钟注入（测试用固定时刻；生产=真实时钟）。
    let now: () -> Date

    // MARK: 派生态（观察窗/UI 消费）
    /// 软溢出标记（D5 派生态，不落库）：本轮排布装不下的块。全屏层弱显示，menu bar 永不显示。
    private(set) var softSpilledIDs: Set<UUID> = []
    private(set) var lastComputeAt: Date?
    private(set) var lastWriteNote: String = "（尚未写回）"
    /// 手改冷却表：blockID → 冷却截止时刻。
    private(set) var manualHolds: [UUID: Date] = [:]

    private var listeners: [Task<Void, Never>] = []
    /// 观察窗弱引用桥（开发期，同 ExecutionBridge 先例；M8 摘除）。
    static weak var sharedForDev: TimelineCoordinator?

    init(planStore: PlanReading & PlanWriting & ActualReading,
         startedDays: StartedDayStore,
         traces: ChangeTraceStore,
         now: @escaping () -> Date = { .now }) {
        self.planStore = planStore
        self.startedDays = startedDays
        self.traces = traces
        self.now = now
    }

    // App 级常驻（组装点单例），无 deinit 清理需求；listeners 的 Task 随进程生命周期走。

    /// 订阅事件源（D10 四源之三；第四源=分钟兜底由执行层 minutePulse 闭包直调 notePulse）。
    /// 测试 host 不订阅（防单测经通知驱动真实协调器写真库——isTestHost 闸惯例）。
    func start() {
        guard !TestHost.isActive else { return }
        listeners.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: ExecutionProgressSignal.changed) {
                await self?.recompute(reason: "执行进展")
            }
        })
        listeners.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: ReconcileService.planChangedExternally) {
                guard let self else { return }
                // 自家写回也发这个通知（刷新 UI 用）——跳过防自激
                if note.userInfo?["source"] as? String == "timelineCoordinator" { continue }
                // 对账回流的块进手改冷却（D12：用户最后动作赢）
                if let ids = note.userInfo?["updatedIDs"] as? [UUID] {
                    self.noteManualEdits(ids: ids)
                }
                await self.recompute(reason: "外部变更")
            }
        })
        listeners.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: Self.planEdited) {
                await self?.recompute(reason: "计划编辑")
            }
        })
    }

    /// 分钟兜底脉冲（执行层守护 ticker 每 60 tick 调一次）：纯函数重算，无变化零写入。
    func notePulse() {
        guard !TestHost.isActive else { return }   // 测试 host 的真协调器不动真库
        Task { await recompute(reason: "分钟兜底") }
    }

    /// 手改冷却登记（D12 用户最后动作赢）：对账回流/亲手编辑的块，窗内映射为钉死、别的块绕它走。
    func noteManualEdits(ids: [UUID]) {
        let until = now().addingTimeInterval(TimeInterval(Self.manualHoldMinutes * 60))
        for id in ids { manualHolds[id] = until }
    }

    // MARK: 核心循环

    @discardableResult
    func recompute(reason: String) async -> Int {
        let now0 = now()
        let today = DayContext.logicalStartOfDay(now0)
        // 影子闸（D7）：只在已开工的实时日动真相；E5f 翻闸时移除此 guard
        guard startedDays.isStarted(today) else {
            softSpilledIDs = []
            return 0
        }
        guard let blocks = try? planStore.plannedBlocks(on: today) else { return 0 }
        let cleared = (try? planStore.clearedPlannedIDs(on: today)) ?? []
        let settled = progress?.settledPlannedIDs ?? []
        let prediction = progress?.activePrediction
        // 过期冷却清理
        manualHolds = manualHolds.filter { $0.value > now0 }

        let workEnd = PinSchedule.workEnd(forLabel: today)
            .addingTimeInterval(TimeInterval(WorkHoursSettings.graceMinutes * 60))
        let dayEnd = PinSchedule.dayInterval(forLabel: today).end

        // 剩余候选：未落定、未清除；晚间豁免（原排收工线后的块钉原位不参与——V2 等价）
        let candidates = blocks.filter { b in
            !settled.contains(b.id) && !cleared.contains(b.id) && b.start < workEnd
        }
        let from = max(now0, prediction?.end ?? now0)
        let modules = candidates.map { b -> FluidModule in
            let held = manualHolds[b.id] != nil
            let dur = b.end.timeIntervalSince(b.start)
            let calibrated = (b.isFixed || b.isAnchor || held)
                ? nil : dur * DurationCalibration.defaultMultiplier
            return FluidModule(
                id: b.id, title: b.title, duration: dur,
                fluidity: held ? .pinned : FluidityTable.resolve(b),
                priority: b.priority, plannedStart: b.start,
                occupiedDuration: calibrated,
                family: b.family, parallelGroup: b.parallelGroup,
                hardEndOverride: b.priority == .important ? dayEnd : nil)
        }

        let result = FluidLayoutEngine.layOut(modules: modules, from: from, hardEnd: workEnd)
        softSpilledIDs = Set(result.overflow)
        lastComputeAt = now0
        let threshold = TimeInterval(Self.writeThresholdMinutes * 60)
        var wrote = 0

        // 活动块行维护（D-2「绿=活预报」）：[实际开始, 预测结束]——同受阈值节流
        if let pr = prediction, let row = blocks.first(where: { $0.id == pr.id }),
           abs(row.start.timeIntervalSince(pr.start)) >= threshold
            || abs(row.end.timeIntervalSince(pr.end)) >= threshold {
            try? planStore.updatePlanned(id: pr.id, start: pr.start, end: pr.end, title: row.title)
            traces.append(ChangeTraceEntry(time: now0, blockID: pr.id, title: row.title, kind: "活动预报",
                                           beforeStart: row.start, beforeEnd: row.end,
                                           afterStart: pr.start, afterEnd: pr.end,
                                           reason: "进行中的事按实际节奏更新预报"),
                          day: today)
            wrote += 1
        }

        // 执行层节流（写回判据）：任一位移 ≥ 阈值 或 顺序变化 才落库；否则内存态而已
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let moves = result.placed.compactMap { p -> (block: ScheduledBlock, p: FluidLayoutResult.Placement)? in
            guard let b = byID[p.id], abs(p.start.timeIntervalSince(b.start)) >= 1 else { return nil }
            return (b, p)
        }
        let bigMove = moves.contains { abs($0.p.start.timeIntervalSince($0.block.start)) >= threshold }
        let placedIDs = Set(result.placed.map(\.id))
        let currentOrder = candidates.filter { placedIDs.contains($0.id) }
            .sorted { $0.start < $1.start }.map(\.id)
        let newOrder = result.placed.sorted { $0.start < $1.start }.map(\.id)
        let orderChanged = currentOrder != newOrder

        if bigMove || (orderChanged && !moves.isEmpty) {
            for (b, p) in moves {
                try? planStore.updatePlanned(id: b.id, start: p.start, end: p.end, title: b.title)
                traces.append(ChangeTraceEntry(time: now0, blockID: b.id, title: b.title, kind: "顺延",
                                               beforeStart: b.start, beforeEnd: b.end,
                                               afterStart: p.start, afterEnd: p.end,
                                               reason: "顺延维护：保持「从现在起可行」（\(reason)）"),
                              day: today)
            }
            wrote += moves.count
        }

        guard wrote > 0 else { return 0 }
        lastWriteNote = "\(reason)：写回 \(wrote) 块（软标 \(softSpilledIDs.count)）"
        DevLog.shared.info("时间线", lastWriteNote)
        // 呈现层通知（带自家标记防自激）：排日程页干净则重载、编辑中亮徽标——复用现成分流
        NotificationCenter.default.post(name: ReconcileService.planChangedExternally, object: nil,
                                        userInfo: ["source": "timelineCoordinator"])
        // 影子期不调 projection（D7）：实时日绿色本来清空，真相变化无画面语义；翻闸后接管投影
        return wrote
    }
}
