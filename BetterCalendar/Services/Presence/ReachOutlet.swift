//
//  ReachOutlet.swift
//  BetterCalendar
//
//  W30（原则 11 · 触达类）：「一处响，处处知」——BetterCalendar 自己发的通知都从这一个出口过：
//  在场设备（DevicePresence）上照常响；其他设备安静地放一份（UNNotificationInterruptionLevel.passive、无声、不亮屏，
//  只进通知中心，回头能看到）；在任何一台处理了（点开 / 已读），其余设备上的那份自动消失。
//
//  怎么做到「每台各自决定、合起来只响一处」：
//    · 每条通知有一个跨设备一致的 reachID（「morning:2026-10-20」「proposal:<id>」…），每台设备各自排 / 各自收到同一条；
//    · 每台设备在 iCloud KV 里有自己的一块板（reach.board.<设备id>，只写自己的键，不会互相覆盖）：
//        回执 receipts = 「本机这一份会响 / 已经响了」；已处理 handled = 「你在本机点开 / 读过了」；
//    · 本机不是在场设备时，只有看到在场设备的回执才安静——
//        提前排的（早晚通知）：在场设备还没排上 → 本机先照常响，等它确认再改安静（宁可多响一台，也不让谁都不响）；
//        立即的（审批 / 智能体消息）：先安静放一份，在场设备 3 分钟内没确认收到 → 改在本机响（升级）。
//    · 在场设备变了（租约变化 / 时间流逝 / 回执变化）→ 重算本机还没响的提前排的通知，必要时原样重排成另一种响法。
//  局限（如实，详见 W30 报告）：被挂起的 iPhone 收不到 KV 变化，它的预排决定停在最后一次运行时——绝大多数情况下表现为「多响一台」；
//  极端情况（iPhone 运行时已改安静、之后被挂起，而在场的 Mac 随即锁屏）那一条只会安静出现在通知中心。
//  不经过这里的（Apple 控制、我们改派不了）：日历事件的会前提醒（EKAlarm）、提醒事项的到点提醒、AlarmKit 闹钟本体、
//  B5 iCloud 直接推送（CloudKit 订阅，App 没运行时由系统直接弹）。
//  总开关 reach.onePlace.enabled 关 = 每条照常响，与改动前一致（决定照样记日志，方便对照）。
//

import Foundation
import Observation
import UserNotifications

// MARK: - 种类与策略

nonisolated enum ReachKind: String, Codable, Sendable, CaseIterable {
    case morning, evening, ddlNudge, proposal, proposalResult, agentMessage, agentChat, alarmMirror

    var label: String {
        switch self {
        case .morning: "早通知"
        case .evening: "晚通知"
        case .ddlNudge: "DDL 补发"
        case .proposal: "审批提案"
        case .proposalResult: "规则代办结果"
        case .agentMessage: "智能体主动消息"
        case .agentChat: "智能体对话"
        case .alarmMirror: "闹钟镜像"
        }
    }
    /// 每台设备都有自己的一份（各自排 / 各自收到）→ 可以只在一处响。只有本机有的（DDL 补发只在你保存计划的那台发）→ 永远照常响。
    var everyDeviceHasCopy: Bool { self != .ddlNudge }
    /// 永远安静（闹钟本体在 iPhone 上，其他设备只放镜像）。
    var alwaysQuiet: Bool { self == .alarmMirror }
    /// 提前排好、到点由系统触发（App 不在场决定）。
    var preScheduled: Bool { self == .morning || self == .evening || self == .alarmMirror }
    /// 有自己的收起机制（提案：一端决定后各端收起；重新弹出也由它管）→ 不进「已处理」板，免得两套机制打架。
    var usesHandledBoard: Bool { self != .proposal }
}

nonisolated struct ReachDecision: Equatable, Sendable {
    var loud: Bool
    /// 立即类：先安静，在场设备没确认收到就升级。
    var escalate: Bool = false
    var note: String
}

