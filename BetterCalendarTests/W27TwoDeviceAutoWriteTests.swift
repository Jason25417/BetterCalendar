//
//  W27TwoDeviceAutoWriteTests.swift
//  BetterCalendarTests
//
//  W27（SPEC §19.14 W22 遗留）：两台设备都跑的自动写入不许记两份。
//  · 固定块到点自动完成（被动推断）：只由持有写权的设备记进真相；另一台只显示；
//  · 两台都记了（离线 / 交接瞬间）：实际按 id 收成一条，记下的赢过被动推断；
//  · 学习层补折、溢出补结算的同类重复。
//  模拟两台设备：在线 = 共享同一个内存 PlanStore（「已同步的真相」）+ 共享假 KV；离线 = 各自的库与 KV，
//  之后把对方的行原样插进来（= CloudKit 导入：同 id 的另一行，没有唯一约束）。
//  纪律：内存库显式 .none；容器随 fixture 保活；时间全部从固定时刻派生（注入时钟，不用 Date.now）；不碰真日历 / 真提醒。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

@MainActor private final class KVBox { var data: Data? }
@MainActor private final class FakeKV: WriteLeaseStoring {
    let box: KVBox
    var onExternalChange: (() -> Void)?
    init(_ box: KVBox) { self.box = box }
    func load() -> Data? { box.data }
    @discardableResult func save(_ data: Data) -> Bool { box.data = data; return true }
}
@MainActor private final class TestClock { var now: Date; init(_ d: Date) { now = d } }

