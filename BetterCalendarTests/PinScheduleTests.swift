//
//  PinScheduleTests.swift
//  BetterCalendarTests
//
//  图钉体系（P1a）：与旧逻辑日算式的行为等价 + 图钉序列的单调性/半开区间语义。
//

import Testing
import Foundation
@testable import BetterCalendar

@Suite struct PinScheduleTests {
    private let cal = Calendar.current

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// 旧算式作 oracle：hour<4 → 昨天零点，否则今天零点。逐小时对拍。
    @Test func dayBoundaryMatchesLegacyLogic() {
        for h in 0..<24 {
            let t = at(2026, 7, 15, h, 30)
            let base = cal.startOfDay(for: t)
            let legacy = h < PinSchedule.dayBoundaryHour
                ? cal.date(byAdding: .day, value: -1, to: base)! : base
            #expect(DayContext.logicalStartOfDay(t) == legacy, "hour=\(h)")
        }
    }

    /// 恰好 4:00:00 属于新的一天（半开区间左闭）。
    @Test func exactBoundaryBelongsToNewDay() {
        let t = at(2026, 7, 15, 4, 0)
        #expect(DayContext.logicalStartOfDay(t) == cal.startOfDay(for: t))
        let justBefore = at(2026, 7, 15, 3, 59)
        #expect(DayContext.logicalStartOfDay(justBefore)
                == cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: justBefore))!)
    }

    /// 逻辑日区间：首尾相连、无缝无叠（连续 5 天滚动检查）。
    @Test func dayIntervalsAreContiguous() {
        var t = at(2026, 7, 10, 12)
        for _ in 0..<5 {
            let iv = PinSchedule.dayInterval(containing: t)
            #expect(iv.start <= t && t < iv.end)
            let nextIv = PinSchedule.dayInterval(containing: iv.end)
            #expect(nextIv.start == iv.end, "相邻区间必须首尾相接")
            t = iv.end.addingTimeInterval(3600)
        }
    }

    /// logicalWindow(forLabel:) 与 dayInterval(forLabel:) 一致（迁移等价）。
    @Test func logicalWindowMatchesPinInterval() {
        let label = cal.startOfDay(for: at(2026, 7, 15, 12))
        let w = DayContext.logicalWindow(forLabel: label)
        #expect(w.start == at(2026, 7, 15, 4))
        #expect(w.end == at(2026, 7, 16, 4))
    }

    /// endOfPlannableDay = 下一根跨日图钉。
    @Test func endOfPlannableDayIsNextBoundaryPin() {
        #expect(DayContext.endOfPlannableDay(at(2026, 7, 15, 22)) == at(2026, 7, 16, 4))
        #expect(DayContext.endOfPlannableDay(at(2026, 7, 16, 2)) == at(2026, 7, 16, 4))   // 凌晨属前一逻辑日
        #expect(DayContext.endOfPlannableDay(at(2026, 7, 16, 4)) == at(2026, 7, 17, 4))   // 恰在钉上→下一根
    }

    /// 收工图钉数学（纯函数版，含 hour=24 落次日零点；不碰全局设置——并行测试竞态教训）。
    @Test func workEndPinMath() {
        let label = cal.startOfDay(for: at(2026, 7, 15, 12))
        for hour in [8, 23] {
            #expect(PinSchedule.workEnd(forLabel: label, hour: hour) == at(2026, 7, 15, hour))
        }
        #expect(PinSchedule.workEnd(forLabel: label, hour: 24) == at(2026, 7, 16, 0))
    }

    /// 图钉序列：升序、半开区间 [start, end)、跨日钉数量正确。
    @Test func pinSequenceMonotoneAndHalfOpen() {
        let start = at(2026, 7, 15, 4)
        let end = at(2026, 7, 18, 4)
        let pins = PinSchedule.pins(in: DateInterval(start: start, end: end))
        for i in 1..<pins.count {
            #expect(pins[i - 1].time <= pins[i].time, "序列必须升序")
        }
        #expect(pins.contains { $0.kind == .dayBoundary && $0.time == start })     // 左闭
        #expect(!pins.contains { $0.time >= end })                                  // 右开
        let dayPins = pins.filter { $0.kind == .dayBoundary }
        #expect(dayPins.count == 3, "3 天窗恰 3 根跨日钉（15/16/17 各一根，18 日 4 点被右开排除）")
    }

    /// 傍晚图钉夹在 16:00–20:00（纯函数版）。
    @Test func eveningPinClamped() {
        let label = cal.startOfDay(for: at(2026, 7, 15, 12))
        #expect(PinSchedule.eveningStart(forLabel: label, windDownHour: 18) == at(2026, 7, 15, 16))   // 13→夹 16
        #expect(PinSchedule.eveningStart(forLabel: label, windDownHour: 24) == at(2026, 7, 15, 19))   // 19 不夹
        #expect(PinSchedule.eveningStart(forLabel: label, windDownHour: 23) == at(2026, 7, 15, 18))   // 收工23→傍晚18
    }
}
