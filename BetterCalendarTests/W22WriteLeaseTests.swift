//
//  W22WriteLeaseTests.swift
//  BetterCalendarTests
//
//  W22 写权租约：两台设备的时间线协调器只让一台写自动调整。
//  模拟两台设备：共享一份「已同步的真相」（同一个内存 PlanStore）+ 一份共享 KV（假存储）+ 各自的时钟与执行进度。
//  纪律：内存库显式 .none；容器随 fixture 保活；时间全部从固定时刻派生（注入时钟，不用 Date.now）。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

/// 共享 KV 的假实现：多台「设备」各持一个 FakeLeaseStore，指向同一个 box。
@MainActor private final class SharedBox { var data: Data? }
@MainActor private final class FakeLeaseStore: WriteLeaseStoring {
    let box: SharedBox
    var onExternalChange: (() -> Void)?
    init(_ box: SharedBox) { self.box = box }
    func load() -> Data? { box.data }
    var failSync = false
    @discardableResult func save(_ data: Data) -> Bool { box.data = data; return !failSync }
}

@MainActor private final class Clock { var now: Date; init(_ d: Date) { now = d } }

@MainActor private final class LeaseProgress: ExecutionProgressReading {
    var settledPlannedIDs: Set<UUID> = []
    var predict: ActivePrediction?
    var activePrediction: ActivePrediction? { predict }
}

