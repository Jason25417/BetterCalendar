//
//  Hotfix0721SyncWedgeTests.swift
//  BetterCalendarTests
//
//  0.72.1 热修（2026-10-20 晚 190 日用三个 bug 的共同根因）：
//  - 根因：Mac 当天跨端日志（DeviceLog.text）涨过 ~680KB → Core Data 把它外溢成 CKAsset 字段 CD_text_ckAsset，
//    生产 schema 没有这个字段 → 服务器拒收；CloudKit 一批原子导出 → Mac 从 10-19 19:54 起导出全败、镜像不再导入。
//    Mac 真相因此落后 iPhone 数小时：B1（提案基线按 Mac 旧数据补，iPhone 执行时版本对不上）、
//    B3（待办池两端不一致；iPhone 跨天挪走的块被 Mac 当成「日历里删了」收进待办）、
//    B2（过了 10 分钟作者宽限，Mac 先拿旧真相盖回 iPhone 的画面，再把日历上的差异当手改采纳并钉图钉）。
//  - 修法：① 日志单条上限 + 续段（根因）；② 同步卡死要可见（setup 成功不再清横幅、带出逐条原因）；
//    ③ 同步卡死期间，对账 / 投影不拿本机真相去盖、也不把日历差异当手改 / 删除（挂起，恢复后重核）。
//  多设备模拟：内存 SwiftData × 假日历 SimulatedEventKitCalendar × 注入时钟（同 P4OwnershipTests）。
//

import Testing
import Foundation
import SwiftData
import CloudKit
import CoreData
@testable import BetterCalendar

private let cal = Calendar.current
private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
}
@MainActor private final class Clock { var now: Date; init(_ d: Date) { now = d } }

// MARK: - ① 根因：DeviceLog 单条上限

