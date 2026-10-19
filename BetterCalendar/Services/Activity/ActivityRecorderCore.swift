//
//  ActivityRecorderCore.swift
//  BetterCalendar
//
//  W13：Mac 实时活动记录的「只记变化」状态机（纯值类型，不碰系统 API，单测直接喂观察值）。
//  输入 = 一次次观察（前台 App、浏览器当前页、窗口标题、空闲秒数、锁屏/睡眠、电源、网络）；
//  输出 = 该写进日志的 ActivityEvent（没变化就不出行，不重复）。
//  规则：
//    - 前台 App 换了才记 appActivated；换 App 后浏览器页 / 窗口标题重新记一次（时间线每段自带上下文）。
//    - 浏览器页：(url, 标题) 有变化才记；同一页面标题变化（单页应用、未读数）也算变化。
//    - 窗口标题：同一 App 内标题变化才记 windowChanged；浏览器读页成功时不重复记它的窗口标题。
//    - 空闲：连续无键鼠输入 ≥ 阈值 → idleStart（时刻 = 最后一次输入）；恢复输入 → idleEnd（时刻 = 恢复那一刻）。
//    - 锁屏 / 睡眠：记下来，并结束进行中的空闲段（补一条 idleEnd，原因写明）；期间不记前台变化；解锁/唤醒后重新记当前前台。
//    - 暂停 / 关闭：记一条 recorder 标记（覆盖起止），清空状态；恢复时再记 recorder resumed + 当前前台。
//

import Foundation

nonisolated struct ActivityFrontApp: Equatable, Sendable {
    var name: String?
    var bundleID: String?
    var pid: Int32 = 0
}

nonisolated struct ActivityPowerState: Equatable, Sendable {
    /// "ac" / "battery" / "unknown"
    var source: String
    var charging: Bool?
    var percent: Int?
}

nonisolated struct ActivityNetworkState: Equatable, Sendable {
    /// "wifi" / "cellular" / "wired" / "other" / "none"
    var type: String
    var expensive = false
    var constrained = false
}

