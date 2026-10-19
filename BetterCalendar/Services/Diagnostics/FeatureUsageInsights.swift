//
//  FeatureUsageInsights.swift
//  BetterCalendar
//
//  W21 功能使用探针的汇总与解读层（纯函数、可解释）：
//    - FeatureUsageAggregator：记录 → 每个功能的计数（今天 / 近 7 天 / 近 30 天 / 保留期）、出现天数、使用天数、
//      首次看见 / 首次用 / 最后用（里程碑兜底）、没做完的比例；
//    - FeatureUsageInterpreter：模式 → 假设，每条带一行「证据」（背后的数字）：
//        从没出现过        → 可能不知道有这个功能
//        出现过、从没用过  → 不需要 / 不感兴趣
//        用过几次、后来停了 → 试过但没留下
//        没做完的比例高    → 可能不会用 / 不好用
//        常被撤销          → 结果不合预期
//        常出错            → 多半是技术问题（先修它）
//      假设只是给智能体和 Jason 的线索，不是结论；措辞中性，不出现「你从没…」（羞辱铁律）。
//    - FeatureUsageExport：context.json 的精简段 + bridge/usage.json 的完整汇总（写前校验桥接目录 CHANNEL）。
//

import Foundation

/// 「让智能体参考功能使用」开关（W17 新功能约定：日用版默认关、Dev 版默认开；随设置同步）。
/// 关着：context.json 只写一句「未开启」，不写 bridge/usage.json；本机记录照常（只在本机、用户看不到任何变化）。
nonisolated enum FeatureUsageSettings {
    static let shareKey = "featureUsage.shareWithAgent.enabled"
    static var shareWithAgent: Bool {
        get { ExperimentDefaults.newFeature(shareKey) }
        set { UserDefaults.standard.set(newValue, forKey: shareKey) }
    }
}

nonisolated struct FeatureStats: Equatable, Sendable {
    let id: FeatureID
    var total: [UsageEvent: Int] = [:]      // 保留期内
    var today: [UsageEvent: Int] = [:]
    var week: [UsageEvent: Int] = [:]       // 近 7 个逻辑日（含今天）
    var month: [UsageEvent: Int] = [:]      // 近 30 个逻辑日（含今天）
    var seenDays = 0                        // 保留期内出现过的逻辑日数
    var usedDays = 0
    var perDay: [String: [UsageEvent: Int]] = [:]   // 逻辑日 → 计数（近 14 天，给开发者页看）
    var bySurface: [String: Int] = [:]      // used 按界面（detail）分（近 30 天）
    var marks = FeatureMarks()

    func count(_ e: UsageEvent, in window: KeyPath<FeatureStats, [UsageEvent: Int]>) -> Int { self[keyPath: window][e] ?? 0 }
    var usedLifetime: Int { max(marks.usedLifetime, total[.used] ?? 0) }
    /// 近 30 天「开了头没做完」的比例（没做完 /（做完 + 没做完））；没有开头记录 → nil。
    var abandonRatio: Double? {
        let a = month[.abandoned] ?? 0, u = month[.used] ?? 0
        guard a + u > 0 else { return nil }
        return Double(a) / Double(a + u)
    }
}

nonisolated struct FeatureUsageReport: Sendable {
    var now: Date
    var trackingSince: Date?
    var stats: [FeatureID: FeatureStats]
    var trackingDays: Int {
        guard let s = trackingSince else { return 0 }
        return max(0, Calendar.current.dateComponents([.day], from: DayContext.logicalStartOfDay(s),
                                                      to: DayContext.logicalStartOfDay(now)).day ?? 0) + 1
    }
}

