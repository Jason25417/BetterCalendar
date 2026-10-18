//
//  ActivityContextSummary.swift
//  BetterCalendar
//
//  W13：写进 context.json 的「最近设备活动」紧凑摘要（每 20 秒重写，要小）：
//    - current：Mac 此刻在用什么（App、开始时刻、网页域名与标题 / 窗口标题、是否空闲 / 锁屏 / 睡眠 / 暂停）；
//    - lastWindow：最近 60 分钟各 App / 网站的前台分钟数（按时间线切段：切 App、换网页、空闲、锁屏、睡眠、暂停都会断段）；
//    - iphone：最近 6 小时 iPhone 快捷指令记下的 App 打开 / 关闭（最近几条）。
//  全部带来源与观察时刻，截断显式标记；完整明细走 MCP read_activity。
//  红线（羞辱铁律，2026-07-11 分心检测审核起一直有效）：App / 网站名只是智能体理解情境与时机的线索，
//  永不出现在复盘、操作留底、成就 / 反馈界面里，也不拿来评判 Jason。
//

import Foundation

nonisolated enum ActivityContextSummary {
    static let windowMinutes = 60
    static let lookbackHours = 12          // 往前多读这么久，好知道窗口开始时的前台状态
    static let topApps = 8
    static let topDomains = 6
    static let iphoneEvents = 10
    static let iphoneHours = 6
    static let titleChars = 80

    nonisolated struct Segment: Equatable, Sendable {
        var app: String
        var bundleID: String?
        var domain: String?
        var start: Date
        var end: Date
    }

    /// 读日志要覆盖的时间窗。
    static func readWindow(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-Double(lookbackHours) * 3600), end: now)
    }

    /// Mac 时间线 → 前台段（「人在用这个 App / 网站」的连续时间）。
    static func segments(_ events: [ActivityEvent], now: Date) -> [Segment] {
        var out: [Segment] = []
        var open: Segment?
        var last: (app: String, bundleID: String?, domain: String?)?
        func close(_ at: Date) { if var s = open { s.end = max(s.start, at); out.append(s); open = nil } }
        for e in events.sorted(by: { $0.at < $1.at }) where e.platform == "macOS" && e.at <= now {
            switch e.kind {
            case .appActivated:
                close(e.at)
                let app = e.appName ?? e.bundleID ?? "?"
                open = Segment(app: app, bundleID: e.bundleID, domain: nil, start: e.at, end: e.at)
                last = (app, e.bundleID, nil)
            case .browserPage:
                let domain = ActivityURL.host(e.url)
                if let o = open, o.domain == domain, o.bundleID == e.bundleID { break }   // 同站换页不断段
                close(e.at)
                let app = e.appName ?? e.bundleID ?? last?.app ?? "?"
                open = Segment(app: app, bundleID: e.bundleID ?? last?.bundleID, domain: domain, start: e.at, end: e.at)
                last = (app, open?.bundleID, domain)
            case .idleStart, .screenLocked, .systemSleep:
                close(e.at)
            case .idleEnd:
                if open == nil, let last { open = Segment(app: last.app, bundleID: last.bundleID, domain: last.domain, start: e.at, end: e.at) }
            case .other where e.detail?["signal"] == "recorder" && ["paused", "stopped"].contains(e.detail?["state"] ?? ""):
                close(e.at); last = nil
            default: break
            }
        }
        close(now)
        return out
    }

    static func build(events: [ActivityEvent], now: Date, recording: Bool, pausedUntil: Date?, sources: [[String: Any]] = []) -> [String: Any] {
        let iso = ISO8601DateFormatter(); iso.timeZone = .current
        let t: (Date) -> String = { iso.string(from: $0) }
        let clip: (String?) -> Any = { s in
            guard let s else { return NSNull() }
            return s.count > titleChars ? String(s.prefix(titleChars)) + "…" : s
        }
        let windowStart = now.addingTimeInterval(-Double(windowMinutes) * 60)
        let mac = events.filter { $0.platform == "macOS" }
        let segs = segments(mac, now: now)

        var o: [String: Any] = [
            "source": "BetterCalendar 设备活动记录（Mac 实时采集 + iPhone 快捷指令经 iCloud 汇入；本机日文件）",
            "asOf": t(now), "recording": recording, "pausedUntil": pausedUntil.map(t) ?? NSNull(),
            "redLine": "只用于理解情境与时机；App/网站名永不写进复盘、留底、反馈，不用来评判 Jason（见 CLAUDE.md「设备活动」）",
            "detailTool": "read_activity",
        ]

        // 此刻（Mac）
        var current: [String: Any] = ["platform": "macOS"]
        let lastState = mac.last(where: { [.idleStart, .idleEnd, .screenLocked, .screenUnlocked, .systemSleep, .systemWake, .appActivated].contains($0.kind)
            || ($0.kind == .other && $0.detail?["signal"] == "recorder") })
        let state: String
        switch lastState?.kind {
        case .idleStart?: state = "idle"
        case .screenLocked?: state = "locked"
        case .systemSleep?: state = "asleep"
        case .other? where ["paused", "stopped"].contains(lastState?.detail?["state"] ?? ""): state = "notRecording"
        case nil: state = "unknown"
        default: state = "active"
        }
        current["state"] = state
        if let since = lastState?.at { current["stateSince"] = t(since) }
        if let seg = segs.last, state == "active", seg.end >= now.addingTimeInterval(-1) {
            current["app"] = seg.app; current["bundleID"] = seg.bundleID ?? NSNull(); current["since"] = t(seg.start)
            if let page = mac.last(where: { $0.kind == .browserPage && $0.at >= seg.start }) {
                current["page"] = ["domain": ActivityURL.host(page.url) ?? NSNull(), "title": clip(page.pageTitle), "at": t(page.at)] as [String: Any]
            }
            if let w = mac.last(where: { $0.kind == .windowChanged && $0.at >= seg.start }) {
                current["windowTitle"] = clip(w.windowTitle)
            }
        }
        if let last = mac.last { current["lastEventAt"] = t(last.at) }
        o["current"] = current

        // 最近 60 分钟：各 App / 网站分钟数（段落裁到窗口内）
        var perApp: [String: Double] = [:], perDomain: [String: Double] = [:]
        for s in segs {
            let lo = max(s.start, windowStart), hi = min(s.end, now)
            guard hi > lo else { continue }
            let sec = hi.timeIntervalSince(lo)
            perApp[s.app, default: 0] += sec
            if let d = s.domain { perDomain[d, default: 0] += sec }
        }
        let rank: ([String: Double], Int, String) -> [String: Any] = { dict, limit, key in
            let sorted = dict.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let kept = sorted.prefix(limit).map { [key: $0.key, "minutes": Int(($0.value / 60).rounded())] as [String: Any] }
            var r: [String: Any] = ["items": Array(kept), "total": sorted.count, "truncated": sorted.count > kept.count]
            if sorted.count > kept.count { r["truncatedNote"] = "只列前 \(kept.count) 个（共 \(sorted.count) 个）" }
            return r
        }
        o["lastWindow"] = ["minutes": windowMinutes, "start": t(windowStart), "end": t(now),
                           "apps": rank(perApp, topApps, "app"), "domains": rank(perDomain, topDomains, "domain"),
                           "note": "前台分钟数 = 记录器看到的连续使用段（空闲 ≥3 分钟、锁屏、睡眠、暂停都不算）；不等于在做事，也不等于没在做事"] as [String: Any]

        // iPhone（快捷指令自动化，经 iCloud 汇入）
        let phoneSince = now.addingTimeInterval(-Double(iphoneHours) * 3600)
        let phone = events.filter { $0.platform == "iOS" && $0.at >= phoneSince && $0.at <= now }
        let kept = phone.suffix(iphoneEvents).map { e -> [String: Any] in
            var r: [String: Any] = ["at": t(e.at), "kind": e.kind.rawValue]
            if let a = e.appName { r["app"] = a }
            if let s = e.detail?["signal"] {
                r["signal"] = s
                if let a = e.detail?["activity"] { r["activity"] = a }
                if let st = e.detail?["state"] { r["state"] = st }
            }
            if e.kind == .appClosed, let to = e.detail?["switchedTo"] { r["switchedTo"] = to }
            return r
        }
        var iphone: [String: Any] = ["source": "iPhone 快捷指令自动化 / 运动与健康回填（经 iCloud 汇到 Mac；可能晚到几分钟）",
                                     "note": "signal=overlay（started/ended）= 控制中心 / 通知盖了一层，不是关闭；appClosed 才是真关闭（回主屏幕或切换）",
                                     "windowHours": iphoneHours, "items": Array(kept), "total": phone.count, "truncated": phone.count > kept.count]
        if phone.count > kept.count { iphone["truncatedNote"] = "只列最近 \(kept.count) 条（共 \(phone.count) 条）" }
        o["iphone"] = iphone
        let problems = sources.filter { ["failed", "noPermission"].contains($0["state"] as? String ?? "") }
        if !problems.isEmpty { o["sourceProblems"] = problems }
        return o
    }
}