@MainActor
@Suite(.serialized) struct DeviceLogRecordLimitTests {
    private func store() throws -> ModelContainer {
        try ModelContainer(for: DeviceLog.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// 和 10-19 那条一样：一天约 95 万字节的中文日志。
    private func bigLog(bytes: Int) -> String {
        var s = ""; var i = 0
        while s.utf8.count < bytes {
            s += String(format: "%02d:%02d:%02d", (i / 3600) % 24, (i / 60) % 60, i % 60)
            s += " [INFO] PlanStore: 读到 7 计划块 @ Oct 19, 2026 · 第 \(i) 行\n"; i += 1
        }
        return s
    }

    private func parts(_ c: ModelContainer, device: String, day: String) throws -> [DeviceLog] {
        try c.mainContext.fetch(FetchDescriptor<DeviceLog>())
            .filter { $0.deviceID == device && LogSyncService.parsePart($0.dayKey).day == day }
            .sorted { LogSyncService.parsePart($0.dayKey).part < LogSyncService.parsePart($1.dayKey).part }
    }

    @Test func chunksRespectLimitAndRejoinExactly() {
        let text = bigLog(bytes: 500_000) + String(repeating: "长", count: 90_000) + "\n尾巴"   // 含一行 27 万字节的超长行
        let pieces = LogSyncService.chunks(text, limit: LogSyncService.recordTextLimit)
        #expect(pieces.count >= 3)
        #expect(pieces.allSatisfy { $0.utf8.count <= LogSyncService.recordTextLimit })
        #expect(pieces.joined() == text, "不丢字、不加字")
        #expect(LogSyncService.chunks("短", limit: 10) == ["短"])
    }

    /// 10-19 那条 951KB 的 Mac 日志：下次 flush 拆成多段，每段都在上限内，拼回原文；另一台设备的记录不碰。
    @Test func oversizedLegacyRecordIsSplitOnNextFlush() throws {
        let c = try store()
        let me = LogSyncService.deviceID
        let original = bigLog(bytes: 951_219)
        c.mainContext.insert(DeviceLog(deviceID: me, deviceName: "Mac", dayKey: "2026-10-19", text: original))
        let phoneText = bigLog(bytes: 250_000)
        c.mainContext.insert(DeviceLog(deviceID: "iphone", deviceName: "iPhone", dayKey: "2026-10-19", text: phoneText))
        try c.mainContext.save()

        let sync = LogSyncService(context: c.mainContext)
        sync.dumpEnabled = false
        sync.flush(now: at(20, 12))

        let mine = try parts(c, device: me, day: "2026-10-19")
        #expect(mine.count >= 5)
        #expect(mine.allSatisfy { $0.text.utf8.count <= LogSyncService.recordTextLimit },
                "任何一条超过上限都会外溢成 CD_text_ckAsset、被生产 schema 拒收、整台设备同步卡死")
        #expect(mine.map(\.text).joined() == original)
        #expect(mine.first?.dayKey == "2026-10-19" && mine.last?.dayKey.hasPrefix("2026-10-19-part") == true)
        #expect(try parts(c, device: "iphone", day: "2026-10-19").map(\.text) == [phoneText], "只拆本设备自己写的")
    }

    /// 今天写满就续下一段；续段跟着它那天按 7 天清理。
    @Test func appendRollsOverAndPartsArePrunedWithTheirDay() throws {
        let c = try store()
        let me = LogSyncService.deviceID
        let nearlyFull = bigLog(bytes: LogSyncService.recordTextLimit - 50)
        c.mainContext.insert(DeviceLog(deviceID: me, deviceName: "Mac", dayKey: "2026-10-20", text: nearlyFull))
        c.mainContext.insert(DeviceLog(deviceID: me, deviceName: "Mac", dayKey: "2026-10-01-part2", text: "旧"))
        try c.mainContext.save()

        let sync = LogSyncService(context: c.mainContext)
        sync.dumpEnabled = false
        sync.start()
        for i in 0..<20 { DevLog.shared.info("测试", "续段第 \(i) 条") }
        sync.flush(now: at(20, 12))
        DevLog.shared.onAppend = nil

        let today = try parts(c, device: me, day: "2026-10-20")
        #expect(today.count == 2)
        #expect(today[0].text == nearlyFull || today[0].text.utf8.count <= LogSyncService.recordTextLimit)
        #expect(today.allSatisfy { $0.text.utf8.count <= LogSyncService.recordTextLimit })
        #expect(today.map(\.text).joined().contains("续段第 19 条"))
        #expect(try parts(c, device: me, day: "2026-10-01").isEmpty, "续段跟着它那天清")
    }
}

// MARK: - ② 同步卡死要可见

@Suite struct SyncWedgeVisibilityTests {
    private func partial(_ reason: String) -> NSError {
        let bad = NSError(domain: CKErrorDomain, code: CKError.Code.invalidArguments.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: reason])
        let batch = NSError(domain: CKErrorDomain, code: CKError.Code.batchRequestFailed.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "Batch Request Failed"])
        return NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "Failed to modify some records",
            CKPartialErrorsByItemIDKey: ["log": bad, "block": batch] as [AnyHashable: Error],
        ])
    }

    @Test func serverRejectedExportWedgesUntilAnExportSucceeds() {
        var e = DataSyncTransportEvidence()
        e.opened(cloud: true)
        e.finished(.export, at: Date(timeIntervalSince1970: 100), succeeded: true, error: nil)
        #expect(!e.isWedged)
        e.finished(.export, at: Date(timeIntervalSince1970: 200), succeeded: false, error: partial("x"))
        #expect(e.isWedged)
        e.finished(.setup, at: Date(timeIntervalSince1970: 300), succeeded: true, error: nil)
        #expect(e.isWedged, "每轮重试前 setup 都会成功——那不是恢复（10-19 起的横幅就是被它清掉的）")
        e.finished(.export, at: Date(timeIntervalSince1970: 400), succeeded: true, error: nil)
        #expect(!e.isWedged)
        e.finished(.export, at: Date(timeIntervalSince1970: 500), succeeded: false,
                   error: NSError(domain: NSCocoaErrorDomain, code: 134419))
        #expect(!e.isWedged, "系统延后之类会自己好，不算卡死")
    }

    @Test func partialFailureNamesTheRealServerReason() {
        let reason = "Cannot create or modify field 'CD_text_ckAsset' in record 'CD_DeviceLog' in production schema"
        #expect(DataSyncMonitor.firstPartialReason(partial(reason)) == reason)
        #expect(DataSyncMonitor.describe(type: .export, error: partial(reason)).contains("CD_text_ckAsset"))
        #expect(DataSyncMonitor.firstPartialReason(NSError(domain: NSURLErrorDomain, code: -1009)) == nil)
    }
}

