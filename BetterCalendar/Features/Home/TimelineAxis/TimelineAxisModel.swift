//
//  TimelineAxisModel.swift
//  BetterCalendar
//
//  W23 时间轴的数据与直接操作（ViewModel）。
//  读：计划块（PlanStore，跨今天前 3 天到后 7 天）+ 做成的事（今天 = 执行陪伴的「做成了」，过去 = PlanStore 实际）+
//      正在做（执行陪伴）+ 你的日历（CalendarReading，只读，按「排布时当作已占用的日历」设置过滤）。
//  写：只有拖动 / 拉长缩短——先按 W18 的 PlanEditRules（与智能体同一套排布规则：固定不挪、不重叠、不进过去、
//      不越截止、不跨 4:00）校验，放不下就**写明原因、什么都不改**（绝不悄悄挤）；过了才交给 HomeViewModel 的
//      W19b 原路保存（改列表 → 立即保存 → 你拖的块钉成图钉 → CalendarSyncEngine 重投影）。本类从不碰日历写。
//

import Foundation
import Observation

/// 时间轴要的「执行陪伴」那一面（今天做成了什么、正在做什么）；ExecutionViewModel 实现，测试换假的。
@MainActor protocol AxisLiveSource: ExecutionProgressReading {
    /// 今天做成的事（不含被动推断的自动完成）。
    var axisTodayDone: [AxisActual] { get }
    /// 正在做（前台 + 后台同时做）。
    var axisRunning: [AxisRunning] { get }
}

extension ExecutionViewModel: AxisLiveSource {
    var axisTodayDone: [AxisActual] {
        done.filter { !$0.isAuto }.map { AxisActual(title: $0.title, start: $0.start, end: $0.end, plannedID: $0.plannedID) }
    }
    var axisRunning: [AxisRunning] {
        var out: [AxisRunning] = []
        if let a = active { out.append(AxisRunning(plannedID: a.plannedID, title: a.title, start: a.start)) }
        out += background.map { AxisRunning(plannedID: $0.plannedID, title: $0.title, start: $0.start) }
        return out
    }
}

/// W23 开关：今天页用时间轴（关 = W19 的卡片列表，行为与没有这个功能完全一致）。
/// 日用版纪律（W17）本该默认关；**有意偏离**：2026-10-19 Jason 拍板日用版也默认打开试（两个通道都默认开），
/// 设置里随时可关回卡片列表；随 iCloud 设置同步。
enum TimelineAxisSettings {
    static let key = "today.timelineAxis.enabled"
    /// 键不存在时的默认（给 @AppStorage 用，不写回）。
    static var defaultValue: Bool { true }
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@Observable @MainActor
final class TimelineAxisModel {
    /// 往前看几天（做成的事）。
    static let daysBack = 3
    /// 往后几天 = 可排范围（与 W18 一致：智能体看得到、能排的也就是这几天）。
    static let daysForward = PlanEditRules.horizonDays

    private let plans: PlanReading
    private let actualsReader: ActualReading
    private let calendar: CalendarReading
    private weak var live: (any AxisLiveSource)?
    private let home: HomeViewModel
    private let clock: () -> Date

    /// 此刻（闸门位置）。页面每分钟更新一次（离散跳动，R3：不做连续流动动画）。
    private(set) var now: Date
    private(set) var labels: [Date]
    private(set) var storedPlanned: [ScheduledBlock] = []
    private(set) var pastActuals: [AxisActual] = []
    private(set) var occupied: [SystemCalendarEvent] = []
    /// 读你的日历失败（开发期可见；这期间拖动不校验 = 不写，原则 10 不假装它是空的）。
    private(set) var occupiedError: String?
    /// 一条要你看见的话：放不下的原因、改动没落地等。中性措辞，可点掉。
    var notice: String?
    /// 正在落一次拖动（防连点）。
    private(set) var isCommitting = false
    private var lastOccupiedLoad: Date?

    init(plans: PlanReading, actuals: ActualReading, calendar: CalendarReading, live: (any AxisLiveSource)?,
         home: HomeViewModel, now: @escaping () -> Date = { .now }) {
        self.plans = plans; self.actualsReader = actuals; self.calendar = calendar
        self.live = live; self.home = home; self.clock = now
        let n = now()
        self.now = n
        self.labels = AxisGeometry.labels(now: n, back: Self.daysBack, forward: Self.daysForward)
    }