nonisolated enum ReachPolicy {
    static let escalateMinutes = 3

    static func decide(kind: ReachKind, me: String, presence p: Presence, enabled: Bool, presenceHasCopy: Bool) -> ReachDecision {
        guard enabled else { return ReachDecision(loud: true, note: "「一处响」没打开：照旧每台都响") }
        if kind.alwaysQuiet { return ReachDecision(loud: false, note: "闹钟只在设好的那台响；这里只安静放一份") }
        guard kind.everyDeviceHasCopy else { return ReachDecision(loud: true, note: "只有本机有这一条（别的设备收不到）→ 照常响") }
        guard let target = p.deviceID else { return ReachDecision(loud: true, note: p.why) }
        if target == me { return ReachDecision(loud: true, note: "本机是在场设备：\(p.why)") }
        if presenceHasCopy {
            return ReachDecision(loud: false, note: "响在「\(p.deviceLabel)」（\(p.why)）；本机安静放一份")
        }
        if kind.preScheduled {
            return ReachDecision(loud: true, note: "在场设备「\(p.deviceLabel)」（\(p.why)）还没确认排上 → 本机先照常响，防止谁都不响")
        }
        return ReachDecision(loud: false, escalate: true,
                             note: "响在「\(p.deviceLabel)」（\(p.why)）；本机安静放一份，它 \(escalateMinutes) 分钟内没确认收到就改在本机响")
    }
}

// MARK: - 每台设备的板

nonisolated struct ReachBoard: Codable, Equatable, Sendable {
    var label: String = ""
    /// 本机有一份会响 / 已经响了的：reachID → 时刻。
    var receipts: [String: Date] = [:]
    /// 你在本机处理了（点开 / 读过）：reachID → 时刻。
    var handled: [String: Date] = [:]

    static let keepFor: TimeInterval = 3 * 86_400
    static let cap = 150

    mutating func prune(now: Date) {
        func trim(_ d: [String: Date]) -> [String: Date] {
            let kept = d.filter { now.timeIntervalSince($0.value) < Self.keepFor }
            guard kept.count > Self.cap else { return kept }
            return Dictionary(uniqueKeysWithValues: kept.sorted { $0.value > $1.value }.prefix(Self.cap).map { ($0.key, $0.value) })
        }
        receipts = trim(receipts); handled = trim(handled)
    }
}

nonisolated struct ReachLogEntry: Codable, Equatable, Sendable {
    var at: Date
    var kind: ReachKind
    var reachID: String
    var loud: Bool
    var note: String

    var line: String {
        "\(at.formatted(date: .omitted, time: .shortened)) \(kind.label) → 本机\(loud ? "响" : "安静")：\(note)"
    }
}

// MARK: - 通知中心的缝

/// 触达出口需要的通知中心能力（生产 = UNUserNotificationCenter；测试 = 内存假实现）。
@MainActor protocol ReachNotificationCentering: AnyObject {
    func add(_ request: UNNotificationRequest) async throws
    func pendingRequests() async -> [UNNotificationRequest]
    /// 已送达的（取其 request；测试里无法构造 UNNotification）。
    func deliveredRequests() async -> [UNNotificationRequest]
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

@MainActor final class SystemReachCenter: ReachNotificationCentering {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func pendingRequests() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func deliveredRequests() async -> [UNNotificationRequest] { await center.deliveredNotifications().map(\.request) }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

// MARK: - 出口

@MainActor
@Observable
final class ReachOutlet {
    static weak var sharedForDev: ReachOutlet?

    static let kindKey = "bcReachKind"
    static let idKey = "bcReachID"
    static let loudSoundKey = "bcReachLoudSound"
    static let fireAtKey = "bcReachFireAt"
    static let boardPrefix = "reach.board."
    static let logKey = "reach.log.v1"
    static let logCap = 60
    static var escalateAfter: TimeInterval { TimeInterval(ReachPolicy.escalateMinutes * 60) }

    let deviceID: String
    let deviceLabel: String
    private let presence: @MainActor (Date) -> Presence
    private let kv: any SharedKVStoring
    private let center: any ReachNotificationCentering
    private let isEnabled: @MainActor () -> Bool
    private let now: () -> Date
    private let logDefaults: UserDefaults?
    /// 生产：过一会儿再查一次升级（Task.sleep）。测试不接，直接调 runEscalations()。
    var scheduleEscalationCheck: (@MainActor (TimeInterval) -> Void)?

    private(set) var entries: [ReachLogEntry] = []
    private struct Escalation { var identifier: String; var kind: ReachKind; var deadline: Date; var presenceID: String; var presenceLabel: String }
    private var escalations: [String: Escalation] = [:]
    private var board: ReachBoard

