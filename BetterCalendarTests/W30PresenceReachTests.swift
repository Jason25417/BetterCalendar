//
//  W30PresenceReachTests.swift
//  BetterCalendarTests
//
//  W30（原则 11「人是单位，设备是触点」）：在场设备 + 一处响 + 闹钟默认 iPhone + 草稿接力。
//  三台设备（Mac / iPhone / iPad）的模拟：共用一个假「iCloud KV」（写权租约那一个键 + 每台的板 + 草稿键），
//  各自一个假通知中心、同一个注入时钟。纪律：不碰真通知中心 / 真 KV / 真 UserDefaults.standard；时间全部从固定时刻派生。
//

import Testing
import Foundation
import UserNotifications
@testable import BetterCalendar

// MARK: - 假实现

/// 三台设备共用的「云」。
private final class FakeCloud: @unchecked Sendable {
    var values: [String: Data] = [:]
    /// 各台设备的租约存储：一台写了，其余立刻收到推送（= 在线、KV 正常投递）。
    var leaseStores: [AnyObject] = []
}

/// 某台设备看到的 KV（直接读写共用的云 = 「已同步」；投递延迟靠测试里先后调用来模拟）。
private final class FakeSharedKV: SharedKVStoring, @unchecked Sendable {
    let cloud: FakeCloud
    init(_ cloud: FakeCloud) { self.cloud = cloud }
    func data(forKey key: String) -> Data? { cloud.values[key] }
    @discardableResult func set(_ data: Data?, forKey key: String) -> Bool { cloud.values[key] = data; return true }
    func keys(withPrefix prefix: String) -> [String] { cloud.values.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    func addChangeObserver(_ block: @escaping @MainActor ([String]?) -> Void) {}
}

@MainActor private final class FakeLeaseKV: WriteLeaseStoring {
    let cloud: FakeCloud
    var onExternalChange: (() -> Void)?
    init(_ cloud: FakeCloud) { self.cloud = cloud; cloud.leaseStores.append(self) }
    func load() -> Data? { cloud.values[ICloudKVWriteLeaseStore.key] }
    @discardableResult func save(_ data: Data) -> Bool {
        cloud.values[ICloudKVWriteLeaseStore.key] = data
        for case let other as FakeLeaseKV in cloud.leaseStores where other !== self { other.onExternalChange?() }
        return true
    }
}

@MainActor private final class FakeCenter: ReachNotificationCentering {
    var pending: [UNNotificationRequest] = []
    var delivered: [UNNotificationRequest] = []
    /// 每次「出声送达」的记录（trigger=nil 的立即通知 + 到点触发的）。
    var rang: [String] = []
    func add(_ request: UNNotificationRequest) async throws {
        pending.removeAll { $0.identifier == request.identifier }
        if request.trigger == nil {
            delivered.removeAll { $0.identifier == request.identifier }
            delivered.append(request)
            if request.content.interruptionLevel != .passive { rang.append(request.identifier) }
        } else {
            pending.append(request)
        }
    }
    func pendingRequests() async -> [UNNotificationRequest] { pending }
    func deliveredRequests() async -> [UNNotificationRequest] { delivered }
    func removePending(_ ids: [String]) { pending.removeAll { ids.contains($0.identifier) } }
    func removeDelivered(_ ids: [String]) { delivered.removeAll { ids.contains($0.identifier) } }
    func isLoud(_ id: String) -> Bool? {
        (pending + delivered).first { $0.identifier == id }.map { $0.content.interruptionLevel != .passive }
    }
}

@MainActor private final class Clock { var now: Date; init(_ d: Date) { now = d } }
private final class SendableClock: @unchecked Sendable { var now: Date; init(_ d: Date) { now = d } }
private final class SendableFlag: @unchecked Sendable { var on: Bool; init(_ v: Bool) { on = v } }

@MainActor
@Suite struct W30PresenceReachTests {
    private static let base: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 20; c.hour = 0
        return Calendar.current.date(from: c)!
    }()
    private func at(_ h: Int, _ m: Int = 0) -> Date { Self.base.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }

    private func devices(seenAt: Date) -> [KnownDevice] {
        [KnownDevice(id: "mac", label: "Mac", platform: "macOS", seenAt: seenAt, kind: "mac"),
         KnownDevice(id: "iphone", label: "iPhone", platform: "iOS", seenAt: seenAt, kind: "iphone"),
         KnownDevice(id: "ipad", label: "iPad", platform: "iOS", seenAt: seenAt, kind: "ipad")]
    }

    private struct Device {
        let id: String
        let lease: TimelineWriteLease
        let presence: DevicePresence
        let reach: ReachOutlet
        let center: FakeCenter
    }

    @MainActor private final class World {
        let cloud = FakeCloud()
        let clock: Clock
        var enabled = true
        init(_ now: Date) { clock = Clock(now) }
    }

    private func device(_ id: String, kind: String, world w: World, releasesOnBackground: Bool) -> Device {
        let lease = TimelineWriteLease(store: FakeLeaseKV(w.cloud), deviceID: id, deviceLabel: kindLabel(kind), deviceKind: kind,
                                       releasesOnBackground: releasesOnBackground, isEnabled: { true },
                                       now: { w.clock.now }, log: { _, _ in })
        let list = devices(seenAt: at(0))
        let presence = DevicePresence(deviceID: id, deviceLabel: kindLabel(kind), devices: { list },
                                      leaseEnabled: { true }, now: { w.clock.now })
        presence.attach(lease)
        let center = FakeCenter()
        let reach = ReachOutlet(deviceID: id, deviceLabel: kindLabel(kind), presence: { presence.predicted(at: $0) },
                                kv: FakeSharedKV(w.cloud), center: center, isEnabled: { w.enabled },
                                now: { w.clock.now }, logDefaults: nil, reactsToRemoteChanges: false)
        return Device(id: id, lease: lease, presence: presence, reach: reach, center: center)
    }
    private func kindLabel(_ k: String) -> String { ["mac": "Mac", "iphone": "iPhone", "ipad": "iPad"][k]! }

    private func three(_ w: World) -> (mac: Device, phone: Device, pad: Device) {
        (device("mac", kind: "mac", world: w, releasesOnBackground: false),
         device("iphone", kind: "iphone", world: w, releasesOnBackground: true),
         device("ipad", kind: "ipad", world: w, releasesOnBackground: true))
    }

