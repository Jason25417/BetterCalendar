//
//  TimelineWriteLease.swift
//  BetterCalendar
//
//  W22 写权租约（SPEC §19.14 W15 遗留「两台设备协调器各写数据库」）：
//  两台设备都跑时间线协调器，执行进度只在各自本机 → 两边算出的排布可能不同 → CloudKit 字段级「后写赢」让计划块来回翻。
//  这里让**任一时刻只有一台设备**写「自动调整」（顺延 / 活动预报 / 影子直写 / 启动补结算）；另一台照样算、只用来显示，不写真相。
//  你亲手的动作（拖动、批准提案、删除、对账采纳你在日历里的改动、一键撤、收尾盖章）**永远不经过这道闸**（原则 8：你最大）。
//
//  租约放在 iCloud KV（NSUbiquitousKeyValueStore，与「已开始今天」、设置同步同一个存储；Dev 版与日用版的 KV 按 bundle id 天然分开）：
//  不新建 CloudKit 记录类型。记录：持有设备 id / 名字、原因、续约时刻、到期时刻、序号。
//
//  谁拿写权（先到先得之上的优先级）：
//    1. 正在计时的设备（本机有前台或后台计时）——它才知道「现在做到哪了」；计时租约有效到预计结束 + 10 分钟（最多 3 小时），
//       所以 iPhone 锁屏挂起时，Mac 不会拿着不完整的进度去改；
//    2. 否则：最近一次回到前台的设备（前台切换那一刻抢，持续在前台不抢回）；
//    3. 否则：租约过期后第一个续约的设备。
//    计时租约只能等它过期 / 失联才被接手；其他原因的租约可被「正在计时」或「刚回前台」抢走。
//
//  时钟偏差：到期判断只用「持有者自己写的时长」（到期 − 续约，两个时刻出自同一台钟，偏差相互抵消）+「本机上次看到它续约的本机时刻」，
//  外加对绝对到期时刻留 2 分钟容差；所以两台设备钟差几十秒也不会误判。
//  失联接手（卡住）：持有者的绝对到期时刻还没到，但本机已经超过「它声明的时长 + 10 分钟」没看到它续约（多半是钟不准或 KV 卡住）
//  → 接手并记 warning（🐞 计数，持续才升级横幅）；正常到期接手只记 info。
//  两台都离线：各自看对方租约过期 → 各自写（本机 KV）→ 重新联网后 KV 后写赢、只剩一个持有者，期间的计划改动按现有 CloudKit 后写赢合并（与改动前相同）。
//  单设备：只有本机 → 永远是持有者，写入行为与改动前完全一致；KV 不可用（没登录 iCloud）时 KV 退化为本机存储，同样只有本机。
//

import Foundation
import Observation

// MARK: - 数据

nonisolated enum WriteLeaseReason: String, Codable, Sendable, Equatable {
    case timer             // 正在计时
    case foreground        // 最近回到前台
    case held              // 计时结束后继续持有（没有更优先的设备）
    case expiredTakeover   // 上一个持有者到期 / 交出后接手
    case staleTakeover     // 上一个持有者失联（久未续约）后接手

    var label: String {
        switch self {
        case .timer: return "正在计时"
        case .foreground: return "最近在前台"
        case .held: return "继续持有"
        case .expiredTakeover: return "到期接手"
        case .staleTakeover: return "对方失联后接手"
        }
    }
}

nonisolated struct WriteLease: Codable, Equatable, Sendable {
    var holder: String
    var holderLabel: String
    var reason: WriteLeaseReason
    /// 持有者自己的时钟。
    var renewedAt: Date
    var expiresAt: Date
    /// 每次写（含续约）+1：本机据此判断「看到了一次新的续约」。
    var seq: Int64
    /// 持有者主动交出（iPhone 回到后台且没在计时）：别的设备立即可接手。
    var releasedAt: Date?

    /// 持有者声明的有效时长（同一台钟的两个时刻相减，不受钟差影响）。
    var span: TimeInterval { max(0, expiresAt.timeIntervalSince(renewedAt)) }
    var observationKey: String { "\(holder)#\(seq)" }
}

