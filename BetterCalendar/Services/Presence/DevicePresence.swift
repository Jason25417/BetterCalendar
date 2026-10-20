//
//  DevicePresence.swift
//  BetterCalendar
//
//  W30（原则 11「人是单位，设备是触点」）：「你此刻在哪台设备」——在场设备。
//  判断顺序（按可靠程度）：
//    1. 正在计时的那台；
//    2. 最近真正被你用过的那台（Mac = 键鼠输入且没锁屏，iPhone / iPad = 在前台）；
//    3. 都判断不了 → 随身的 iPhone。这一步是**写明了的默认**（原则 10：看得见，不是悄悄兜底）：
//       每次据此做的决定都带着原因（「没判断出你在哪 → 算随身的 iPhone」），开发者选项里看得到。
//    （连 iPhone 都没登记过 → 每台都响：宁可多响一台，也不让谁都不响。）
//  一份实现：在场设备不另起一套存储——它就是 W22 写权租约那份共享记录（TimelineWriteLease：持有者 + 原因 + 到期 + activeAt）。
//  自动调整按它决定谁写，触达（ReachOutlet）按它决定在哪台响。租约的「到期接手 / 继续持有」不算在场（那只是为了有人写）：
//  在场只认「计时中」或「activeAt 在 15 分钟窗口内」。
//  局限（如实）：iCloud KV 投递有延迟（几秒到几分钟），两台设备短时间内可能看法不同——设计上让分歧落在「多响一台」那一侧。
//

import Foundation
import Observation
#if os(macOS)
import AppKit
import CoreGraphics
#endif

// MARK: - 开关

nonisolated enum ReachSettings {
    /// 「一处响，处处知」总开关（W17 新功能约定：Dev 版默认开、日用版默认关；随设置同步）。
    /// 关 = 通知行为与改动前逐字一致（每台照常响），在场设备只显示不决定任何事。
    static let onePlaceKey = "reach.onePlace.enabled"
    static func onePlaceEnabled(in d: UserDefaults = .standard) -> Bool { ExperimentDefaults.newFeature(onePlaceKey, in: d) }
    static var onePlaceEnabled: Bool { onePlaceEnabled() }
}

// MARK: - 纯策略

nonisolated enum PresenceBasis: String, Codable, Sendable, Equatable {
    case timer           // 正在计时
    case recentUse       // 最近真正在用
    case carriedDefault  // 判断不了 → 随身的 iPhone（写明的默认）
    case everyDevice     // 判断不了，也没登记过 iPhone → 每台都响

    var label: String {
        switch self {
        case .timer: "正在计时"
        case .recentUse: "最近在用"
        case .carriedDefault: "默认：随身的 iPhone"
        case .everyDevice: "判断不了：每台都响"
        }
    }
}

nonisolated struct Presence: Equatable, Sendable {
    /// nil = 不指定某一台（每台都算在场）。
    var deviceID: String?
    var deviceLabel: String
    var kind: ActivityDeviceKind?
    var basis: PresenceBasis
    /// 给人看的原因（「Mac 2 分钟前有键鼠输入」「没判断出你在哪 → 算随身的 iPhone」）。
    var why: String

    func includes(_ id: String) -> Bool { deviceID == nil || deviceID == id }
    /// 用来判断「在场设备变了没有」（原因里的分钟数变化不算）。
    var identity: String { "\(deviceID ?? "*")|\(basis.rawValue)" }
}

