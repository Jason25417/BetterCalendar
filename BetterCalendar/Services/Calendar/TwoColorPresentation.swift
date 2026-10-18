//
//  TwoColorPresentation.swift
//  BetterCalendar
//
//  P4 呈现规则（SPEC §19.13 Q2/Q4，§13.1 A.4「两色」）：苹果日历里**一件事只画一次**。
//  - 「现在」之前是蓝（实际），之后是绿（计划）：做完/记下了的块只剩蓝色，绿色让位；
//    正在做的块（蓝色在长）只画「蓝色尽头 → 计划结束」那段绿；
//  - 你自己日历里本来就有的课和会（关联上的块）不再画绿——你那一份就是它；
//  - 固定块到点被动推断的完成只记数据、不画蓝，所以绿色照常留着（它是这件事唯一的一份）。
//  计划 vs 实际的对比改由当日最初快照（DayPlanSnapshot）承担，日历只负责「一件事只出现一次」。
//  规则只依赖**会跨设备同步的数据**（PlanStore 计划行/实际行 + 你的日历）：两台设备算出同一张画，不来回改。
//

import Foundation

/// 实际行的状态（PlanBlock.actualState）。nil 存储 = recorded。
nonisolated enum ActualState: String, Sendable {
    /// 记下的实际（完成 / 结束计时 / 复盘补记 / 提醒打勾）：蓝色，绿色让位。
    case recorded
    /// 正在做（每 5 分钟延长的蓝色）：绿色只画剩下那段。
    case live
    /// 被动推断（固定块到点自动完成）：只记数据、不画蓝；绿色照留。
    case auto

    init(stored: String?) { self = stored.flatMap(ActualState.init(rawValue:)) ?? .recorded }
    var stored: String? { self == .recorded ? nil : rawValue }
}

enum GreenPresentation {
    enum HiddenReason: String, Sendable {
        /// 已经有蓝色（做完了）
        case done
        /// 关联了你自己的日历事件（你那一份就是它）
        case linked
    }

    struct Item: Sendable {
        var block: ScheduledBlock
        /// 画在日历上的起止（正在做的块 = 从蓝色尽头起）。
        var start: Date
        var end: Date
        /// 起点被蓝色截过（对账采纳你的改动时只认结束与标题，开始以真相为准）。
        var clipped: Bool
    }

    struct Result: Sendable {
        var drawn: [Item] = []
        var hidden: [UUID: HiddenReason] = [:]
        func item(_ id: UUID) -> Item? { drawn.first { $0.block.id == id } }
    }

    /// 剩余不超过这么长就不画绿（避免日历里留一条细线）。
    static let minRemainder: TimeInterval = 60

    static func present(blocks: [ScheduledBlock], actuals: [UUID: ActualBlock], linked: Set<UUID>) -> Result {
        var r = Result()
        for b in blocks {
            if linked.contains(b.id) { r.hidden[b.id] = .linked; continue }
            guard let a = actuals[b.id] else {
                r.drawn.append(Item(block: b, start: b.start, end: b.end, clipped: false)); continue
            }
            switch a.state {
            case .auto:
                r.drawn.append(Item(block: b, start: b.start, end: b.end, clipped: false))
            case .recorded:
                r.hidden[b.id] = .done
            case .live:
                let from = max(b.start, a.end)
                if b.end.timeIntervalSince(from) <= minRemainder { r.hidden[b.id] = .done }
                else { r.drawn.append(Item(block: b, start: from, end: b.end, clipped: from > b.start)) }
            }
        }
        return r
    }
}

/// 计划块 ↔ 你自己日历里的事件 的关联（P4 Q4：只关联、不复制）。纯函数、本机判定（标题不出云）。
/// 判据：时间重叠 ≥ 较短一方的 50%，且（标题相似 ≥ 0.6，或共享 ≥3 位的数字串——课号「5529」这类）。
/// 全天事件不参与。一件事件最多关联一个块、一个块最多关联一件事件（取重叠最多的）。
/// 关联不落库：每次按两边的同步数据重算——两台设备结论相同，你改了自己的事件也立刻跟着变。
enum ExternalEventLinker {
    static func links(blocks: [ScheduledBlock], events: [SystemCalendarEvent]) -> [UUID: SystemCalendarEvent] {
        var candidates: [(block: UUID, event: Int, overlap: TimeInterval)] = []
        for (i, e) in events.enumerated() where !e.isAllDay && e.end > e.start {
            for b in blocks where b.end > b.start {
                let overlap = min(b.end, e.end).timeIntervalSince(max(b.start, e.start))
                guard overlap > 0 else { continue }
                let shorter = min(b.end.timeIntervalSince(b.start), e.end.timeIntervalSince(e.start))
                guard overlap >= shorter * 0.5, sameThing(b.title, e.title) else { continue }
                candidates.append((b.id, i, overlap))
            }
        }
        var result: [UUID: SystemCalendarEvent] = [:]
        var usedEvents: Set<Int> = []
        // 重叠多的先配；并列按块 id、事件下标定序（确定性）
        for c in candidates.sorted(by: { ($0.overlap, $1.block.uuidString, $1.event) > ($1.overlap, $0.block.uuidString, $0.event) })
        where result[c.block] == nil && !usedEvents.contains(c.event) {
            result[c.block] = events[c.event]
            usedEvents.insert(c.event)
        }
        return result
    }

    static func sameThing(_ a: String, _ b: String) -> Bool {
        if TitleMatch.similarity(a, b) >= 0.6 { return true }
        let da = digitRuns(a), db = digitRuns(b)
        return !da.isDisjoint(with: db)
    }

    private static func digitRuns(_ s: String) -> Set<String> {
        var runs: Set<String> = [], cur = ""
        for ch in s + " " {
            if ch.isASCII, ch.isNumber { cur.append(ch) } else {
                if cur.count >= 3 { runs.insert(cur) }
                cur = ""
            }
        }
        return runs
    }
}