    init(deviceID: String, deviceLabel: String,
         presence: @escaping @MainActor (Date) -> Presence,
         kv: any SharedKVStoring,
         center: any ReachNotificationCentering,
         isEnabled: @escaping @MainActor () -> Bool = { ReachSettings.onePlaceEnabled },
         now: @escaping () -> Date = { .now },
         logDefaults: UserDefaults? = nil,
         reactsToRemoteChanges: Bool = true) {
        self.deviceID = deviceID; self.deviceLabel = deviceLabel
        self.presence = presence; self.kv = kv; self.center = center
        self.isEnabled = isEnabled; self.now = now; self.logDefaults = logDefaults
        board = Self.decodeBoard(kv.data(forKey: Self.boardPrefix + deviceID)) ?? ReachBoard()
        board.label = deviceLabel
        if let data = logDefaults?.data(forKey: Self.logKey),
           let saved = try? JSONDecoder().decode([ReachLogEntry].self, from: data) { entries = saved }
        if reactsToRemoteChanges {
            kv.addChangeObserver { [weak self] keys in
                guard let self, keys?.contains(where: { $0.hasPrefix(Self.boardPrefix) }) ?? true else { return }
                Task { @MainActor [weak self] in await self?.reevaluate() }
            }
        }
    }

    // MARK: 对外

    /// 一条通知要发 / 要排之前过这里：决定本机这一份响不响，盖上 reachID，记下决定；返回要交给系统的请求。
    /// fireAt：提前排的通知的触发时刻（按那个时刻的在场设备决定）；立即的传 nil。
    func route(_ request: UNNotificationRequest, kind: ReachKind, reachID: String, fireAt: Date? = nil) -> UNNotificationRequest {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return request }
        let loudSound = content.sound != nil
        var info = content.userInfo
        info[Self.kindKey] = kind.rawValue
        info[Self.idKey] = reachID
        info[Self.loudSoundKey] = loudSound
        if let fireAt { info[Self.fireAtKey] = fireAt.timeIntervalSince1970 }
        content.userInfo = info
        let d = decide(kind: kind, reachID: reachID, target: fireAt ?? now())
        Self.apply(loud: d.loud, loudSound: loudSound, to: content)
        note(kind, reachID, d.loud, d.note)
        setReceipt(reachID, d.loud)
        if d.escalate, let p = presence(now()).deviceID {
            escalations[reachID] = Escalation(identifier: request.identifier, kind: kind, deadline: now().addingTimeInterval(Self.escalateAfter),
                                              presenceID: p, presenceLabel: presence(now()).deviceLabel)
            scheduleEscalationCheck?(Self.escalateAfter + 5)
        }
        saveBoard()
        return UNNotificationRequest(identifier: request.identifier, content: content, trigger: request.trigger)
    }

    /// 你在本机处理了这些（点开通知 / 读了对话）→ 记在本机的板上，其他设备看到后收起它们那份。
    func markHandled(_ reachIDs: [String]) async {
        guard isEnabled(), !reachIDs.isEmpty else { return }
        let t = now()
        for id in reachIDs where board.handled[id] == nil {
            board.handled[id] = t; board.receipts.removeValue(forKey: id); escalations.removeValue(forKey: id)
        }
        saveBoard()
    }

    /// 在场设备变了 / 别的设备的板变了 / 回前台：收起别处已处理的、重算还没响的提前排的通知、查升级。
    func reevaluate() async {
        await applyHandled()
        for req in await center.pendingRequests() {
            let info = req.content.userInfo
            // 闹钟镜像永远安静、去留由 AlarmMirrorSync 管（开关关掉时它收起镜像，这里不能把它改成响的）
            guard let raw = info[Self.kindKey] as? String, let kind = ReachKind(rawValue: raw), kind.preScheduled, !kind.alwaysQuiet,
                  let id = info[Self.idKey] as? String else { continue }
            let fireAt = (info[Self.fireAtKey] as? Double).map(Date.init(timeIntervalSince1970:)) ?? now()
            guard fireAt > now() else { continue }
            let d = decide(kind: kind, reachID: id, target: fireAt)
            setReceipt(id, d.loud)
            let isLoud = req.content.interruptionLevel != .passive
            guard d.loud != isLoud, let content = req.content.mutableCopy() as? UNMutableNotificationContent else { continue }
            Self.apply(loud: d.loud, loudSound: (info[Self.loudSoundKey] as? Bool) ?? false, to: content)
            do {
                try await center.add(UNNotificationRequest(identifier: req.identifier, content: content, trigger: req.trigger))
                note(kind, id, d.loud, "改派：" + d.note)
            } catch {
                DevLog.shared.warn("触达", "\(kind.label)改派没成功（保持原来的响法）：\(error.localizedDescription)")
            }
        }
        await runEscalations()
        saveBoard()
    }

