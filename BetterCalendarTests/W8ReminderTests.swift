import Foundation
import Testing
@testable import BetterCalendar

/// SPEC §19.5 D3（W8）：智能体经审批设「提醒」（普通通知，不保证叫醒）和「闹钟」（iPhone 系统闹钟）。
/// 两台「设备」（mac / phone）共用内存中转；排程能力用内存假实现；时钟注入。
@MainActor @Suite struct W8ReminderTests {
    final class Clock { var now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 22))! }

    final class FakeScheduler: ProposalNotificationScheduling {
        var alarmsSupported: Bool
        var reminders: [UUID: (title: String, body: String, fireAt: Date, revision: String)] = [:]
        var alarms: [UUID: Date] = [:]
        var calls: [String] = []
        init(alarms: Bool) { alarmsSupported = alarms }
        func scheduleReminder(id: UUID, title: String, body: String, fireAt: Date) async throws -> String {
            calls.append("reminder"); reminders[id] = (title, body, fireAt, "rev-\(id.uuidString.prefix(4))"); return "rev-\(id.uuidString.prefix(4))"
        }
        func cancelReminder(id: UUID, expectedRevision: String?) async throws {
            calls.append("cancelReminder")
            guard let r = reminders[id] else { throw ProposalExecutionError.conflict("找不到") }
            if let expectedRevision, expectedRevision != r.revision { throw ProposalExecutionError.conflict("被改过") }
            reminders[id] = nil
        }
        func scheduleAlarm(id: UUID, title: String, fireAt: Date) async throws { calls.append("alarm"); alarms[id] = fireAt }
        func cancelAlarm(id: UUID) async throws { calls.append("cancelAlarm"); alarms[id] = nil }
    }

    struct Rig {
        let clock: Clock
        let mac: ProposalCenter, phone: ProposalCenter
        let macScheduler: FakeScheduler, phoneScheduler: FakeScheduler
        let macExecutor: ProposalActionExecutor
    }

    func rig() -> Rig {
        let clock = Clock()
        let devices = [KnownDevice(id: "mac", label: "Jason 的 Mac", platform: "macOS", seenAt: clock.now),
                       KnownDevice(id: "phone", label: "Jason 的 iPhone", platform: "iOS", seenAt: clock.now)]
        let macScheduler = FakeScheduler(alarms: false), phoneScheduler = FakeScheduler(alarms: true)
        let macExecutor = ProposalActionExecutor(items: nil, deviceId: "mac", now: { clock.now })
        macExecutor.notifications = macScheduler; macExecutor.knownDevices = { devices }
        let phoneExecutor = ProposalActionExecutor(items: nil, deviceId: "phone", now: { clock.now })
        phoneExecutor.notifications = phoneScheduler; phoneExecutor.knownDevices = { devices }
        let transport = InMemoryProposalTransport(), ledger = MemoryOperationLedger()
        let mac = ProposalCenter(transport: transport, executor: macExecutor, notifier: SilentProposalNotifier(), ledger: ledger,
                                 deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        let phone = ProposalCenter(transport: transport, executor: phoneExecutor, notifier: SilentProposalNotifier(), ledger: ledger,
                                   deviceId: "phone", deviceLabel: "iPhone", now: { clock.now })
        return Rig(clock: clock, mac: mac, phone: phone, macScheduler: macScheduler, phoneScheduler: phoneScheduler, macExecutor: macExecutor)
    }

    func draft(_ action: ProposalAction, target: String? = nil) -> ProposalDraft {
        ProposalDraft(origin: .agent, originLabel: "BetterCalendar 智能体", targetDeviceId: target, title: "明早 8 点叫你赶大巴",
                      changes: [], reason: "Jason 在对话里说的", action: action, experiment: false)
    }

    var tomorrow8: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8))! }

    @Test func alarmGoesToTheIPhoneShowsDeviceAndTimeAndUndoCancels() async throws {
        let r = rig()
        let p = try #require(await r.mac.submit(draft(.alarm(id: UUID(), title: "赶大巴", fireAt: tomorrow8, deviceId: "phone"))))
        #expect(p.targetDeviceId == "phone")   // 固定在 iPhone 上执行，Mac 批准也一样
        #expect(p.notificationBody.contains("在「Jason 的 iPhone」上 10月19日 08:00 响铃（iPhone 系统闹钟）"))
        await r.mac.decide(p.id, .approve)     // 在 Mac 上点批准
        await r.mac.refresh(); await r.phone.refresh()
        let done = try #require(r.phone.proposals.first { $0.id == p.id })
        #expect(done.state == .applied && r.phoneScheduler.alarms.count == 1 && r.macScheduler.calls.isEmpty)
        #expect(r.mac.undoBlockedReason(done)?.contains("那台设备") == true && r.phone.canUndo(done))
        #expect(done.undoHint == "撤销 = 取消这个闹钟")
        #expect(await r.phone.undo(p.id))
        #expect(r.phoneScheduler.alarms.isEmpty && r.phoneScheduler.calls == ["alarm", "cancelAlarm"])
    }

    @Test func alarmIsRefusedOnMacOrUnknownDeviceAndNeverDowngraded() async throws {
        let r = rig()
        #expect(await r.mac.submit(draft(.alarm(id: UUID(), title: "赶大巴", fireAt: tomorrow8, deviceId: "mac"))) == nil)
        #expect(r.mac.lastError?.contains("闹钟只能设在 iPhone 上") == true)
        #expect(await r.mac.submit(draft(.alarm(id: UUID(), title: "赶大巴", fireAt: tomorrow8, deviceId: "ipad-unknown"))) == nil)
        #expect(r.mac.lastError?.contains("不认识") == true)
        // 防御：即使绕过准备直接在 Mac 上执行，也拒绝且不改成普通通知
        await #expect(throws: ProposalExecutionError.self) {
            _ = try await r.macExecutor.perform(.alarm(id: UUID(), title: "x", fireAt: self.tomorrow8, deviceId: "mac"))
        }
        #expect(r.macScheduler.calls.isEmpty && r.mac.proposals.isEmpty)
    }

    @Test func reminderSaysNotGuaranteedToWakeAndRunsOnChosenDevice() async throws {
        let r = rig()
        let p = try #require(await r.mac.submit(draft(.reminder(id: UUID(), title: "交表", body: "N1 的表", fireAt: tomorrow8, deviceId: "mac"))))
        #expect(p.targetDeviceId == "mac")
        #expect(p.notificationBody.contains("在「Jason 的 Mac」上 10月19日 08:00 弹一条通知"))
        #expect(p.notificationBody.contains("不保证叫醒"))
        await r.phone.decide(p.id, .approve); await r.mac.refresh()
        let done = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(done.state == .applied && r.macScheduler.reminders.count == 1 && r.phoneScheduler.calls.isEmpty)
        #expect(done.resultNote?.contains("不保证叫醒") == true)
        #expect(await r.mac.undo(p.id))
        #expect(r.macScheduler.reminders.isEmpty)
        // 不指定设备 = 批准的那台执行
        let any = try #require(await r.mac.submit(draft(.reminder(id: UUID(), title: "喝水", body: nil, fireAt: tomorrow8, deviceId: nil))))
        #expect(any.targetDeviceId == nil && any.notificationBody.contains("在批准的那台设备上"))
        await r.phone.decide(any.id, .approve); await r.phone.refresh()
        #expect(r.phoneScheduler.reminders.count == 1)
    }

    @Test func reminderAndAlarmTimeRules() async throws {
        let r = rig(), c = r.clock
        func reason(_ action: ProposalAction) async -> String? {
            r.mac.clearError(); _ = await r.mac.submit(draft(action)); return r.mac.lastError
        }
        #expect(await reason(.reminder(id: UUID(), title: "t", body: nil, fireAt: c.now.addingTimeInterval(30), deviceId: nil))?.contains("太近") == true)
        #expect(await reason(.reminder(id: UUID(), title: "t", body: nil, fireAt: c.now.addingTimeInterval(-60), deviceId: nil))?.contains("已经过了") == true)
        #expect(await reason(.reminder(id: UUID(), title: "  ", body: nil, fireAt: tomorrow8, deviceId: nil))?.contains("标题不能为空") == true)
        #expect(await reason(.reminderCancel(id: UUID(), expectedRevision: nil))?.contains("只用于撤销") == true)
        #expect(await reason(.alarmCancel(id: UUID()))?.contains("只用于撤销") == true)
        #expect(r.mac.proposals.isEmpty)
        // 批准时时刻已过 → 执行失败、不补发
        let late = try #require(await r.mac.submit(draft(.reminder(id: UUID(), title: "t", body: nil, fireAt: c.now.addingTimeInterval(120), deviceId: "mac"))))
        c.now = c.now.addingTimeInterval(600)
        await r.phone.decide(late.id, .approve); await r.mac.refresh()
        #expect(r.mac.proposals.first { $0.id == late.id }?.state == .failed && r.macScheduler.calls.isEmpty)
    }

    @Test func bridgeParsesReminderAndAlarm() throws {
        func file(_ action: [String: Any], target: String? = nil) throws -> Data {
            var o: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString, "title": "t", "reason": "r", "action": action]
            if let target { o["targetDevice"] = target }
            return try JSONSerialization.data(withJSONObject: o)
        }
        let alarm = try AgentBridgeIO.draft(from: file(["kind": "alarm", "title": "赶大巴", "fireAt": "2026-10-19T08:00:00-04:00"], target: "phone"))
        guard case let .alarm(_, title, _, device) = alarm.action else { Issue.record("应解析为 alarm"); return }
        #expect(title == "赶大巴" && device == "phone" && !alarm.experiment)
        let reminder = try AgentBridgeIO.draft(from: file(["kind": "reminder", "title": "交表", "body": "N1", "fireAt": "2026-10-19T08:00:00-04:00", "device": "mac"]))
        guard case let .reminder(_, _, body, _, rDevice) = reminder.action else { Issue.record("应解析为 reminder"); return }
        #expect(body == "N1" && rDevice == "mac")
        #expect(throws: (any Error).self) { try AgentBridgeIO.draft(from: file(["kind": "alarm", "title": "x", "fireAt": "2026-10-19T08:00:00-04:00"])) }   // 没指定 iPhone
        #expect(throws: (any Error).self) { try AgentBridgeIO.draft(from: file(["kind": "reminder", "title": "x", "fireAt": "2026-10-19T08:00:00-04:00", "device": "a"], target: "b")) }
        #expect(throws: (any Error).self) { try AgentBridgeIO.draft(from: file(["kind": "reminder", "title": "x", "fireAt": "08:00"])) }
        #expect(throws: (any Error).self) { try AgentBridgeIO.draft(from: file(["kind": "alarmCancel", "alarmId": UUID().uuidString])) }
        #expect(throws: (any Error).self) { try AgentBridgeIO.draft(from: file(["kind": "reminder", "title": "x", "fireAt": "2026-10-19T08:00:00-04:00", "sound": false])) }
    }

    // MARK: 生产适配器：普通提醒走 NativeReminderScheduler（回读核验），Mac 上闹钟拒收

    @MainActor final class FakeSystem: NativeReminderSystem {
        var pendingPlans: [String: NativeReminderPlan] = [:]
        func authorized() async -> Bool { true }
        func pending(_ identifier: String) async throws -> NativeReminderPlan? { pendingPlans[identifier] }
        func submit(_ plan: NativeReminderPlan) async throws { pendingPlans[plan.identifier] = plan }
        func remove(_ identifier: String) async { pendingPlans[identifier] = nil }
    }

    @Test func nativeAdapterSchedulesVerifiesAndCancelsWithRevisionCheck() async throws {
        let clock = Clock(), system = FakeSystem()
        let scheduler = NativeReminderScheduler(system: system, persistence: NativeReminderMemoryPersistence(), now: { clock.now })
        let adapter = NativeProposalNotificationScheduler(reminders: scheduler, alarms: UnsupportedNativeAlarms())
        let id = UUID()
        let revision = try await adapter.scheduleReminder(id: id, title: "交表", body: "", fireAt: tomorrow8)
        #expect(system.pendingPlans.count == 1 && revision.count == 64)
        await #expect(throws: ProposalExecutionError.self) { try await adapter.cancelReminder(id: id, expectedRevision: "stale") }
        #expect(system.pendingPlans.count == 1)
        try await adapter.cancelReminder(id: id, expectedRevision: revision)
        #expect(system.pendingPlans.isEmpty)
        try await adapter.cancelReminder(id: id, expectedRevision: revision)   // 已取消 = 成功（幂等）
        #expect(!adapter.alarmsSupported)
        do { try await adapter.scheduleAlarm(id: UUID(), title: "x", fireAt: tomorrow8); Issue.record("Mac 上应拒收") } catch {
            #expect(error.localizedDescription.contains("只有 iPhone"))
        }
    }

    @Test func knownDevicesMergeDedupesAndForgetsStaleOnes() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let old = KnownDevice(id: "old", label: "旧手机", platform: "iOS", seenAt: now.addingTimeInterval(-90 * 86_400))
        let phone = KnownDevice(id: "phone", label: "iPhone", platform: "iOS", seenAt: now.addingTimeInterval(-3600))
        var mac = KnownDevice(id: "mac", label: "Mac", platform: "macOS", seenAt: now.addingTimeInterval(-7200))
        var list = KnownDevicesCodec.merge([old, phone, mac], adding: mac, now: now)
        #expect(list.map(\.id) == ["phone", "mac"])          // 旧设备淡出、按最近见过排序
        mac.seenAt = now; mac.label = "Jason 的 Mac"
        list = KnownDevicesCodec.merge(list, adding: mac, now: now)
        #expect(list.map(\.id) == ["mac", "phone"] && list[0].label == "Jason 的 Mac")
        let data = try? JSONEncoder().encode(list)
        #expect(KnownDevicesCodec.decode(data) == list && KnownDevicesCodec.decode(Data("x".utf8)).isEmpty)
    }
}
