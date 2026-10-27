//
//  ActivitySignature.swift
//  BetterCalendar
//
//  0.79 W49（Jason 10-26：哨兵只会「到点提醒」，不会看接入的数据判断我有没有开始 / 结束某件事）：
//  计划块 ↔ 设备活动的对应关系。10 月决策日志实锤：活动类信号（像是开始了 / 做完了）从没过线，根因之一是摘要里
//  「14:00–16:00 写 BetterCalendar：没见开始迹象」和「各 App 前台：Xcode 25 分」互不相干——模型没有「这块通常在哪个 App 里做」的知识。
//  · 活动画像（ActivityProfile）= 一段时间里 Mac 各前台 App 的时长占比 + 浏览器域名占比。
//  · 每条实际记录（计时结束 / 补记）都是现成的标注样本：读那段时间的活动 → 并进这个标题的签名（EWMA，不建新 schema）。
//  · 匹配 = 两份画像的直方图交集（0–1）：最近 10 分钟的活动像不像这块平时的样子。
//  · 冷启动：没学过的标题按分词借同族标题的签名（「写 BetterCalendar」借「BetterCalendar 发版」），借来的也标明。
//  · 只在 Mac 有意义（iPhone 只有 App 打开次数，不进画像）；签名存本机容器 JSON，不同步。
//  · 拒绝的推断补记回流：那段活动按负样本减权（见 ActivitySignatureStore.unlearn）。
//

import Foundation

nonisolated struct ActivityProfile: Codable, Equatable, Sendable {
    /// 前台 App → 时长占比（窗口内各 App 之和 ≤ 1；离开的时间不计入）。
    var apps: [String: Double] = [:]
    /// 浏览器域名 → 页数占比。
    var hosts: [String: Double] = [:]
    var samples = 0
    var minutes: Double = 0
    var updatedAt: Date?

    var isEmpty: Bool { apps.isEmpty }

    /// EWMA 步长：新样本占三成，老习惯慢慢让位。
    static let alpha = 0.3
    /// 一段时间里 Mac 前台时长至少占这个比例才算「这段时间在用 Mac」（否则是在手机 / 外出 / 睡觉，学了只会污染签名）。
    static let minForegroundShare = 0.5

    /// 从活动记录里取一段时间的画像；Mac 前台时长不够（没在用电脑）→ nil。
    static func sample(_ events: [ActivityEvent], interval: DateInterval, now: Date) -> ActivityProfile? {
        guard interval.duration > 0 else { return nil }
        let s = SentinelActivitySummary.summarize(events, window: interval, now: min(now, interval.end))
        let total = s.appSeconds.reduce(0) { $0 + $1.seconds }
        guard total >= interval.duration * minForegroundShare, total > 0 else { return nil }
        var p = ActivityProfile(samples: 1, minutes: interval.duration / 60)
        for a in s.appSeconds { p.apps[a.name] = a.seconds / total }
        let pages = s.hosts.reduce(0) { $0 + $1.count }
        if pages > 0 { for h in s.hosts { p.hosts[h.host] = Double(h.count) / Double(pages) } }
        return p
    }

    /// 直方图交集：Σ min(占比)。App 占八成权重；两边都有域名时域名占两成。
    func match(_ other: ActivityProfile) -> Double {
        guard !apps.isEmpty, !other.apps.isEmpty else { return 0 }
        let a = apps.reduce(0.0) { $0 + min($1.value, other.apps[$1.key] ?? 0) }
        guard !hosts.isEmpty, !other.hosts.isEmpty else { return min(1, a) }
        let h = hosts.reduce(0.0) { $0 + min($1.value, other.hosts[$1.key] ?? 0) }
        return min(1, a * 0.8 + h * 0.2)
    }

    /// 并入一个样本：第一次照抄；之后 EWMA。负样本（推断被拒）按同样步长减权，不低于 0。
    mutating func learn(_ s: ActivityProfile, positive: Bool = true, at: Date) {
        if positive, samples == 0 {
            apps = s.apps; hosts = s.hosts
        } else {
            let sign: Double = positive ? 1 : -1
            let alpha = Self.alpha
            func merge(_ mine: [String: Double], _ theirs: [String: Double]) -> [String: Double] {
                var out: [String: Double] = [:]
                for k in Set(mine.keys).union(theirs.keys) {
                    let v = (mine[k] ?? 0) * (positive ? 1 - alpha : 1) + sign * alpha * (theirs[k] ?? 0)
                    if v > 0.005 { out[k] = v }
                }
                return out
            }
            apps = merge(apps, s.apps); hosts = merge(hosts, s.hosts)
        }
        samples += positive ? 1 : 0
        minutes += positive ? s.minutes : 0
        updatedAt = at
    }
}

/// 一个标题的签名查找结果：学过的，或从同族标题借来的（摘要里写明）。
nonisolated struct ActivitySignatureHit: Equatable, Sendable {
    var profile: ActivityProfile
    /// 借自哪个标题（nil = 这个标题自己学的）。
    var borrowedFrom: String?
}