nonisolated enum FeatureUsageAggregator {
    static func report(records: [UsageRecord], marks: [FeatureID: FeatureMarks], trackingSince: Date?, now: Date) -> FeatureUsageReport {
        let cal = Calendar.current
        let todayStart = DayContext.logicalStartOfDay(now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let monthStart = cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        let perDayStart = cal.date(byAdding: .day, value: -13, to: todayStart) ?? todayStart
        var stats: [FeatureID: FeatureStats] = [:]
        for f in FeatureID.allCases { stats[f] = FeatureStats(id: f, marks: marks[f] ?? FeatureMarks()) }
        var seenDays: [FeatureID: Set<String>] = [:], usedDays: [FeatureID: Set<String>] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX"); dayFormatter.dateFormat = "yyyy-MM-dd"
        for r in records {
            guard let f = r.feature, r.at <= now.addingTimeInterval(60) else { continue }
            let dayStart = DayContext.logicalStartOfDay(r.at)
            let day = dayFormatter.string(from: dayStart)
            var s = stats[f]!
            s.total[r.e, default: 0] += 1
            if dayStart == todayStart { s.today[r.e, default: 0] += 1 }
            if dayStart >= weekStart { s.week[r.e, default: 0] += 1 }
            if dayStart >= monthStart {
                s.month[r.e, default: 0] += 1
                if r.e == .used { s.bySurface[r.d ?? "—", default: 0] += 1 }
            }
            if dayStart >= perDayStart { s.perDay[day, default: [:]][r.e, default: 0] += 1 }
            // 里程碑兜底（UserDefaults 里没有时用记录补）
            switch r.e {
            case .seen:
                seenDays[f, default: []].insert(day)
                if s.marks.firstSeen.map({ r.at < $0 }) ?? true { s.marks.firstSeen = r.at }
                if s.marks.lastSeen.map({ r.at > $0 }) ?? true { s.marks.lastSeen = r.at }
            case .used:
                usedDays[f, default: []].insert(day)
                if s.marks.firstUsed.map({ r.at < $0 }) ?? true { s.marks.firstUsed = r.at }
                if s.marks.lastUsed.map({ r.at > $0 }) ?? true { s.marks.lastUsed = r.at }
            default: break
            }
            stats[f] = s
        }
        for (f, d) in seenDays { stats[f]?.seenDays = d.count }
        for (f, d) in usedDays { stats[f]?.usedDays = d.count }
        let since = trackingSince ?? records.map(\.at).min()
        return FeatureUsageReport(now: now, trackingSince: since, stats: stats)
    }
}

/// 一条假设（模式 → 可能的原因 + 证据）。
nonisolated struct FeatureHypothesis: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case neverSeen, seenNotUsed, triedNotKept, hardToUse, unexpectedResult, oftenFails
        /// 假设的话（中性；给智能体与 Jason 的线索，不是结论）。
        var text: String {
            switch self {
            case .neverSeen: "可能不知道有这个功能"
            case .seenNotUsed: "不需要 / 不感兴趣"
            case .triedNotKept: "试过但没留下"
            case .hardToUse: "可能不会用 / 不好用"
            case .unexpectedResult: "结果不合预期"
            case .oftenFails: "常出错——多半是技术问题，先修它，不算使用习惯"
            }
        }
    }
    var feature: FeatureID
    var kind: Kind
    var evidence: String
    var text: String { kind.text }
}

nonisolated enum FeatureUsageInterpreter {
    /// 阈值（解释得清的整数，改动请同步给智能体的用法说明）。
    static let minTrackingDaysForNeverSeen = 7
    static let seenDaysForNotInterested = 3
    static let triedMaxUses = 5
    static let triedQuietDays = 14
    static let minAttemptsForHardToUse = 3
    static let minUndoneForUnexpected = 2
    static let minFailedForOftenFails = 3

    /// 每个功能至多一条（最具体的优先：出错 > 撤销 > 没做完 > 试过没留下 > 看见没用 > 没看见）。
    static func hypotheses(_ report: FeatureUsageReport) -> [FeatureHypothesis] {
        var out: [FeatureHypothesis] = []
        for f in FeatureID.allCases {
            guard let s = report.stats[f] else { continue }
            if let h = hypothesis(f, s, report: report) { out.append(h) }
        }
        return out
    }

    static func hypothesis(_ f: FeatureID, _ s: FeatureStats, report: FeatureUsageReport) -> FeatureHypothesis? {
        let used30 = s.month[.used] ?? 0, abandoned30 = s.month[.abandoned] ?? 0
        let undone30 = s.month[.undone] ?? 0, failed30 = s.month[.failed] ?? 0
        if failed30 >= minFailedForOftenFails, failed30 >= used30 {
            return .init(feature: f, kind: .oftenFails, evidence: "近 30 天出错 \(failed30) 次、成功用过 \(used30) 次")
        }
        if undone30 >= minUndoneForUnexpected, f.isAutomatic || used30 == 0 || undone30 * 10 >= used30 * 3 {
            let base = f.isAutomatic ? "近 30 天被你撤销 \(undone30) 次" : "近 30 天用过 \(used30) 次、其中结果被撤销 \(undone30) 次"
            return .init(feature: f, kind: .unexpectedResult, evidence: base)
        }
        if abandoned30 + used30 >= minAttemptsForHardToUse, abandoned30 * 2 >= abandoned30 + used30 {
            return .init(feature: f, kind: .hardToUse,
                         evidence: "近 30 天开了头 \(abandoned30 + used30) 次、没做完 \(abandoned30) 次（\(Int((Double(abandoned30) / Double(abandoned30 + used30) * 100).rounded()))%）")
        }
        guard !f.isAutomatic else { return nil }
        let lifetime = s.usedLifetime
        if (1...triedMaxUses).contains(lifetime), let last = s.marks.lastUsed,
           let quiet = Calendar.current.dateComponents([.day], from: DayContext.logicalStartOfDay(last),
                                                          to: DayContext.logicalStartOfDay(report.now)).day, quiet >= triedQuietDays {
            return .init(feature: f, kind: .triedNotKept, evidence: "一共用过 \(lifetime) 次，最近一次在 \(quiet) 天前")
        }
        guard lifetime == 0 else { return nil }
        let since = "开始统计 \(report.trackingDays) 天"
        switch f.exposure {
        case .direct:
            if !f.isSurface, s.seenDays >= seenDaysForNotInterested {
                return .init(feature: f, kind: .seenNotUsed, evidence: "\(since)；出现过 \(s.seenDays) 天、用过 0 次")
            }
            if s.seenDays == 0, report.trackingDays >= minTrackingDaysForNeverSeen {
                return .init(feature: f, kind: .neverSeen, evidence: "\(since)；没出现在眼前过、用过 0 次")
            }
        case let .onPage(parent):
            let ps = report.stats[parent]?.seenDays ?? 0
            if ps >= seenDaysForNotInterested {
                return .init(feature: f, kind: .seenNotUsed, evidence: "\(since)；所在的「\(parent.label)」打开过 \(ps) 天、它用过 0 次")
            }
        case let .inMenu(parent):
            let ps = report.stats[parent]?.seenDays ?? 0
            if ps >= seenDaysForNotInterested, report.trackingDays >= minTrackingDaysForNeverSeen {
                return .init(feature: f, kind: .neverSeen,
                             evidence: "\(since)；它收在「\(parent.label)」的菜单 / 折叠区里，那里出现过 \(ps) 天、它用过 0 次")
            }
        case let .gesture(parent):
            let ps = report.stats[parent]?.seenDays ?? 0
            if ps >= seenDaysForNotInterested, report.trackingDays >= minTrackingDaysForNeverSeen {
                return .init(feature: f, kind: .neverSeen,
                             evidence: "\(since)；它是「\(parent.label)」上的手势（没有按钮），那里出现过 \(ps) 天、它用过 0 次")
            }
        case .none:
            break   // 没有「看见」这回事：不推断「不知道 / 不需要」
        }
        return nil
    }
}