nonisolated enum PresencePolicy {
    /// 「最近真正在用」的窗口：持有者 activeAt 在这么久以内才算在场；预测某个时刻在不在场也用它（activeAt + 窗口 ≥ 那个时刻）。
    static let activeWindow: TimeInterval = WriteLeasePolicy.presenceWindow

    /// 在 target 时刻（立即触达 = now；提前排的通知 = 触发时刻）你会在哪台。
    /// observedAt = 本机最近一次看到这份租约变化的本机时刻（判断持有者失联用，同写权租约）。
    static func resolve(lease: WriteLease?, observedAt: Date?, devices: [KnownDevice], leaseEnabled: Bool,
                        at target: Date, now: Date) -> Presence {
        var unknownWhy = "还没有设备报告过在用"
        if !leaseEnabled {
            unknownWhy = "写权租约总闸关着，判断不了"
        } else if let l = lease {
            let label = l.holderLabel
            let kind = l.holderKind.flatMap(ActivityDeviceKind.init(rawValue:))
                ?? devices.first(where: { $0.id == l.holder })?.deviceKind
            let live = WriteLeasePolicy.liveness(l, observedAt: observedAt ?? now, now: now)
            if l.releasedAt != nil {
                unknownWhy = "「\(label)」已经不在用（回后台 / 锁屏）"
            } else if live != .valid {
                unknownWhy = live == .stale ? "「\(label)」很久没更新（可能离线）" : "「\(label)」的在用记录已过期"
            } else {
                if l.reason == .timer, target <= l.expiresAt.addingTimeInterval(WriteLeasePolicy.skewTolerance) {
                    return Presence(deviceID: l.holder, deviceLabel: label, kind: kind, basis: .timer,
                                    why: "「\(label)」正在计时")
                }
                if let a = l.activeAt, now.timeIntervalSince(a) <= activeWindow, target.timeIntervalSince(a) <= activeWindow {
                    let mins = max(0, Int(now.timeIntervalSince(a) / 60))
                    let how = kind == .mac ? "有键鼠输入" : "在前台用过"
                    return Presence(deviceID: l.holder, deviceLabel: label, kind: kind, basis: .recentUse,
                                    why: "「\(label)」\(mins == 0 ? "刚刚" : "\(mins) 分钟前")\(how)")
                }
                if l.activeAt != nil, now.timeIntervalSince(l.activeAt!) <= activeWindow {
                    unknownWhy = "「\(label)」最近在用，但到那个时刻已超出 \(Int(activeWindow / 60)) 分钟窗口"
                } else {
                    unknownWhy = "没有设备正在计时，也没有设备在最近 \(Int(activeWindow / 60)) 分钟里被用过"
                }
            }
        }
        if let phone = devices.filter({ $0.deviceKind == .iphone }).max(by: { $0.seenAt < $1.seenAt }) {
            return Presence(deviceID: phone.id, deviceLabel: phone.label, kind: .iphone, basis: .carriedDefault,
                            why: "没判断出你在哪（\(unknownWhy)）→ 算随身的 iPhone")
        }
        return Presence(deviceID: nil, deviceLabel: "每台设备", kind: nil, basis: .everyDevice,
                        why: "没判断出你在哪（\(unknownWhy)），也没登记过 iPhone → 每台都响")
    }
}

// MARK: - 运行时

/// 在场设备的运行时视图：读写权租约那份共享记录 + 设备名册，算「此刻 / 某个时刻你在哪台」；变化时通知监听者（触达出口重算）。
@MainActor
@Observable
final class DevicePresence {
    /// 开发者选项状态行用（同 TimelineWriteLease.sharedForDev 先例）。
    static weak var sharedForDev: DevicePresence?

    let deviceID: String
    let deviceLabel: String
    /// 在场记录的来源（写权租约）。组装点在租约建好后接上；没接 = 只能用默认（随身的 iPhone）。
    private(set) var lease: TimelineWriteLease?
    private let devices: @MainActor () -> [KnownDevice]
    private let leaseEnabled: @MainActor () -> Bool
    private let now: () -> Date
    private var observers: [@MainActor () -> Void] = []
    private var lastIdentity: String?
    /// 当前在场设备从什么时候起是它（本机观察到的时刻）。
    private(set) var since: Date?
    private(set) var latest: Presence?

    init(deviceID: String, deviceLabel: String,
         devices: @escaping @MainActor () -> [KnownDevice],
         leaseEnabled: @escaping @MainActor () -> Bool = { TimelineWriteLease.enabledSetting },
         now: @escaping () -> Date = { .now }) {
        self.deviceID = deviceID; self.deviceLabel = deviceLabel
        self.devices = devices; self.leaseEnabled = leaseEnabled; self.now = now
    }

    func attach(_ lease: TimelineWriteLease) {
        self.lease = lease
        lease.onChange = { [weak self] in self?.tick() }
        tick()
    }

