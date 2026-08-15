//
//  TimelineCoordinatorTests.swift
//  BetterCalendarTests
//
//  时间线协调器（E5b）：影子闸 / 写回阈值节流 / 手改冷却 / 墓碑排除 / 晚间豁免 /
//  ★不软溢出 / 活预报推 from + 活动行维护 / 变更痕迹落盘。
//  纪律：内存库显式 .none；容器随 fixture 保活（第五根因）；时间全部从固定时刻派生。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

@MainActor
private final class FakeProgress: ExecutionProgressReading {
    var settledPlannedIDs: Set<UUID> = []
    var predict: ActivePrediction?
    var activePrediction: ActivePrediction? { predict }
}

@MainActor
@Suite struct TimelineCoordinatorTests {
    private let cal = Calendar.current
    /// 基准=真实逻辑今天的日历日（防「固定日期 × 真实时钟 prune」时间炸弹——测试手册教训）；
    /// 时刻固定 13:00（白天正中，避开日界线与收工线附近的机器差异）。
    private let base: Date = Calendar.current.startOfDay(for: DayContext.logicalDay(offset: 0))
    private func at(_ h: Int, _ mi: Int = 0) -> Date {
        cal.date(byAdding: .minute, value: h * 60 + mi, to: base)!
    }
    private var fixedNow: Date { at(13) }

    private struct Fixture {
        let co: TimelineCoordinator
        let plan: PlanStore
        let started: StartedDayStore
        let progress: FakeProgress
        let traces: ChangeTraceStore
        let container: ModelContainer   // 只为保活（ModelContext 不持有容器——第五根因）
    }

    private func makeFixture(started: Bool = true) throws -> Fixture {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let plan = PlanStore(context: container.mainContext)
        let startedDays = StartedDayStore(persisted: false)
        let progress = FakeProgress()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-tests-\(UUID().uuidString)", isDirectory: true)
        let traces = ChangeTraceStore(directory: dir)
        let now = fixedNow
        let co = TimelineCoordinator(planStore: plan, startedDays: startedDays,
                                     traces: traces, now: { now })
        co.progress = progress
        if started { startedDays.markStarted(DayContext.logicalStartOfDay(now)) }
        return Fixture(co: co, plan: plan, started: startedDays, progress: progress,
                       traces: traces, container: container)
    }

    private var today: Date { DayContext.logicalStartOfDay(fixedNow) }

    /// 影子闸（D7）：未开工的日子零写回、零软标——绿仍只由确认/对账写。
    @Test func shadowGateBlocksUnstartedDay() async throws {
        let f = try makeFixture(started: false)
        let b = ScheduledBlock(title: "写作", start: at(9), end: at(10))
        try f.plan.replacePlanned([b], on: today)
        let wrote = await f.co.recompute(reason: "测试")
        #expect(wrote == 0)
        #expect(try f.plan.plannedBlocks(on: today).first?.start == at(9), "真相未动")
        #expect(f.co.softSpilledIDs.isEmpty)
    }

    /// 位移 ≥ 阈值才写：过点 3 小时的块被拉到现在（写回+落痕迹）；5 分钟内的漂移不写。
    @Test func writeThresholdGatesTruthWrites() async throws {
        let f = try makeFixture()
        let stale = ScheduledBlock(title: "过点块", start: at(10), end: at(11))
        try f.plan.replacePlanned([stale], on: today)
        let wrote = await f.co.recompute(reason: "测试")
        #expect(wrote == 1)
        let row = try f.plan.plannedBlocks(on: today).first!
        #expect(row.start == fixedNow, "从现在起可行：拉到 now")
        #expect(row.end.timeIntervalSince(row.start) == 3600, "标称时长不变（校准只进占线不进块）")
        #expect(f.traces.entries(day: today).count == 1)
        #expect(f.traces.entries(day: today).first?.kind == "顺延")

        // 小漂移：块在 now+5min，重排会拉到 now（Δ=5min < 10min 阈值）→ 不写
        let near = ScheduledBlock(title: "临近块", start: fixedNow.addingTimeInterval(5 * 60),
                                  end: fixedNow.addingTimeInterval(35 * 60))
        try f.plan.replacePlanned([near], on: today)
        let wrote2 = await f.co.recompute(reason: "测试")
        #expect(wrote2 == 0, "阈值内抖动不落库")
        #expect(try f.plan.plannedBlocks(on: today).first?.start == near.start)
    }

    /// 手改冷却（D12）：冷却窗内的块映射为钉死——原位不动，用户最后动作赢。
    @Test func manualHoldPinsBlockInPlace() async throws {
        let f = try makeFixture()
        let moved = ScheduledBlock(title: "手改块", start: fixedNow.addingTimeInterval(20 * 60),
                                   end: fixedNow.addingTimeInterval(50 * 60))
        try f.plan.replacePlanned([moved], on: today)
        f.co.noteManualEdits(ids: [moved.id])
        let wrote = await f.co.recompute(reason: "测试")
        #expect(wrote == 0, "冷却窗内不被拉前（无冷却时 Δ=20min 本该写回）")
        #expect(try f.plan.plannedBlocks(on: today).first?.start == moved.start)
    }