nonisolated struct ActivityRecorderCore: Sendable {
    /// 空闲阈值：连续这么久没有键鼠输入才算「离开」（3 分钟：看一段视频、想一会儿不算离开）。
    static let idleThreshold: TimeInterval = 180

    let deviceId: String
    let platform: String
    var idleThreshold: TimeInterval = ActivityRecorderCore.idleThreshold

    private(set) var front: ActivityFrontApp?
    private(set) var page: (url: String, title: String?)?
    private(set) var windowTitle: String?
    private(set) var idleSince: Date?
    private(set) var suspended: String?          // "screenLocked" / "systemSleep" / nil
    private(set) var recording: Bool?            // nil = 还没开始过
    private var power: ActivityPowerState?
    private var network: ActivityNetworkState?

    init(deviceId: String, platform: String) { self.deviceId = deviceId; self.platform = platform }

    private func event(_ kind: ActivityEvent.Kind, at: Date, app: ActivityFrontApp? = nil, url: String? = nil,
                       title: String? = nil, window: String? = nil, detail: [String: String]? = nil) -> ActivityEvent {
        ActivityEvent(at: at, kind: kind, source: .live, deviceId: deviceId, platform: platform,
                      appName: app?.name, bundleID: app?.bundleID, url: url, pageTitle: title, windowTitle: window, detail: detail,
                      deviceKind: platform == "macOS" ? ActivityDeviceKind.mac.rawValue : nil)
    }

    private mutating func resetContext() { front = nil; page = nil; windowTitle = nil }

    // MARK: 覆盖（开始 / 暂停 / 恢复）

    /// 每次观察前调用：记录状态变化 → recorder 标记。返回 false = 此刻不记（后续观察一律忽略）。
    mutating func setRecording(_ on: Bool, at: Date, reason: String) -> [ActivityEvent] {
        guard recording != on else { return [] }
        let first = recording == nil
        recording = on
        if on {
            return [event(.other, at: at, detail: ["signal": "recorder", "state": first ? "started" : "resumed", "reason": reason])]
        }
        var out: [ActivityEvent] = []
        if let since = idleSince { out.append(idleEnd(at: at, since: since, reason: "recorderPaused")) }
        resetContext(); idleSince = nil
        if !first { out.append(event(.other, at: at, detail: ["signal": "recorder", "state": "paused", "reason": reason])) }
        return out
    }

    /// App 退出时（能收到 willTerminate 的话）：标记覆盖结束。
    mutating func stop(at: Date) -> [ActivityEvent] {
        guard recording == true else { return [] }
        recording = false
        var out: [ActivityEvent] = []
        if let since = idleSince { out.append(idleEnd(at: at, since: since, reason: "recorderStopped")) }
        resetContext(); idleSince = nil
        out.append(event(.other, at: at, detail: ["signal": "recorder", "state": "stopped"]))
        return out
    }

    private var active: Bool { recording == true && suspended == nil }

    // MARK: 前台 / 浏览器 / 窗口

    mutating func observeFront(_ app: ActivityFrontApp?, at: Date) -> [ActivityEvent] {
        guard active, let app, app.bundleID != nil || app.name != nil else { return [] }
        guard app.bundleID != front?.bundleID || (app.bundleID == nil && app.name != front?.name) else { return [] }
        front = app; page = nil; windowTitle = nil
        return [event(.appActivated, at: at, app: app)]
    }

    mutating func observePage(url rawURL: String?, title rawTitle: String?, at: Date) -> [ActivityEvent] {
        guard active, let front, let url = ActivityURL.clean(rawURL) else { return [] }
        let title = ActivityURL.clip(rawTitle)
        if let page, page.url == url, page.title == title { return [] }
        page = (url, title)
        return [event(.browserPage, at: at, app: front, url: url, title: title)]
    }

    mutating func observeWindowTitle(_ raw: String?, at: Date) -> [ActivityEvent] {
        guard active, let front, let title = ActivityURL.clip(raw), title != windowTitle else { return [] }
        windowTitle = title
        return [event(.windowChanged, at: at, app: front, window: title)]
    }

    // MARK: 空闲

    mutating func observeIdle(seconds: Double?, at: Date) -> [ActivityEvent] {
        guard active, let seconds, seconds >= 0 else { return [] }
        if idleSince == nil, seconds >= idleThreshold {
            let since = at.addingTimeInterval(-seconds)
            idleSince = since
            return [event(.idleStart, at: since, app: front, detail: ["thresholdSeconds": String(Int(idleThreshold))])]
        }
        if let since = idleSince, seconds < idleThreshold {
            idleSince = nil
            return [idleEnd(at: at.addingTimeInterval(-seconds), since: since, reason: "input")]
        }
        return []
    }

    private func idleEnd(at: Date, since: Date, reason: String) -> ActivityEvent {
        event(.idleEnd, at: max(at, since), app: front,
              detail: ["idleSeconds": String(Int(max(0, at.timeIntervalSince(since)))), "reason": reason])
    }

    // MARK: 锁屏 / 睡眠

    mutating func suspend(_ kind: ActivityEvent.Kind, at: Date) -> [ActivityEvent] {
        guard recording == true else { return [] }
        let reason = kind == .screenLocked ? "screenLocked" : "systemSleep"
        var out: [ActivityEvent] = []
        if let since = idleSince { out.append(idleEnd(at: at, since: since, reason: reason)); idleSince = nil }
        // 已经锁着又睡眠：照记（两件事都发生了），但不重复结束空闲。
        if kind == .screenLocked, suspended == "screenLocked" { return out }
        out.append(event(kind, at: at))
        suspended = suspended ?? reason
        resetContext()
        return out
    }

    mutating func resume(_ kind: ActivityEvent.Kind, at: Date) -> [ActivityEvent] {
        guard recording == true else { return [] }
        if kind == .screenUnlocked, suspended == nil { return [] }   // 没见过锁屏的解锁（启动时）不记
        let out = [event(kind, at: at)]
        // 唤醒后可能仍在锁屏界面：只有解锁 / 本来就是因睡眠而暂停时才恢复。
        if kind == .screenUnlocked || suspended == "systemSleep" { suspended = nil }
        resetContext()
        return out
    }

    // MARK: 电源 / 网络（变化才记）

    mutating func observePower(_ p: ActivityPowerState?, at: Date) -> [ActivityEvent] {
        guard recording == true, let p else { return [] }
        defer { power = p }
        guard let old = power else { return [powerEvent(p, at: at, reason: "first")] }
        if old.source != p.source || old.charging != p.charging { return [powerEvent(p, at: at, reason: "changed")] }
        // 电池电量跨过 20% / 10% 也记一次（快没电是有用的情境）。
        if p.source == "battery", let a = old.percent, let b = p.percent, [20, 10].contains(where: { a > $0 && b <= $0 }) {
            return [powerEvent(p, at: at, reason: "low")]
        }
        return []
    }

    private func powerEvent(_ p: ActivityPowerState, at: Date, reason: String) -> ActivityEvent {
        var d = ["signal": "power", "source": p.source, "reason": reason]
        if let c = p.charging { d["charging"] = c ? "true" : "false" }
        if let pct = p.percent { d["percent"] = String(pct) }
        return event(.other, at: at, detail: d)
    }

    mutating func observeNetwork(_ n: ActivityNetworkState?, at: Date) -> [ActivityEvent] {
        guard recording == true, let n, n != network else { return [] }
        network = n
        return [event(.other, at: at, detail: ["signal": "network", "type": n.type,
                                                "expensive": n.expensive ? "true" : "false", "constrained": n.constrained ? "true" : "false"])]
    }
}