    var todayLabel: Date { DayContext.logicalStartOfDay(now) }

    // MARK: 读

    /// 重读计划 / 实际（便宜：几百行内存过滤）；你的日历按需（打开、回前台、每 5 分钟）。
    func reload(includeCalendar: Bool = true) async {
        now = clock()
        labels = AxisGeometry.labels(now: now, back: Self.daysBack, forward: Self.daysForward)
        do { storedPlanned = try plans.plannedBlocks(onLabels: labels) } catch {
            DevLog.shared.error("今天页", "时间轴读计划失败：\(error.localizedDescription)")
            notice = "这次没读到计划（\(error.localizedDescription)）——稍后会自动再读"
        }
        var past: [AxisActual] = []
        for label in labels where label < todayLabel {
            do {
                past += try actualsReader.actualBlocks(on: label)
                    .filter { $0.state != .auto }   // 被动推断的只记数据、不画蓝
                    .map { AxisActual(title: $0.title, start: $0.start, end: $0.end, plannedID: $0.id) }
            } catch {
                DevLog.shared.warn("今天页", "时间轴读 \(PlanEditRules.dayName(label)) 做成的事失败：\(error.localizedDescription)")
            }
        }
        pastActuals = past
        if includeCalendar || lastOccupiedLoad.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
            await loadOccupied()
        }
    }

    /// 每分钟一次：闸门挪到新位置；顺手重读（你的日历 5 分钟一次）。
    func tick() async { await reload(includeCalendar: false) }

    private var window: DateInterval {
        DateInterval(start: DayContext.logicalWindow(forLabel: labels.first ?? todayLabel).start,
                     end: DayContext.logicalWindow(forLabel: labels.last ?? todayLabel).end)
    }

    private func loadOccupied() async {
        lastOccupiedLoad = now
        do {
            let events = try await calendar.externalEvents(in: window)
            occupied = ExternalCalendarSettings.busy(events, excluding: ExternalCalendarSettings.excludedTitles)
                .filter { $0.end > $0.start }
            occupiedError = nil
        } catch {
            occupiedError = "读不到你的日历（\(error.localizedDescription)）——轴上暂时不显示你的安排，拖动也先不改（没法确认会不会和你的安排撞上）"
            DevLog.shared.warn("今天页", "时间轴读你的日历失败：\(error.localizedDescription)")
        }
    }

    /// 轴上要画的全部（纯函数组装）。正在编辑的那一天用编辑中的版本（改完马上看得见，不等自动保存）。
    func days() -> [AxisDay] {
        var planned = storedPlanned
        if let page = home.pageDay, labels.contains(page) {
            let pins = Dictionary(storedPlanned.map { ($0.id, $0.pinnedUntil) }, uniquingKeysWith: { a, _ in a })
            planned.removeAll { DayContext.logicalStartOfDay($0.start) == page }
            planned += home.blocks.map { eb in
                var b = eb.scheduled
                b.pinnedUntil = pins[eb.id] ?? nil
                return b
            }
        }
        let todayDone = live?.axisTodayDone ?? []
        return TimelineAxisComposer.compose(AxisInput(
            labels: labels, now: now, planned: planned, actuals: pastActuals + todayDone,
            running: live?.axisRunning ?? [], occupied: occupied, windDownHour: WorkHoursSettings.windDownHour))
    }

    /// 今天从现在起还有没有绿色（收尾卡的「剩余为空」信号用）。
    func hasRemainingToday(in days: [AxisDay]) -> Bool {
        days.first { $0.label == todayLabel }?.items.contains { $0.kind == .plan && !$0.isRunning } ?? false
    }

    // MARK: 写：拖动 / 拉长缩短

    /// 拖到新开始时刻（吸附 5 分钟）：保时长。返回 nil = 已落地（或没变）；否则 = 没改的原因。
    @discardableResult
    func commitDrag(_ item: AxisItem, start rawStart: Date) async -> String? {
        guard item.isDraggable, let id = item.blockID, let ps = item.plannedStart, let pe = item.plannedEnd else { return nil }
        let start = AxisGeometry.snap(rawStart)
        let end = start.addingTimeInterval(pe.timeIntervalSince(ps))
        guard start != ps else { return nil }
        return await commit(id: id, label: DayContext.logicalStartOfDay(ps), start: start, end: end,
                            step: .move(ProposalBlockMove(id: id, start: start, end: end, expectedRevision: nil)))
    }

