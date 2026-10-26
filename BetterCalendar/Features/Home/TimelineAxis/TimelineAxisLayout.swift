//
//  TimelineAxisLayout.swift
//  BetterCalendar
//
//  W23（Jason 2026-10-19，SPEC §13.1 统一时间线 v2 的呈现层）：「今天」页的真时间轴——纯函数层（可单测）。
//  Jason 的抽象：所有时间是一根连续的流水线；逻辑日之间靠**图钉**推进（4:00 日界线 = 零长度的图钉对象）；
//  「现在」是流水线上的**闸门**——闸门之前是计划（绿，概率性），闸门之后是实际（蓝，凝固）。
//  在屏幕上：轴自上而下 = 时间往后流；「现在」线以上是过去（只有蓝色做成的事），以下是将来（绿色计划）。
//
//  本文件只管三件事：
//    ① 几何：时间 ↔ 位置（整根轴一个线性映射，逻辑日首尾相接，夏令时那天自然多 / 少一小时）+ 5 分钟吸附；
//    ② 组装：计划块 / 实际 / 正在做 / 你的日历 → 每个逻辑日一段（含图钉）；
//    ③ 红线（统一时间线档案 §三 R1–R13，核心=「数据可以知道一切，呈现永远只朝前」）落在组装规则里：
//       - 闸门以上**只画蓝色实际**：没做的计划不留尸体 / 虚影 / 空槽 / 缺口标记（R1），不出现任何红色、「错过」；
//       - 正在做的那块跨在闸门上：蓝色画到现在，绿色只画剩下那段（复用 W9 GreenPresentation 的语义）；
//       - 当日最初计划快照只在内部（LearningStore），这里根本不读，自然不会画成 ghost（R11）；
//       - 语义图钉（收工线 / 截止 / 你钉住的块）只朝前画：闸门以上不画，过去的截止不会读成「没赶上」。
//

import Foundation
import CoreGraphics

// MARK: - ① 几何

/// 整根轴的几何：轴顶 = 第一个逻辑日的 4:00，轴底 = 最后一个逻辑日的次日 4:00。时间与位置线性对应。
struct AxisGeometry: Equatable {
    var start: Date
    var end: Date
    var pointsPerHour: CGFloat

    init(labels: [Date], pointsPerHour: CGFloat) {
        let first = labels.min() ?? DayContext.logicalStartOfDay(.now)
        let last = labels.max() ?? first
        start = DayContext.logicalWindow(forLabel: first).start
        end = DayContext.logicalWindow(forLabel: last).end
        self.pointsPerHour = pointsPerHour
    }

    /// 时刻 → 距轴顶的位置（pt）。
    func y(_ t: Date) -> CGFloat { CGFloat(t.timeIntervalSince(start) / 3600) * pointsPerHour }
    /// 位置 → 时刻（y 的逆）。
    func time(atY y: CGFloat) -> Date { start.addingTimeInterval(TimeInterval(y / pointsPerHour) * 3600) }
    /// 整根轴的高度。
    var height: CGFloat { y(end) }

    /// 某逻辑日那一段在轴上的位置（顶 = 当日 4:00 图钉，高 = 这一天的实际长度：通常 24h，夏令时那天 23 / 25h）。
    func section(_ label: Date) -> (top: CGFloat, height: CGFloat) {
        let w = DayContext.logicalWindow(forLabel: label)
        return (y(w.start), y(w.end) - y(w.start))
    }

    /// 吸附到 5 分钟（按绝对时间取整：所有整 5 分钟时差的时区里都等于本地钟面的整 5 分钟）。
    static func snap(_ t: Date, minutes: Int = 5) -> Date {
        let step = TimeInterval(max(1, minutes) * 60)
        return Date(timeIntervalSince1970: (t.timeIntervalSince1970 / step).rounded() * step)
    }

    /// 轴覆盖的逻辑日：今天往前 back 天、往后 forward 天（往后 = 可排范围，与 W18 PlanEditRules.horizonDays 一致）。
    static func labels(now: Date, back: Int, forward: Int) -> [Date] {
        (-max(0, back)...max(0, forward)).map { DayContext.logicalDay(offset: $0, from: now) }
    }
}

// MARK: - ② 组装的输入 / 输出

/// 一条做成的事（蓝）。plannedID = 对应的计划块（计划外 bonus 为 nil）。
struct AxisActual: Equatable {
    var title: String
    var start: Date
    var end: Date
    var plannedID: UUID?
}

/// 正在做（前台 / 后台同时做）。蓝色从 start 长到现在。
struct AxisRunning: Equatable {
    var plannedID: UUID?
    var title: String
    var start: Date
}