    /// 立即类的升级：先安静的那份，在场设备到时还没确认收到 → 改在本机响。
    func runEscalations() async {
        let t = now()
        let due = escalations.filter { t >= $0.value.deadline }
        guard !due.isEmpty else { return }
        let delivered = await center.deliveredRequests()
        let handled = allHandled()
        for (id, e) in due {
            escalations.removeValue(forKey: id)
            if hasCopy(device: e.presenceID, reachID: id) {
                note(e.kind, id, false, "「\(e.presenceLabel)」已确认收到，本机保持安静")
                continue
            }
            guard !handled.contains(id), let req = delivered.first(where: { $0.identifier == e.identifier }),
                  let content = req.content.mutableCopy() as? UNMutableNotificationContent else { continue }   // 已收起 / 已处理
            Self.apply(loud: true, loudSound: (req.content.userInfo[Self.loudSoundKey] as? Bool) ?? false, to: content)
            do {
                try await center.add(UNNotificationRequest(identifier: req.identifier, content: content, trigger: nil))
                setReceipt(id, true)
                note(e.kind, id, true, "升级：「\(e.presenceLabel)」\(ReachPolicy.escalateMinutes) 分钟内没确认收到 → 改在本机响")
            } catch {
                DevLog.shared.warn("触达", "\(e.kind.label)升级没成功：\(error.localizedDescription)")
            }
        }
        saveBoard()
    }

    // MARK: 开发者选项

    /// 某条触达现在在哪些设备上「会响 / 已响」（各设备板上的回执）。
    func ringingDevices(_ reachID: String) -> [String] {
        boards().compactMap { $0.value.receipts[reachID] != nil ? ($0.value.label.isEmpty ? String($0.key.prefix(8)) : $0.value.label) : nil }.sorted()
    }

    var recentLines: [String] {
        entries.suffix(30).reversed().map { e in
            let ring = ringingDevices(e.reachID)
            return e.line + (ring.isEmpty ? "" : "（现在会响 / 已响的：\(ring.joined(separator: "、"))）")
        }
    }

    // MARK: 内部

    private func decide(kind: ReachKind, reachID: String, target: Date) -> ReachDecision {
        let p = presence(target)
        let has = p.deviceID.map { $0 != deviceID && hasCopy(device: $0, reachID: reachID) } ?? false
        return ReachPolicy.decide(kind: kind, me: deviceID, presence: p, enabled: isEnabled(), presenceHasCopy: has)
    }

    nonisolated static func apply(loud: Bool, loudSound: Bool, to content: UNMutableNotificationContent) {
        if loud {
            content.interruptionLevel = .active
            content.sound = loudSound ? .default : nil
        } else {
            content.interruptionLevel = .passive   // 不亮屏、不出声、不弹横幅：只进通知中心
            content.sound = nil
        }
    }

    private func applyHandled() async {
        guard isEnabled() else { return }
        let handled = allHandled()
        guard !handled.isEmpty else { return }
        func matches(_ r: UNNotificationRequest) -> Bool {
            let info = r.content.userInfo
            guard let id = info[Self.idKey] as? String, handled.contains(id),
                  let raw = info[Self.kindKey] as? String, let kind = ReachKind(rawValue: raw) else { return false }
            return kind.usesHandledBoard
        }
        let delivered = await center.deliveredRequests().filter(matches).map(\.identifier)
        let pending = await center.pendingRequests().filter(matches).map(\.identifier)
        if !delivered.isEmpty { center.removeDelivered(delivered) }
        if !pending.isEmpty { center.removePending(pending) }
        if !delivered.isEmpty || !pending.isEmpty {
            DevLog.shared.info("触达", "已在别的设备处理：收起本机 \(delivered.count + pending.count) 条")
        }
    }

    private func allHandled() -> Set<String> {
        Set(boards().values.flatMap { $0.handled.keys })
    }