    /// 墓碑排除：被「清掉完成」的计划块（completion=.missed）不参与重排、不软标。
    @Test func clearedTombstoneExcluded() async throws {
        let f = try makeFixture()
        let ghost = ScheduledBlock(title: "清掉的", start: at(9), end: at(10))
        try f.plan.replacePlanned([ghost], on: today)
        try f.plan.latchCompletion(plannedID: ghost.id, .missed)
        let wrote = await f.co.recompute(reason: "测试")
        #expect(wrote == 0)
        #expect(try f.plan.plannedBlocks(on: today).first?.start == at(9), "墓碑原位不动")
        #expect(f.co.softSpilledIDs.isEmpty)
    }

    /// 晚间豁免：原排收工线后的块钉原位不参与（V2 等价）。
    @Test func eveningBlocksExempt() async throws {
        let f = try makeFixture()
        let workEnd = PinSchedule.workEnd(forLabel: today)
            .addingTimeInterval(TimeInterval(WorkHoursSettings.graceMinutes * 60))
        let evening = ScheduledBlock(title: "晚间块", start: workEnd.addingTimeInterval(1800),
                                     end: workEnd.addingTimeInterval(1800 + 3600))
        try f.plan.replacePlanned([evening], on: today)
        let wrote = await f.co.recompute(reason: "测试")
        #expect(wrote == 0)
        #expect(try f.plan.plannedBlocks(on: today).first?.start == evening.start)
    }

    /// ★永不软溢出（hardEnd=日界线映射）：普通块装不下进软标，★越线照排。
    @Test func importantNeverSoftSpills() async throws {
        let f = try makeFixture()
        let workEnd = PinSchedule.workEnd(forLabel: today)
            .addingTimeInterval(TimeInterval(WorkHoursSettings.graceMinutes * 60))
        // 普通块长 = 窗口 + 1 小时 → 必溢出；★ 2 小时排在其后
        let windowLen = workEnd.timeIntervalSince(fixedNow)
        let big = ScheduledBlock(title: "装不下的普通块", start: at(14),
                                 end: at(14).addingTimeInterval(windowLen + 3600))
        let star = ScheduledBlock(title: "要紧事", start: at(15),
                                  end: at(15).addingTimeInterval(7200), priority: .important)
        try f.plan.replacePlanned([big, star], on: today)
        await f.co.recompute(reason: "测试")
        #expect(f.co.softSpilledIDs == [big.id], "普通块软标")
        #expect(!f.co.softSpilledIDs.contains(star.id), "★绝不软溢出")
        let starRow = try f.plan.plannedBlocks(on: today).first { $0.id == star.id }!
        #expect(starRow.start == fixedNow, "★照排（拉到现在）")
    }

    /// 活预报（D-2 绿=活预报）：from 从预测结束起排；活动行维护为 [实际开始, 预测结束]。
    @Test func activePredictionDrivesFromAndRowMaintenance() async throws {
        let f = try makeFixture()
        let activeBlock = ScheduledBlock(title: "进行中", start: at(12), end: at(13, 30))
        let next = ScheduledBlock(title: "下一件", start: at(13), end: at(14))
        try f.plan.replacePlanned([activeBlock, next], on: today)
        let predictedEnd = fixedNow.addingTimeInterval(30 * 60)
        f.progress.settledPlannedIDs = [activeBlock.id]
        f.progress.predict = ActivePrediction(id: activeBlock.id, start: at(12, 10), end: predictedEnd)
        let wrote = await f.co.recompute(reason: "测试")
        #expect(wrote == 2, "活动行 + 下一件各写一次")
        let rows = try f.plan.plannedBlocks(on: today)
        let activeRow = rows.first { $0.id == activeBlock.id }!
        #expect(activeRow.start == at(12, 10) && activeRow.end == predictedEnd, "活动行=[实际开始,预测结束]")
        #expect(rows.first { $0.id == next.id }!.start == predictedEnd, "下一件从预测结束起排")
        #expect(f.traces.entries(day: today).contains { $0.kind == "活动预报" })
    }

    /// 痕迹存取：按日分页、逆序回放素材齐全、过期日 prune。
    @Test func changeTraceRoundTripAndPrune() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-rt-\(UUID().uuidString)", isDirectory: true)
        let store = ChangeTraceStore(directory: dir)
        let day = DayContext.logicalDay(offset: 0)
        let e = ChangeTraceEntry(time: fixedNow, blockID: UUID(), title: "写作", kind: "顺延",
                                 beforeStart: at(9), beforeEnd: at(10),
                                 afterStart: at(13), afterEnd: at(14), reason: "测试")
        store.append(e, day: day)
        #expect(store.entries(day: day).count == 1)
        #expect(store.entries(day: day).first?.beforeStart == at(9), "前像齐全（一键撤的素材）")
        // 8 天前的页在下次 append 时被 prune（只留最近 7 逻辑日）
        let old = cal.date(byAdding: .day, value: -8, to: day)!
        store.append(e, day: old)
        store.append(e, day: day)
        #expect(store.entries(day: old).isEmpty, "过期页已清")
        store.clear(day: day)
        #expect(store.entries(day: day).isEmpty)
    }
}
