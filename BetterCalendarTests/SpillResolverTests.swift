//
//  SpillResolverTests.swift
//  BetterCalendarTests
//
//  溢出机制（P1c；E5c 裁定版=I1 收口）：默认收待办区（不自动滚明天）/ 生活锚溶解 /
//  DDL 挡路升提议 / 显式覆盖恒压默认 / ask 永不默认（机器检查）。
//  「连滚 ≥3 次升级」随待办池裁定退役——溢出物不回线，连滚问题结构性消失。
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

    /// 裁定默认：工作块与池投放件都收待办区/回池——不自动滚明天。
    @Test func defaultIsReturnToPoolNotForward() {
        let work = SpillCandidate(id: UUID(), title: "写作")
        #expect(SpillResolver.resolve(work, reference: ref) == .returnToPool)
        let pool = SpillCandidate(id: UUID(), title: "论文块", fromPool: true)
        #expect(SpillResolver.resolve(pool, reference: ref) == .returnToPool)
    }

    /// 生活锚默认溶解（零记录、明天照常、不进偏差叙事）。
    @Test func anchorDissolves() {
        let anchor = SpillCandidate(id: UUID(), title: "午休", isAnchor: true)
        #expect(SpillResolver.resolve(anchor, reference: ref) == .dissolve)
    }

    /// DDL 在明天窗口起点之前 → 静默收池会错过 → 升提议（晨间置顶）。
    @Test func deadlineBlocksEscalates() {
        var c = SpillCandidate(id: UUID(), title: "交作业")
        c.deadline = at(2026, 7, 15, 23)   // 今晚 23 点截止；明天窗口 7/16 04:00 > DDL
        #expect(SpillResolver.resolve(c, reference: ref) == .escalate(.deadlineBlocksForward))
        // 显式排明天同样挡路升提议（预授权覆盖不了「静默错过 DDL」）
        c.policyOverride = .forward
        #expect(SpillResolver.resolve(c, reference: ref) == .escalate(.deadlineBlocksForward))
    }

    /// DDL 在明天窗口内 → 收池不升级（明早露脸还来得及）。
    @Test func deadlineTomorrowPoolsQuietly() {
        var c = SpillCandidate(id: UUID(), title: "交作业")
        c.deadline = at(2026, 7, 16, 18)   // 明晚 18 点截止
        #expect(SpillResolver.resolve(c, reference: ref) == .returnToPool)
    }

    /// 显式覆盖恒压默认：排明天（forward 保留为用户选项）/ 溶解 / ask。
    @Test func explicitOverrideBeatsDefault() {
        var fwd = SpillCandidate(id: UUID(), title: "明天再做")
        fwd.policyOverride = .forward
        #expect(SpillResolver.resolve(fwd, reference: ref)
                == .forward(to: DayContext.logicalDay(offset: 1, from: ref)))
        var drop = SpillCandidate(id: UUID(), title: "就算了")
        drop.policyOverride = .dissolve
        #expect(SpillResolver.resolve(drop, reference: ref) == .dissolve)
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
