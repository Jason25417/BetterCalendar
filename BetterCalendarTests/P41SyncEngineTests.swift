//
//  P41SyncEngineTests.swift
//  BetterCalendarTests
//
//  W15 / P4.1（2026-10-19）：
//  ① 单一写者：BetterCalendar 自家日历只由 CalendarSyncEngine 写（架构守卫 + 搬家前后等价）；
//  ② DataArchive 归档 P4 新字段（图钉、版本、写者、来源、实际状态），旧档案向后兼容；
//  ③ iPhone 先发现的日历删除：回执随被删的计划块同步，Mac 中继转交一次（去重）。
//  全部用假日历 × 内存 SwiftData；时钟注入。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

private let cal = Calendar.current
/// 固定基准：2026-10-20（周二）。
private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
}

@MainActor private final class Clock { var now: Date; init(_ d: Date) { now = d } }

/// 比较用：只看日历里一个事件的可见内容与身份。
private struct Shape: Hashable { let kind: String; let title: String; let start: Date; let end: Date; let blockID: UUID? }
private func shapes(_ c: SimulatedEventKitCalendar, _ kind: PlanCalendarKind) -> Set<Shape> {
    Set(c.events(kind).map { Shape(kind: "\($0.kind)", title: $0.title, start: $0.start, end: $0.end, blockID: $0.blockID) })
}

// MARK: - ① 单一写者