// MARK: - 纯策略（可单测）

nonisolated enum WriteLeasePolicy {
    /// 普通（前台 / 接手）租约时长；持有者过半就续。
    static let baseTTL: TimeInterval = 6 * 60
    /// 计时租约：预计结束后再留这么久；最长这么久（防计时忘关时永远霸着写权）。
    static let timerGrace: TimeInterval = 10 * 60
    static let timerCap: TimeInterval = 3 * 3600
    /// 计时但没有预计结束（计划外的 bonus 计时）时的时长。
    static let timerFallbackTTL: TimeInterval = 30 * 60
    /// 绝对到期时刻的钟差容差。
    static let skewTolerance: TimeInterval = 2 * 60
    /// KV 投递延迟的余量：超过「声明时长 + 它」没看到续约 → 失联。
    static let deliveryAllowance: TimeInterval = 10 * 60

    enum Liveness: Equatable, Sendable { case valid, expired, stale }

    enum Trigger: Equatable, Sendable { case automaticWrite, becameForeground, becameBackground }

    struct Local: Equatable, Sendable {
        var deviceID: String
        var deviceLabel: String
        var timing: Bool
        var timingUntil: Date?
        var foreground: Bool
    }

    enum Event: Equatable, Sendable {
        case claimedFresh
        case reasonChanged(from: WriteLeaseReason, to: WriteLeaseReason)
        case preempted(from: WriteLease)
        case tookOverExpired(from: WriteLease)
        case tookOverStale(from: WriteLease, unseenMinutes: Int)
        case released
        case reclaimedOwn
    }

    struct Outcome: Equatable, Sendable {
        /// 本机此刻能否写自动调整。
        var mayWrite: Bool
        /// 需要写进共享存储的新租约（nil = 不写）。
        var write: WriteLease?
        var event: Event?
    }

    static func liveness(_ lease: WriteLease, observedAt: Date, now: Date) -> Liveness {
        if lease.releasedAt != nil { return .expired }
        if now > lease.expiresAt.addingTimeInterval(skewTolerance) { return .expired }
        if now.timeIntervalSince(observedAt) > lease.span + deliveryAllowance { return .stale }
        return .valid
    }

    static func expiry(for reason: WriteLeaseReason, local: Local, now: Date) -> Date {
        guard reason == .timer else { return now.addingTimeInterval(baseTTL) }
        guard let until = local.timingUntil else { return now.addingTimeInterval(timerFallbackTTL) }
        let target = until.addingTimeInterval(timerGrace)
        return min(max(target, now.addingTimeInterval(baseTTL)), now.addingTimeInterval(timerCap))
    }

    static func make(_ reason: WriteLeaseReason, local: Local, now: Date, after previous: WriteLease?) -> WriteLease {
        WriteLease(holder: local.deviceID, holderLabel: local.deviceLabel, reason: reason,
                   renewedAt: now, expiresAt: expiry(for: reason, local: local, now: now),
                   seq: (previous?.seq ?? 0) + 1, releasedAt: nil)
    }

    /// 核心判定。observedAt = 本机最近一次看到这份租约（holder#seq）变化的本机时刻。
    static func decide(current: WriteLease?, observedAt: Date?, local: Local,
                       trigger: Trigger, now: Date) -> Outcome {
        let desired: WriteLeaseReason? = local.timing ? .timer : (local.foreground ? .foreground : nil)

        guard let cur = current else {
            // 从没有人持有过（首次 / 单设备）：直接拿。回后台的那一刻不必去拿。
            if trigger == .becameBackground { return Outcome(mayWrite: false, write: nil, event: nil) }
            return Outcome(mayWrite: true, write: make(desired ?? .expiredTakeover, local: local, now: now, after: nil),
                           event: .claimedFresh)
        }

        if cur.holder == local.deviceID {
            return decideOwn(cur, desired: desired, local: local, trigger: trigger, now: now)
        }

        // 别的设备持有
        if trigger == .becameBackground { return Outcome(mayWrite: false, write: nil, event: nil) }
        switch liveness(cur, observedAt: observedAt ?? now, now: now) {
        case .valid:
            if local.timing && cur.reason != .timer {
                return Outcome(mayWrite: true, write: make(.timer, local: local, now: now, after: cur), event: .preempted(from: cur))
            }
            if trigger == .becameForeground && cur.reason != .timer {
                return Outcome(mayWrite: true, write: make(desired ?? .foreground, local: local, now: now, after: cur),
                               event: .preempted(from: cur))
            }
            return Outcome(mayWrite: false, write: nil, event: nil)
        case .expired:
            return Outcome(mayWrite: true, write: make(desired ?? .expiredTakeover, local: local, now: now, after: cur),
                           event: .tookOverExpired(from: cur))
        case .stale:
            let unseen = Int(now.timeIntervalSince(observedAt ?? now) / 60)
            return Outcome(mayWrite: true, write: make(local.timing ? .timer : .staleTakeover, local: local, now: now, after: cur),
                           event: .tookOverStale(from: cur, unseenMinutes: unseen))
        }
    }

    private static func decideOwn(_ cur: WriteLease, desired: WriteLeaseReason?, local: Local,
                                  trigger: Trigger, now: Date) -> Outcome {
        if cur.releasedAt != nil {
            // 自己交出过、还没有别的设备接手：回到前台 / 开始计时才重新拿；
            // 后台里的零星重算照旧可写但不重新拿（单设备与改动前一致；另一台一接手，下一轮读到就让出）
            if trigger == .becameBackground { return Outcome(mayWrite: false, write: nil, event: nil) }
            guard let desired else { return Outcome(mayWrite: true, write: nil, event: nil) }
            return Outcome(mayWrite: true, write: make(desired, local: local, now: now, after: cur), event: .reclaimedOwn)
        }
        if trigger == .becameBackground {
            guard !local.timing else { return Outcome(mayWrite: true, write: nil, event: nil) }   // 计时中不交出
            var released = cur
            released.seq += 1
            released.releasedAt = now
            return Outcome(mayWrite: false, write: released, event: .released)
        }
        var reason = cur.reason
        if local.timing { reason = .timer }
        else if cur.reason == .timer { reason = local.foreground ? .foreground : .held }
        else if trigger == .becameForeground { reason = .foreground }

        let targetExpiry = expiry(for: reason, local: local, now: now)
        let halfSpent = now >= cur.renewedAt.addingTimeInterval(cur.span / 2)
        let timerExtended = reason == .timer && targetExpiry.timeIntervalSince(cur.expiresAt) > 5 * 60
        // 自己的租约在本机钟上已过期（挂起很久刚醒）也照样续：对方若已接手，KV 很快送到，下一轮就让出
        guard reason != cur.reason || halfSpent || timerExtended || now >= cur.expiresAt else {
            return Outcome(mayWrite: true, write: nil, event: nil)
        }
        let next = make(reason, local: local, now: now, after: cur)
        return Outcome(mayWrite: true, write: next,
                       event: reason != cur.reason ? .reasonChanged(from: cur.reason, to: reason) : nil)
    }
}

