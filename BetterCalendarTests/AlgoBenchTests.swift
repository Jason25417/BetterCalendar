//
//  AlgoBenchTests.swift
//  BetterCalendarTests
//
//  算法试验台的纯逻辑测试：ReflowLayoutV2（收工线执法/候补/豁免）、断言引擎、时间工具、用例集存取。
//  时间一律钉死（凌晨跑 CI 也不挂）；LLM 调用不在此测（试验台本身就是它的测法）。
//

import Testing
import Foundation
@testable import BetterCalendar

@MainActor
struct AlgoBenchTests {

    // MARK: 工具

    /// 钉死的参考日（2026-03-09 周一）。
    private var day: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 9))!
    }

    private func at(_ h: Int, _ m: Int = 0, plusDays: Int = 0) -> Date {
        let base = Calendar.current.date(byAdding: .day, value: plusDays, to: day)!
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: base)!
    }

    private func block(_ title: String, _ startH: Int, _ startM: Int = 0, dur: Int,
                       fixed: Bool = false, important: Bool = false,
                       group: String? = nil) -> ScheduledBlock {
        var labels: [String] = []
        if let g = group { labels.append(ScheduledBlock.parallelPrefix + g) }
        return ScheduledBlock(title: title, start: at(startH, startM),
                              end: at(startH, startM).addingTimeInterval(TimeInterval(dur * 60)),
                              isFixed: fixed,
                              priority: important ? .important : .normal,
                              labels: labels)
    }

    // MARK: ReflowLayoutV2

    @Test func v2AllFitNoDeferred() {
        let r = ReflowLayoutV2.layOut(flexible: [block("A", 13, dur: 60), block("B", 14, dur: 60)],
                                      fixed: [], from: at(13, 40),
                                      windDown: at(23), graceMinutes: 10)
        #expect(r.deferred.isEmpty)
        #expect(r.scheduled.count == 2)
        #expect(r.scheduled[0].start == at(13, 40))
        #expect(r.scheduled[1].start == at(14, 40))
    }

    @Test func v2OverflowGoesToStandbyAndShorterStillFits() {
        // 20:00 起：大 150m 排到 22:30（≤线），中 120m 放不下→候补且 cursor 不前进，小 30m 仍塞进 22:30–23:00
        let r = ReflowLayoutV2.layOut(
            flexible: [block("大", 20, dur: 150), block("中", 20, dur: 120), block("小", 21, dur: 30)],
            fixed: [], from: at(20),
            windDown: at(23), graceMinutes: 10)
        #expect(r.deferred.map(\.title) == ["中"])
        let small = r.scheduled.first { $0.title == "小" }
        #expect(small?.start == at(22, 30))
        #expect(small?.end == at(23))
    }

    @Test func v2ImportantNeverDeferred() {
        // ★ 2h 从 22:00 排到 24:00，远超 23:00 线，仍然照排
        let r = ReflowLayoutV2.layOut(flexible: [block("★事", 22, dur: 120, important: true)],
                                      fixed: [], from: at(22),
                                      windDown: at(23), graceMinutes: 10)
        #expect(r.deferred.isEmpty)
        #expect(r.scheduled.first?.title == "★事")
    }

    @Test func v2EveningBlockPinned() {
        // 原计划 23:30 的晚间块（≥收工线）钉原时间；弹性块绕它排
        let r = ReflowLayoutV2.layOut(
            flexible: [block("夜宵散步", 23, 30, dur: 30), block("回邮件", 20, dur: 30)],
            fixed: [], from: at(20),
            windDown: at(23), graceMinutes: 10)
        let walk = r.scheduled.first { $0.title == "夜宵散步" }
        #expect(walk?.start == at(23, 30))
        #expect(r.deferred.isEmpty)
        let mail = r.scheduled.first { $0.title == "回邮件" }
        #expect(mail?.start == at(20))
    }

    @Test func v2ParallelSlotDeferredTogether() {
        // 并行组槽长 60（组内最长），22:30 起排到 23:30 > 23:10 线 → 整组候补
        let r = ReflowLayoutV2.layOut(
            flexible: [block("洗衣", 22, 30, dur: 60, group: "家务"),
                       block("听播客", 22, 30, dur: 45, group: "家务")],
            fixed: [], from: at(22, 30),
            windDown: at(23), graceMinutes: 10)
        #expect(r.scheduled.isEmpty)
        #expect(Set(r.deferred.map(\.title)) == ["洗衣", "听播客"])
    }

    @Test func v2ParallelSlotSameStartWhenFits() {
        let r = ReflowLayoutV2.layOut(
            flexible: [block("洗衣", 19, dur: 60, group: "家务"),
                       block("听播客", 19, dur: 45, group: "家务"),
                       block("晚自习", 20, dur: 120)],
            fixed: [], from: at(18),
            windDown: at(23), graceMinutes: 10)
        let a = r.scheduled.first { $0.title == "洗衣" }
        let b = r.scheduled.first { $0.title == "听播客" }
        #expect(a?.start == b?.start)
        #expect(r.deferred.isEmpty)
    }

    @Test func v2LLMDeferredHonoredButImportantVetoed() {
        let normal = block("普通", 20, dur: 60)
        let vip = block("要紧", 21, dur: 60, important: true)
        let r = ReflowLayoutV2.layOut(flexible: [normal, vip], fixed: [], from: at(20),
                                      windDown: at(23), graceMinutes: 10,
                                      llmDeferred: [normal.id, vip.id])
        #expect(r.deferred.map(\.title) == ["普通"])       // LLM 让路：采纳
        #expect(r.scheduled.map(\.title) == ["要紧"])      // ★ 让路：本地否决
    }

    @Test func v2GraceBoundary() {
        // 恰好压线（end == 线+宽限）→ 排；超 1 分钟 → 候补
        let exact = ReflowLayoutV2.layOut(flexible: [block("压线", 20, dur: 190)],   // 20:00+190m=23:10
                                          fixed: [], from: at(20),
                                          windDown: at(23), graceMinutes: 10)
        #expect(exact.deferred.isEmpty)
        let over = ReflowLayoutV2.layOut(flexible: [block("超线", 20, dur: 191)],
                                         fixed: [], from: at(20),
                                         windDown: at(23), graceMinutes: 10)
        #expect(over.deferred.map(\.title) == ["超线"])
    }

    @Test func v2FlowsAroundFixed() {
        let r = ReflowLayoutV2.layOut(
            flexible: [block("写方案", 13, dur: 60), block("改简历", 14, dur: 90)],
            fixed: [block("部门会", 15, dur: 60, fixed: true)],
            from: at(13, 40),
            windDown: at(23), graceMinutes: 10)
        let resume = r.scheduled.first { $0.title == "改简历" }
        #expect(resume?.start == at(16))   // 14:40 撞会 → 顺延到会后
        #expect(r.deferred.isEmpty)
    }

    // MARK: 断言引擎

    @Test func assertionsBasics() {
        let out = BenchOutput(blocks: [block("写作", 9, dur: 120), block("会议", 11, 30, dur: 60, fixed: true)])
        let ctx = BenchAssertions.Context(referenceDay: day)
        let checks = BenchAssertions.evaluate([
            .init(kind: .blockCountExact, count: 2),
            .init(kind: .hasBlockStart, title: "写作", hm: "09:00"),
            .init(kind: .hasBlockEnd, title: "写作", hm: "11:00"),
            .init(kind: .noBlock, title: "休息"),
            .init(kind: .fixedFlag, title: "会议", flag: true),
            .init(kind: .noOverlaps),
        ], output: out, context: ctx)
        let allPass = checks.allSatisfy { $0.passed }
        #expect(allPass)
    }

    @Test func assertionsCatchFailures() {
        let out = BenchOutput(blocks: [block("写作", 10, dur: 60)])
        let ctx = BenchAssertions.Context(referenceDay: day)
        let checks = BenchAssertions.evaluate([
            .init(kind: .hasBlockStart, title: "写作", hm: "09:00"),   // 实际 10:00 → 挂
            .init(kind: .hasBlock, title: "阅读"),                      // 没有 → 挂
        ], output: out, context: ctx)
        let allFail = checks.allSatisfy { !$0.passed }
        #expect(allFail)
    }

    @Test func assertionsParallelOverlapExempt() {
        let out = BenchOutput(blocks: [block("洗衣", 19, dur: 60, group: "g"),
                                       block("播客", 19, dur: 45, group: "g")])
        let checks = BenchAssertions.evaluate([.init(kind: .noOverlaps), .init(kind: .sameStart, title: "洗衣", title2: "播客")],
                                              output: out,
                                              context: .init(referenceDay: day))
        let allPass = checks.allSatisfy { $0.passed }
        #expect(allPass)
    }

    @Test func assertionsWindDownExemptions() {
        let input = [block("普通", 20, dur: 60), block("★事", 21, dur: 180, important: true),
                     block("夜宵", 23, 30, dur: 30)]
        // 输出：普通 22:30–23:30（违规）、★ 21:00–24:00（豁免）、夜宵 23:30（晚间豁免）
        var late = input[0]; late.start = at(22, 30); late.end = at(23, 30)
        let out = BenchOutput(blocks: [late, input[1], input[2]])
        let ctx = BenchAssertions.Context(referenceDay: day, inputBlocks: input,
                                          windDown: at(23), graceMinutes: 10)
        let checks = BenchAssertions.evaluate([.init(kind: .allWithinWindDown)], output: out, context: ctx)
        #expect(checks[0].passed == false)
        #expect(checks[0].detail.contains("普通"))
        #expect(!checks[0].detail.contains("★事"))
        #expect(!checks[0].detail.contains("夜宵"))
    }

    @Test func assertionsFlagsUnchangedExcept() {
        let input = [block("写作", 9, dur: 120), block("阅读", 14, dur: 60)]
        var flipped = input[1]; flipped.timingStyle = .pomodoro   // 没被点名却翻了计时
        let out = BenchOutput(blocks: [input[0], flipped])
        let checks = BenchAssertions.evaluate([.init(kind: .flagsUnchangedExcept, title: "写作")],
                                              output: out,
                                              context: .init(referenceDay: day, inputBlocks: input))
        #expect(checks[0].passed == false)
        #expect(checks[0].detail.contains("阅读"))
    }

    @Test func assertionsFixedUnmovedDetectsShift() {
        let input = [block("会议", 11, 30, dur: 60, fixed: true)]
        var moved = input[0]; moved.start = at(12); moved.end = at(13)
        let out = BenchOutput(blocks: [moved])
        let checks = BenchAssertions.evaluate([.init(kind: .fixedUnmoved)], output: out,
                                              context: .init(referenceDay: day, inputBlocks: input))
        #expect(checks[0].passed == false)
    }

    @Test func assertionsDeferredChecks() {
        let out = BenchOutput(blocks: [], deferred: [block("整理桌面", 21, 30, dur: 90)])
        let ctx = BenchAssertions.Context(referenceDay: day)
        let checks = BenchAssertions.evaluate([
            .init(kind: .deferredContains, title: "整理桌面"),
            .init(kind: .deferredNotContains, title: "回信"),
        ], output: out, context: ctx)
        let allPass = checks.allSatisfy { $0.passed }
        #expect(allPass)
        let empty = BenchAssertions.evaluate([.init(kind: .deferredEmpty)], output: out, context: ctx)
        #expect(empty[0].passed == false)
    }

    // MARK: 时间工具 / 用例集

    @Test func benchTimeParsing() {
        #expect(BenchTime.date(hm: "09:30", on: day) == at(9, 30))
        #expect(BenchTime.date(hm: "01:00", dayOffset: 1, on: day) == at(1, 0, plusDays: 1))
        #expect(BenchTime.date(hm: "24:00", on: day) == at(0, 0, plusDays: 1))
        #expect(BenchTime.date(hm: "25:00", on: day) == nil)
        #expect(BenchTime.date(hm: "乱写", on: day) == nil)
    }

    @Test func suiteSeedValidAndRoundTrips() throws {
        let cases = BenchSuiteStore.defaultCases
        #expect(!cases.isEmpty)
        #expect(Set(cases.map(\.id)).count == cases.count)   // id 唯一
        // 所有输入块可物化（时间合法）
        for c in cases {
            for spec in c.blocks ?? [] {
                #expect(spec.materialize(on: day) != nil, "\(c.id) 的块 \(spec.title) 无法物化")
            }
        }
        let data = try JSONEncoder().encode(cases)
        let back = try JSONDecoder().decode([BenchCase].self, from: data)
        #expect(back.count == cases.count)
    }

    @Test func suiteStoreSeedsAndResets() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-tests-\(UUID().uuidString)", isDirectory: true)
        let store = BenchSuiteStore(directory: dir)
        let first = store.load()                       // 无文件 → 播种
        #expect(first.count == BenchSuiteStore.defaultCases.count)
        store.save(Array(first.prefix(2)))             // 改成 2 条
        #expect(store.load().count == 2)
        #expect(store.resetToDefaults().count == BenchSuiteStore.defaultCases.count)
        try? FileManager.default.removeItem(at: dir)
    }
}