nonisolated enum FeatureUsageExport {
    static let contextMostUsed = 8
    static let contextHypotheses = 10
    static let bridgeFile = "usage.json"

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = .current; return f.string(from: d)
    }
    private static func opt(_ d: Date?) -> Any { d.map(iso) ?? NSNull() }

    static func hypothesisJSON(_ h: FeatureHypothesis) -> [String: Any] {
        ["id": h.feature.rawValue, "label": h.feature.label, "kind": h.kind.rawValue, "hypothesis": h.text, "evidence": h.evidence]
    }

    static let guidance = "只在合适时偶尔用一次、以提议的口吻（「要不要试试 X，可以……」），可被忽略、不追问、不复读；绝不说「你从没用过 X」这类话；假设只是线索，不是结论。完整说明见智能体用法文档。"

    /// context.json 的 featureUsage 段（精简）。enabled = false → 只写一句未开启。
    static func contextSection(_ report: FeatureUsageReport, enabled: Bool) -> [String: Any] {
        let asOf = iso(report.now)
        guard enabled else {
            return ["included": false, "source": "BetterCalendar 功能使用探针", "asOf": asOf,
                    "note": "Jason 没打开「让智能体参考功能使用」（设置 → 智能体），这里不提供使用统计"]
        }
        let used = report.stats.values.filter { !$0.id.isAutomatic && ($0.month[.used] ?? 0) > 0 }
            .sorted { ($0.month[.used] ?? 0, $1.id.rawValue) > ($1.month[.used] ?? 0, $0.id.rawValue) }
        let hyps = FeatureUsageInterpreter.hypotheses(report)
        return [
            "included": true,
            "source": "BetterCalendar 功能使用探针（只记哪个功能、什么事件；本机记录，不上传）", "asOf": asOf,
            "trackingSince": opt(report.trackingSince), "trackingDays": report.trackingDays, "windowDays": 30,
            "mostUsed": used.prefix(contextMostUsed).map { s -> [String: Any] in
                ["id": s.id.rawValue, "label": s.id.label, "used7d": s.week[.used] ?? 0, "used30d": s.month[.used] ?? 0]
            },
            "hypotheses": hyps.prefix(contextHypotheses).map(hypothesisJSON),
            "hypothesesTotal": hyps.count, "truncated": hyps.count > contextHypotheses,
            "full": "bridge/\(bridgeFile)（全部功能的计数与假设）",
            "howToUse": guidance,
        ]
    }

    /// bridge/usage.json 的完整汇总。内容只随记录 / 日期变化（不含写入时刻），方便「没变就不重写」。
    static func bridgeSummary(_ report: FeatureUsageReport, channel: AppChannel) -> [String: Any] {
        let dayKey = DayContext.dayKey(report.now)
        let rows = FeatureID.allCases.compactMap { f -> [String: Any]? in
            guard let s = report.stats[f] else { return nil }
            var row: [String: Any] = [
                "id": f.rawValue, "label": f.label, "area": f.area,
                "seen7d": s.week[.seen] ?? 0, "used7d": s.week[.used] ?? 0, "used30d": s.month[.used] ?? 0,
                "abandoned30d": s.month[.abandoned] ?? 0, "undone30d": s.month[.undone] ?? 0, "failed30d": s.month[.failed] ?? 0,
                "seenDays": s.seenDays, "usedDays": s.usedDays, "usedLifetime": s.usedLifetime,
                "firstSeen": opt(s.marks.firstSeen), "firstUsed": opt(s.marks.firstUsed), "lastUsed": opt(s.marks.lastUsed),
                "abandonRatio": s.abandonRatio.map { ($0 * 100).rounded() / 100 } ?? NSNull(),
            ]
            if !s.bySurface.isEmpty { row["usedBySurface30d"] = s.bySurface }
            return row
        }
        return [
            "schemaVersion": 1, "channel": channel.rawValue, "day": dayKey,
            "source": "BetterCalendar 功能使用探针（只记哪个功能、什么事件；本机记录，不上传）",
            "trackingSince": opt(report.trackingSince), "trackingDays": report.trackingDays,
            "privacy": "不含任何标题、正文、App 或网站名；detail 只有界面名 / 设置值",
            "howToUse": guidance,
            "features": rows,
            "hypotheses": FeatureUsageInterpreter.hypotheses(report).map(hypothesisJSON),
        ]
    }

    /// 写 bridge/usage.json：桥接目录通道与本 App 不符 → 不写、抛错（W17：两套数据绝不混）；内容没变 → 不重写。
    /// 返回是否真的写了。
    @discardableResult
    static func writeBridge(_ report: FeatureUsageReport, io: AgentBridgeIO, channel: AppChannel = .current) throws -> Bool {
        if let mismatch = channel.bridgeMismatch(io.root) { throw AgentBridgeError.invalid(mismatch) }
        let data = try SafeJSON.data(withJSONObject: bridgeSummary(report, channel: channel), options: [.prettyPrinted, .sortedKeys])
        let url = io.root.appendingPathComponent(bridgeFile)
        if (try? Data(contentsOf: url)) == data { return false }
        try io.writeAtomic(data, to: bridgeFile)
        return true
    }
}