/// 轴上的一块。
struct AxisItem: Identifiable, Equatable {
    /// pastPlan（0.76，Jason 10-26 定）：整块已在闸门以上、还没记下做成的计划——淡色保留（不标「没做」），点一下可记成做完。
    enum Kind: Equatable { case plan, actual, occupied, pastPlan }
    var id: String
    var kind: Kind
    var title: String
    /// 画出来的起止（已按闸门 / 日界线截过）。
    var start: Date
    var end: Date
    /// 计划块 id（plan；以及正在做那块的蓝色）。
    var blockID: UUID? = nil
    /// 可直接拖（只有闸门以下的绿色计划；正在做的不行）。
    var isDraggable = false
    var isFixed = false
    var isImportant = false
    var isAnchor = false
    var deadline: Date? = nil
    /// 你钉住的块（你亲手拖过、当天有效）。
    var isPinned = false
    /// 正在做（蓝色那段，或它剩下的绿色那段）。
    var isRunning = false
    /// 绿色起点被闸门截过（剩下的从现在起）。
    var clippedByGate = false
    /// 你的日历名（occupied）。
    var calendarName: String? = nil
    /// 计划块在库里的起止（拖动 / 改时长以它为准；截过的绿色画的是剩下那段）。
    var plannedStart: Date? = nil
    var plannedEnd: Date? = nil
    /// 并排：第几列 / 共几列（时间重叠的块并排放）。
    var lane = 0
    var lanes = 1
}

/// 零长度的图钉。
struct AxisPin: Identifiable, Equatable {
    enum Kind: Equatable { case dayBoundary, windDown, deadline }
    var id: String
    var kind: Kind
    var at: Date
    var label: String
}

/// 一个逻辑日在轴上的一段。
struct AxisDay: Identifiable, Equatable {
    var label: Date
    var window: DateInterval
    var items: [AxisItem]
    var pins: [AxisPin]
    var id: Date { label }
}

struct AxisInput {
    var labels: [Date]
    var now: Date
    /// 各逻辑日的计划块（本页正在编辑的那天已换成编辑中的版本）。
    var planned: [ScheduledBlock]
    /// 做成的事（不含「被动推断」的自动完成——那只记数据、不画蓝，P4 Q4c）。
    var actuals: [AxisActual]
    var running: [AxisRunning] = []
    /// 你的日历事件（已按「排布时当作已占用的日历」设置过滤；全天事件不占时段，调用方先滤掉）。
    var occupied: [SystemCalendarEvent] = []
    /// 收工线小时（nil = 不画）。
    var windDownHour: Int? = nil
}

// MARK: - ③ 组装

enum TimelineAxisComposer {
    /// 太短的蓝 / 绿不画（避免一条细线）。
    static let minVisible: TimeInterval = 60

    static func compose(_ input: AxisInput) -> [AxisDay] {
        let now = input.now
        let busy = input.occupied.filter { !$0.isAllDay && $0.end > $0.start }
        // 一件事只画一次（P4 Q4）：和你日历里某件事是同一件的计划块不画绿——你那一份（灰）就是它
        let linked = Set(ExternalEventLinker.links(blocks: input.planned, events: busy).keys)

        // 绿色：GreenPresentation 的语义（做完的让位；正在做的只画蓝色尽头之后）
        var presentActuals: [UUID: ActualBlock] = [:]
        for a in input.actuals { if let id = a.plannedID { presentActuals[id] = ActualBlock(id: id, title: a.title, start: a.start, end: a.end) } }
        for r in input.running {
            if let id = r.plannedID { presentActuals[id] = ActualBlock(id: id, title: r.title, start: r.start, end: now, state: .live) }
        }
        let runningIDs = Set(input.running.compactMap(\.plannedID))
        let green = GreenPresentation.present(blocks: input.planned, actuals: presentActuals, linked: linked)

        var all: [AxisItem] = []
        for g in green.drawn {
            // 0.76（Jason 10-26 改 R1）：整块在过去、还没记下做成的 → 淡色留在闸门以上（流水线照常往上走），点一下可记做完；
            // 跨着现在的只画剩下那段（绿）
            if g.end <= now, !runningIDs.contains(g.block.id) {
                guard g.end.timeIntervalSince(g.start) >= minVisible else { continue }
                let b = g.block
                all.append(AxisItem(id: "past-\(b.id.uuidString)", kind: .pastPlan, title: b.title, start: g.start, end: g.end,
                                    blockID: b.id, isFixed: b.isFixed, isAnchor: b.isAnchor,
                                    plannedStart: b.start, plannedEnd: b.end))
                continue
            }
            let from = max(g.start, now)
            guard g.end.timeIntervalSince(from) >= minVisible else { continue }
            let b = g.block
            let running = runningIDs.contains(b.id)
            all.append(AxisItem(id: "plan-\(b.id.uuidString)", kind: .plan, title: b.title, start: from, end: g.end,
                                blockID: b.id, isDraggable: !running, isFixed: b.isFixed,
                                isImportant: b.priority == .important, isAnchor: b.isAnchor, deadline: b.deadline,
                                isPinned: b.isPinned(at: now), isRunning: running, clippedByGate: from > b.start,
                                plannedStart: b.start, plannedEnd: b.end))
        }
        // 蓝色：做成的事（闸门以上；记下的结束不会晚于现在，防御性截到现在）
        for (i, a) in input.actuals.enumerated() {
            let end = min(a.end, now)
            guard end.timeIntervalSince(a.start) >= minVisible else { continue }
            all.append(AxisItem(id: "actual-\(a.plannedID?.uuidString ?? "bonus\(i)")-\(Int(a.start.timeIntervalSince1970))",
                                kind: .actual, title: a.title, start: a.start, end: end, blockID: a.plannedID))
        }
        // 正在做：蓝色从开始长到现在（不足 1 分钟也画一小段：它确实在发生）
        for (i, r) in input.running.enumerated() where now > r.start {
            all.append(AxisItem(id: "running-\(r.plannedID?.uuidString ?? "bonus\(i)")", kind: .actual, title: r.title,
                                start: r.start, end: max(now, r.start.addingTimeInterval(minVisible)),
                                blockID: r.plannedID, isRunning: true))
        }
        // 已占用：你的日历（灰、只读；过去和将来都画——那是你的事实，不是债）
        for (i, e) in busy.enumerated() {
            all.append(AxisItem(id: "occ-\(i)-\(Int(e.start.timeIntervalSince1970))", kind: .occupied, title: e.title,
                                start: e.start, end: e.end, calendarName: e.calendarTitle))
        }

        return input.labels.sorted().map { label in
            let window = DayContext.logicalWindow(forLabel: label)
            // 跨日界线的（多半是实际 / 你的事件）按这一天的窗口截开，两边各画一段
            var items: [AxisItem] = all.compactMap { it in
                let s = max(it.start, window.start), e = min(it.end, window.end)
                guard e > s else { return nil }
                var c = it
                if s != it.start || e != it.end { c.id += "@\(Int(window.start.timeIntervalSince1970))" }
                c.start = s; c.end = e
                return c
            }
            items = assignLanes(items)
            return AxisDay(label: label, window: window, items: items,
                           pins: pins(label: label, window: window, now: now, planned: input.planned,
                                      hidden: Set(green.hidden.keys), windDownHour: input.windDownHour))
        }
    }

