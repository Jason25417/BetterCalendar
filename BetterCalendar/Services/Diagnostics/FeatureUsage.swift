//
//  FeatureUsage.swift
//  BetterCalendar
//
//  W21 功能使用探针：每个用户看得见的功能（登记表见 FeatureRegistry）统一一个调用口：
//      FeatureUsage.record(.proposalApprove, .used)
//  五种事件：seen（出现在眼前，节流）/ used（用了）/ abandoned（开了头没做完）/ undone（结果被撤销）/ failed（出错）。
//  「开了头没做完」用 begin → complete / abandonIfOpen 成对追踪（例：展开「回一句」没发就收起、调了数值没批准）。
//
//  隐私：**只存本机、绝不上传**（与 BehaviorLog 同口径）。只记「哪个功能、什么事件、在哪个界面」，
//  detail 只放界面名 / 设置值这类短标签，**绝不放标题、正文、App 或网站名**（羞辱铁律：用法永不变成评判）。
//  Mac 端另把一份**汇总**写进智能体桥接目录（bridge/usage.json，经 CHANNEL 校验；见 FeatureUsageInsights.swift），
//  由「让智能体参考功能使用」开关控制（W17 新功能约定：日用版默认关）。
//
//  存储：App 容器 Application Support/BetterCalendar/feature-usage/<逻辑日>.jsonl（按天一个文件、追加写、坏行跳过），
//  保留 120 天（过期整文件删）。首次看见 / 首次用 / 最后用 / 累计用这几个「里程碑」另存 UserDefaults
//  （只用 plist 类型 [String: Double]），过了保留期也不丢。测试宿主里 shared 不写任何东西（单测各自建实例）。
//

import Foundation

nonisolated enum UsageEvent: String, CaseIterable, Codable, Sendable {
    case seen, used, abandoned, undone, failed

    var label: String {
        switch self {
        case .seen: "看见"
        case .used: "用过"
        case .abandoned: "没做完"
        case .undone: "撤销"
        case .failed: "出错"
        }
    }
}

/// 一行记录（JSONL）。字段名短：一天可能几百行。
nonisolated struct UsageRecord: Codable, Equatable, Sendable {
    var at: Date
    var f: String
    var e: UsageEvent
    var d: String?

    var feature: FeatureID? { FeatureID(rawValue: f) }
}

/// 过了保留期也要留住的里程碑（UserDefaults，plist 类型）。
nonisolated struct FeatureMarks: Equatable, Sendable {
    var firstSeen: Date?
    var lastSeen: Date?
    var firstUsed: Date?
    var lastUsed: Date?
    var usedLifetime = 0
}