// MARK: - 共享存储

/// 跨设备共享的一小块数据（生产 = iCloud KV；测试 = 内存假存储）。
protocol WriteLeaseStoring: AnyObject {
    func load() -> Data?
    /// 返回 false = 已存本机但这次没能交给 iCloud（KV synchronize 失败）。
    @discardableResult func save(_ data: Data) -> Bool
    /// 另一台设备改了它（KV 推送）→ 回调（主线程）。
    var onExternalChange: (() -> Void)? { get set }
}

final class ICloudKVWriteLeaseStore: WriteLeaseStoring {
    static let key = "timeline.writeLease.v1"
    private let kv = NSUbiquitousKeyValueStore.default
    /// 同一个 KV 存储里的一个键（写权租约 / W22b 跨设备手改冷却共用这个实现）。
    let key: String
    var onExternalChange: (() -> Void)?

    init(key: String = ICloudKVWriteLeaseStore.key) {
        self.key = key
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv, queue: .main) { [weak self] note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            guard let self, changed?.contains(self.key) ?? true else { return }
            Task { @MainActor [weak self] in self?.onExternalChange?() }
        }
    }

    func load() -> Data? { kv.data(forKey: key) }
    @discardableResult func save(_ data: Data) -> Bool {
        kv.set(data, forKey: key)
        return kv.synchronize()
    }
}