    func addObserver(_ block: @escaping @MainActor () -> Void) { observers.append(block) }

    /// 此刻你在哪台。
    func current() -> Presence { predicted(at: now()) }

    /// 某个将来的时刻你会在哪台（提前排的通知用）：计时到它预计结束为止、最近在用到窗口为止，再往后 = 随身的 iPhone。
    func predicted(at target: Date) -> Presence {
        PresencePolicy.resolve(lease: lease?.current, observedAt: lease?.currentObservedAt, devices: devices(),
                               leaseEnabled: lease != nil && leaseEnabled(), at: target, now: now())
    }

    /// 重算一次；在场设备（哪台 + 依据）变了就通知监听者。租约变化 / 定时心跳 / 回前台时调。
    func tick() {
        let p = current()
        latest = p
        guard p.identity != lastIdentity else { return }
        let first = lastIdentity == nil
        lastIdentity = p.identity
        since = now()
        if !first { DevLog.shared.info("在场设备", "现在算在「\(p.deviceLabel)」：\(p.why)") }
        for o in observers { o() }
    }

    var statusLine: String {
        let p = latest ?? current()
        let me = p.deviceID == deviceID ? "（本机）" : ""
        let when = since.map { " · 自 \($0.formatted(date: .omitted, time: .shortened)) 起" } ?? ""
        return "\(p.deviceLabel)\(me) · \(p.basis.label)\(when)\n\(p.why)"
    }
}

// MARK: - 「真正在用」的信号

/// 本机是不是正在被用：Mac 读系统的「距上次键鼠输入多少秒」+ 是否锁屏；iOS 前台 = 在用（后台计时器不会跑）。
/// 每 60 秒看一次（一个 Timer，不是 TimelineView；只比较两个数，不碰界面），并在锁屏 / 睡眠 / 解锁那一刻立即看一次。
/// 只在状态变化或在用期间调回调；回调里决定要不要写共享记录（约 4 分钟一次）。
@MainActor
final class UserActivityProbe {
    nonisolated static let interval: TimeInterval = 60
    /// 超过这么久没有键鼠输入 = 没在用。
    nonisolated static let idleThreshold: TimeInterval = 120

    nonisolated struct Reading: Equatable, Sendable {
        var idleSeconds: Double
        var locked: Bool
    }

    /// 纯函数（可单测）：上一刻在不在用 + 这次读数 → 现在在不在用、是否刚变化。
    nonisolated static func step(wasActive: Bool, reading: Reading) -> (active: Bool, transition: Bool) {
        let active = !reading.locked && reading.idleSeconds < idleThreshold
        return (active, active != wasActive)
    }

    private let read: @MainActor () -> Reading
    private let onReading: @MainActor (_ active: Bool, _ transition: Bool) -> Void
    private var timer: Timer?
    private var active = false
    private var observers: [NSObjectProtocol] = []

    init(read: @escaping @MainActor () -> Reading, onReading: @escaping @MainActor (Bool, Bool) -> Void) {
        self.read = read; self.onReading = onReading
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = 15   // 不需要准点：让系统合并唤醒
        RunLoop.main.add(t, forMode: .common)
        timer = t
        #if os(macOS)
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let asleep = [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                              NSWorkspace.willSleepNotification].contains(note.name)
                MainActor.assumeIsolated { self?.sample(forceInactive: asleep) }
            })
        }
        #endif
        sample()
    }

    func sample(forceInactive: Bool = false) {
        var r = read()
        if forceInactive { r.locked = true }
        let s = Self.step(wasActive: active, reading: r)
        active = s.active
        if s.active || s.transition { onReading(s.active, s.transition) }
    }

    #if os(macOS)
    /// Mac 读数：系统层面的「距上次任意键鼠输入」（沙盒可用，不需要辅助功能权限）+ 会话是否锁屏。
    static func macReading() -> Reading {
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        var locked = false
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            locked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? ((dict["CGSSessionScreenIsLocked"] as? Int) == 1)
            if let onConsole = dict[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { locked = true }
        }
        return Reading(idleSeconds: idle, locked: locked)
    }
    #endif
}