/// 汇总缓存（context.json 每 20 秒重写一次；记录没变、日子没变就复用）。
nonisolated final class FeatureUsageReporter: @unchecked Sendable {
    private let store: FeatureUsageStore
    private let lock = NSLock()
    private var cached: (version: Int, day: String, report: FeatureUsageReport)?

    init(store: FeatureUsageStore) { self.store = store }

    func report(now: Date) -> FeatureUsageReport {
        store.sweepStaleAttempts()
        let day = DayContext.dayKey(now)
        lock.lock(); defer { lock.unlock() }
        let version = store.currentVersion()
        if let c = cached, c.version == version, c.day == day { var r = c.report; r.now = now; return r }
        let r = FeatureUsageAggregator.report(records: store.records(), marks: store.marks(), trackingSince: store.trackingSince(), now: now)
        cached = (version, day, r)
        return r
    }

    static let shared = FeatureUsageReporter(store: FeatureUsage.shared)
}

/// Mac：每轮桥接同步时把汇总写进 bridge/usage.json（AgentBridge.usageMirror 调）。
/// 开关关着 → 不写，且删掉以前写过的那份（关了 = 智能体看不到）；通道不符 → 不写、醒目报错（同一原因只记一次）。
@MainActor final class FeatureUsageBridgeMirror {
    static let shared = FeatureUsageBridgeMirror(reporter: .shared)

    private let reporter: FeatureUsageReporter
    var enabled: () -> Bool = { FeatureUsageSettings.shareWithAgent }
    var channel: AppChannel = .current
    var now: () -> Date = Date.init
    private(set) var lastError: String?

    init(reporter: FeatureUsageReporter) { self.reporter = reporter }

    func mirror(to io: AgentBridgeIO) {
        do {
            if enabled() {
                try FeatureUsageExport.writeBridge(reporter.report(now: now()), io: io, channel: channel)
            } else {
                let url = io.root.appendingPathComponent(FeatureUsageExport.bridgeFile)
                if channel.bridgeMismatch(io.root) == nil, FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            lastError = nil
        } catch {
            let text = "功能使用汇总没写进桥接目录：\(error.localizedDescription)"
            if lastError != text { lastError = text; DevLog.shared.error("功能使用", text) }
        }
    }
}
