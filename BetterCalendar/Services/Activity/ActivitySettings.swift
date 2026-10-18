//
//  ActivitySettings.swift
//  BetterCalendar
//
//  W13 设备活动记录（实验）的开关、暂停、来源状态，以及网址清洗。
//  Jason 2026-10-18：实验期数据源尽量宽（含一定侵入），靠清楚的披露而不是少采；默认开；日后按使用日志删减。
//  - 总开关默认开（ExperimentDefaults：键不存在 = 从没设过 = 开）；「暂停 1 小时」= 记一个恢复时刻。
//    两者随 iCloud 设置同步（SettingsSync 白名单）：在 iPhone 上暂停，Mac 的实时记录也停——「我现在不想被记」通常是对人不是对设备。
//  - 每个来源一行状态：在工作 / 没有权限 / 失败（带原因）/ 已关或暂停 / 等待中——失败必须可见（开发期约定）。
//

import Foundation
import Observation

nonisolated enum ActivitySettings {
    static let enabledKey = "activity.recording.enabled"
    static let pausedUntilKey = "activity.recording.pausedUntil"
    /// 暂停一次的时长（「暂停 1 小时」按钮）。
    static let pauseSeconds: TimeInterval = 3600

    static func enabled(_ d: UserDefaults = .standard) -> Bool { ExperimentDefaults.bool(enabledKey, default: true, in: d) }
    static func setEnabled(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: enabledKey) }

    /// 暂停到什么时候（nil = 没暂停）。存 Double（plist 类型），不存 Date 以外的东西。
    static func pausedUntil(_ d: UserDefaults = .standard) -> Date? {
        guard let t = d.object(forKey: pausedUntilKey) as? Double, t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    static func pause(until: Date?, _ d: UserDefaults = .standard) {
        if let until { d.set(until.timeIntervalSince1970, forKey: pausedUntilKey) } else { d.removeObject(forKey: pausedUntilKey) }
    }

    /// 此刻是否在记：总开关开，且不在暂停期内。
    static func isRecording(at now: Date, _ d: UserDefaults = .standard) -> Bool {
        guard enabled(d) else { return false }
        if let until = pausedUntil(d), now < until { return false }
        return true
    }
}

/// 活动来源（设置页逐行显示状态）。
nonisolated enum ActivitySource: String, CaseIterable, Sendable {
    case frontApp, browser, windowTitle, idle, lockSleep, power, network
    case storage, bridgeMirror, cloudImport, cloudUpload, shortcut, motion, health, launchAtLogin

    var label: String {
        switch self {
        case .frontApp: "前台 App 切换"
        case .browser: "浏览器当前页（网址 + 标题）"
        case .windowTitle: "其他 App 的窗口标题"
        case .idle: "键鼠空闲开始 / 结束"
        case .lockSleep: "锁屏 / 解锁、睡眠 / 唤醒"
        case .power: "电源（插电 / 电池、电量）"
        case .network: "网络类型（Wi-Fi / 蜂窝 / 有线 / 断网）"
        case .storage: "本机日文件"
        case .bridgeMirror: "镜像到智能体桥接目录"
        case .cloudImport: "从 iCloud 导入 iPhone 记录"
        case .cloudUpload: "上传到 iCloud（给 Mac 上的智能体）"
        case .shortcut: "快捷指令：App 打开 / 关闭"
        case .motion: "运动状态（步行 / 跑步 / 乘车 / 静止）"
        case .health: "健康：睡眠、锻炼"
        case .launchAtLogin: "开机自动启动（保证持续记录）"
        }
    }
}

nonisolated enum ActivitySourceState: Equatable, Sendable {
    case working(lastAt: Date?)
    case noPermission(String)
    case failed(String)
    case off(String)
    case waiting(String)

    var isProblem: Bool { if case .noPermission = self { return true }; if case .failed = self { return true }; return false }
    var code: String {
        switch self { case .working: "working"; case .noPermission: "noPermission"; case .failed: "failed"; case .off: "off"; case .waiting: "waiting" }
    }
    var reason: String? {
        switch self { case .working: nil; case let .noPermission(s), let .failed(s), let .off(s), let .waiting(s): s }
    }
}

