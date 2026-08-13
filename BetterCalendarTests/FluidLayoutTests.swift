//
//  FluidLayoutTests.swift
//  BetterCalendarTests
//
//  流动性排布引擎（P1b）：钉死/软锚/队列三类行为 + 硬边界溢出 + ★救援置换 + 与旧 ReflowLayout 的退化等价。
//

import Testing
import Foundation
@testable import BetterCalendar

@Suite struct FluidLayoutTests {
    private let cal = Calendar.current

    private func at(_ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: h, minute: mi))!
    }

    private func module(_ title: String, start: Int, durationMin: Int,
                        fluidity: Fluidity, priority: BlockPriority = .normal) -> FluidModule {
        FluidModule(title: title, duration: TimeInterval(durationMin * 60),
                    fluidity: fluidity, priority: priority, plannedStart: at(start))
    }

    /// 钉死块原位；队列块绕开它顺延。
    @Test func queueFlowsAroundPinned() {
        let meeting = module("会议", start: 10, durationMin: 60, fluidity: .pinned)
        let work = module("写作", start: 9, durationMin: 120, fluidity: .free)
        let r = FluidLayoutEngine.layOut(modules: [meeting, work], from: at(9), hardEnd: at(18))
        #expect(r.overflow.isEmpty)
        let m = r.placed.first { $0.id == meeting.id }!
        let w = r.placed.first { $0.id == work.id }!
        #expect(m.start == at(10))
        #expect(w.start == at(11), "写作 120min 塞不进 9-10 的空隙，顺延到会议后")
    }

    /// 队列块能塞进钉死块前的空隙（首次适配）。
    @Test func queueFillsGapBeforePinned() {
        let meeting = module("会议", start: 10, durationMin: 60, fluidity: .pinned)
        let small = module("回邮件", start: 9, durationMin: 45, fluidity: .free)
        let r = FluidLayoutEngine.layOut(modules: [meeting, small], from: at(9), hardEnd: at(18))
        #expect(r.placed.first { $0.id == small.id }!.start == at(9), "45min 塞得进 9-10 空隙")
    }

    /// 软锚块被钉死块占位时在 ± 范围内让位；范围内无处可去则溢出。
    @Test func softAnchorYieldsWithinRange() {
        let meeting = module("会议", start: 12, durationMin: 60, fluidity: .pinned)
        let lunch = module("午饭", start: 12, durationMin: 30, fluidity: .soft(60))
        let r = FluidLayoutEngine.layOut(modules: [meeting, lunch], from: at(9), hardEnd: at(18))
        #expect(r.overflow.isEmpty)
        let l = r.placed.first { $0.id == lunch.id }!
        #expect(l.start == at(13), "优先不早于原时刻的最近可行位：13:00（会议后）")
        #expect(l.start <= at(13), "±60min 范围内")
    }

    /// 收工硬边界：装不下的队列块进溢出集，已放的不受影响。
    @Test func hardEndProducesOverflow() {
        let a = module("A", start: 9, durationMin: 120, fluidity: .free)
        let b = module("B", start: 11, durationMin: 120, fluidity: .free)
        let c = module("C", start: 13, durationMin: 120, fluidity: .free)
        let r = FluidLayoutEngine.layOut(modules: [a, b, c], from: at(9), hardEnd: at(13))
        #expect(r.placed.count == 2)
        #expect(r.overflow == [c.id], "9-13 恰好装 A+B，C 溢出")
    }

    /// ★救援置换：装不下的要紧事挤掉已放的最后一个普通块（优先级低者先溢）。
    @Test func importantEvictsLastNormal() {
        let a = module("普通A", start: 9, durationMin: 120, fluidity: .free)
        let b = module("普通B", start: 11, durationMin: 120, fluidity: .free)
        let star = module("要紧事", start: 13, durationMin: 90, fluidity: .free, priority: .important)
        let r = FluidLayoutEngine.layOut(modules: [a, b, star], from: at(9), hardEnd: at(13, 30))
        #expect(r.overflow == [b.id], "B 被挤出让位给★")
        #expect(r.placed.contains { $0.id == star.id })
        #expect(r.placed.first { $0.id == star.id }!.start == at(11), "★接在 A 后")
    }

    /// 窗口外的钉死块不参与本窗口、也不算溢出（属于别的窗口）。
    @Test func pinnedOutsideWindowIgnored() {
        let tomorrow = module("明早会", start: 9, durationMin: 60, fluidity: .pinned)
        var m = tomorrow
        m.plannedStart = cal.date(byAdding: .day, value: 1, to: tomorrow.plannedStart)!
        let r = FluidLayoutEngine.layOut(modules: [m], from: at(9), hardEnd: at(18))
        #expect(r.placed.isEmpty && r.overflow.isEmpty)
    }

    /// 退化等价：全部钉死/自由、无软锚、空间充足时，与旧 ReflowLayout 铺排一致。
    @Test func degenerateCaseMatchesLegacyReflow() {
        let fixed = ScheduledBlock(title: "会议", start: at(11), end: at(12), isFixed: true)
        let f1 = ScheduledBlock(title: "写作", start: at(9), end: at(10, 30))
        let f2 = ScheduledBlock(title: "阅读", start: at(10, 30), end: at(11, 30))
        let legacy = ReflowLayout.layOut(flexible: [f1, f2], fixed: [fixed], from: at(9))

        let modules = [
            FluidModule(id: fixed.id, title: fixed.title, duration: 3600,
                        fluidity: .pinned, plannedStart: fixed.start),
            FluidModule(id: f1.id, title: f1.title, duration: 90 * 60,
                        fluidity: .free, plannedStart: f1.start),
            FluidModule(id: f2.id, title: f2.title, duration: 60 * 60,
                        fluidity: .free, plannedStart: f2.start),
        ]
        let r = FluidLayoutEngine.layOut(modules: modules, from: at(9), hardEnd: at(23))
        #expect(r.overflow.isEmpty)
        for lb in legacy {
            let p = r.placed.first { $0.id == lb.id }
            #expect(p != nil, "\(lb.title) 两引擎都应放置")
            #expect(p?.start == lb.start, "\(lb.title) 起点一致（退化等价）")
        }
    }
}