    private func morning(at fire: Date) -> UNNotificationRequest {
        let c = UNMutableNotificationContent()
        c.title = "开始今天"; c.body = "今天 3 件"
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        return UNNotificationRequest(identifier: "bc.reminder.morning", content: c,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
    }
    private func proposalRequest(_ id: UUID) -> UNNotificationRequest {
        let c = UNMutableNotificationContent()
        c.title = "挪一下"; c.sound = .default
        return UNNotificationRequest(identifier: "bc.proposal." + id.uuidString, content: c, trigger: nil)
    }
    private func loudCount(_ ds: [Device], _ id: String) -> Int { ds.filter { $0.center.isLoud(id) == true }.count }

    // MARK: 在场设备

    @Test func presenceOrderTimerThenRecentUseThenLabeledIPhoneDefault() {
        let list = devices(seenAt: at(0))
        func lease(_ holder: String, _ kind: String, _ reason: WriteLeaseReason, renewed: Date, expires: Date, active: Date?) -> WriteLease {
            WriteLease(holder: holder, holderLabel: kindLabel(kind), reason: reason, renewedAt: renewed, expiresAt: expires,
                       seq: 1, releasedAt: nil, activeAt: active, holderKind: kind, heldSince: renewed)
        }
        // 1. 正在计时的 iPad（即使 Mac 不知道它最近有没有被碰过）
        let timer = lease("ipad", "ipad", .timer, renewed: at(9), expires: at(10), active: nil)
        let p1 = PresencePolicy.resolve(lease: timer, observedAt: at(9), devices: list, leaseEnabled: true, at: at(9, 5), now: at(9, 5))
        #expect(p1.deviceID == "ipad" && p1.basis == .timer)
        // 计时预计结束之后的时刻 → 不再算它
        let p1b = PresencePolicy.resolve(lease: timer, observedAt: at(9), devices: list, leaseEnabled: true, at: at(11), now: at(9, 5))
        #expect(p1b.deviceID == "iphone" && p1b.basis == .carriedDefault)
        // 2. Mac 2 分钟前有键鼠输入
        let mac = lease("mac", "mac", .foreground, renewed: at(9), expires: at(9, 6), active: at(9, 1))
        let p2 = PresencePolicy.resolve(lease: mac, observedAt: at(9), devices: list, leaseEnabled: true, at: at(9, 3), now: at(9, 3))
        #expect(p2.deviceID == "mac" && p2.basis == .recentUse && p2.why.contains("键鼠"))
        // 3. Mac 持有着租约但 20 分钟没被碰 → 写明了的默认：随身的 iPhone，原因写清
        let idle = lease("mac", "mac", .foreground, renewed: at(9, 20), expires: at(9, 26), active: at(9))
        let p3 = PresencePolicy.resolve(lease: idle, observedAt: at(9, 20), devices: list, leaseEnabled: true, at: at(9, 21), now: at(9, 21))
        #expect(p3.deviceID == "iphone" && p3.basis == .carriedDefault && p3.why.contains("算随身的 iPhone"))
        // 没登记过 iPhone → 每台都响（宁可多响）
        let p4 = PresencePolicy.resolve(lease: nil, observedAt: nil, devices: list.filter { $0.id != "iphone" }, leaseEnabled: true,
                                        at: at(9), now: at(9))
        #expect(p4.deviceID == nil && p4.basis == .everyDevice && p4.includes("mac") && p4.includes("ipad"))
        // 租约总闸关着 → 判断不了，写明原因
        let p5 = PresencePolicy.resolve(lease: mac, observedAt: at(9), devices: list, leaseEnabled: false, at: at(9, 3), now: at(9, 3))
        #expect(p5.deviceID == "iphone" && p5.why.contains("总闸"))
    }

    @Test func userActivityClaimsPresenceButNeverStealsATimer() {
        let w = World(at(9))
        let (mac, phone, _) = three(w)
        phone.lease.setForeground(true)                       // iPhone 回前台：在场
        #expect(phone.presence.current().deviceID == "iphone")
        // Mac 一直在用（没有「刚开始用」的变化）：不抢刚回前台的 iPhone
        w.clock.now = at(9, 1)
        mac.lease.noteUserActivity(active: true, transition: false)
        #expect(mac.presence.current().deviceID == "iphone")
        // Mac 从闲着变成在用（回到 Mac 前）→ 接过来
        w.clock.now = at(9, 2)
        mac.lease.noteUserActivity(active: true, transition: true)
        #expect(phone.presence.current().deviceID == "mac" && phone.presence.current().basis == .recentUse)
        // iPhone 开始计时 → 计时优先；Mac 再怎么用也不抢计时
        phone.lease.timing = { (true, at(10)) }
        w.clock.now = at(9, 3)
        #expect(phone.lease.mayWriteAutomatically())
        w.clock.now = at(9, 4)
        mac.lease.noteUserActivity(active: true, transition: true)
        #expect(mac.presence.current().deviceID == "iphone" && mac.presence.current().basis == .timer)
        // 计时结束、iPhone 回后台交出 → Mac 下一次在用就拿回；Mac 锁屏 → 交出 → 判断不了 → 随身 iPhone（写明）
        phone.lease.timing = { (false, nil) }
        phone.lease.setForeground(false)
        w.clock.now = at(9, 5)
        mac.lease.noteUserActivity(active: true, transition: false)
        #expect(mac.presence.current().deviceID == "mac")
        mac.lease.noteUserActivity(active: false, transition: true)
        let p = phone.presence.current()
        #expect(p.deviceID == "iphone" && p.basis == .carriedDefault && p.why.contains("不在用"))
    }

    @Test func activeAtIsRefreshedAboutEveryFourMinutesNotEveryTick() {
        let w = World(at(9))
        let mac = device("mac", kind: "mac", world: w, releasesOnBackground: false)
        mac.lease.noteUserActivity(active: true, transition: true)
        var seqs: [Int64] = []
        for minute in 1...12 {
            w.clock.now = at(9, minute)
            mac.lease.noteUserActivity(active: true, transition: false)
            seqs.append(mac.lease.current?.seq ?? 0)
        }
        #expect(Set(seqs).count <= 4, "12 分钟的持续在用最多写几次（约 4 分钟一次），不是每分钟一次")
        #expect(mac.lease.current.flatMap(\.activeAt).map { w.clock.now.timeIntervalSince($0) <= 4 * 60 } == true)
    }

    @Test func probeStepIsPureAndLockCountsAsInactive() {
        #expect(UserActivityProbe.step(wasActive: false, reading: .init(idleSeconds: 5, locked: false)) == (true, true))
        #expect(UserActivityProbe.step(wasActive: true, reading: .init(idleSeconds: 30, locked: false)) == (true, false))
        #expect(UserActivityProbe.step(wasActive: true, reading: .init(idleSeconds: 5, locked: true)) == (false, true))
        #expect(UserActivityProbe.step(wasActive: true, reading: .init(idleSeconds: 600, locked: false)) == (false, true))
    }

    // MARK: 一处响

    @Test func morningNotificationRingsOnlyOnTheCarriedIPhoneWhenPresenceUnknown() async {
        let w = World(at(22))   // 前一晚排明早 8:00 的早通知；三台都排一份
        let (mac, phone, pad) = three(w)
        let fire = at(32)       // 明早 8:00
        let id = "morning:2026-10-21"
        // Mac 先排（iPhone 还没排上）→ 先照常响，防止谁都不响
        try? await mac.center.add(mac.reach.route(morning(at: fire), kind: .morning, reachID: id, fireAt: fire))
        #expect(mac.center.isLoud("bc.reminder.morning") == true)
        try? await phone.center.add(phone.reach.route(morning(at: fire), kind: .morning, reachID: id, fireAt: fire))
        try? await pad.center.add(pad.reach.route(morning(at: fire), kind: .morning, reachID: id, fireAt: fire))
        #expect(phone.center.isLoud("bc.reminder.morning") == true)
        #expect(pad.center.isLoud("bc.reminder.morning") == false, "iPad 看到 iPhone 的回执 → 安静")
        // Mac 收到 iPhone 的回执（KV 推送）→ 改派成安静
        await mac.reach.reevaluate()
        #expect(loudCount([mac, phone, pad], "bc.reminder.morning") == 1)
        #expect(phone.center.isLoud("bc.reminder.morning") == true)
        #expect(mac.reach.entries.last?.note.contains("算随身的 iPhone") == true, "原因写明：判断不了 → 随身的 iPhone")
        #expect(mac.reach.ringingDevices(id) == ["iPhone"])
    }

    @Test func morningMovesToTheMacWhenYouAreAtTheMacNearFireTime() async {
        let w = World(at(22))
        let (mac, phone, pad) = three(w)
        let fire = at(32), id = "morning:2026-10-21"
        for d in [phone, mac, pad] { try? await d.center.add(d.reach.route(morning(at: fire), kind: .morning, reachID: id, fireAt: fire)) }
        await mac.reach.reevaluate()
        #expect(loudCount([mac, phone, pad], "bc.reminder.morning") == 1 && phone.center.isLoud("bc.reminder.morning") == true)
        // 7:50 你回到 Mac 前（键鼠输入）→ 在场 = Mac，窗口覆盖 8:00
        w.clock.now = at(31, 50)
        mac.lease.noteUserActivity(active: true, transition: true)
        await mac.reach.reevaluate()        // 在场变化 → Mac 改成响（写回执）
        await phone.reach.reevaluate()      // iPhone 收到推送 → 改安静
        await pad.reach.reevaluate()
        #expect(mac.center.isLoud("bc.reminder.morning") == true)
        #expect(phone.center.isLoud("bc.reminder.morning") == false)
        #expect(loudCount([mac, phone, pad], "bc.reminder.morning") == 1)
        #expect(phone.reach.entries.last?.note.hasPrefix("改派") == true)
        // 7:55 你锁了 Mac 走开 → 交出在场 → iPhone 又成了响的那台（被挂起的 iPhone 收不到这条变化 = 已知局限，见报告）
        w.clock.now = at(31, 55)
        mac.lease.noteUserActivity(active: false, transition: true)
        await phone.reach.reevaluate()
        await mac.reach.reevaluate()
        #expect(phone.center.isLoud("bc.reminder.morning") == true)
        #expect(mac.center.isLoud("bc.reminder.morning") == false)
        #expect(loudCount([mac, phone, pad], "bc.reminder.morning") == 1)
    }

    @Test func immediateProposalRingsOnPresenceDeviceAndEscalatesWhenItNeverArrives() async {
        let w = World(at(14))
        let (mac, phone, pad) = three(w)
        mac.lease.noteUserActivity(active: true, transition: true)   // 你在 Mac 前
        let p = UUID(), rid = "proposal:\(p.uuidString)", ident = "bc.proposal." + p.uuidString
        try? await phone.center.add(phone.reach.route(proposalRequest(p), kind: .proposal, reachID: rid))
        try? await mac.center.add(mac.reach.route(proposalRequest(p), kind: .proposal, reachID: rid))
        #expect(phone.center.isLoud(ident) == false && mac.center.isLoud(ident) == true)
        #expect(phone.center.rang.isEmpty && mac.center.rang == [ident])
        // 3 分钟后 iPhone 查升级：Mac 已确认 → 保持安静
        w.clock.now = at(14, 4)
        await phone.reach.runEscalations()
        #expect(phone.center.isLoud(ident) == false && phone.center.rang.isEmpty)
        // 另一份提案：Mac 没收到（比如推送丢了）→ iPad 3 分钟后改在本机响
        let q = UUID(), qid = "proposal:\(q.uuidString)", qident = "bc.proposal." + q.uuidString
        mac.lease.noteUserActivity(active: true, transition: false)
        try? await pad.center.add(pad.reach.route(proposalRequest(q), kind: .proposal, reachID: qid))
        #expect(pad.center.isLoud(qident) == false)
        w.clock.now = at(14, 8)
        await pad.reach.runEscalations()
        #expect(pad.center.isLoud(qident) == true && pad.center.rang == [qident])
        #expect(pad.reach.entries.last?.note.hasPrefix("升级") == true)
    }

    @Test func handledOnOneDeviceDisappearsEverywhereExceptProposalsKeepTheirOwnLifecycle() async {
        let w = World(at(7, 50))
        let (mac, phone, pad) = three(w)
        let chat = UUID(), cid = "agentChat:\(chat.uuidString)"
        func chatReq() -> UNNotificationRequest {
            let c = UNMutableNotificationContent(); c.body = "要我挪一下吗"
            return UNNotificationRequest(identifier: "bc.agentchat." + chat.uuidString, content: c, trigger: nil)
        }
        for d in [mac, phone, pad] { try? await d.center.add(d.reach.route(chatReq(), kind: .agentChat, reachID: cid)) }
        let p = UUID(), pid = "proposal:\(p.uuidString)"
        for d in [mac, phone, pad] { try? await d.center.add(d.reach.route(proposalRequest(p), kind: .proposal, reachID: pid)) }
        // 你在 iPhone 上读了对话（也点开了提案）
        await phone.reach.markHandled([cid, pid])
        await mac.reach.reevaluate(); await pad.reach.reevaluate()
        #expect(mac.center.delivered.map(\.identifier) == ["bc.proposal." + p.uuidString], "对话那条收起；提案由提案中心自己收起")
        #expect(pad.center.delivered.count == 1)
    }

    @Test func switchOffMeansEveryDeviceRingsAsBefore() async {
        let w = World(at(22)); w.enabled = false
        let (mac, phone, pad) = three(w)
        let fire = at(32)
        for d in [mac, phone, pad] {
            try? await d.center.add(d.reach.route(morning(at: fire), kind: .morning, reachID: "morning:x", fireAt: fire))
        }
        for d in [mac, phone, pad] { await d.reach.reevaluate() }
        #expect(loudCount([mac, phone, pad], "bc.reminder.morning") == 3)
        await phone.reach.markHandled(["morning:x"])
        await mac.reach.reevaluate()
        #expect(mac.center.pending.count == 1, "开关关着：不跨设备收起")
        #expect(mac.reach.entries.last?.note.contains("没打开") == true)
    }

    @Test func singleCopyKindsAlwaysRingAndAlarmMirrorsAreAlwaysQuiet() {
        let p = Presence(deviceID: "iphone", deviceLabel: "iPhone", kind: .iphone, basis: .carriedDefault, why: "x")
        #expect(ReachPolicy.decide(kind: .ddlNudge, me: "mac", presence: p, enabled: true, presenceHasCopy: false).loud)
        #expect(!ReachPolicy.decide(kind: .alarmMirror, me: "mac", presence: p, enabled: true, presenceHasCopy: false).loud)
        let everyone = Presence(deviceID: nil, deviceLabel: "每台设备", kind: nil, basis: .everyDevice, why: "y")
        #expect(ReachPolicy.decide(kind: .agentMessage, me: "mac", presence: everyone, enabled: true, presenceHasCopy: false).loud)
        // 静的那份：不亮屏不出声
        let c = UNMutableNotificationContent(); c.sound = .default
        ReachOutlet.apply(loud: false, loudSound: true, to: c)
        #expect(c.interruptionLevel == .passive && c.sound == nil)
        ReachOutlet.apply(loud: true, loudSound: true, to: c)
        #expect(c.interruptionLevel == .active && c.sound != nil)
    }

    // MARK: 闹钟

    @Test func alarmDefaultsToTheCarriedIPhoneAndOtherDevicesGetAQuietMirror() async throws {
        let list = devices(seenAt: at(0)) + [KnownDevice(id: "old-iphone", label: "旧 iPhone", platform: "iOS", seenAt: at(-48), kind: "iphone")]
        #expect(try ProposalActionExecutor.carriedIPhone(list).id == "iphone", "最近见过的那台 iPhone")
        #expect(throws: ProposalExecutionError.self) { try ProposalActionExecutor.carriedIPhone(list.filter { $0.kind != "iphone" }) }
        // 准备阶段：没写设备 → 换成 iPhone 的 id，审批卡写明默认
        let executor = ProposalActionExecutor(items: nil, deviceId: "mac", now: { self.at(22) })
        executor.knownDevices = { list }
        let prepared = try await executor.prepare(.alarm(id: UUID(), title: "赶大巴", fireAt: at(31), deviceId: ProposalAction.carriedDeviceDefault))
        guard case let .alarm(_, _, _, target) = prepared.action else { Issue.record("不是闹钟"); return }
        #expect(target == "iphone" && prepared.requiredDeviceId == "iphone")
        #expect(prepared.changes?.contains { $0.field.contains("默认设在随身的 iPhone") } == true)
        // 明确指定 iPad：照旧
        let pad = try await executor.prepare(.alarm(id: UUID(), title: "午睡", fireAt: at(31), deviceId: "ipad"))
        #expect(pad.requiredDeviceId == "ipad")

        // 镜像：iPhone 上已执行的闹钟 → Mac 到点安静放一份；撤销后收起
        let w = World(at(22))
        let mac = device("mac", kind: "mac", world: w, releasesOnBackground: false)
        let mirror = AlarmMirrorSync(deviceID: "mac", center: mac.center, reach: mac.reach, devices: { list },
                                     isEnabled: { w.enabled }, now: { w.clock.now })
        let alarmId = UUID()
        var p = Proposal(id: alarmId, createdAt: at(21), expiresAt: at(23), origin: .agent, originLabel: "智能体",
                         originDeviceId: "mac", parentId: nil, targetDeviceId: "iphone", title: "8 点叫我", changes: [],
                         reason: "赶大巴", action: .alarm(id: alarmId, title: "赶大巴", fireAt: at(32), deviceId: "iphone"),
                         experiment: false, state: .applied)
        #expect(AlarmMirrorSync.wanted([p], me: "iphone", now: at(22)).isEmpty, "闹钟所在的那台不放镜像")
        await mirror.sync([p])
        let m = try #require(mac.center.pending.first)
        #expect(m.identifier == AlarmMirrorSync.idPrefix + alarmId.uuidString)
        #expect(m.content.interruptionLevel == UNNotificationInterruptionLevel.passive)
        #expect(m.content.body.contains("iPhone"))
        p.undoneAt = at(22, 30)
        await mirror.sync([p])
        #expect(mac.center.pending.isEmpty)
    }

    // MARK: 草稿接力

    private func suite() -> UserDefaults {
        let name = "bc.test.w30.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func draftsHandOffOnlyIntoEmptyBoxesNewestWinsAndSendClearsEverywhere() {
        let cloud = FakeCloud()
        let clock = SendableClock(at(9))
        let switchBox = SendableFlag(true)
        let handoffA = DraftHandoff(kv: FakeSharedKV(cloud), deviceLabel: "Mac", isEnabled: { switchBox.on })
        let handoffB = DraftHandoff(kv: FakeSharedKV(cloud), deviceLabel: "iPhone", isEnabled: { switchBox.on })
        let mac = TextDraftStore(defaults: suite(), now: { clock.now }, handoff: handoffA)
        let phone = TextDraftStore(defaults: suite(), now: { clock.now }, handoff: handoffB)
        // Mac 上打了一半 → iPhone 打开同一个框（空的）就接着出现
        mac.save("明早 9 点写代码", for: TextDraftKey.agentChat)
        clock.now = at(9, 1)
        #expect(phone.load(TextDraftKey.agentChat) == "明早 9 点写代码")
        // iPhone 接着改（更新）→ Mac 下次打开空框拿到 iPhone 这版
        clock.now = at(9, 2)
        phone.save("明早 9 点写代码，10 点开会", for: TextDraftKey.agentChat)
        #expect(mac.load(TextDraftKey.agentChat) == "明早 9 点写代码，10 点开会")
        // 本机更新 → 本机的赢
        clock.now = at(9, 3)
        mac.save("本机更新的", for: TextDraftKey.todaySay)
        clock.now = at(9, 4)
        phone.save("iPhone 更早？不，更晚", for: TextDraftKey.todaySay)
        clock.now = at(9, 5)
        mac.save("Mac 最后改的", for: TextDraftKey.todaySay)
        #expect(phone.load(TextDraftKey.todaySay) == "Mac 最后改的")
        // 在 Mac 上发送成功（清空）→ iPhone 不再冒出来，本机那份也清掉
        clock.now = at(9, 6)
        mac.clear(TextDraftKey.agentChat)
        #expect(phone.load(TextDraftKey.agentChat) == nil)
        #expect(!phone.keys().contains(TextDraftKey.agentChat))
        // 太长的不接力；不在白名单的（如 API Key）永远不接力
        mac.save(String(repeating: "长", count: DraftHandoff.maxChars + 1), for: TextDraftKey.feedback)
        #expect(phone.load(TextDraftKey.feedback) == nil)
        mac.save("sk-secret", for: "settings.apiKey")
        #expect(cloud.values.keys.allSatisfy { !$0.contains("apiKey") } && phone.load("settings.apiKey") == nil)
        #expect(!TextDraftKey.handoffAllowed("cloud.apiKey") && TextDraftKey.handoffAllowed(TextDraftKey.proposalReply(UUID())))
        // 开关关着：什么都不接力
        switchBox.on = false
        mac.save("关着的时候打的", for: TextDraftKey.longtermSay)
        switchBox.on = true
        #expect(phone.load(TextDraftKey.longtermSay) == nil)
    }

    // MARK: 早晚通知属于哪一天（跨设备）

    @MainActor final class RecordingNotifier: NotificationScheduling {
        var calls: [(morning: Date?, evening: Date?)] = []
        func requestAuthorizationIfNeeded() async {}
        func scheduleDailyReminders(morning: Date?, evening: Date?, summary: String) async { calls.append((morning, evening)) }
    }
    private final class OnePlan: PlanReading {
        init(blocks: [ScheduledBlock]) { self.blocks = blocks }
        let blocks: [ScheduledBlock]
        func plannedBlocks(on day: Date) throws -> [ScheduledBlock] { blocks }
    }

    @Test func otherDevicesScheduleTheirCopyOfTheDailyRemindersWhenEnabled() async {
        let cloud = FakeCloud()
        var on = true
        let now = at(22)
        let tomorrow = DayContext.logicalStartOfDay(at(33))
        let plan = OnePlan(blocks: [ScheduledBlock(title: "写代码", start: at(33), end: at(35))])
        // Mac 保存了明天的计划 → 发布这一天
        let macDefaults = suite(), phoneDefaults = suite()
        let macNotifier = RecordingNotifier(), phoneNotifier = RecordingNotifier()
        let macShared = SharedDailyReminderDay(kv: FakeSharedKV(cloud), deviceID: "mac",
                                               refresher: DailyReminderRefresher(plans: plan, notifier: macNotifier, note: { _ in nil },
                                                                                defaults: macDefaults, now: { now }),
                                               defaults: macDefaults, isEnabled: { on }, now: { now }, reactsToRemoteChanges: false)
        let phoneShared = SharedDailyReminderDay(kv: FakeSharedKV(cloud), deviceID: "iphone",
                                                 refresher: DailyReminderRefresher(plans: plan, notifier: phoneNotifier, note: { _ in nil },
                                                                                  defaults: phoneDefaults, now: { now }),
                                                 defaults: phoneDefaults, isEnabled: { on }, now: { now }, reactsToRemoteChanges: false)
        DailyReminderDay.record(tomorrow, in: macDefaults, publish: false)
        macShared.publish(tomorrow)
        // iPhone 看到 → 记成自己的那一天、按（已同步的）计划排自己的一份
        #expect(await phoneShared.adopt())
        #expect(DailyReminderDay.current(in: phoneDefaults) == tomorrow)
        #expect(phoneNotifier.calls.last?.morning == at(32, 45), "首块 9:00 前 15 分钟")
        // 开关关着：不发布、不接（与改动前一致：只有保存计划的那台排）
        on = false
        let other = suite()
        let ipadShared = SharedDailyReminderDay(kv: FakeSharedKV(cloud), deviceID: "ipad",
                                                refresher: DailyReminderRefresher(plans: plan, notifier: RecordingNotifier(), defaults: other, now: { now }),
                                                defaults: other, isEnabled: { on }, now: { now }, reactsToRemoteChanges: false)
        #expect(await ipadShared.adopt() == false && DailyReminderDay.current(in: other) == nil)
    }
}