    private func boards() -> [String: ReachBoard] {
        var out: [String: ReachBoard] = [:]
        for key in kv.keys(withPrefix: Self.boardPrefix) {
            let id = String(key.dropFirst(Self.boardPrefix.count))
            if id == deviceID { out[id] = board } else if let b = Self.decodeBoard(kv.data(forKey: key)) { out[id] = b }
        }
        out[deviceID] = board
        return out
    }

    private func hasCopy(device: String, reachID: String) -> Bool {
        guard let b = Self.decodeBoard(kv.data(forKey: Self.boardPrefix + device)) else { return false }
        return b.receipts[reachID] != nil
    }

    private func setReceipt(_ id: String, _ loud: Bool) {
        if loud { if board.receipts[id] == nil { board.receipts[id] = now() } } else { board.receipts.removeValue(forKey: id) }
    }

    private var lastSaved: ReachBoard?
    private func saveBoard() {
        board.prune(now: now())
        guard board != lastSaved, let data = try? JSONEncoder().encode(board) else { return }
        if !kv.set(data, forKey: Self.boardPrefix + deviceID) {
            DevLog.shared.warn("触达", "本机的通知回执没能同步到 iCloud（KV synchronize 失败）——别的设备暂时看不到，可能会多响一台")
        }
        lastSaved = board
    }

    private func note(_ kind: ReachKind, _ id: String, _ loud: Bool, _ text: String) {
        entries.append(ReachLogEntry(at: now(), kind: kind, reachID: id, loud: loud, note: text))
        if entries.count > Self.logCap { entries.removeFirst(entries.count - Self.logCap) }
        if let logDefaults, let data = try? JSONEncoder().encode(entries) { logDefaults.set(data, forKey: Self.logKey) }
    }

    private static func decodeBoard(_ data: Data?) -> ReachBoard? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(ReachBoard.self, from: data)
    }
}

// MARK: - 早晚通知属于哪一天（跨设备）

/// 早晚通知原来只排在「你保存计划的那台」。一处响要求每台都有一份（在场的那台响、其余安静），所以「已排的属于哪一天」要跨设备：
/// 本机保存计划时发布这一天；别的设备看到后记成自己的那一天、按（已同步的）计划排自己的一份。开关关着时什么都不做（与改动前一致）。
@MainActor
final class SharedDailyReminderDay {
    static let key = "reach.dailyDay.v1"
    nonisolated struct Record: Codable, Equatable, Sendable { var label: Date; var by: String; var at: Date }

    private let kv: any SharedKVStoring
    private let deviceID: String
    private let refresher: DailyReminderRefresher
    private let defaults: UserDefaults
    private let isEnabled: @MainActor () -> Bool
    private let now: () -> Date

    init(kv: any SharedKVStoring, deviceID: String, refresher: DailyReminderRefresher, defaults: UserDefaults = .standard,
         isEnabled: @escaping @MainActor () -> Bool = { ReachSettings.onePlaceEnabled }, now: @escaping () -> Date = { .now },
         reactsToRemoteChanges: Bool = true) {
        self.kv = kv; self.deviceID = deviceID; self.refresher = refresher
        self.defaults = defaults; self.isEnabled = isEnabled; self.now = now
        if reactsToRemoteChanges {
            kv.addChangeObserver { [weak self] keys in
                guard keys?.contains(Self.key) ?? true else { return }
                Task { @MainActor [weak self] in await self?.adopt() }
            }
        }
    }

    /// 本机保存了某一天的计划（已排早晚通知）。
    func publish(_ label: Date) {
        guard isEnabled(), let data = try? JSONEncoder().encode(Record(label: label, by: deviceID, at: now())) else { return }
        kv.set(data, forKey: Self.key)
    }

    /// 别的设备保存了计划 / 计划数据同步到了 / 回前台：按共享的那一天（还没过去）排本机的一份。返回是否排了。
    @discardableResult
    func adopt() async -> Bool {
        guard isEnabled(), let data = kv.data(forKey: Self.key),
              let r = try? JSONDecoder().decode(Record.self, from: data),
              r.label >= DayContext.logicalStartOfDay(now()) else { return false }
        let changed = DailyReminderDay.current(in: defaults) != r.label
        if changed { DailyReminderDay.record(r.label, in: defaults, publish: false) }
        // 数据同步每来一次都会调这里：只有接到新的一天时才记日志（重排本身幂等）
        return await refresher.refresh(affecting: [r.label], logs: changed)
    }
}