/// 各来源状态板（设置页、桥接 status.json 共用）。失败第一次出现与原因变化时写 DevLog（不刷屏）。
@MainActor @Observable final class ActivityStatusBoard {
    private(set) var states: [ActivitySource: ActivitySourceState] = [:]
    @ObservationIgnored private var logged: [ActivitySource: String] = [:]
    /// 测试里关掉 DevLog（仍然记状态）。
    @ObservationIgnored var logsFailures = true

    func set(_ source: ActivitySource, _ state: ActivitySourceState) {
        // 「working」只更新最近时刻，不必每次触发界面刷新到秒；但值变了才写，避免无谓的观察通知。
        if states[source] != state { states[source] = state }
        if state.isProblem, let reason = state.reason {
            let message = "\(source.label)：\(reason)"
            if logged[source] != message, logsFailures {
                logged[source] = message
                if case .failed = state { DevLog.shared.warn("设备活动", message) } else { DevLog.shared.info("设备活动", message) }
            }
        } else { logged[source] = nil }
    }

    func working(_ source: ActivitySource, at: Date?) { set(source, .working(lastAt: at)) }

    /// 「在工作」但没有新的事件时刻：已经是 working 就保留原来的最近时刻，不抹掉。
    func keepWorking(_ source: ActivitySource) {
        if case .working? = states[source] { return }
        set(source, .working(lastAt: nil))
    }

    /// 给桥接 status.json / 智能体看的形状。
    func snapshot() -> [[String: Any]] {
        ActivitySource.allCases.compactMap { s -> [String: Any]? in
            guard let st = states[s] else { return nil }
            var o: [String: Any] = ["source": s.rawValue, "label": s.label, "state": st.code]
            if let r = st.reason { o["reason"] = r }
            if case let .working(at?) = st { o["lastAt"] = ActivityCodec.iso(at) }
            return o
        }
    }
}

/// 网址清洗：保留路径与查询（实验期要宽：搜索词等本身就是情境），去掉账号密码与锚点，
/// 疑似凭据的查询参数值替换成 REDACTED（token/code/key/密码之类——这些进智能体与云端模型没有好处，只有风险）。
nonisolated enum ActivityURL {
    static let maxLength = 2048
    /// 名字里含这些就算凭据（够长、不会误伤普通参数）。
    private static let sensitiveParts = ["token", "secret", "password", "passwd", "signature", "credential", "session", "assertion",
                                         "saml", "jwt", "apikey", "api_key", "authorization"]
    /// 名字恰好是这些才算（短词，避免误伤 keyword / zipcode 之类）。
    private static let sensitiveExact: Set<String> = ["code", "key", "sig", "sid", "auth", "pwd", "pass", "otp", "ticket", "nonce", "state"]
    static func isSensitive(_ name: String) -> Bool {
        let n = name.lowercased()
        return sensitiveExact.contains(n) || sensitiveParts.contains(where: { n.contains($0) })
    }

    static func clean(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard var parts = URLComponents(string: raw) else { return String(raw.prefix(300)) }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        if let items = parts.queryItems {
            parts.queryItems = items.map { item in
                isSensitive(item.name) ? URLQueryItem(name: item.name, value: "REDACTED") : item
            }
            if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        }
        let s = parts.string ?? raw
        return s.count > maxLength ? String(s.prefix(maxLength)) : s
    }

    static func host(_ url: String?) -> String? {
        guard let url, let h = URLComponents(string: url)?.host?.lowercased() else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func clip(_ s: String?, _ n: Int = 300) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s.count > n ? String(s.prefix(n)) : s
    }
}