    /// 拉底边改结束时刻（吸附 5 分钟）：开始不动。返回同 commitDrag。
    @discardableResult
    func commitResize(_ item: AxisItem, end rawEnd: Date) async -> String? {
        guard item.isDraggable, let id = item.blockID, let ps = item.plannedStart, let pe = item.plannedEnd else { return nil }
        let end = AxisGeometry.snap(rawEnd)
        guard end != pe else { return nil }
        return await commit(id: id, label: DayContext.logicalStartOfDay(ps), start: ps, end: end,
                            step: .edit(ProposalBlockEdit(id: id, duration: end.timeIntervalSince(ps))))
    }

    /// 校验 → 写。返回 nil = 已落地；否则 = 没改的原因（同时放进 notice 给你看）。
    @discardableResult
    func commit(id: UUID, label: Date, start: Date, end: Date, step: ProposalPlanStep) async -> String? {
        guard !isCommitting else { return nil }
        isCommitting = true
        defer { isCommitting = false }
        // 拖动只在同一天里挪：一天一页的保存路径按天整页写，跨天要走智能体（PlanEditRules 的跨天挪 + 审批）
        guard DayContext.logicalStartOfDay(start) == label else {
            return refuse("拖动只在同一天里挪（一块不跨过凌晨 4:00 的日界线）；要挪到别的日子，跟智能体说一句")
        }
        if let occupiedError {
            return refuse(occupiedError)
        }
        // 先把这一天切进编辑页、把等着的改动存掉，校验看的就是最新的库
        await home.focusDay(label)
        await home.flushAutosave()
        do { storedPlanned = try plans.plannedBlocks(onLabels: labels) } catch {
            return refuse("这次没读到计划，没有改动：\(error.localizedDescription)")
        }
        now = clock()
        do {
            _ = try PlanEditRules.evaluate([step], in: context())
        } catch let e as ProposalExecutionError {
            return refuse(e.errorDescription ?? "放不下")
        } catch {
            return refuse(error.localizedDescription)
        }
        guard await home.applyAxisSpan(id: id, start: start, end: end) else {
            return refuse("这一块刚被别处改过或删掉了，没有改动")
        }
        if let err = home.errorText {   // 保存路径自己的失败（写库 / 提醒同步）已在页面横幅上；这里只补一句
            DevLog.shared.warn("今天页", "时间轴改动保存时有问题：\(err)")
        }
        notice = nil
        BehaviorLog.record("今天页时间轴", stepName(step))
        await reload(includeCalendar: false)
        return nil
    }

    private func stepName(_ step: ProposalPlanStep) -> String {
        if case .move = step { return "拖动挪时间" }
        return "拉底边改时长"
    }

    private func refuse(_ reason: String) -> String {
        notice = reason
        DevLog.shared.info("今天页", "时间轴改动没做：\(reason)")
        return reason
    }

    /// 与智能体同一套规则的上下文（ApprovedPlanMover.context 的同款口径：可排范围 / 已落定 / 正在做 / 你的日历）。
    func context() -> PlanEditRules.Context {
        let today = todayLabel
        let windowBlocks = storedPlanned.filter { DayContext.logicalStartOfDay($0.start) >= today }
        let settled = live?.settledPlannedIDs ?? []
        let prediction = live?.activePrediction
        var ctx = PlanEditRules.Context(blocks: windowBlocks, now: now,
                                        window: PlanEditRules.window(now: now, horizon: Self.daysForward),
                                        settledIDs: settled.subtracting(prediction.map { [$0.id] } ?? []),
                                        active: prediction.map { ($0.id, $0.start, $0.end) })
        let links = ExternalEventLinker.links(blocks: windowBlocks, events: occupied)
        ctx.occupied = occupied.map { e in
            PlanEditRules.Occupied(title: e.title, start: e.start, end: e.end, calendar: e.calendarTitle,
                                   linkedBlockID: links.first { $0.value == e }?.key)
        }
        return ctx
    }
}