@MainActor
@Suite struct W27TwoDeviceAutoWriteTests {
    private let cal = Calendar.current
    /// 基准 = 真实逻辑今天的日历日（防「固定日期 × 真实时钟」时间炸弹，同 W22 / 协调器测试）；时刻全部由它派生。
    private let base: Date = Calendar.current.startOfDay(for: DayContext.logicalDay(offset: 0))
    private func at(_ h: Int, _ mi: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + mi, to: base)! }
    private var today: Date { DayContext.logicalStartOfDay(at(13)) }

    @MainActor private final class Store {
        let container: ModelContainer   // 只为保活（ModelContext 不持有容器）
        let context: ModelContext
        init() throws {
            let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            container = try ModelContainer(for: PlanBlock.self, LongTask.self, ResidualSample.self, DayPlanSnapshot.self,
                                           configurations: config)
            context = container.mainContext
        }
        func actualRows() throws -> [PlanBlock] {
            try context.fetch(FetchDescriptor<PlanBlock>()).filter { $0.kind == .actual && !$0.isInTrash }
        }
    }

    private struct Device {
        let id: String
        let plan: PlanStore
        let vm: ExecutionViewModel
        let lease: TimelineWriteLease
        let clock: TestClock
    }

    /// 一台设备：自己的时钟 / 租约 / 执行页；真相库与 KV 由调用方决定共享（在线）或各自一份（离线）。
    private func makeDevice(_ id: String, store: Store, kv: KVBox, now: Date,
                            timing: @escaping () -> (Bool, Date?) = { (false, nil) }) -> Device {
        let clock = TestClock(now)
        let plan = PlanStore(context: store.context, writerID: id, now: { clock.now })
        let lease = TimelineWriteLease(store: FakeKV(kv), deviceID: id, deviceLabel: id, releasesOnBackground: false,
                                       isEnabled: { true }, now: { clock.now }, log: { _, _ in })
        lease.timing = timing
        let vm = ExecutionViewModel(calendarStore: FakeCalendarStore(),
                                    reschedule: RescheduleService(planStore: plan, planner: NaivePlanningEngine()),
                                    planStore: plan, reminderStore: FakeReminderStore(),
                                    liveActivity: NoLiveActivity(), persistsRunState: false)
        vm.clock = { clock.now }
        vm.autoCompleteFixed = { true }
        vm.automaticWriteGate = { lease.mayWriteAutomatically() }
        return Device(id: id, plan: plan, vm: vm, lease: lease, clock: clock)
    }

    private func meeting() -> ScheduledBlock {
        ScheduledBlock(title: "组会", start: at(10), end: at(11), isFixed: true)
    }

    /// 重新联网后 CloudKit 双向导入的等价物：两边各自的实际行原样插进对方库（同 id 的另一行）。
    private func syncBoth(_ a: Store, _ b: Store) throws {
        let fromA = try a.actualRows(), fromB = try b.actualRows()
        try insert(fromB, into: a)
        try insert(fromA, into: b)
    }

    private func insert(_ rows: [PlanBlock], into: Store) throws {
        for r in rows {
            let copy = PlanBlock(id: r.id, title: r.title, start: r.start, end: r.end, kind: .actual)
            copy.actualState = r.actualState
            copy.syncVersion = r.syncVersion
            copy.syncWriter = r.syncWriter
            into.context.insert(copy)
        }
        try into.context.save()
    }

    // MARK: 固定块到点：两台都开着

    @Test func fixedBlockEndsWhileBothRunRecordsExactlyOneActual() async throws {
        let store = try Store()
        let kv = KVBox()
        let block = meeting()
        let mac = makeDevice("mac", store: store, kv: kv, now: at(11, 5))
        let phone = makeDevice("phone", store: store, kv: kv, now: at(11, 5))
        try mac.plan.replacePlanned([block], on: today)
        mac.lease.setForeground(true)   // Mac 在前台：持有写权

        await phone.vm.loadToday()   // 没写权：只显示
        #expect(try store.actualRows().isEmpty, "非持有者不记被动完成")
        #expect(phone.vm.isDone(phone.vm.planned[0]), "非持有者照样显示做成了")
        #expect(phone.vm.withheldPassive.map(\.plannedID) == [block.id])

        await mac.vm.loadToday()     // 持有者记一次
        await phone.vm.loadToday()   // 同步到了：按 id 接上，不再推断
        await mac.vm.loadToday()     // 再跑也幂等
        #expect(try store.actualRows().count == 1, "物理上只有一行实际")
        let actuals = try mac.plan.actualBlocks(on: today)
        #expect(actuals.count == 1 && actuals[0].id == block.id && actuals[0].state == .auto)
        #expect(phone.vm.withheldPassive.isEmpty, "真相到了 → 不再挂着只显示")
        #expect(phone.vm.done.filter { $0.plannedID == block.id }.count == 1, "显示也只有一条")
    }

    // MARK: 交接：块进行中写权换手

    @Test func leaseHandoverMidBlockStillRecordsOnce() async throws {
        let store = try Store()
        let kv = KVBox()
        let block = meeting()
        var macTiming = true
        let mac = makeDevice("mac", store: store, kv: kv, now: at(10, 30), timing: { (macTiming, at(11)) })
        let phone = makeDevice("phone", store: store, kv: kv, now: at(10, 30))
        try mac.plan.replacePlanned([block], on: today)
        #expect(mac.lease.mayWriteAutomatically(), "Mac 计时中：拿写权")
        #expect(!phone.lease.mayWriteAutomatically())

        // 10:45 Mac 停表（还持有）；10:50 iPhone 回前台抢走写权
        macTiming = false
        mac.clock.now = at(10, 45); _ = mac.lease.mayWriteAutomatically()
        phone.clock.now = at(10, 50); phone.lease.setForeground(true)
        #expect(phone.lease.current?.holder == "phone")

        // 11:03 iPhone 的协调器分钟脉冲顺手续约（生产里每分钟都会判一次）
        phone.clock.now = at(11, 3); #expect(phone.lease.mayWriteAutomatically())
        // 11:05 两台都算：旧持有者先跑（只显示），新持有者记
        mac.clock.now = at(11, 5); phone.clock.now = at(11, 5)
        await mac.vm.loadToday()
        #expect(try store.actualRows().isEmpty, "交出写权的设备不记")
        await phone.vm.loadToday()
        await mac.vm.loadToday()
        #expect(try store.actualRows().count == 1)
        #expect(try mac.plan.actualBlocks(on: today).count == 1)
        #expect(mac.vm.withheldPassive.isEmpty)
    }

    @Test func holderRecordsBeforeHandoverNewHolderDoesNotRepeat() async throws {
        let store = try Store()
        let kv = KVBox()
        let block = meeting()
        let mac = makeDevice("mac", store: store, kv: kv, now: at(11, 2))
        let phone = makeDevice("phone", store: store, kv: kv, now: at(11, 2))
        try mac.plan.replacePlanned([block], on: today)
        mac.lease.setForeground(true)
        await mac.vm.loadToday()                      // 交接前已记
        phone.clock.now = at(11, 20); phone.lease.setForeground(true)   // 换手
        await phone.vm.loadToday()
        #expect(try store.actualRows().count == 1, "新持有者看到已有的实际，不再推断")
    }

    // MARK: 两台都离线：各记一份 → 合并后仍是一条

    @Test func offlineBothRecordThenMergeCollapsesToOne() async throws {
        let macStore = try Store(), phoneStore = try Store()
        let block = meeting()
        let mac = makeDevice("mac", store: macStore, kv: KVBox(), now: at(11, 5))     // 离线：各自的 KV
        let phone = makeDevice("phone", store: phoneStore, kv: KVBox(), now: at(11, 7))
        try mac.plan.replacePlanned([block], on: today)
        try phone.plan.replacePlanned([block], on: today)
        mac.lease.setForeground(true); phone.lease.setForeground(true)
        await mac.vm.loadToday(); await phone.vm.loadToday()
        #expect(try macStore.actualRows().count == 1 && phoneStore.actualRows().count == 1, "离线时两台各记了一份")

        try syncBoth(macStore, phoneStore)   // 重新联网：CloudKit 双向导入
        #expect(try macStore.actualRows().count == 2 && phoneStore.actualRows().count == 2, "导入后物理上有重复行（没有唯一约束）")
        let onMac = try mac.plan.actualBlocks(on: today), onPhone = try phone.plan.actualBlocks(on: today)
        #expect(onMac.count == 1 && onPhone.count == 1, "读者按 id 只看到一条——不双计")
        #expect(onMac == onPhone, "两台设备选出同一个保留者")

        await mac.vm.loadToday(); await phone.vm.loadToday()
        #expect(mac.vm.done.filter { $0.plannedID == block.id }.count == 1)
        #expect(try mac.plan.actualBlocks(on: today).count == 1, "合并后再跑也不新增")
    }

    @Test func recordedBeatsPassiveAfterMergeAndIsNeverDowngraded() async throws {
        let macStore = try Store(), phoneStore = try Store()
        let block = meeting()
        let mac = makeDevice("mac", store: macStore, kv: KVBox(), now: at(11, 5))
        let phone = makeDevice("phone", store: phoneStore, kv: KVBox(), now: at(11, 30))
        try mac.plan.replacePlanned([block], on: today)
        try phone.plan.replacePlanned([block], on: today)
        mac.lease.setForeground(true)
        await mac.vm.loadToday()                                        // Mac：到点被动推断（auto）
        try phone.plan.upsertActuals([ActualBlock(id: block.id, title: block.title,
                                                  start: at(10, 5), end: at(11, 20), state: .recorded)])   // iPhone：你记下的
        try syncBoth(macStore, phoneStore)
        for d in [mac, phone] {
            let a = try d.plan.actualBlocks(on: today)
            #expect(a.count == 1 && a[0].state == .recorded && a[0].end == at(11, 20), "\(d.id)：记下的赢过被动推断")
        }
        // 再来一次被动推断的写（旧状态补记）不许把记下的降级；写穿后两行收敛成同一份
        try mac.plan.upsertActuals([ActualBlock(id: block.id, title: block.title, start: at(10), end: at(11), state: .auto)])
        #expect(try mac.plan.actualBlocks(on: today)[0].state == .recorded)
        try mac.plan.upsertActuals([ActualBlock(id: block.id, title: block.title, start: at(10, 5), end: at(11, 25))])
        let rows = try macStore.actualRows().filter { $0.id == block.id }
        #expect(rows.count == 2 && Set(rows.map(\.end)) == [at(11, 25)], "同 id 的每一行都写穿")
    }

    // MARK: 你的动作不经过闸

    @Test func manualCompletionOnNonHolderIsRecorded() async throws {
        let store = try Store()
        let kv = KVBox()
        let block = ScheduledBlock(title: "写报告", start: at(9), end: at(10))
        let mac = makeDevice("mac", store: store, kv: kv, now: at(10, 5))
        let phone = makeDevice("phone", store: store, kv: kv, now: at(10, 5))
        try mac.plan.replacePlanned([block], on: today)
        mac.lease.setForeground(true)
        await phone.vm.loadToday()
        _ = await phone.vm.markDone(titleLike: "写报告")   // 非持有者上你亲手点完成
        let a = try phone.plan.actualBlocks(on: today)
        #expect(a.count == 1 && a[0].state == .recorded, "你的动作永远照记")
    }

    // MARK: 学习层补折：两台各折一份

    @Test func residualSamplesFoldedOnBothDevicesCountOnce() throws {
        let store = try Store()
        let blockID = UUID()
        func sample(created: Date, minutes: Int) -> ResidualSample {
            let s = ResidualSample(dayLabel: today, blockID: blockID, title: "写报告", plannedStart: at(9), plannedMinutes: 60,
                                   actualStart: at(9), actualMinutes: minutes, source: .live)
            s.createdAt = created
            return s
        }
        store.context.insert(sample(created: at(23, 10), minutes: 70))   // iPhone 先折
        store.context.insert(sample(created: at(23, 40), minutes: 70))   // Mac 后折（同一块）
        store.context.insert(ResidualSample(dayLabel: today, blockID: UUID(), title: "别的", plannedStart: at(14),
                                            plannedMinutes: 30, actualStart: at(14), actualMinutes: 30, source: .live))
        try store.context.save()
        let learning = LearningStore(context: store.context)
        #expect(learning.samples(on: today).count == 2, "同（日, 块）只算一份")
        #expect(learning.allSamples().count == 2)
        #expect(learning.allSamples().first { $0.blockID == blockID }?.createdAt == at(23, 10), "留最早折的那份（与聚合游标一致）")
    }

    // MARK: 溢出补结算：另一台已结算过的日子不再收一遍池

    @Test func spillSettledOnOneDeviceIsNotPooledAgainOnTheOther() throws {
        let macStore = try Store(), phoneStore = try Store()   // iPhone 还没收到 Mac 的删除
        let marks = KVBox()
        func coordinator(_ store: Store, _ label: String) -> (TimelineCoordinator, LongTaskStore, PlanStore) {
            let plan = PlanStore(context: store.context, writerID: label, now: { at(22) })
            let pool = LongTaskStore(context: store.context)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w27-\(UUID().uuidString)", isDirectory: true)
            let co = TimelineCoordinator(planStore: plan, startedDays: StartedDayStore(persisted: false),
                                         traces: ChangeTraceStore(directory: dir),
                                         markerDefaults: UserDefaults(suiteName: "w27-\(UUID().uuidString)")!,
                                         now: { at(22) })
            co.longTasks = pool
            co.sharedSpillMarks = SharedSpillMarks(store: FakeKV(marks), log: { _, _ in })
            return (co, pool, plan)
        }
        let undone = ScheduledBlock(title: "没做的", start: at(10), end: at(11))
        let (macCo, macPool, macPlan) = coordinator(macStore, "mac")
        let (phoneCo, phonePool, phonePlan) = coordinator(phoneStore, "phone")
        try macPlan.replacePlanned([undone], on: today)
        try phonePlan.replacePlanned([undone], on: today)

        #expect(macCo.executeSpills(day: today) == 1, "Mac 收工盖章：收进待办区")
        #expect(phoneCo.executeSpills(day: today) == 0, "iPhone 补结算：看到 Mac 已结算，不再收")
        #expect(macPool.todoItems().count == 1 && phonePool.todoItems().isEmpty, "待办区只有一份")
        #expect(try phonePlan.plannedBlocks(on: today).count == 1, "iPhone 不动数据，等 Mac 的删除同步过来")
    }
}
