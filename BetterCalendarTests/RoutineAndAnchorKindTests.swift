//
//  RoutineAndAnchorKindTests.swift
//  BetterCalendarTests
//
//  K4 生活锚细表（吃饭±30/锻炼睡眠±120/其他±60；routine: 标签权威 > 标题启发式）+
//  K1 例行模板（默认全关 opt-in / 周几生效 / 物化实例字段）。
//  RoutineTemplateStore 用 persisted:false（不碰真 iCloud KV）。
//

import Testing
import Foundation
@testable import BetterCalendar

@MainActor
@Suite struct RoutineAndAnchorKindTests {
    private let cal = Calendar.current

    // MARK: K4 细表

    /// routine: 标签是权威判定：meal→±30、exercise/sleep→±120、门块（morning/evening）→±60。
    @Test func anchorRangeByRoutineLabel() {
        #expect(AnchorKindTable.rangeMinutes(title: "随便叫什么", labels: ["routine:meal"]) == 30)
        #expect(AnchorKindTable.rangeMinutes(title: "x", labels: ["routine:exercise"]) == 120)
        #expect(AnchorKindTable.rangeMinutes(title: "x", labels: ["routine:sleep"]) == 120)
        #expect(AnchorKindTable.rangeMinutes(title: "x", labels: ["routine:morning"]) == 60)
    }

    /// 无标签走标题启发式：午饭±30、健身±120、通勤（其他锚）±60。
    @Test func anchorRangeByTitleHeuristic() {
        #expect(AnchorKindTable.rangeMinutes(title: "午饭", labels: []) == 30)
        #expect(AnchorKindTable.rangeMinutes(title: "健身", labels: []) == 120)
        #expect(AnchorKindTable.rangeMinutes(title: "睡个午觉", labels: []) == 120)
        #expect(AnchorKindTable.rangeMinutes(title: "通勤", labels: []) == 60)
    }

    /// FluidityTable.resolve(块)：锚点按细表出软锚；固定块恒钉死；工作块恒自由。
    @Test func fluidityResolveUsesKindTable() {
        let lunch = ScheduledBlock(title: "午饭", start: .now, end: .now + 1800, isAnchor: true)
        #expect(FluidityTable.resolve(lunch) == .soft(30))
        let gym = ScheduledBlock(title: "锻炼", start: .now, end: .now + 3600, isAnchor: true)
        #expect(FluidityTable.resolve(gym) == .soft(120))
        let meeting = ScheduledBlock(title: "午饭会议", start: .now, end: .now + 3600, isFixed: true)
        #expect(FluidityTable.resolve(meeting) == .pinned, "固定块不吃锚细表")
        let work = ScheduledBlock(title: "写作", start: .now, end: .now + 3600)
        #expect(FluidityTable.resolve(work) == .free)
    }

    // MARK: K1 模板

    /// opt-in 铁律：内置五件、默认全关；update 只改目标件。
    @Test func builtinsDefaultAllOff() {
        let store = RoutineTemplateStore(persisted: false)
        #expect(store.templates.count == 5)
        #expect(store.templates.allSatisfy { !$0.enabled }, "默认全关（opt-in）")
        var lunch = store.templates.first { $0.id == "meal.lunch" }!
        lunch.enabled = true
        store.update(lunch)
        #expect(store.templates.filter(\.enabled).map(\.id) == ["meal.lunch"])
    }

    /// 周几生效过滤：只在 weekdays 命中的日子物化。
    @Test func enabledFiltersByWeekday() {
        let store = RoutineTemplateStore(persisted: false)
        var gym = store.templates.first { $0.id == "life.exercise" }!
        gym.enabled = true
        let monday = cal.date(from: DateComponents(year: 2026, month: 8, day: 17))!   // 周一
        gym.weekdays = [2]   // 只周一
        store.update(gym)
        #expect(store.enabled(on: monday).map(\.id) == ["life.exercise"])
        let tuesday = cal.date(byAdding: .day, value: 1, to: monday)!
        #expect(store.enabled(on: tuesday).isEmpty)
    }

    /// 物化实例：当日正确时刻、isAnchor 占位语义、不计时、带 routine: 标签（K4 权威判定源）。
    @Test func instantiateProducesAnchorBlock() {
        let t = RoutineTemplate(id: "meal.lunch", name: "午饭", kind: "meal",
                                hour: 12, minute: 30, durationMinutes: 45)
        let day = cal.date(from: DateComponents(year: 2026, month: 8, day: 17))!
        let b = RoutineTemplateStore.instantiate(t, on: day)
        #expect(cal.component(.hour, from: b.start) == 12 && cal.component(.minute, from: b.start) == 30)
        #expect(b.end.timeIntervalSince(b.start) == 45 * 60)
        #expect(b.isAnchor && !b.isFixed, "占位语义：不进执行列表、溢出走溶解")
        #expect(b.timingStyle == TimingStyle.none)
        #expect(b.labels == ["routine:meal"])
        #expect(FluidityTable.resolve(b) == .soft(30), "实例经标签吃到细表 ±30")
    }
}