@MainActor
@Suite struct W22WriteLeaseTests {
    private let cal = Calendar.current
    private let base: Date = Calendar.current.startOfDay(for: DayContext.logicalDay(offset: 0))
    private func at(_ h: Int, _ mi: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + mi, to: base)! }
    private var today: Date { DayContext.logicalStartOfDay(at(13)) }

    private struct Device {
        let co: TimelineCoordinator
        let lease: TimelineWriteLease
        let clock: Clock
        let progress: LeaseProgress
    }

    private final class Logs { var lines: [(DevLog.Level, String)] = [] }

    private struct World {
        let plan: PlanStore
        let started: StartedDayStore
        let traces: ChangeTraceStore
        let pool: LongTaskStore
        let box: SharedBox
        let editsBox: SharedBox
        let logs: Logs
        let container: ModelContainer
    }

    private func makeWorld() throws -> World {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, LongTask.self, configurations: config)
        let started = StartedDayStore(persisted: false)
        started.markStarted(today)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w22-\(UUID().uuidString)", isDirectory: true)
        return World(plan: PlanStore(context: container.mainContext), started: started,
                     traces: ChangeTraceStore(directory: dir), pool: LongTaskStore(context: container.mainContext),
                     box: SharedBox(), editsBox: SharedBox(), logs: Logs(), container: container)
    }

    /// 一台设备：自己的时钟 / 执行进度 / 租约，共享真相与 KV。timingFlag 由闭包读，测试里随时改。
    private func makeDevice(_ w: World, id: String, now: Date, releasesOnBackground: Bool = false,
                            timing: @escaping () -> (Bool, Date?) = { (false, nil) }) -> Device {
        let clock = Clock(now)
        let logs = w.logs
        let lease = TimelineWriteLease(store: FakeLeaseStore(w.box), deviceID: id, deviceLabel: id,
                                       releasesOnBackground: releasesOnBackground,
                                       isEnabled: { true }, now: { clock.now },
                                       log: { level, msg in logs.lines.append((level, msg)) })
        lease.timing = timing
        let markers = UserDefaults(suiteName: "w22-\(UUID().uuidString)")!
        let co = TimelineCoordinator(planStore: w.plan, startedDays: w.started, traces: w.traces,
                                     markerDefaults: markers, now: { clock.now })
        let progress = LeaseProgress()
        co.progress = progress
        co.longTasks = w.pool
        co.writeLease = lease
        co.sharedEdits = SharedRecentEdits(store: FakeLeaseStore(w.editsBox), log: { level, msg in logs.lines.append((level, msg)) })
        return Device(co: co, lease: lease, clock: clock, progress: progress)
    }

    private func currentLease(_ w: World) -> WriteLease? {
        w.box.data.flatMap { try? JSONDecoder().decode(WriteLease.self, from: $0) }
    }

    // MARK: 只有持有者写自动调整

    @Test func onlyHolderWritesAutomaticAdjustments() async throws {
        let w = try makeWorld()
        let mac = makeDevice(w, id: "Mac", now: at(13))
        let phone = makeDevice(w, id: "iPhone", now: at(13))
        mac.lease.setForeground(true)
        #expect(currentLease(w)?.holder == "Mac")

        let stale = ScheduledBlock(title: "过点块", start: at(10), end: at(11))
        try w.plan.replacePlanned([stale], on: today)

        // 非持有者：照算（skipped 计数）但不写真相
        let phoneWrote = await phone.co.recompute(reason: "测试")
        #expect(phoneWrote == 0)
        #expect(phone.co.lastSkippedWrites == 1, "算出了要挪，只是不写")
        #expect(try w.plan.plannedBlocks(on: today).first?.start == at(10), "真相未动")
        #expect(w.traces.entries(day: today).isEmpty, "不落痕迹")

        // 持有者：照旧写
        let macWrote = await mac.co.recompute(reason: "测试")
        #expect(macWrote == 1)
        #expect(try w.plan.plannedBlocks(on: today).first?.start == at(13))
        #expect(currentLease(w)?.holder == "Mac", "非持有者没有抢走写权")
    }

    /// 活动预报（prediction write-back）同样只由持有者写。
    @Test func predictionWriteBackOnlyOnHolder() async throws {
        let w = try makeWorld()
        let mac = makeDevice(w, id: "Mac", now: at(13))
        let phone = makeDevice(w, id: "iPhone", now: at(13))
        mac.lease.setForeground(true)
        let b = ScheduledBlock(title: "写作", start: at(12), end: at(13))
        try w.plan.replacePlanned([b], on: today)
        phone.progress.predict = ActivePrediction(id: b.id, start: at(12, 30), end: at(14))
        phone.progress.settledPlannedIDs = [b.id]
        #expect(await phone.co.recompute(reason: "测试") == 0)
        #expect(phone.co.lastSkippedWrites == 1)
        #expect(try w.plan.plannedBlocks(on: today).first?.end == at(13), "预报没写回")
    }

    // MARK: 你的动作永远不经过闸

    @Test func userActionsAreNeverGated() async throws {
        let w = try makeWorld()
        let mac = makeDevice(w, id: "Mac", now: at(13))
        let phone = makeDevice(w, id: "iPhone", now: at(13))
        mac.lease.setForeground(true)
        let stale = ScheduledBlock(title: "过点块", start: at(10), end: at(11))
        try w.plan.replacePlanned([stale], on: today)
        _ = await mac.co.recompute(reason: "测试")   // Mac 自动顺延了它
        #expect(try w.plan.plannedBlocks(on: today).first?.start == at(13))

        // iPhone（不是写者）上点「撤销今天的自动调整」：照办
        #expect(phone.lease.mayWriteAutomatically() == false, "前提：iPhone 不是写者")
        #expect(phone.co.undoToday() == 1)
        #expect(try w.plan.plannedBlocks(on: today).first?.start == at(10))

        // iPhone 上日历手改回流 / 批准的挪块（带 updatedIDs）：手改冷却照常登记
        _ = await phone.co.handlePlanChangedExternally(userInfo: ["updatedIDs": [stale.id], PlanChangeSource.key: PlanChangeSource.calendarReconcile])
        #expect(phone.co.manualHolds.keys.contains(stale.id))

        // iPhone 上收尾盖章（你的承诺）：溢出硬执行照办
        let other = ScheduledBlock(title: "没做的", start: at(9), end: at(9, 30))
        try w.plan.replacePlanned([other], on: today)
        #expect(phone.co.executeSpills(day: today) == 1)
        #expect(w.pool.todoItems().map(\.title) == ["没做的"])

        // 拖动 / 删除直接走 PlanStore，协调器的闸根本不在路径上
        let dragged = ScheduledBlock(title: "拖过的", start: at(15), end: at(16))
        try w.plan.replacePlanned([dragged], on: today)
        try w.plan.updatePlanned(id: dragged.id, start: at(16), end: at(17), title: dragged.title, reason: .userEdit)
        #expect(try w.plan.plannedBlocks(on: today).first?.start == at(16))
    }

    // MARK: 正在计时的设备拿写权

    @Test func runningTimerTakesLease() async throws {
        let w = try makeWorld()
        let mac = makeDevice(w, id: "Mac", now: at(13))
        var phoneTiming = false
        let phone = makeDevice(w, id: "iPhone", now: at(13), timing: { (phoneTiming, at(14)) })
        mac.lease.setForeground(true)
        #expect(currentLease(w)?.holder == "Mac")

        phoneTiming = true
        #expect(phone.lease.mayWriteAutomatically() == true, "计时抢走非计时租约")
        let l = try #require(currentLease(w))
        #expect(l.holder == "iPhone" && l.reason == .timer)
        #expect(l.expiresAt == at(14).addingTimeInterval(WriteLeasePolicy.timerGrace), "计时租约有效到预计结束 + 10 分钟")
        #expect(mac.lease.mayWriteAutomatically() == false)

        // Mac 回到前台也抢不走计时租约
        mac.lease.setForeground(false)
        mac.lease.setForeground(true)
        #expect(currentLease(w)?.holder == "iPhone")

        // 计时结束：iPhone 降为普通租约（继续持有），Mac 再回前台时可以接过去
        phoneTiming = false
        phone.clock.now = at(13, 5)
        #expect(phone.lease.mayWriteAutomatically() == true)
        #expect(currentLease(w)?.reason == .held)
        mac.clock.now = at(13, 6)
        mac.lease.setForeground(false)
        mac.lease.setForeground(true)
        #expect(currentLease(w)?.holder == "Mac" && currentLease(w)?.reason == .foreground)
    }

    // MARK: 到期交接

    @Test func expiryHandsOverToOtherDevice() async throws {
        let w = try makeWorld()
        let mac = makeDevice(w, id: "Mac", now: at(13))
        let phone = makeDevice(w, id: "iPhone", now: at(13))
        phone.lease.setForeground(true)
        #expect(mac.lease.mayWriteAutomatically() == false)

        // iPhone 没再续（离线 / 挂起）；Mac 的钟走到 6 分钟 TTL + 2 分钟容差之后
        mac.clock.now = at(13, 9)
        #expect(mac.lease.mayWriteAutomatically() == true)
        let l = try #require(currentLease(w))
        #expect(l.holder == "Mac" && l.reason == .expiredTakeover)
        #expect(w.logs.lines.contains { $0.0 == .info && $0.1.contains("到期") }, "交接记 info")
        #expect(!w.logs.lines.contains { $0.0 == .warning }, "正常到期不算卡住")

        // 期间不到期就不交接：容差内（7 分钟）不接手
        let w2 = try makeWorld()
        let a = makeDevice(w2, id: "A", now: at(13))
        let b = makeDevice(w2, id: "B", now: at(13))
        a.lease.setForeground(true)
        b.clock.now = at(13, 7)
        #expect(b.lease.mayWriteAutomatically() == false)
    }

    /// iPhone 回后台且没在计时 → 主动交出；Mac 下一轮立即接手（不用等到期）。
    @Test func phoneReleasesOnBackgroundAndMacTakesOver() async throws {
        let w = try makeWorld()
        let mac = makeDevice(w, id: "Mac", now: at(13))
        let phone = makeDevice(w, id: "iPhone", now: at(13), releasesOnBackground: true)
        phone.lease.setForeground(true)
        #expect(mac.lease.mayWriteAutomatically() == false)
        phone.lease.setForeground(false)
        #expect(currentLease(w)?.releasedAt != nil)
        mac.clock.now = at(13, 1)
        #expect(mac.lease.mayWriteAutomatically() == true)
        #expect(currentLease(w)?.holder == "Mac")
        #expect(phone.lease.mayWriteAutomatically() == false, "交出后不在后台抢回")
    }

    // MARK: 失联持有者被接手并记录（卡住）

    @Test func staleHolderIsTakenOverAndLogged() async throws {
        let w = try makeWorld()
        // iPhone 的钟快了 1 小时：它写的到期时刻在 Mac 看来远在未来
        let phone = makeDevice(w, id: "iPhone", now: at(14))
        let mac = makeDevice(w, id: "Mac", now: at(13))
        phone.lease.setForeground(true)
        #expect(mac.lease.mayWriteAutomatically() == false, "刚看到：有效")

        // Mac 自己的钟走了 15 分钟（> 声明时长 6 + 投递余量 10 分钟？还差一点）→ 仍等待
        mac.clock.now = at(13, 15)
        #expect(mac.lease.mayWriteAutomatically() == false)
        // 17 分钟没看到续约 → 失联接手 + warning
        mac.clock.now = at(13, 17)
        #expect(mac.lease.mayWriteAutomatically() == true)
        let l = try #require(currentLease(w))
        #expect(l.holder == "Mac" && l.reason == .staleTakeover)
        #expect(w.logs.lines.contains { $0.0 == .warning && $0.1.contains("没续约") }, "卡住才记 warning")
    }

    /// 钟差容忍：持有者的钟慢 1 分钟、按时续约 → 对方不误判到期。
    @Test func clockSkewWithinToleranceDoesNotFlip() async throws {
        let w = try makeWorld()
        let phone = makeDevice(w, id: "iPhone", now: at(12, 59))   // 慢 1 分钟
        let mac = makeDevice(w, id: "Mac", now: at(13))
        phone.lease.setForeground(true)
        for step in 1...6 {   // 每 3 分钟各走一拍：iPhone 过半续约
            phone.clock.now = at(12, 59 + step * 3)
            _ = phone.lease.mayWriteAutomatically()
            mac.clock.now = at(13, step * 3)
            #expect(mac.lease.mayWriteAutomatically() == false, "第 \(step) 拍不应接手")
        }
        #expect(currentLease(w)?.holder == "iPhone")
    }

    // MARK: 单设备与改动前一致

    @Test func singleDeviceBehavesExactlyAsBefore() async throws {
        // 同一场景：一台带租约（从没回过前台、也没计时），一台不带租约（旧行为）
        func run(withLease: Bool) async throws -> (Int, [Date], Int) {
            let w = try makeWorld()
            let d = makeDevice(w, id: "Solo", now: at(13), releasesOnBackground: true)
            if !withLease { d.co.writeLease = nil }
            let blocks = [ScheduledBlock(title: "过点块", start: at(10), end: at(11)),
                          ScheduledBlock(title: "下午", start: at(14), end: at(15))]
            try w.plan.replacePlanned(blocks, on: today)
            var wrote = await d.co.recompute(reason: "测试")
            // 回后台交出后，后台零星重算照旧可写
            d.lease.setForeground(true); d.lease.setForeground(false)
            d.clock.now = at(13, 30)
            try w.plan.updatePlanned(id: blocks[1].id, start: at(11), end: at(12), title: "下午", reason: .userEdit)
            wrote += await d.co.recompute(reason: "测试")
            let starts = try w.plan.plannedBlocks(on: today).map(\.start).sorted()
            return (wrote, starts, w.traces.entries(day: today).count)
        }
        let before = try await run(withLease: false)
        let after = try await run(withLease: true)
        #expect(before.0 == after.0 && before.1 == after.1 && before.2 == after.2, "\(before) vs \(after)")
        #expect(before.0 >= 2, "场景确实发生了自动写")
    }

    /// 启动补结算：没写权就记下，拿到写权那一轮补跑。
    @Test func backstopDeferredUntilLeaseAcquired() async throws {
        let w = try makeWorld()
        let mac = makeDevice(w, id: "Mac", now: at(13))
        let phone = makeDevice(w, id: "iPhone", now: at(13))
        mac.lease.setForeground(true)
        phone.co.executePendingSpills()
        #expect(phone.co.pendingBackstop)
        phone.lease.setForeground(true)   // iPhone 回前台抢到写权
        _ = await phone.co.recompute(reason: "测试")
        #expect(!phone.co.pendingBackstop, "拿到写权那一轮补跑了")
    }

    // MARK: W22b 跨设备手改冷却

    /// 在不持有写权的 iPhone 上批准智能体挪块 → 持有写权的 Mac 30 分钟内不把它排走；过期后恢复正常；不写图钉。
    @Test func approvalOnNonHolderIsHeldOnHolderUntilCooldownExpires() async throws {
        let w = try makeWorld()
        let mac = makeDevice(w, id: "Mac", now: at(13))
        let phone = makeDevice(w, id: "iPhone", now: at(13))
        mac.lease.setForeground(true)
        let b = ScheduledBlock(title: "智能体挪过的", start: at(10), end: at(11))
        try w.plan.replacePlanned([b], on: today)

        // iPhone 执行批准的挪块（同 ApprovedPlanMover：按 id 改时间 + 发带 updatedIDs 的通知）
        try w.plan.updatePlanned(id: b.id, start: at(11), end: at(12), title: b.title, reason: .agentApproval)
        _ = await phone.co.handlePlanChangedExternally(userInfo: ["updatedIDs": [b.id],
                                                                  PlanChangeSource.key: ApprovedPlanMover.notificationSource])
        #expect(mac.co.manualHolds[b.id] == nil, "前提：Mac 本机没有这条冷却")

        // Mac（写者）重算：冷却窗内不挪
        #expect(await mac.co.recompute(reason: "测试") == 0)
        let held = try #require(try w.plan.plannedBlocks(on: today).first)
        #expect(held.start == at(11), "另一台发布的冷却生效")
        #expect(held.pinnedUntil == nil, "批准的挪块不是图钉")

        // 30 分钟后：恢复正常维护
        mac.clock.now = at(13, 31)
        #expect(await mac.co.recompute(reason: "测试") == 1)
        #expect(try w.plan.plannedBlocks(on: today).first?.start == at(13, 31))
    }

    /// 一键撤（另一条登记冷却的路径）同样跨设备；条目过期即被丢弃。
    @Test func undoOnNonHolderIsHeldOnHolder() async throws {
        let w = try makeWorld()
        let mac = makeDevice(w, id: "Mac", now: at(13))
        let phone = makeDevice(w, id: "iPhone", now: at(13))
        mac.lease.setForeground(true)
        let b = ScheduledBlock(title: "过点块", start: at(10), end: at(11))
        try w.plan.replacePlanned([b], on: today)
        _ = await mac.co.recompute(reason: "测试")
        #expect(phone.co.undoToday() == 1)
        #expect(await mac.co.recompute(reason: "测试") == 0)
        #expect(try w.plan.plannedBlocks(on: today).first?.start == at(10))
        let edits = SharedRecentEdits(store: FakeLeaseStore(w.editsBox), log: { _, _ in })
        #expect(edits.active(now: at(13, 29))[b.id] != nil)
        #expect(edits.active(now: at(13, 31)).isEmpty, "过期条目不再生效")
    }

    /// KV 同步失败可见（只记一次，不刷屏）；本机冷却照常。
    @Test func sharedEditsSyncFailureIsLoggedOnce() {
        let box = SharedBox()
        let store = FakeLeaseStore(box)
        store.failSync = true
        var lines: [(DevLog.Level, String)] = []
        let edits = SharedRecentEdits(store: store, log: { lines.append(($0, $1)) })
        edits.publish(ids: [UUID()], until: at(13, 30), now: at(13))
        edits.publish(ids: [UUID()], until: at(13, 31), now: at(13, 1))
        #expect(lines.filter { $0.0 == .warning }.count == 1)
        #expect(edits.active(now: at(13, 2)).count == 2, "本机副本仍在")
        // 坏数据：读不懂只记一次
        box.data = Data("坏".utf8)
        _ = edits.active(now: at(13)); _ = edits.active(now: at(13))
        #expect(lines.filter { $0.0 == .warning }.count == 2)
    }

    /// 条数上限：只留最晚到期的 maxEntries 条。
    @Test func sharedEditsCapSize() {
        let edits = SharedRecentEdits(store: FakeLeaseStore(SharedBox()), log: { _, _ in })
        for i in 0..<(SharedRecentEdits.maxEntries + 20) {
            edits.publish(ids: [UUID()], until: at(14).addingTimeInterval(TimeInterval(i)), now: at(13))
        }
        #expect(edits.active(now: at(13)).count == SharedRecentEdits.maxEntries)
    }

    /// 应急总闸关 = 旧行为：谁都能写，不碰共享存储。
    @Test func killSwitchRestoresOldBehavior() {
        let box = SharedBox()
        let lease = TimelineWriteLease(store: FakeLeaseStore(box), deviceID: "X", deviceLabel: "X",
                                       releasesOnBackground: true, isEnabled: { false }, now: { Date(timeIntervalSince1970: 0) },
                                       log: { _, _ in })
        lease.setForeground(true)
        #expect(lease.mayWriteAutomatically())
        #expect(box.data == nil)
    }
}