// MARK: - ③ 卡死期间：不盖另一台设备的画面、不把差异当手改 / 删除

@MainActor
@Suite struct SyncWedgeReconcileTests {
    private struct Rig {
        let clock: Clock
        let plan: PlanStore
        let calendar: SimulatedEventKitCalendar
        let projection: ProjectionService
        let reconcile: ReconcileService
        let container: ModelContainer
        let wedged: Box
        @MainActor var today: Date { DayContext.logicalStartOfDay(clock.now) }
    }
    @MainActor final class Box { var value = false }

    /// Mac（本机）：今天 13:00；Mac 的真相停在 iPhone 改动之前。
    private func mac(now: Date = at(20, 13)) throws -> Rig {
        let container = try ModelContainer(for: PlanBlock.self, LongTask.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let clock = Clock(now)
        let plan = PlanStore(context: container.mainContext, writerID: "mac", now: { clock.now })
        let defaults = try #require(UserDefaults(suiteName: "bc-hotfix0721-\(UUID().uuidString)"))
        let calendar = SimulatedEventKitCalendar(now: now)
        let wedged = Box()
        let projection = ProjectionService(planStore: plan, calendarStore: calendar, localWriter: "mac",
                                           fingerprintDefaults: defaults, now: { clock.now })
        projection.transportTrusted = { !wedged.value }
        let reconcile = ReconcileService(planReader: plan, planWriter: plan, calendarStore: calendar, projection: projection,
                                         defaults: defaults, now: { clock.now }, calendarAuthorized: { true })
        return Rig(clock: clock, plan: plan, calendar: calendar, projection: projection, reconcile: reconcile,
                   container: container, wedged: wedged)
    }

    private func green(_ r: Rig, _ id: UUID) -> [SimulatedEventKitCalendar.Event] {
        r.calendar.events(.planned).filter { $0.blockID == id }
    }

    /// iPhone 把块挪走并按它的新版本重画（日历经 iCloud 先到 Mac，数据卡在 CloudKit 路上）。
    private func phonePaints(_ r: Rig, _ b: ScheduledBlock, to s: Date, _ e: Date, version: Int64, on day: Date) async throws {
        var d = CalendarEventDraft(title: b.title, start: s, end: e, kind: .planned, blockID: b.id)
        d.stampV2(version: version)
        let others = r.calendar.events(.planned).filter { $0.blockID != b.id }.map {
            var o = CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .planned, blockID: $0.blockID)
            o.stampVersion = $0.stampVersion; o.stampHash = $0.stampHash
            return o
        }
        try await r.calendar.apply(others + [d], kind: .planned, window: DayContext.logicalWindow(forLabel: day))
    }

