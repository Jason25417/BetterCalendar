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
//    外部变更只认真外部来源：本机保存回声（DataSyncMonitor 标 localStoreSave）不触发重算（B10，见 PlanChangeSource）。
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
    /// 溢出硬执行的去向（E5c）：收待办区/回长期池。nil=不接池（测试可省）。
    weak var longTasks: LongTaskStore?
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

    /// 溢出结算的幂等标记库（注入=测试不污染真实 UserDefaults——共享默认库的老坑）。
    private let markerDefaults: UserDefaults

    init(planStore: PlanReading & PlanWriting & ActualReading,
         startedDays: StartedDayStore,
         traces: ChangeTraceStore,
         markerDefaults: UserDefaults = .standard,
         now: @escaping () -> Date = { .now }) {
        self.planStore = planStore
        self.startedDays = startedDays
        self.traces = traces
        self.markerDefaults = markerDefaults
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
                await self.handlePlanChangedExternally(userInfo: note.userInfo)
            }
        })
        listeners.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: Self.planEdited) {
                await self?.recompute(reason: "计划编辑")
            }
        })
    }

    /// planChangedExternally 的分流（B10 修复，P4.0-7）：
    /// · 自家写回（timelineCoordinator）与本机保存回声（localStoreSave）→ 不重算——否则「写 → 保存 → 回声 → 重算 → 又写」自激；
    /// · 带 updatedIDs 的（日历手改回流 / 智能体批准的挪块）→ 先进手改冷却（D12 用户最后动作赢），再重算；
    /// · CloudKit 导入、显式重新读取、没标来源的旧发出方 → 照常当外部变更重算。
    /// 返回本次写回的块数（不重算 = 0）。
    @discardableResult
    func handlePlanChangedExternally(userInfo: [AnyHashable: Any]?) async -> Int {
        let source = userInfo?[PlanChangeSource.key] as? String
        if let source, PlanChangeSource.ignoredByCoordinator.contains(source) { return 0 }
        if let ids = userInfo?["updatedIDs"] as? [UUID] {
            noteManualEdits(ids: ids)
        }
        return await recompute(reason: "外部变更")
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
        SmokeLog.hit("手改冷却", "\(ids.count) 块进 30min 冷却")
    }

    // MARK: 一键撤（E5d，D6：预授权直写绿的配套义务）

    /// 撤销今天的自动位移（顺延/活动预报/晨间投放）：逆序回放前像 → 终态=当天最早的原位。
    /// 收池不在撤销范围（它经过了收工复盘的逐件可改环节）。撤完的块进手改冷却——
    /// 撤销是用户显式动作，协调器不许下一秒又把它们挪回去（D12 用户最后动作赢）。
    @discardableResult
    func undoToday() -> Int {
        let today = DayContext.logicalStartOfDay(now())
        let movable: Set<String> = ["顺延", "活动预报", "晨间投放"]
        let entries = traces.entries(day: today).filter { movable.contains($0.kind) }
        guard !entries.isEmpty else { return 0 }
        var restored: Set<UUID> = []
        for e in entries.reversed() {   // 逆序回放：终态=每块最早的前像
            guard let blocks = try? planStore.plannedBlocks(on: today),
                  blocks.contains(where: { $0.id == e.blockID }) else { continue }
            try? planStore.updatePlanned(id: e.blockID, start: e.beforeStart, end: e.beforeEnd,
                                         title: e.title, reason: .undo)
            restored.insert(e.blockID)
        }
        guard !restored.isEmpty else { return 0 }
        noteManualEdits(ids: Array(restored))
        traces.append(ChangeTraceEntry(time: now(), blockID: restored.first ?? UUID(),
                                       title: "撤销 \(restored.count) 块", kind: "撤销",
                                       beforeStart: now(), beforeEnd: now(),
                                       afterStart: now(), afterEnd: now(),
                                       reason: "按你的要求恢复今天的自动调整"),
                      day: today)
        lastWriteNote = "撤销：恢复 \(restored.count) 块"
        DevLog.shared.info("时间线", lastWriteNote)
        SmokeLog.hit("一键撤", "恢复 \(restored.count) 块到原位")
        NotificationCenter.default.post(name: ReconcileService.planChangedExternally, object: nil,
                                        userInfo: [PlanChangeSource.key: PlanChangeSource.timelineCoordinator])
        return restored.count
    }

    /// 今日自动调整计数（晨间摘要/痕迹条用；撤销条目不算「调整」）。
    func todayTraceCount() -> Int {
        traces.entries(day: DayContext.logicalStartOfDay(now())).filter { $0.kind != "撤销" }.count
    }

    /// 今日痕迹（sheet 列表用，时间正序）。
    func todayTraces() -> [ChangeTraceEntry] {
        traces.entries(day: DayContext.logicalStartOfDay(now()))
    }

    // MARK: 溢出硬执行（E5c，两阶段溢出的第二阶段）

    /// 复盘展开逐件可改的覆写（收待办[默认]/排明天/就算了）：seal 时随硬执行消费。
    private(set) var spillOverrides: [UUID: SpillPolicy] = [:]
    func setSpillOverride(_ id: UUID, policy: SpillPolicy?) {
        spillOverrides[id] = policy
    }

    /// 某逻辑日的溢出候选（今日与过去日统一派生口径——软标是派生态，过去日重导同一规则）：
    /// 计划行中「无实际、无清除墓碑、非固定块、原排在收工线前」者=没做成的溢出物。
    func pendingSpillCandidates(day: Date) -> [ScheduledBlock] {
        guard let blocks = try? planStore.plannedBlocks(on: day) else { return [] }
        let actualIDs = Set(((try? planStore.actualBlocks(on: day)) ?? []).map(\.id))
        let cleared = (try? planStore.clearedPlannedIDs(on: day)) ?? []
        let workEnd = PinSchedule.workEnd(forLabel: day)
            .addingTimeInterval(TimeInterval(WorkHoursSettings.graceMinutes * 60))
        return blocks.filter { b in
            !b.isFixed && !actualIDs.contains(b.id) && !cleared.contains(b.id) && b.start < workEnd
        }
    }

    private func spillExecutedKey(_ day: Date) -> String { "bc.spill.executed.\(DayContext.dayKey(day))" }

    /// 硬执行某逻辑日的溢出（收工盖章时刻调；幂等闸按日一次）。返回收池件数（复盘/DevLog 用）。
    /// 默认静默：溶解=deletePlanned 零痕迹零叙事；收池=deletePlanned+待办区（昨日露脸判据）+痕迹；
    /// 排明天（用户显式选）=时间平移到明天同钟点；DDL 挡路=同收池但 DevLog 标注（晨间置顶排序在 E5d）。
    @discardableResult
    func executeSpills(day: Date) -> Int {
        guard !markerDefaults.bool(forKey: spillExecutedKey(day)) else { return 0 }
        let candidates = pendingSpillCandidates(day: day)
        guard !candidates.isEmpty else {
            markerDefaults.set(true, forKey: spillExecutedKey(day))
            return 0
        }
        let spillCs = candidates.map { b in
            SpillCandidate(id: b.id, title: b.title, deadline: b.deadline,
                           fromPool: b.linkedTaskID != nil, isAnchor: b.isAnchor,
                           policyOverride: spillOverrides[b.id])
        }
        let reference = DayContext.logicalWindow(forLabel: day).start
        var pooled = 0
        for (c, decision) in SpillResolver.resolveAll(spillCs, reference: reference) {
            guard let block = candidates.first(where: { $0.id == c.id }) else { continue }
            switch decision {
            case .dissolve:
                try? planStore.deletePlanned(ids: [c.id], reason: .spill)   // 零记录、明天照常、不进偏差叙事
            case .forward(let target):
                // 用户显式「排到明天」：同钟点平移（懒物化——明天重算时自然归位）
                let shift = target.timeIntervalSince(day)
                try? planStore.updatePlanned(id: c.id, start: block.start.addingTimeInterval(shift),
                                             end: block.end.addingTimeInterval(shift), title: block.title,
                                             reason: .spill)
                traces.append(ChangeTraceEntry(time: now(), blockID: c.id, title: c.title, kind: "顺延",
                                               beforeStart: block.start, beforeEnd: block.end,
                                               afterStart: block.start.addingTimeInterval(shift),
                                               afterEnd: block.end.addingTimeInterval(shift),
                                               reason: "按你的选择排到明天"),
                              day: day)
            case .returnToPool, .escalate:
                // 收待办区（池投放件回它的长期任务——addTodo 的归属让路自动处理）；
                // escalate（DDL 挡路/显式 ask）同收池但保露脸：晨间摘要置顶（E5d 按 DDL 排序）
                try? planStore.deletePlanned(ids: [c.id], reason: .spill)
                longTasks?.addTodo(title: c.title,
                                   family: block.family,
                                   spilledFromDay: day,
                                   deadline: block.deadline)   // E5d：DDL 保留→晨间置顶
                traces.append(ChangeTraceEntry(time: now(), blockID: c.id, title: c.title, kind: "收池",
                                               beforeStart: block.start, beforeEnd: block.end,
                                               afterStart: block.start, afterEnd: block.end,
                                               reason: "今天没排下——收进待办区，明早会露脸"),
                              day: day)
                pooled += 1
                if case .escalate(.deadlineBlocksForward) = decision {
                    DevLog.shared.warn("溢出", "「\(c.title)」带 DDL 收池——晨间必须置顶露脸")
                }
            }
        }
        markerDefaults.set(true, forKey: spillExecutedKey(day))
        spillOverrides = [:]
        softSpilledIDs = []
        DevLog.shared.info("溢出", "硬执行 \(DayContext.dayKey(day))：候选 \(candidates.count) · 收池 \(pooled)")
        SmokeLog.hit("收工硬执行", "候选 \(candidates.count) · 收池 \(pooled)")
        return pooled
    }

    /// 启动兜底：过去 7 天里「已过去且未结算」的日子补执行（先 fold 残差再执行——数据面不相交，
    /// 顺序仅为叙事清晰；今天不在此列，今天的硬执行只发生在收工盖章）。
    /// 祖父条款：首次启用只把过去日全部标记为已结算、不动数据——E5c 之前的历史遗留块
    /// 不搞一次性洪水入池（追溯式收池会把旧账突然堆进待办区，违背无维护义务的池铁律）。
    func executePendingSpills() {
        let today = DayContext.logicalStartOfDay(now())
        let initKey = "bc.spill.backstop.initialized"
        let initialized = markerDefaults.bool(forKey: initKey)
        for offset in 1...7 {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: today) else { continue }
            if initialized {
                executeSpills(day: day)
            } else {
                markerDefaults.set(true, forKey: spillExecutedKey(day))   // 祖父：只销账不动数据
            }
        }
        markerDefaults.set(true, forKey: initKey)
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
            try? planStore.updatePlanned(id: pr.id, start: pr.start, end: pr.end, title: row.title,
                                         reason: .timelineCoordinator)
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
                try? planStore.updatePlanned(id: b.id, start: p.start, end: p.end, title: b.title,
                                             reason: .timelineCoordinator)
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
        SmokeLog.hit("影子直写绿", "\(reason)·写回 \(wrote)·软标 \(softSpilledIDs.count)")
        // 呈现层通知（带自家标记防自激）：排日程页干净则重载、编辑中亮徽标——复用现成分流
        NotificationCenter.default.post(name: ReconcileService.planChangedExternally, object: nil,
                                        userInfo: [PlanChangeSource.key: PlanChangeSource.timelineCoordinator])
        // 影子期不调 projection（D7）：实时日绿色本来清空，真相变化无画面语义；翻闸后接管投影
        return wrote
    }
}
