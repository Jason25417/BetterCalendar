//
//  SpillResolverTests.swift
//  BetterCalendarTests
//
//  溢出机制（P1c）：四策略默认分流 + 三种升级局面 + DDL 边界 + 显式覆盖恒压默认。
//

import Testing
import Foundation
@testable import BetterCalendar

@Suite struct SpillResolverTests {
    private let cal = Calendar.current
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }
    private var ref: Date { at(2026, 7, 15, 20) }   // 晚 8 点裁决，目标日=7/16

    /// 工作块默认顺延到下一逻辑日。
    @Test func workBlockForwardsToTomorrow() {
        let c = SpillCandidate(id: UUID(), title: "写作")
        let d = SpillResolver.resolve(c, reference: ref)
        #expect(d == .forward(to: DayContext.logicalDay(offset: 1, from: ref)))
    }

    /// 池投放件默认回池；生活锚默认溶解。
    @Test func poolReturnsAndAnchorDissolves() {
        let pool = SpillCandidate(id: UUID(), title: "论文块", fromPool: true)
        #expect(SpillResolver.resolve(pool, reference: ref) == .returnToPool)
        let anchor = SpillCandidate(id: UUID(), title: "午休", isAnchor: true)
        #expect(SpillResolver.resolve(anchor, reference: ref) == .dissolve)
    }

    /// DDL 在明天窗口起点之前 → 推不过去，升提议。
    @Test func deadlineBlocksForwardEscalates() {
        var c = SpillCandidate(id: UUID(), title: "交作业")
        c.deadline = at(2026, 7, 15, 23)   // 今晚 23 点截止；明天窗口 7/16 04:00 > DDL
        #expect(SpillResolver.resolve(c, reference: ref) == .escalate(.deadlineBlocksForward))
    }

    /// DDL 在明天窗口内 → 照常顺延（明天还来得及）。
    @Test func deadlineTomorrowStillForwards() {
        var c = SpillCandidate(id: UUID(), title: "交作业")
        c.deadline = at(2026, 7, 16, 18)   // 明晚 18 点截止
        #expect(SpillResolver.resolve(c, reference: ref)
                == .forward(to: DayContext.logicalDay(offset: 1, from: ref)))
    }

    /// 连续自动顺延达上限 → 不再静默滚，升提议。
    @Test func repeatedSpillsEscalate() {
        var c = SpillCandidate(id: UUID(), title: "一直没做的事")
        c.spillCount = SpillResolver.maxSilentSpills
        #expect(SpillResolver.resolve(c, reference: ref)
                == .escalate(.repeatedSpills(count: SpillResolver.maxSilentSpills)))
        c.spillCount = SpillResolver.maxSilentSpills - 1
        #expect(SpillResolver.resolve(c, reference: ref)
                == .forward(to: DayContext.logicalDay(offset: 1, from: ref)), "未达上限照常顺延")
    }

    /// 显式覆盖恒压默认（数据只填空原则同族）：池件设 forward、工作块设回池、任何件设 ask。
    @Test func explicitOverrideBeatsDefault() {
        var pool = SpillCandidate(id: UUID(), title: "论文块", fromPool: true)
        pool.policyOverride = .forward
        #expect(SpillResolver.resolve(pool, reference: ref)
                == .forward(to: DayContext.logicalDay(offset: 1, from: ref)))
        var work = SpillCandidate(id: UUID(), title: "杂务")
        work.policyOverride = .returnToPool
        #expect(SpillResolver.resolve(work, reference: ref) == .returnToPool)
        var ask = SpillCandidate(id: UUID(), title: "要问的")
        ask.policyOverride = .ask
        #expect(SpillResolver.resolve(ask, reference: ref) == .escalate(.userAskedToAsk))
    }

    /// 「问一下」不作任何身份的默认值（哲学审核条件的机器检查）。
    @Test func askIsNeverDefault() {
        for (fromPool, isAnchor) in [(false, false), (true, false), (false, true), (true, true)] {
            let c = SpillCandidate(id: UUID(), title: "x", fromPool: fromPool, isAnchor: isAnchor)
            #expect(SpillResolver.defaultPolicy(for: c) != .ask)
        }
    }
}