nonisolated final class FeatureUsageStore: @unchecked Sendable {
    static let retentionDays = 120
    /// seen 节流：同一功能 30 分钟内只记一次（每次渲染都触发的信号不刷屏）。
    static let seenThrottle: TimeInterval = 30 * 60
    /// 开了头超过这么久还没做完 → 下次汇总时记为 abandoned。
    static let staleAttempt: TimeInterval = 6 * 3600
    static let detailMaxChars = 40
    static let marksKey = "featureUsage.marks.v1"
    static let trackingSinceKey = "featureUsage.trackingSince"

    static var defaultRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BetterCalendar", isDirectory: true)
            .appendingPathComponent("feature-usage", isDirectory: true)
    }

    private let root: URL?
    private let defaults: UserDefaults?
    private let now: @Sendable () -> Date
    private let enabled: Bool
    /// 写文件失败时的回调（生产：DevLog 警告，失败可见；只报第一次）。
    var onWriteError: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var loaded = false
    private var cache: [UsageRecord] = []
    private var lastSeenAt: [String: Date] = [:]
    private var openAttempts: [String: Date] = [:]
    private var reportedWriteError = false
    private var lastPruneDay: String?
    /// 每次有新记录 +1（汇总缓存据此失效）。
    private var version = 0
    func currentVersion() -> Int { lock.lock(); defer { lock.unlock() }; return version }

    /// root = nil → 只在内存里（不落盘）；defaults = nil → 里程碑只在内存里；enabled = false → 什么都不记（测试宿主的 shared）。
    init(root: URL?, defaults: UserDefaults?, now: @escaping @Sendable () -> Date = { Date() }, enabled: Bool = true) {
        self.root = root; self.defaults = defaults; self.now = now; self.enabled = enabled
    }

    // MARK: 记录

    /// 记一条。seen 自动节流；throttle 非 nil 时对其它事件也按「同功能同事件」节流（例：打字时的 used）。
    func record(_ f: FeatureID, _ e: UsageEvent, detail: String? = nil, throttle: TimeInterval? = nil) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        appendLocked(f, e, detail: detail, throttle: throttle ?? (e == .seen ? Self.seenThrottle : nil))
    }

    /// 开了个头（展开输入框、开始调数值）。同一 key 已开着就不重复记。
    func begin(_ f: FeatureID, key: String = "") {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        let k = attemptKey(f, key)
        if openAttempts[k] == nil { openAttempts[k] = now() }
    }

    /// 做完了：记 used，关掉对应的开头（没 begin 过也照记 used——used 是主信号）。
    func complete(_ f: FeatureID, key: String = "", detail: String? = nil) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        openAttempts.removeValue(forKey: attemptKey(f, key))
        appendLocked(f, .used, detail: detail, throttle: nil)
    }

    /// 收起 / 放弃：开着的开头 → 记 abandoned；没开着 → 什么都不记。返回是否记了。
    @discardableResult
    func abandonIfOpen(_ f: FeatureID, key: String = "", detail: String? = nil) -> Bool {
        guard enabled else { return false }
        lock.lock(); defer { lock.unlock() }
        guard openAttempts.removeValue(forKey: attemptKey(f, key)) != nil else { return false }
        appendLocked(f, .abandoned, detail: detail, throttle: nil)
        return true
    }

    /// 关掉开头但什么都不记（调用方稍后自己记结果）。返回之前是否开着。
    @discardableResult
    func end(_ f: FeatureID, key: String = "") -> Bool {
        guard enabled else { return false }
        lock.lock(); defer { lock.unlock() }
        return openAttempts.removeValue(forKey: attemptKey(f, key)) != nil
    }

    func isOpen(_ f: FeatureID, key: String = "") -> Bool {
        lock.lock(); defer { lock.unlock() }
        return openAttempts[attemptKey(f, key)] != nil
    }

    /// 某功能开着的开头里，key 以 prefix 开头的（例：某份提案的各个方案）。
    func openKeys(_ f: FeatureID) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let p = f.rawValue + "|"
        return openAttempts.keys.filter { $0.hasPrefix(p) }.map { String($0.dropFirst(p.count)) }
    }

    /// 开了头超过 staleAttempt 还没做完 → 记 abandoned（汇总前调用）。
    func sweepStaleAttempts() {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        let t = now()
        for (k, started) in openAttempts where t.timeIntervalSince(started) >= Self.staleAttempt {
            openAttempts.removeValue(forKey: k)
            if let f = FeatureID(rawValue: String(k.prefix { $0 != "|" })) {
                appendLocked(f, .abandoned, detail: "超时未完成", throttle: nil)
            }
        }
    }

    // MARK: 读

    /// 保留期内的全部记录（按时间）。
    func records() -> [UsageRecord] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeededLocked()
        return cache
    }

    func marks() -> [FeatureID: FeatureMarks] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeededLocked()
        return decodeMarks(rawMarksLocked())
    }

    /// 开始统计的时刻（第一次记录时写下）。
    func trackingSince() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return trackingSinceLocked()
    }

    // MARK: 保留期

    /// 删掉保留期之外的日文件与缓存。每天第一条记录时自动跑一次。
    func prune() {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
    }

    // MARK: 内部（调用方持锁）

    private var memoryMarks: [String: Double] = [:]
    private var memoryTrackingSince: Date?

    private func attemptKey(_ f: FeatureID, _ key: String) -> String { f.rawValue + "|" + key }

    private func appendLocked(_ f: FeatureID, _ e: UsageEvent, detail: String?, throttle: TimeInterval?) {
        loadIfNeededLocked()
        let t = now()
        if let throttle {
            let tk = f.rawValue + "|" + e.rawValue
            if let last = lastSeenAt[tk], t.timeIntervalSince(last) < throttle, t >= last { return }
            lastSeenAt[tk] = t
        }
        let d = detail.map { String($0.prefix(Self.detailMaxChars)) }.flatMap { $0.isEmpty ? nil : $0 }
        let rec = UsageRecord(at: t, f: f.rawValue, e: e, d: d)
        cache.append(rec)
        version += 1
        updateMarksLocked(f, e, at: t)
        let day = DayContext.dayKey(t)
        if lastPruneDay != day { lastPruneDay = day; pruneLocked() }
        writeLocked(rec, day: day)
    }

    private func writeLocked(_ rec: UsageRecord, day: String) {
        guard let root else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var data = try Self.encoder.encode(rec)
            data.append(0x0A)
            let url = root.appendingPathComponent(day + ".jsonl")
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            if !reportedWriteError {
                reportedWriteError = true
                onWriteError?("功能使用记录写入失败：\(error.localizedDescription)")
            }
        }
    }

    private func loadIfNeededLocked() {
        guard !loaded else { return }
        loaded = true
        guard let root, let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var out: [UsageRecord] = []
        for url in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let rec = try? Self.decoder.decode(UsageRecord.self, from: Data(line.utf8)) { out.append(rec) }
            }
        }
        cache = out.sorted { $0.at < $1.at } + cache
        for r in cache {
            let tk = r.f + "|" + r.e.rawValue
            if lastSeenAt[tk].map({ $0 < r.at }) ?? true { lastSeenAt[tk] = r.at }
        }
    }

    private func pruneLocked() {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: DayContext.logicalStartOfDay(now())) ?? .distantPast
        let cutoff = DayContext.dayKey(cutoffDate)
        cache.removeAll { DayContext.dayKey($0.at) < cutoff }
        guard let root, let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "jsonl" && url.deletingPathExtension().lastPathComponent < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func rawMarksLocked() -> [String: Double] {
        guard let defaults else { return memoryMarks }
        return defaults.dictionary(forKey: Self.marksKey) as? [String: Double] ?? [:]
    }

    private func updateMarksLocked(_ f: FeatureID, _ e: UsageEvent, at t: Date) {
        var m = rawMarksLocked()
        let ts = t.timeIntervalSince1970
        func setFirst(_ k: String) { if m[k] == nil { m[k] = ts } }
        switch e {
        case .seen: setFirst(f.rawValue + ".firstSeen"); m[f.rawValue + ".lastSeen"] = ts
        case .used:
            setFirst(f.rawValue + ".firstUsed"); m[f.rawValue + ".lastUsed"] = ts
            m[f.rawValue + ".usedLifetime", default: 0] += 1
        case .abandoned, .undone, .failed: break
        }
        if let defaults {
            defaults.set(m, forKey: Self.marksKey)   // [String: Double]：plist 类型
            if defaults.object(forKey: Self.trackingSinceKey) == nil { defaults.set(ts, forKey: Self.trackingSinceKey) }
        } else {
            memoryMarks = m
            if memoryTrackingSince == nil { memoryTrackingSince = t }
        }
    }

    private func trackingSinceLocked() -> Date? {
        guard let defaults else { return memoryTrackingSince }
        return (defaults.object(forKey: Self.trackingSinceKey) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    private func decodeMarks(_ raw: [String: Double]) -> [FeatureID: FeatureMarks] {
        var out: [FeatureID: FeatureMarks] = [:]
        for (k, v) in raw {
            guard let dot = k.lastIndex(of: "."), let f = FeatureID(rawValue: String(k[..<dot])) else { continue }
            let date = Date(timeIntervalSince1970: v)
            var m = out[f] ?? FeatureMarks()
            switch k[k.index(after: dot)...] {
            case "firstSeen": m.firstSeen = date
            case "lastSeen": m.lastSeen = date
            case "firstUsed": m.firstUsed = date
            case "lastUsed": m.lastUsed = date
            case "usedLifetime": m.usedLifetime = Int(v)
            default: break
            }
            out[f] = m
        }
        return out
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// 全 App 的调用口（转给 shared）。测试宿主里 shared 关闭——单测给要测的对象注入自己的 FeatureUsageStore。
nonisolated enum FeatureUsage {
    static let shared: FeatureUsageStore = {
        if TestHost.isActive { return FeatureUsageStore(root: nil, defaults: nil, enabled: false) }
        let store = FeatureUsageStore(root: FeatureUsageStore.defaultRoot, defaults: .standard)
        store.onWriteError = { message in Task { @MainActor in DevLog.shared.warn("功能使用", message) } }
        return store
    }()

    static func record(_ f: FeatureID, _ e: UsageEvent, _ detail: String? = nil) { shared.record(f, e, detail: detail) }
    static func seen(_ f: FeatureID, _ detail: String? = nil) { shared.record(f, .seen, detail: detail) }
    static func used(_ f: FeatureID, _ detail: String? = nil) { shared.record(f, .used, detail: detail) }
    /// 打字 / 连续拖滑块这类一次操作触发多次的 used：同功能 2 分钟内只记一次。
    static func usedThrottled(_ f: FeatureID, _ detail: String? = nil) { shared.record(f, .used, detail: detail, throttle: 120) }
    static func begin(_ f: FeatureID, key: String = "") { shared.begin(f, key: key) }
    static func complete(_ f: FeatureID, key: String = "", _ detail: String? = nil) { shared.complete(f, key: key, detail: detail) }
    static func abandonIfOpen(_ f: FeatureID, key: String = "") { shared.abandonIfOpen(f, key: key) }
}
