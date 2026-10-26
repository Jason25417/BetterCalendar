//
//  AgentWakeSchedule.swift
//  BetterCalendar
//
//  0.76（Jason 10-25：「可以给你设置一个定时唤醒」「12 点半再来复盘」这种不该做成待办）：智能体给自己约一个时刻，
//  到点被叫醒（事件 scheduled_wake）接着做约好的事。
//  · 存储：随 iCloud 设置同步的 UserDefaults 字符串（键在 SettingsSync 白名单、带更新时间防旧副本覆盖），不建新的 CloudKit 记录类型。
//  · 谁来叫醒：Mac 到点就叫（不会被系统收回后台时间）；iPhone / iPad 晚 2 分钟、还没人叫才叫（Mac 没开时兜底）。
//    叫醒前先写「已叫醒」回执再同步；两台几乎同时到点时极少数可能叫两次——可见、不丢。
//  · App 都没开着就等下次打开时补叫（写明迟到多久）；迟到超过 12 小时不再叫，记一笔。
//

import Foundation

nonisolated struct AgentScheduledWake: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var at: Date
    /// 到点要做的事（智能体写给自己的）。
    var note: String
    var createdAt: Date
    var createdBy: String
    var firedAt: Date?
    var firedBy: String?
    var cancelledAt: Date?
    var missed: Bool?

    var isPending: Bool { firedAt == nil && cancelledAt == nil && missed != true }
}

nonisolated enum AgentWakeError: Error, LocalizedError, Equatable {
    case badTime(String)
    case notFuture
    case tooFar(Int)
    case tooMany(Int)
    case emptyNote
    case notFound
    var errorDescription: String? {
        switch self {
        case let .badTime(s): "看不懂时间「\(s)」：用带时区的 ISO 8601，如 2026-10-26T12:30:00-04:00"
        case .notFuture: "这个时间已经过了：定一个以后的时刻"
        case let .tooFar(d): "最多约 \(d) 天以内的时刻；更远的事进待办"
        case let .tooMany(n): "已经约了 \(n) 个还没到的时刻：先取消不需要的（cancel = id）"
        case .emptyNote: "要写清到点做什么（note）"
        case .notFound: "没找到这个还没到的约定（可能已经叫醒过或取消了）"
        }
    }
}

@MainActor final class AgentWakeSchedule {
    static let key = "agent.scheduledWakes.v1"
    static let maxPending = 20
    static let maxDaysAhead = 7
    /// iPhone / iPad 到点后再等多久（给 Mac 先叫）。
    static let nonMacGrace: TimeInterval = 120
    static let maxLate: TimeInterval = 12 * 3600
    /// 已叫醒 / 取消 / 错过的留几天（给智能体回看），之后清掉。
    static let keepDone: TimeInterval = 2 * 86400

    nonisolated struct Stored: Codable, Equatable { var updatedAt: Date; var wakes: [AgentScheduledWake] }

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
    }

    var all: [AgentScheduledWake] { Self.decode(defaults.string(forKey: Self.key))?.wakes ?? [] }
    var pending: [AgentScheduledWake] { all.filter(\.isPending).sorted { $0.at < $1.at } }

    @discardableResult
    func add(at: Date, note: String, by: String) throws -> AgentScheduledWake {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentWakeError.emptyNote }
        let t = now()
        guard at > t else { throw AgentWakeError.notFuture }
        guard at.timeIntervalSince(t) <= Double(Self.maxDaysAhead) * 86400 else { throw AgentWakeError.tooFar(Self.maxDaysAhead) }
        let open = pending
        guard open.count < Self.maxPending else { throw AgentWakeError.tooMany(open.count) }
        let w = AgentScheduledWake(id: UUID(), at: at, note: String(text.prefix(500)), createdAt: t, createdBy: by)
        save(all + [w])
        return w
    }

    func cancel(_ id: UUID) throws {
        var list = all
        guard let i = list.firstIndex(where: { $0.id == id && $0.isPending }) else { throw AgentWakeError.notFound }
        list[i].cancelledAt = now()
        save(list)
    }

    /// 该由这台叫醒的（到点、还没人叫）。迟到超过 maxLate 的标成错过（不叫），一并返回给调用方记日志。
    func takeDue(isMac: Bool, by device: String) -> (fire: [AgentScheduledWake], missed: [AgentScheduledWake]) {
        let t = now()
        var list = all, fire: [AgentScheduledWake] = [], missed: [AgentScheduledWake] = []
        for i in list.indices where list[i].isPending && list[i].at.addingTimeInterval(isMac ? 0 : Self.nonMacGrace) <= t {
            if t.timeIntervalSince(list[i].at) > Self.maxLate {
                list[i].missed = true; missed.append(list[i])
            } else {
                list[i].firedAt = t; list[i].firedBy = device; fire.append(list[i])
            }
        }
        if !fire.isEmpty || !missed.isEmpty { save(list) }
        return (fire, missed)
    }

    /// 给智能体看的：还没到的约定 + 最近叫醒 / 取消过的。
    func json() -> [[String: Any]] {
        let iso = ISO8601DateFormatter(); iso.timeZone = .current
        return all.sorted { $0.at < $1.at }.map { w in
            var o: [String: Any] = ["id": w.id.uuidString, "at": iso.string(from: w.at), "note": w.note,
                                    "state": w.isPending ? "pending" : w.cancelledAt != nil ? "cancelled" : w.missed == true ? "missed" : "fired"]
            if let f = w.firedAt { o["firedAt"] = iso.string(from: f) }
            return o
        }
    }

    private func save(_ list: [AgentScheduledWake]) {
        let t = now()
        let kept = list.filter { $0.isPending || t.timeIntervalSince($0.firedAt ?? $0.cancelledAt ?? $0.at) < Self.keepDone }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Stored(updatedAt: t, wakes: kept)) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key)   // String = plist 类型，可进 iCloud KV
    }

    nonisolated static func decode(_ raw: String?) -> Stored? {
        guard let raw else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(Stored.self, from: Data(raw.utf8))
    }

    /// 智能体给的时间：带时区的 ISO 8601（有无小数秒都行）；不带时区按本机时区。
    nonisolated static func parseTime(_ s: String) throws -> Date {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let f = ISO8601DateFormatter(); f.formatOptions = opts
            if let d = f.date(from: trimmed) { return d }
        }
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = fmt
            if let d = local.date(from: trimmed) { return d }
        }
        throw AgentWakeError.badTime(s)
    }
}