    /// 图钉：日界线（结构图钉，整根轴都画）+ 收工线 / 截止（语义图钉，只画闸门之后）。
    static func pins(label: Date, window: DateInterval, now: Date, planned: [ScheduledBlock],
                     hidden: Set<UUID>, windDownHour: Int?) -> [AxisPin] {
        var out = [AxisPin(id: "day-\(Int(window.start.timeIntervalSince1970))", kind: .dayBoundary,
                           at: window.start, label: dayLabel(label, now: now))]
        if let h = windDownHour {
            let at = PinSchedule.workEnd(forLabel: label, hour: h)
            if at > now, window.contains(at) {
                out.append(AxisPin(id: "winddown-\(Int(at.timeIntervalSince1970))", kind: .windDown, at: at, label: "收工线"))
            }
        }
        for b in planned where !hidden.contains(b.id) {
            guard let d = b.deadline, d > now, window.contains(d) else { continue }
            out.append(AxisPin(id: "ddl-\(b.id.uuidString)", kind: .deadline, at: d, label: "截止 · \(b.title)"))
        }
        return out.sorted { $0.at < $1.at }
    }

    /// 日界线图钉上的字：「10月20日（周二）· 今天」。
    static func dayLabel(_ label: Date, now: Date) -> String {
        let name = PlanEditRules.dayName(label)
        let today = DayContext.logicalStartOfDay(now)
        let cal = Calendar.current
        let offset = cal.dateComponents([.day], from: today, to: label).day ?? 0
        let word: String? = switch offset {
        case 0: "今天"
        case 1: "明天"
        case 2: "后天"
        case -1: "昨天"
        default: nil
        }
        return word.map { "\(name) · \($0)" } ?? name
    }

    /// 时间重叠的块并排：按开始排序，重叠成簇；簇内每块拿第一个空出来的列，簇的列数 = 簇内最多同时几块。
    static func assignLanes(_ items: [AxisItem]) -> [AxisItem] {
        let sorted = items.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        var out: [AxisItem] = []
        var cluster: [AxisItem] = []
        var clusterEnd = Date.distantPast
        var laneEnds: [Date] = []
        func flush() {
            let n = max(1, laneEnds.count)
            out += cluster.map { var c = $0; c.lanes = n; return c }
            cluster = []; laneEnds = []
        }
        for var it in sorted {
            if !cluster.isEmpty, it.start >= clusterEnd { flush() }
            if let free = laneEnds.firstIndex(where: { $0 <= it.start }) {
                it.lane = free; laneEnds[free] = it.end
            } else {
                it.lane = laneEnds.count; laneEnds.append(it.end)
            }
            clusterEnd = cluster.isEmpty ? it.end : max(clusterEnd, it.end)
            cluster.append(it)
        }
        if !cluster.isEmpty { flush() }
        return out
    }
}
