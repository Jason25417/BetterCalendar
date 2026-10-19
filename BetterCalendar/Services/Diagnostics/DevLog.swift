//
//  DevLog.swift
//  BetterCalendar
//
//  开发期集中日志：把任何层（含 service 里的静默回退）的失败显出来。
//  ⚠️ 这是**开发期**设施，与产品「正反馈优先 / 无感」原则有意冲突；当前以开发便利+稳定优先，上架前切回静默自愈。
//

import Foundation
import Observation

@Observable
final class DevLog {
    static let shared = DevLog()

    nonisolated enum Level: String, Sendable { case info, warning, error }

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let level: Level
        let source: String
        let message: String
        /// W16：这条该不该打扰你（IssueTriage 统一判；日志本身一条不少）。
        let verdict: IssueTriage.Verdict

        init(time: Date = Date(), level: Level, source: String, message: String) {
            self.time = time; self.level = level; self.source = source; self.message = message
            self.verdict = IssueTriage.classify(level: level, source: source, message: message)
        }
    }

    /// 同一类问题（verdict.key）的运行时状态：横幅 / 🐞 计数 / 升级 / 恢复都看它。
    struct IssueState: Equatable {
        let key: String
        let source: String
        var verdict: IssueTriage.Verdict
        var firstSeen: Date
        var lastSeen: Date
        var count: Int
        var lastMessage: String
        var lastLevel: Level
        /// 「知道了」：在这之后没有新的出现就不再横幅。
        var acknowledgedAt: Date?
    }

    /// 横幅要显示的内容（白话）。
    struct Surface: Equatable {
        let key: String
        let source: String
        let level: Level
        let text: String
        let action: String?
        let escalated: Bool
        let since: Date
        let count: Int
    }

    private(set) var entries: [Entry] = []
    /// 未恢复的问题（info 不进）。恢复 = resolve(source:) 或（无恢复信号的）quietDecay 内不再出现。
    private(set) var issues: [String: IssueState] = [:]
    /// 测试注入时钟（生产用真时间）。
    @ObservationIgnored var now: () -> Date = { Date() }

    /// 最近一条 警告/错误（保留给旧调用者；首页横幅改用 bannerIssue）。
    var lastIssue: Entry? { entries.last { $0.level != .info } }

    /// 外挂 sink（0.14：LogSyncService 收走进 CloudKit 跨端日志）。
    var onAppend: ((Entry) -> Void)?

    func log(_ level: Level, _ source: String, _ message: String) {
        let entry = Entry(time: now(), level: level, source: source, message: message)
        entries.append(entry)
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
        print("[\(level.rawValue.uppercased())] \(source): \(message)")  // 也进 Xcode 控制台
        track(entry)
        onAppend?(entry)
    }

    func info(_ source: String, _ message: String) { log(.info, source, message) }
    func warn(_ source: String, _ message: String) { log(.warning, source, message) }
    func error(_ source: String, _ message: String) { log(.error, source, message) }
    func clear() { entries.removeAll(); issues.removeAll() }

    // MARK: 分级与恢复（W16，SPEC §19.9 欠账① 中间步）

    private func track(_ e: Entry) {
        guard e.verdict.tier != .info else { return }
        let key = e.verdict.key
        if var s = issues[key], !isDecayed(s, at: e.time) {
            s.lastSeen = e.time; s.count += 1; s.lastMessage = e.message; s.lastLevel = e.level; s.verdict = e.verdict
            issues[key] = s
        } else {
            issues[key] = IssueState(key: key, source: e.source, verdict: e.verdict, firstSeen: e.time, lastSeen: e.time,
                                     count: 1, lastMessage: e.message, lastLevel: e.level, acknowledgedAt: nil)
        }
    }

    /// 某通道成功了（如 iCloud 拉取 / 导入成功）→ 它名下的短暂问题恢复，计数与升级横幅自动消失。日志里记一笔恢复。
    func resolve(source: String) {
        let keys = issues.values.filter { $0.source == source && $0.verdict.tier == .transient }.map(\.key)
        guard !keys.isEmpty else { return }
        for k in keys { issues.removeValue(forKey: k) }
        let entry = Entry(time: now(), level: .info, source: source, message: "已恢复（之前的短暂失败自动消除）")
        entries.append(entry)
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
        onAppend?(entry)
    }

    /// 横幅「知道了」：同一类问题再出现（或再次升级）才重新横幅。
    func acknowledge(_ key: String) { issues[key]?.acknowledgedAt = now() }

    private func isDecayed(_ s: IssueState, at t: Date) -> Bool {
        s.verdict.tier == .transient && !IssueTriage.sourcesWithRecoverySignal.contains(s.source)
            && t.timeIntervalSince(s.lastSeen) >= IssueTriage.quietDecay
    }

    /// (c) 持续失败：反复出现跨度够长，或有恢复信号的通道失败后迟迟没恢复。
    func isEscalated(_ s: IssueState, at t: Date) -> Bool {
        guard s.verdict.tier == .transient, !isDecayed(s, at: t) else { return false }
        if s.lastSeen.timeIntervalSince(s.firstSeen) >= IssueTriage.escalateAfter, s.count >= 2 { return true }
        return IssueTriage.sourcesWithRecoverySignal.contains(s.source) && t.timeIntervalSince(s.firstSeen) >= IssueTriage.escalateAfter
    }

    private func wantsBanner(_ s: IssueState, at t: Date) -> Bool {
        if let ack = s.acknowledgedAt, s.lastSeen <= ack { return false }
        return s.verdict.tier == .actionable || isEscalated(s, at: t)
    }

    /// 首页横幅：最近一个「你能处理的」或「已持续失败」的问题（白话 + 怎么办）。
    var bannerIssue: Surface? {
        let t = now()
        guard let s = issues.values.filter({ wantsBanner($0, at: t) }).max(by: { $0.lastSeen < $1.lastSeen }) else { return nil }
        let escalated = s.verdict.tier == .transient
        let base = s.verdict.headline ?? IssueTriage.plainText(s.lastMessage)
        let minutes = Int(t.timeIntervalSince(s.firstSeen) / 60)
        let text = escalated ? "\(s.source)：\(base)（已持续约 \(max(minutes, 1)) 分钟）" : (s.verdict.headline != nil ? base : "\(s.source)：\(base)")
        return Surface(key: s.key, source: s.source, level: s.lastLevel, text: text,
                       action: s.verdict.action ?? (escalated ? "点开日志看原因；网络恢复后通常会自己好" : nil),
                       escalated: escalated, since: s.firstSeen, count: s.count)
    }

    /// 🐞 入口上的小计数：安静中的短暂问题（未升级、未恢复）。
    var quietIssueCount: Int {
        let t = now()
        return issues.values.filter { $0.verdict.tier == .transient && !isDecayed($0, at: t) && !isEscalated($0, at: t) }.count
    }

    /// 面板 / 对话里的就地错误文字（lastError）是否该显示：短暂问题在升级前不显示（日志与 🐞 计数里照样有）。
    func shouldShowInline(source: String, message: String) -> Bool {
        let v = IssueTriage.classify(level: .error, source: source, message: message)
        switch v.tier {
        case .actionable: return true
        case .info: return false
        case .transient:
            guard let s = issues[v.key] else { return false }
            return isEscalated(s, at: now())
        }
    }
}