// MARK: - 运行时

@MainActor
@Observable
final class TimelineWriteLease {
    /// 应急总闸（开发者选项，随 iCloud 设置同步；默认开）：关 = 回到改动前「两台设备都写」。
    static let enabledKey = "timeline.writeLease.enabled"
    nonisolated static var enabledSetting: Bool { ExperimentDefaults.bool(enabledKey, default: true) }
    /// 开发者选项的状态行用（同 TimelineCoordinator.sharedForDev 先例；M8 摘除）。
    static weak var sharedForDev: TimelineWriteLease?

    let deviceID: String
    let deviceLabel: String
    /// iPhone：回到后台（会被挂起）且没在计时 → 主动交出；Mac 后台照常运行，不交出。
    let releasesOnBackground: Bool
    /// 本机计时状态（组装点接执行层）：是否在计时 + 预计结束。
    var timing: () -> (running: Bool, until: Date?) = { (false, nil) }

    private let store: any WriteLeaseStoring
    private let now: () -> Date
    private let isEnabled: @MainActor () -> Bool
    private let log: @MainActor (DevLog.Level, String) -> Void

    private(set) var current: WriteLease?
    private(set) var isForeground = false
    /// 最近一次判定：本机能不能写（状态行 / 协调器备注用）。
    private(set) var lastMayWrite = true
    private(set) var lastChangeNote = "（还没有判定过）"
    private var syncFailureLogged = false
    private var observedKey: String?
    private var observedAt: Date?

    init(store: any WriteLeaseStoring,
         deviceID: String,
         deviceLabel: String,
         releasesOnBackground: Bool,
         isEnabled: @escaping @MainActor () -> Bool = { TimelineWriteLease.enabledSetting },
         now: @escaping () -> Date = { .now },
         log: @escaping @MainActor (DevLog.Level, String) -> Void = { level, msg in
             switch level {
             case .info: DevLog.shared.info("写权租约", msg)
             case .warning: DevLog.shared.warn("写权租约", msg)
             case .error: DevLog.shared.error("写权租约", msg)
             }
         }) {
        self.store = store
        self.deviceID = deviceID
        self.deviceLabel = deviceLabel
        self.releasesOnBackground = releasesOnBackground
        self.isEnabled = isEnabled
        self.now = now
        self.log = log
        store.onExternalChange = { [weak self] in self?.reloadFromStore() }
        reloadFromStore()
    }

    // MARK: 对外

    /// 协调器每轮重算时调：本机此刻能否写自动调整（必要时顺手拿 / 续 / 抢租约）。总闸关 = 永远可以（旧行为）。
    func mayWriteAutomatically() -> Bool {
        guard isEnabled() else { lastMayWrite = true; return true }
        return apply(.automaticWrite)
    }

    /// 前台切换（scenePhase）：回前台那一刻按「最近在前台」抢；iPhone 回后台且没计时 → 交出。
    func setForeground(_ active: Bool) {
        let was = isForeground
        isForeground = active
        guard isEnabled(), active != was else { return }
        if active { _ = apply(.becameForeground) }
        else if releasesOnBackground { _ = apply(.becameBackground) }
    }

