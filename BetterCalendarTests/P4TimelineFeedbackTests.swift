//
//  P4TimelineFeedbackTests.swift
//  BetterCalendarTests
//
//  B10 / P4.0-7：时间线协调器自激循环回归 + P4.0-8 PlanStore 写入来源。内存库，容器随 fixture 保活。
//  不碰真日历/提醒事项；时间全部从固定时刻派生，不用 Date.now。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

private let cal = Calendar.current

// MARK: - B10：时间线协调器自激循环（P4.0-7）+ PlanStore 来源（P4.0-8）

@MainActor
private final class GrowingPrediction: ExecutionProgressReading {
    /// 模拟真机的反馈：协调器把活动块写长 → 执行层重读后预测也跟着变长（暂停 ≥10 分钟时每次 +暂停时长）。
    var id: UUID
    var start: Date
    var end: Date
    var step: TimeInterval = 20 * 60
    init(id: UUID, start: Date, end: Date) { self.id = id; self.start = start; self.end = end }
    var settledPlannedIDs: Set<UUID> { [] }
    var activePrediction: ActivePrediction? {
        end = end.addingTimeInterval(step)
        return ActivePrediction(id: id, start: start, end: end)
    }
}

@MainActor
@Suite struct P4TimelineFeedbackTests {
    private let base: Date = Calendar.current.startOfDay(for: DayContext.logicalDay(offset: 0))
    private func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: base)! }
    private var fixedNow: Date { at(13) }

    private struct Fixture {
        let co: TimelineCoordinator
        let plan: PlanStore
        let container: ModelContainer
    }

    private func make() throws -> Fixture {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, LongTask.self, configurations: config)
        let plan = PlanStore(context: container.mainContext)
        let started = StartedDayStore(persisted: false)
        let traces = ChangeTraceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("p4-trace-\(UUID().uuidString)", isDirectory: true))
        let markers = try #require(UserDefaults(suiteName: "bc-p4-spill-\(UUID().uuidString)"))
        let now = fixedNow
        let co = TimelineCoordinator(planStore: plan, startedDays: started, traces: traces,
                                     markerDefaults: markers, now: { now })
        started.markStarted(DayContext.logicalStartOfDay(now))
        return Fixture(co: co, plan: plan, container: container)
    }

    private var today: Date { DayContext.logicalStartOfDay(fixedNow) }

    /// 刷新分流：本机保存回声 → localStoreSave；防抖窗口里有过 CloudKit 导入 → cloudImport（不被吞）。
    @Test func routingSeparatesLocalEchoFromCloudImport() {
        var r = PlanChangeRouting()
        r.note(.storeRemoteChange)
        #expect(r.drain() == PlanChangeSource.localStoreSave)
        r.note(.cloudImportSucceeded); r.note(.storeRemoteChange)
        #expect(r.drain() == PlanChangeSource.cloudImport)
        #expect(r.drain() == PlanChangeSource.localStoreSave, "drain 后清空")
        r.note(.manualRefresh)
        #expect(r.drain() == PlanChangeSource.manualRefresh)
        #expect(!PlanChangeSource.ignoredByCoordinator.contains(PlanChangeSource.cloudImport))
        #expect(!PlanChangeSource.ignoredByCoordinator.contains(PlanChangeSource.manualRefresh))
    }

    /// 协调器分流：自家写回、本机保存回声 → 不重算；CloudKit 导入、没标来源的旧发出方 → 照常重算。
    @Test func coordinatorIgnoresOwnEchoButHandlesRealExternalChanges() async throws {
        let f = try make()
        let stale = ScheduledBlock(title: "过点块", start: at(10), end: at(11))
        try f.plan.replacePlanned([stale], on: today)
        #expect(await f.co.handlePlanChangedExternally(userInfo: [PlanChangeSource.key: PlanChangeSource.localStoreSave]) == 0)
        #expect(await f.co.handlePlanChangedExternally(userInfo: [PlanChangeSource.key: PlanChangeSource.timelineCoordinator]) == 0)
        #expect(f.co.lastComputeAt == nil, "回声不触发重算")
        #expect(try f.plan.plannedBlocks(on: today).first?.start == at(10))
        #expect(await f.co.handlePlanChangedExternally(userInfo: [PlanChangeSource.key: PlanChangeSource.cloudImport]) == 1)
        #expect(f.co.lastComputeAt != nil)
    }

    /// W1 路径不被破坏：智能体批准的挪块（带 updatedIDs、来源 approvedProposal）→ 进手改冷却并重算，块钉在原位。
    @Test func approvedMoveStillPinsBlockForThirtyMinutes() async throws {
        let f = try make()
        let moved = ScheduledBlock(title: "智能体挪过的", start: fixedNow.addingTimeInterval(20 * 60),
                                   end: fixedNow.addingTimeInterval(50 * 60))
        try f.plan.replacePlanned([moved], on: today)
        let wrote = await f.co.handlePlanChangedExternally(
            userInfo: ["updatedIDs": [moved.id], PlanChangeSource.key: ApprovedPlanMover.notificationSource])
        #expect(f.co.manualHolds[moved.id] != nil)
        #expect(f.co.lastComputeAt != nil, "照常重算")
        #expect(wrote == 0, "冷却窗内不被拉前")
        #expect(try f.plan.plannedBlocks(on: today).first?.start == moved.start)
        // 日历手改回流同理
        let other = UUID()
        _ = await f.co.handlePlanChangedExternally(userInfo: ["updatedIDs": [other], PlanChangeSource.key: PlanChangeSource.calendarReconcile])
        #expect(f.co.manualHolds[other] != nil)
    }

    /// B10 回归：同样的输入（一次 CloudKit 导入 + 每次写回都会让预测变长的活动块），
    /// 修复后整条链路只写有限次；旧链路（本机保存回声被当外部变更）每一轮都写、永不停（真机 10,523 次）。
    @Test func localSaveEchoNoLongerFeedsTheCoordinator() async throws {
        // 修复后：本机保存回声标 localStoreSave
        let fixed = try make()
        let active = ScheduledBlock(title: "5529 笔记整理", start: at(9), end: at(10))
        try fixed.plan.replacePlanned([active], on: today)
        let fixedWrites = await simulate(fixed, active: active, maxSteps: 10_000, legacy: false)
        #expect(fixedWrites.writes >= 1 && fixedWrites.writes <= 2, "只为那一次真外部变更写")
        #expect(fixedWrites.drained, "信号队列排空：回声不再回灌")

        // 旧链路对照：同样输入，回声不带来源 → 每轮都写，跑满步数仍停不下来
        let legacy = try make()
        let active2 = ScheduledBlock(title: "5529 笔记整理", start: at(9), end: at(10))
        try legacy.plan.replacePlanned([active2], on: today)
        let legacyWrites = await simulate(legacy, active: active2, maxSteps: 200, legacy: true)
        #expect(!legacyWrites.drained)
        #expect(legacyWrites.writes >= 200, "旧链路：每一轮回声都触发一次写回")
    }

    /// 事件驱动模拟：协调器每写一次 PlanStore = 一次本机保存 = 一个 NSPersistentStoreRemoteChange 回声。
    private func simulate(_ f: Fixture, active: ScheduledBlock, maxSteps: Int,
                          legacy: Bool) async -> (writes: Int, drained: Bool) {
        let progress = GrowingPrediction(id: active.id, start: at(12, 30), end: at(13, 30))
        f.co.progress = progress
        var routing = PlanChangeRouting()
        var queue: [PlanChangeRouting.Signal] = [.cloudImportSucceeded]
        var writes = 0, steps = 0
        while !queue.isEmpty, steps < maxSteps {
            steps += 1
            routing.note(queue.removeFirst())
            let source = routing.drain()
            let info: [AnyHashable: Any]? = legacy ? nil : [PlanChangeSource.key: source]   // 旧 DataSyncMonitor：不带来源
            let w = await f.co.handlePlanChangedExternally(userInfo: info)
            writes += w
            if w > 0 { queue.append(.storeRemoteChange) }   // 写回落库 → 本机保存回声
        }
        return (writes, queue.isEmpty)
    }

    /// P4.0-8 + B10 防线：值没变的更新不保存（不制造同步噪声）；日志按真实来源标注，不再全叫「对账回流」。
    @Test func planStoreSkipsNoOpSavesAndLabelsRealSource() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
        let store = PlanStore(context: container.mainContext)
        let b = ScheduledBlock(title: "写作", start: at(9), end: at(10))
        try store.replacePlanned([b], on: today)
        final class Counter: @unchecked Sendable { var n = 0 }
        let saves = Counter()
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave,
                                                           object: container.mainContext, queue: nil) { _ in saves.n += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.updatePlanned(id: b.id, start: at(9, 30), end: at(10, 30), title: "写作", reason: .timelineCoordinator)
        #expect(saves.n == 1)
        #expect(DevLog.shared.entries.contains { $0.message.contains("时间线协调器：更新「写作」") })
        try store.updatePlanned(id: b.id, start: at(9, 30), end: at(10, 30), title: "写作", reason: .timelineCoordinator)
        #expect(saves.n == 1, "同值更新不保存")
    }
}