    /// B2 前半（10-20 19:52）：iPhone 19:18 的新画面，Mac 过了 10 分钟宽限就拿旧真相盖回去。卡死时不盖。
    @Test func wedgedDeviceDoesNotPaintStaleTruthOverNewerStamp() async throws {
        let r = try mac()
        let b = ScheduledBlock(title: "5635 考前复习", start: at(20, 20, 50), end: at(20, 21, 20))
        try r.plan.replacePlanned([b], on: r.today)
        try await r.projection.project(label: r.today)
        let v = try #require(try r.plan.plannedBlocks(on: r.today).first).syncVersion
        try await phonePaints(r, b, to: at(20, 22, 40), at(20, 23, 10), version: v + 60_000, on: r.today)
        r.wedged.value = true
        r.clock.now = r.clock.now.addingTimeInterval(ProjectionService.authorGrace + 30 * 60)   // 34 分钟后
        await r.reconcile.reconcileWindow()
        try await r.projection.project(label: r.today)
        #expect(green(r, b.id).first?.start == at(20, 22, 40), "同步卡死：不拿可能落后的真相去盖另一台设备的新画面")
        #expect(try r.plan.plannedBlocks(on: r.today).first?.start == at(20, 20, 50), "也不当成你的改动")
        // 通道正常时保持 Q8 原规则：过了宽限真相赢
        r.wedged.value = false
        try await r.projection.project(label: r.today)
        #expect(green(r, b.id).first?.start == at(20, 20, 50))
    }

    /// B2 后半（10-20 20:15:51）：日历上的差异被 Mac 当成你在日历里手改 → 采纳并钉图钉。卡死时挂起、不钉。
    @Test func wedgedDeviceDoesNotAdoptOrPinCalendarDifference() async throws {
        let r = try mac()
        let b = ScheduledBlock(title: "锻炼", start: at(20, 17, 15), end: at(20, 18, 15))
        try r.plan.replacePlanned([b], on: r.today)
        try await r.projection.project(label: r.today)
        // 日历上这块出现了 Mac 真相以外的时间（与 Mac 自己的章同版本 = 照旧判定就是「你手改」）
        r.calendar.edit(try #require(green(r, b.id).first).externalID, start: at(20, 20, 35), end: at(20, 21, 15))
        r.wedged.value = true
        await r.reconcile.reconcileWindow()
        let row = try #require(try r.plan.plannedBlocks(on: r.today).first)
        #expect(row.start == at(20, 17, 15) && !row.isPinned(at: r.clock.now), "卡死期间不采纳、不钉图钉")
        #expect(green(r, b.id).first?.start == at(20, 20, 35), "画面原样保留，等核对")
        // 恢复后照常：真是你改的就采纳（并钉）
        r.wedged.value = false
        await r.reconcile.reconcileWindow()
        let after = try #require(try r.plan.plannedBlocks(on: r.today).first)
        #expect(after.start == at(20, 20, 35) && after.isPinned(at: r.clock.now))
    }

    /// B3（10-19 23:50:34）：iPhone 把「5529 第 4–5 题」从今晚挪到明早，日历上今晚那份先消失 → Mac 判成你删了、收进待办。
    /// 卡死时不删、不收待办。
    @Test func wedgedDeviceDoesNotTreatVanishedEventAsUserDeletion() async throws {
        let r = try mac(now: at(19, 23, 50))
        let pool = LongTaskStore(context: r.container.mainContext)
        r.reconcile.collectTodo = { b, _ in _ = pool.addTodo(title: b.title, family: b.family, deadline: b.deadline); return true }
        var reported: [CalendarUserDeletion] = []
        r.reconcile.onUserDeleted = { reported += $0 }
        let tonight = DayContext.logicalStartOfDay(r.clock.now)
        let b = ScheduledBlock(title: "5529 题目（第 4–5 题）", start: at(19, 19, 5), end: at(19, 20, 5))
        let other = ScheduledBlock(title: "锻炼 1 小时", start: at(19, 20, 15), end: at(19, 21, 15))
        try r.plan.replacePlanned([b, other], on: tonight)
        try await r.projection.project(label: tonight)
        r.calendar.delete(try #require(green(r, b.id).first).externalID)   // iPhone 投影先删了今晚那份
        r.wedged.value = true
        await r.reconcile.reconcileWindow()
        #expect(try r.plan.plannedBlocks(on: tonight).map(\.id).contains(b.id), "不当成你删的")
        #expect(pool.todoItems().isEmpty && reported.isEmpty, "不收进待办、不报 calendar_user_deleted")
    }
}