    /// 另一台设备改了租约（KV 推送）或启动读取。
    func reloadFromStore() {
        let fresh = Self.decode(store.load())
        let before = current
        noteObserved(fresh)
        current = fresh
        guard let fresh, fresh.holder != deviceID,
              before?.holder != fresh.holder || before?.reason != fresh.reason
                || (before?.releasedAt == nil) != (fresh.releasedAt == nil) else { return }
        let note = fresh.releasedAt != nil
            ? "「\(fresh.holderLabel)」交出了写权"
            : "写权在「\(fresh.holderLabel)」（\(fresh.reason.label)）：本机只算不写自动调整"
        lastChangeNote = note
        log(.info, note)
    }

    /// 开发者选项状态行。
    var statusLine: String {
        guard isEnabled() else { return "已关闭（应急总闸）：两台设备都会写自动调整，同改动前" }
        guard let l = current else { return "还没有设备持有（下一次自动调整时本机会拿）" }
        let who = l.holder == deviceID ? "本机（\(deviceLabel)）" : "「\(l.holderLabel)」"
        if l.releasedAt != nil { return "\(who) 已交出，等下一台设备接手" }
        let mins = max(0, Int(l.expiresAt.timeIntervalSince(now()) / 60))
        let role = l.holder == deviceID ? "本机写自动调整" : "本机只算不写"
        return "\(who) · \(l.reason.label) · 约 \(mins) 分钟后到期（持有者会自动续）· \(role)"
    }

    // MARK: 内部

    private func apply(_ trigger: WriteLeasePolicy.Trigger) -> Bool {
        let fresh = Self.decode(store.load())   // 每次都读最新（另一台设备可能刚写）
        noteObserved(fresh)
        current = fresh
        let t = timing()
        let local = WriteLeasePolicy.Local(deviceID: deviceID, deviceLabel: deviceLabel,
                                           timing: t.running, timingUntil: t.until, foreground: isForeground)
        let out = WriteLeasePolicy.decide(current: fresh, observedAt: observedAt, local: local, trigger: trigger, now: now())
        if let next = out.write, let data = try? JSONEncoder().encode(next) {
            if store.save(data) {
                syncFailureLogged = false
            } else if !syncFailureLogged {   // 只记第一次（没登录 iCloud 时每次续约都会失败，别刷屏）；恢复后再失败会再记
                syncFailureLogged = true
                log(.warning, "写权租约没能同步到 iCloud（KV synchronize 失败）——另一台设备暂时看不到，下次续约再试")
            }
            current = next
            noteObserved(next)
        }
        if let event = out.event { report(event) }
        lastMayWrite = out.mayWrite
        return out.mayWrite
    }

    private func noteObserved(_ lease: WriteLease?) {
        let key = lease?.observationKey
        if key != observedKey || observedAt == nil {
            observedKey = key
            observedAt = now()
        }
    }

    private func report(_ event: WriteLeasePolicy.Event) {
        let me = "本机（\(deviceLabel)）"
        let reason = current?.reason.label ?? ""
        let (level, note): (DevLog.Level, String) = {
            switch event {
            case .claimedFresh: return (.info, "\(me)拿到写权（\(reason)）")
            case .reasonChanged(let a, let b): return (.info, "\(me)继续持有写权：\(a.label) → \(b.label)")
            case .preempted(let from): return (.info, "\(me)从「\(from.holderLabel)」（\(from.reason.label)）接过写权：\(reason)")
            case .tookOverExpired(let from): return (.info, "「\(from.holderLabel)」的写权已到期 / 交出，\(me)接手（\(reason)）")
            case .tookOverStale(let from, let m):
                return (.warning, "「\(from.holderLabel)」已约 \(m) 分钟没续约写权（可能离线或时钟不准），\(me)接手自动调整")
            case .released: return (.info, "\(me)回到后台，交出写权")
            case .reclaimedOwn: return (.info, "\(me)重新拿回写权（\(reason)）")
            }
        }()
        lastChangeNote = note
        log(level, note)
    }

    private static func decode(_ data: Data?) -> WriteLease? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(WriteLease.self, from: data)
    }
}