@MainActor final class ActivitySignatureStore {
    nonisolated struct Stored: Codable, Equatable { var profiles: [String: ActivityProfile] = [:]; var learned: [String] = [] }

    static let fileName = "activity-signatures.json"
    static let maxLearned = 500
    /// 短于这个的实际记录不学（学不出习惯，还会把误触计时学进去）。
    static let minSampleMinutes: Double = 10
    /// 实际记录结束超过这么久的不再补学（启动时别把三天前的全扫一遍）。
    static let learnWindow: TimeInterval = 36 * 3600

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterCalendarSentinel", isDirectory: true)
    }

    let file: URL
    private(set) var stored = Stored()

    init(directory: URL? = nil) {
        file = (directory ?? Self.defaultDirectory).appendingPathComponent(Self.fileName)
        if let data = try? Data(contentsOf: file) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            stored = (try? d.decode(Stored.self, from: data)) ?? Stored()
        }
    }

    var profiles: [String: ActivityProfile] { stored.profiles }

    nonisolated static func key(_ title: String) -> String { title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    nonisolated static func sampleKey(title: String, interval: DateInterval) -> String {
        "\(key(title))|\(Int(interval.start.timeIntervalSince1970))|\(Int(interval.end.timeIntervalSince1970))"
    }

    /// 分词：空白 / 标点切开，连续汉字按整段再按双字切，长度 ≥ 2 的英文 / 数字串原样；用于冷启动借签名。
    nonisolated static func tokens(_ title: String) -> Set<String> {
        var out = Set<String>()
        var latin = "", han = ""
        func flushLatin() { if latin.count >= 2 { out.insert(latin.lowercased()) }; latin = "" }
        func flushHan() {
            if han.count >= 2 {
                let chars = Array(han)
                for i in 0 ..< chars.count - 1 { out.insert(String(chars[i ... i + 1])) }
            }
            han = ""
        }
        for ch in title {
            if ch.isLetter, let s = ch.unicodeScalars.first, s.value >= 0x4E00, s.value <= 0x9FFF {
                flushLatin(); han.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushHan(); latin.append(ch)
            } else {
                flushLatin(); flushHan()
            }
        }
        flushLatin(); flushHan()
        return out
    }

    /// 这个标题的签名：自己学过的优先；否则借分词重合最多（≥ 一半）的同族标题。
    func signature(for title: String) -> ActivitySignatureHit? {
        let k = Self.key(title)
        if let p = stored.profiles[k], !p.isEmpty { return ActivitySignatureHit(profile: p) }
        let mine = Self.tokens(title)
        guard !mine.isEmpty else { return nil }
        var best: (key: String, score: Double)?
        for (other, p) in stored.profiles where !p.isEmpty {
            let theirs = Self.tokens(other)
            guard !theirs.isEmpty else { continue }
            let score = Double(mine.intersection(theirs).count) / Double(min(mine.count, theirs.count))
            if score >= 0.5, score > (best?.score ?? 0) { best = (other, score) }
        }
        guard let best, let p = stored.profiles[best.key] else { return nil }
        return ActivitySignatureHit(profile: p, borrowedFrom: best.key)
    }

    /// 一条实际记录 = 一个正样本（幂等：同一条只学一次）。返回是否真的学了。
    @discardableResult
    func learn(title: String, interval: DateInterval, events: [ActivityEvent], now: Date) -> Bool {
        let sk = Self.sampleKey(title: title, interval: interval)
        guard !stored.learned.contains(sk), interval.duration >= Self.minSampleMinutes * 60 else { return false }
        stored.learned.append(sk)
        if stored.learned.count > Self.maxLearned { stored.learned.removeFirst(stored.learned.count - Self.maxLearned) }
        defer { save() }
        guard let s = ActivityProfile.sample(events, interval: interval, now: now) else { return false }
        var p = stored.profiles[Self.key(title)] ?? ActivityProfile()
        p.learn(s, at: now)
        stored.profiles[Self.key(title)] = p
        return true
    }

    /// 推断出来的补记被拒 → 那段活动对这个标题是负样本。
    func unlearn(title: String, interval: DateInterval, events: [ActivityEvent], now: Date) {
        guard var p = stored.profiles[Self.key(title)], let s = ActivityProfile.sample(events, interval: interval, now: now) else { return }
        p.learn(s, positive: false, at: now)
        stored.profiles[Self.key(title)] = p
        save()
    }

    func hasLearned(title: String, interval: DateInterval) -> Bool {
        stored.learned.contains(Self.sampleKey(title: title, interval: interval))
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
            try e.encode(stored).write(to: file, options: .atomic)
        } catch {
            DevLog.shared.warn("哨兵", "活动签名写入失败：\(error.localizedDescription)")
        }
    }
}