@MainActor
@Suite struct P41SingleWriterTests {
    /// 架构守卫：能写日历的类型（CalendarStore = 读写合一 / CalendarProjecting = 写角色）只许出现在
    /// 协议定义、EventKit 实现、组装点和引擎里；蓝色「读回 ∪ 新增」合并也只在引擎里。
    @Test func calendarWriteCapabilityStaysInEngine() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BetterCalendar")
        let allowed: Set<String> = ["CalendarStore.swift", "CalendarSyncEngine.swift",
                                    "EventKitCalendarStore.swift", "AppContainer.swift"]
        let capability = try NSRegularExpression(pattern: #"(?<![A-Za-z])(CalendarStore|CalendarProjecting)(?![A-Za-z])"#)
        var offenders: [String] = []
        var unionOutside: [String] = []
        let files = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let code = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                .joined(separator: "\n")
            let name = url.lastPathComponent
            if !allowed.contains(name),
               capability.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil { offenders.append(name) }
            if !["CalendarSyncEngine.swift", "CalendarMerge.swift"].contains(name), code.contains("CalendarMerge.union(") {
                unionOutside.append(name)
            }
        }
        #expect(offenders.isEmpty, "这些文件拿到了日历写角色（应只依赖 CalendarReading，写经 CalendarSyncEngine）：\(offenders)")
        #expect(unionOutside.isEmpty, "蓝色合并写只能在引擎里：\(unionOutside)")
    }

    /// 搬家前的执行页 / 复盘补一笔写法（原样抄自旧代码，作等价参照）。
    private func legacyUnionWrite(_ c: SimulatedEventKitCalendar, _ drafts: [CalendarEventDraft]) async throws {
        let existing = try await c.read(kind: .actual)
        try await c.write(CalendarMerge.union(existing: existing, additions: drafts, kind: .actual))
    }

    private static let yesterdayID = UUID(), greenID = UUID()
    private func seeded(_ now: Date, other: UUID, mine: UUID) -> SimulatedEventKitCalendar {
        let c = SimulatedEventKitCalendar(now: now)
        c.seed(.actual, "Career Fair", at(20, 10), at(20, 12))                          // 你的（无章）
        c.seed(.actual, "另一台设备做的", at(20, 8), at(20, 9), blockID: other)          // 别处产生的实际
        c.seed(.actual, "写作", at(20, 9), at(20, 9, 20), blockID: mine)                // 同一件：旧的（较短）
        c.seed(.actual, "昨天的", at(19, 15), at(19, 16), blockID: Self.yesterdayID)
        c.seed(.planned, "绿色", at(20, 14), at(20, 15), blockID: Self.greenID)               // 别的日历不受影响
        return c
    }

    /// 蓝色写入搬进引擎：与旧的「读回 ∪ 新增 再写」逐字等价（含重复确认、你的事件不动、别处实际不删）。
    @Test func recordActualsMatchesLegacyUnionWrite() async throws {
        let now = at(20, 13), other = UUID(), mine = UUID(), bonus = UUID()
        let legacy = seeded(now, other: other, mine: mine)
        let viaEngine = seeded(now, other: other, mine: mine)
        let container = try ModelContainer(for: PlanBlock.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let engine = CalendarSyncEngine(planStore: PlanStore(context: container.mainContext), calendarStore: viaEngine, now: { now })
        let rounds: [[CalendarEventDraft]] = [
            [CalendarEventDraft(title: "写作", start: at(20, 9), end: at(20, 9, 50), kind: .actual, blockID: mine),
             CalendarEventDraft(title: "计划外", start: at(20, 11), end: at(20, 11, 30), kind: .actual, blockID: bonus)],
            [CalendarEventDraft(title: "写作", start: at(20, 9), end: at(20, 9, 50), kind: .actual, blockID: mine)],   // 重复确认
            [],                                                                                                       // 空 = 不碰
        ]
        for drafts in rounds {
            if !drafts.isEmpty { try await legacyUnionWrite(legacy, drafts) }
            try await engine.recordActuals(drafts)
            #expect(shapes(viaEngine, .actual) == shapes(legacy, .actual))
            #expect(shapes(viaEngine, .planned) == shapes(legacy, .planned))
        }
        #expect(shapes(viaEngine, .actual).contains(Shape(kind: "actual", title: "Career Fair", start: at(20, 10), end: at(20, 12), blockID: nil)))
        #expect(viaEngine.events(.actual).filter { $0.blockID == mine }.count == 1)
        #expect(viaEngine.events(.actual).contains { $0.blockID == other })
    }

    /// 回收站恢复实际：与旧的「读该日别的蓝 ＋ 这条，按窗口对齐」逐字等价。
    @Test func restoreActualMatchesLegacyWindowApply() async throws {
        let now = at(20, 13), other = UUID(), mine = UUID(), restored = UUID()
        let legacy = seeded(now, other: other, mine: mine)
        let viaEngine = seeded(now, other: other, mine: mine)
        let container = try ModelContainer(for: PlanBlock.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let engine = CalendarSyncEngine(planStore: PlanStore(context: container.mainContext), calendarStore: viaEngine, now: { now })
        let (start, end) = (at(20, 16), at(20, 17))
        // 旧 RetainedTrashService 写法（原样）
        let window = DayContext.logicalWindow(forLabel: DayContext.logicalStartOfDay(start))
        var existing = try await legacy.read(kind: .actual).filter {
            $0.start >= window.start && $0.start < window.end && $0.blockID != restored
        }
        existing.append(CalendarEventDraft(title: "恢复的", start: start, end: end, kind: .actual, blockID: restored))
        try await legacy.apply(existing, kind: .actual, window: window)

        try await engine.restoreActual(id: restored, title: "恢复的", start: start, end: end)
        #expect(shapes(viaEngine, .actual) == shapes(legacy, .actual))
        #expect(viaEngine.events(.actual).contains { $0.blockID == restored })
    }

    /// 执行页做完一件：经引擎画蓝（与旧行为同：只剩蓝、绿色让位）；**日历写失败也先落真相**（P4.1 唯一的有意行为变化）。
    @Test func completingWritesTruthEvenWhenCalendarWriteFails() async throws {
        let container = try ModelContainer(for: PlanBlock.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = PlanStore(context: container.mainContext)
        let label = DayContext.logicalDay(offset: 0)
        let s = Calendar.current.date(byAdding: .hour, value: 10, to: label)!
        try store.replacePlanned([ScheduledBlock(title: "写代码", start: s, end: s.addingTimeInterval(3600))], on: label)
        let broken = WriteFailingCalendar()
        let engine = CalendarSyncEngine(planStore: store, calendarStore: broken)
        let vm = ExecutionViewModel(calendarStore: broken,
                                    reschedule: RescheduleService(planStore: store, planner: NaivePlanningEngine()),
                                    planStore: store, reminderStore: FakeReminderStore(),
                                    liveActivity: NoLiveActivity(), persistsRunState: false, projection: engine)
        await vm.loadToday()
        let first = try #require(vm.planned.first)
        await vm.startBlock(first)
        await vm.waitForPreview()
        await vm.completeCurrent()
        await vm.waitForPreview()
        #expect(try store.actualBlocks(on: label).map(\.id) == [first.id], "日历坏了，做成了什么照样记进真相")
        #expect(vm.lastError != nil, "日历失败可见")
    }
}

/// 读正常、写全失败的日历（模拟没权限 / EventKit 出错）。
@MainActor private final class WriteFailingCalendar: CalendarStore {
    func write(_ drafts: [CalendarEventDraft]) async throws { throw CalendarError(message: "fixture write unavailable") }
    func read(kind: PlanCalendarKind) async throws -> [CalendarEventDraft] { [] }
    func clear(kind: PlanCalendarKind) async throws { throw CalendarError(message: "fixture write unavailable") }
    func apply(_ drafts: [CalendarEventDraft], kind: PlanCalendarKind, window: DateInterval) async throws {
        throw CalendarError(message: "fixture write unavailable")
    }
}

// MARK: - ② DataArchive 归档 P4 字段

@MainActor
@Suite struct P41ArchiveTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: DataArchiveStore.schema,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func seed(_ context: ModelContext) throws -> (planned: UUID, actual: UUID) {
        let p = PlanBlock(title: "钉住的", start: at(20, 9), end: at(20, 10))
        p.pinnedUntil = at(21, 4)
        p.syncVersion = 1_760_000_000_123
        p.syncWriter = "phone-abc"
        p.syncSource = PlanWriteReason.calendarReconcile.rawValue
        let a = PlanBlock(title: "会议到点", start: at(20, 11), end: at(20, 12), kind: .actual)
        a.actualState = ActualState.auto.stored
        context.insert(p); context.insert(a)
        try context.save()
        return (p.id, a.id)
    }

    /// 新档案（v3）带上图钉、版本、写者、来源、实际状态；经 JSON 封存 → 隔离空库恢复后一字不差。
    @Test func archiveRoundTripKeepsSyncFields() throws {
        let src = try container()
        let ids = try seed(src.mainContext)
        let archive = try DataArchiveStore.capture(src.mainContext, now: at(20, 13))
        #expect(archive.formatVersion == 3)
        // 走一遍真实的封存 / 解封（Int64 毫秒版本经 JSON 数字不丢精度）
        let sealed = try ArchiveCodec.encoder().encode(SealedDataArchive(archive))
        let reopened = try ArchiveCodec.decoder().decode(SealedDataArchive.self, from: sealed).verified()
        try DataArchiveStore.validateRestoration(reopened)
        let dst = try container()
        try DataArchiveStore.restore(reopened, into: dst.mainContext)
        let rows = try dst.mainContext.fetch(FetchDescriptor<PlanBlock>())
        let p = try #require(rows.first { $0.id == ids.planned })
        #expect(p.pinnedUntil == at(21, 4) && p.syncVersion == 1_760_000_000_123)
        #expect(p.syncWriter == "phone-abc" && p.syncSource == PlanWriteReason.calendarReconcile.rawValue)
        let a = try #require(rows.first { $0.id == ids.actual })
        #expect(ActualState(stored: a.actualState) == .auto, "被动推断的实际恢复后仍是 auto（不画蓝），不会变成「记下的」")
    }

    /// 旧档案（v2，没有 P4 字段）照样能校验和恢复：按当时语义补默认（没钉、版本 0、实际 = 记下的）。
    @Test func versionTwoArchiveUpgradesWithDefaults() throws {
        let src = try container()
        let ids = try seed(src.mainContext)
        var legacy = try DataArchiveStore.capture(src.mainContext, now: at(20, 13))
        legacy.formatVersion = 2
        for i in legacy.records.indices where legacy.records[i].entity == "PlanBlock" {
            for name in DataArchiveStore.syncFields { legacy.records[i].values.removeValue(forKey: name) }
        }
        let original = try ArchiveCodec.encoder().encode(legacy)
        try DataArchiveStore.validateRestoration(legacy)
        #expect(try ArchiveCodec.encoder().encode(legacy) == original, "原档案不被改写")
        let dst = try container()
        try DataArchiveStore.restore(legacy, into: dst.mainContext)
        let p = try #require(dst.mainContext.fetch(FetchDescriptor<PlanBlock>()).first { $0.id == ids.planned })
        #expect(p.pinnedUntil == nil && p.syncVersion == 0 && p.syncWriter == nil && p.syncSource == nil)
        #expect(try DataArchiveStore.upgraded(legacy).formatVersion == 3)
    }

    /// 版本 1 一路升到 3；版本 2 却夹带新字段 = 来路不明 → 拒绝（保留原文件，不猜）。
    @Test func versionChainAndMislabeledArchiveRejected() throws {
        let src = try container()
        _ = try seed(src.mainContext)
        let current = try DataArchiveStore.capture(src.mainContext, now: at(20, 13))
        var v1 = current
        v1.formatVersion = 1
        for i in v1.records.indices {
            for name in DataArchiveStore.retentionFields { v1.records[i].values.removeValue(forKey: name) }
            if v1.records[i].entity == "PlanBlock" {
                for name in DataArchiveStore.syncFields { v1.records[i].values.removeValue(forKey: name) }
            }
        }
        try DataArchiveStore.validateRestoration(v1)
        #expect(try DataArchiveStore.upgraded(v1).formatVersion == 3)
        var mislabeled = current
        mislabeled.formatVersion = 2
        #expect(throws: (any Error).self) { try DataArchiveStore.validateRestoration(mislabeled) }
        var partial = current
        let i = try #require(partial.records.firstIndex { $0.entity == "PlanBlock" })
        partial.records[i].values.removeValue(forKey: "pinnedUntil")
        #expect(throws: (any Error).self) { try DataArchiveStore.validateRestoration(partial) }   // v3 少字段 = 不恢复
    }
}

// MARK: - ③ iPhone 先发现的日历删除 → Mac 转交一次

@MainActor
@Suite struct P41DeletionRelayTests {
    private struct Rig {
        let clock: Clock
        let plan: PlanStore
        let calendar: SimulatedEventKitCalendar
        let engine: CalendarSyncEngine
        let reconcile: ReconcileService
        let relay: CalendarDeletionRelay
        let pool: LongTaskStore
        let container: ModelContainer   // 保活
    }

    /// 一份库 = 「iCloud 已同步」后的样子：iPhone 的对账写入，Mac 的中继读同一份。
    private func rig(now: Date = at(20, 13)) throws -> Rig {
        let container = try ModelContainer(for: PlanBlock.self, LongTask.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let clock = Clock(now)
        let plan = PlanStore(context: container.mainContext, writerID: "phone", now: { clock.now })
        let defaults = try #require(UserDefaults(suiteName: "bc-p41-relay-\(UUID().uuidString)"))
        let calendar = SimulatedEventKitCalendar(now: now)
        let engine = CalendarSyncEngine(planStore: plan, calendarStore: calendar, localWriter: "phone",
                                        fingerprintDefaults: defaults, now: { clock.now })
        let reconcile = ReconcileService(planReader: plan, planWriter: plan, calendarStore: calendar, projection: engine,
                                         defaults: defaults, now: { clock.now }, calendarAuthorized: { true })
        reconcile.deviceLabel = "测试 iPhone"
        let pool = LongTaskStore(context: container.mainContext)
        reconcile.collectTodo = { b, _ in _ = pool.addTodo(title: b.title, family: b.family, deadline: b.deadline); return true }
        let relay = CalendarDeletionRelay(source: plan, defaults: defaults, now: { clock.now })
        return Rig(clock: clock, plan: plan, calendar: calendar, engine: engine, reconcile: reconcile,
                   relay: relay, pool: pool, container: container)
    }

    /// iPhone 端：画两块、你在日历里删掉一块、iPhone 对账照办（iPhone 不接桥接 = onUserDeleted 为空）。
    private func phoneDeletes(_ r: Rig) async throws -> (deleted: ScheduledBlock, kept: ScheduledBlock) {
        let a = ScheduledBlock(title: "读论文", start: at(21, 9), end: at(21, 10))
        let b = ScheduledBlock(title: "跑步", start: at(21, 18), end: at(21, 19))
        let day = DayContext.logicalDay(offset: 1, from: r.clock.now)
        try r.plan.replacePlanned([a, b], on: day)
        try await r.engine.project(label: day)
        let ev = try #require(r.calendar.events(.planned).first { $0.blockID == a.id })
        r.calendar.delete(ev.externalID)
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: day).map(\.id) == [b.id], "iPhone 照办")
        return (a, b)
    }

    @Test func phoneFirstDeletionIsRelayedOnceByMac() async throws {
        let r = try rig()
        let (a, _) = try await phoneDeletes(r)
        var emitted: [[CalendarUserDeletion]] = []
        #expect(r.relay.relay { emitted.append($0); return true } == 1)
        let d = try #require(emitted.first?.first)
        #expect(d.block.id == a.id && d.block.title == "读论文" && d.collectedToTodo && !d.trimmedLive)
        #expect(d.detectedBy == "测试 iPhone")
        let payload = AgentCalendarEvents.deletionPayload(emitted[0])
        let clues = try #require(payload["clues"] as? [String: Any])
        #expect(clues["detectedBy"] as? String == "测试 iPhone" && clues["relayed"] as? Bool == true)
        #expect((payload["deletions"] as? [[String: Any]])?.first?["handled"] as? String == "movedToTodo")
        #expect((payload["deletions"] as? [[String: Any]])?.first?["logicalDay"] as? String == DayContext.dayKey(at(21, 9)))   // 块在 21 日 09:00 → 逻辑日 21 日
        // 再来一轮（又一次 CloudKit 导入）：不重复发
        #expect(r.relay.relay { emitted.append($0); return true } == 0)
        #expect(emitted.count == 1)
    }

    /// Mac 自己先发现、当场发了事件 → 中继记一笔，之后看到同一块的回执不再发。
    @Test func macFirstDeletionIsNotRelayedAgain() async throws {
        let r = try rig()
        var direct: [CalendarUserDeletion] = []
        r.reconcile.onUserDeleted = { [relay = r.relay] ds in direct += ds; relay.markRelayed(ds.map(\.block.id)) }
        _ = try await phoneDeletes(r)
        #expect(direct.count == 1 && direct.first?.detectedBy == nil, "本机发现 = 本机名（payload 里退回 ProposalDevice）")
        var relayed = 0
        r.relay.relay { relayed += $0.count; return true }
        #expect(relayed == 0)
    }

    /// 桥接没接通 / 事件关着（emit 交不出去）→ 不记「已转交」，下次再试；回执留在行上不丢。
    @Test func undeliveredRelayIsRetried() async throws {
        let r = try rig()
        _ = try await phoneDeletes(r)
        #expect(r.relay.relay { _ in false } == 0)
        #expect(r.relay.pending().count == 1)
        #expect(r.relay.relay { _ in true } == 1)
        #expect(r.relay.pending().isEmpty)
    }

    /// 回执只认它那次删除：恢复后又因别的原因删掉 → 旧回执失效，不误报成「你在日历里删了」。
    @Test func staleReceiptAfterRestoreIsIgnored() async throws {
        let r = try rig()
        let (a, _) = try await phoneDeletes(r)
        let row = try #require(r.container.mainContext.fetch(FetchDescriptor<PlanBlock>()).first { $0.id == a.id && $0.kind == .planned })
        try row.acknowledgeRestoration(expected: try #require(row.deletionID))
        try r.container.mainContext.save()
        #expect(r.relay.pending().isEmpty, "恢复了 = 不用再告诉智能体")
        try r.plan.deletePlanned(ids: [a.id], reason: .userEdit)     // 在 App 里删（不是日历）
        #expect(row.isInTrash && row.deletionContext != nil, "旧回执还在行上")
        #expect(r.relay.pending().isEmpty, "但它属于上一次删除，不认")
    }

    /// 很久以前的删除（新装的 Mac / 好几天没开）不一股脑倒给智能体。
    @Test func oldReceiptsBeyondLookbackAreNotRelayed() async throws {
        let r = try rig()
        _ = try await phoneDeletes(r)
        r.clock.now = r.clock.now.addingTimeInterval(CalendarDeletionRelay.lookback + 60)
        #expect(r.relay.pending().isEmpty)
    }

    /// 回执与照片归属等其它 deletionContext 内容互不误认。
    @Test func receiptDecodingIsStrict() {
        #expect(CalendarDeletionReceipt.decode(Data("[]".utf8)) == nil)
        #expect(CalendarDeletionReceipt.decode(nil) == nil)
        let r = CalendarDeletionReceipt(deletionID: UUID(), detectedAt: at(20, 13), detectedBy: "iPhone", collectedToTodo: true)
        #expect(CalendarDeletionReceipt.decode(r.encoded()) == r)
    }
}
