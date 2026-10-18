//
//  PhoneAppSession.swift
//  BetterCalendar
//
//  W13（Jason 2026-10-18 的做法，原本在他的快捷指令「打开/关闭游戏模式 v10.1」里用 Data Jar 实现，这里搬进 BetterCalendar）：
//  iPhone「App 打开 / 关闭」自动化的两个难点——
//    ① 是哪个 App：快捷指令动作「获取当前 App」（is.workflow.actions.getcurrentapp，范围=当前）返回前台 App 的名字，
//       所以一条自动化可以选「全部 App」，再把名字传给我们的动作（之前「选全部 App 就拿不到名字」的结论作废）。
//    ② 「关闭」很吵：主窗口一失去焦点 iOS 就触发「已关闭」——下拉通知中心 / 控制中心也算。
//       办法：关闭触发后等 2 秒（前台状态稳定），再「获取当前 App」，与打开时记下的 App 比较：
//         · 相同 → 只是盖了一层（控制中心 / 通知），记 overlay（.other，detail.signal=overlay），不算关闭；
//         · 为空（回到主屏幕）→ 真关闭；
//         · 是另一个 App → 切换：记上一个 App 关闭；新 App 自己的「打开」触发会记它的打开，这里不重复记。
//  另外处理两种触发先后：切换时新 App 的「打开」可能先于旧 App 的「关闭」到达——新 App 刚打开（6 秒内）就来了
//  一个「关闭」且前台仍是新 App，那这个关闭属于上一个 App，不是盖层。
//  纯值类型状态机（单测直接喂），状态存本机 UserDefaults（Data，plist 类型；设备本地，不同步）。
//

import Foundation

nonisolated struct PhoneAppSession: Codable, Equatable, Sendable {
    /// 关闭触发后快捷指令等待的秒数（事件时刻按「调用时刻 − 这段」记）。
    static let settleSeconds: TimeInterval = 2
    /// 新 App 打开后这么久内到达的「关闭」（前台仍是新 App）= 上一个 App 的关闭。
    static let switchWindow: TimeInterval = 6
    static let defaultsKey = "activity.phone.appSession.v1"

    /// 认为在前台的 App（最近一次打开、还没真正关闭）。
    var current: String?
    var currentSince: Date?
    /// 上一个前台 App（切换时它的「关闭」可能晚到）。
    var previous: String?
    /// 控制中心 / 通知中心之类正盖在 current 上。
    var overlayActive = false

    /// 「获取当前 App」的结果 → App 名；空、主屏幕 → nil。
    static func normalize(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if ["springboard", "主屏幕", "home screen", "主画面"].contains(s.lowercased()) { return nil }
        return String(s.prefix(80))
    }

    nonisolated struct Factory: Sendable {
        var deviceId: String
        var platform: String
        var extra: [String: String] = [:]
        func make(_ kind: ActivityEvent.Kind, at: Date, app: String?, detail: [String: String] = [:]) -> ActivityEvent {
            var d = extra.merging(detail) { _, new in new }
            if app == nil, kind == .appOpened || kind == .appClosed { d["appUnknown"] = "true" }
            return ActivityEvent(at: at, kind: kind, source: .shortcut, deviceId: deviceId, platform: platform,
                                 appName: app, detail: d.isEmpty ? nil : d)
        }
    }

    /// 「记录 App 打开」：appName = 自动化里「获取当前 App」的结果。
    mutating func opened(_ raw: String?, at: Date, _ f: Factory) -> [ActivityEvent] {
        guard let name = Self.normalize(raw) else {
            return [f.make(.appOpened, at: at, app: nil)]   // 老式自动化没传名字：只知道「某个 App 打开了」
        }
        if name == current {
            if overlayActive {   // 控制中心 / 通知收起，回到原 App：不是新的打开
                overlayActive = false
                return [f.make(.other, at: at, app: name, detail: ["signal": "overlay", "state": "ended"])]
            }
            return []            // 同一个 App 的重复触发
        }
        previous = current; current = name; currentSince = at; overlayActive = false
        return [f.make(.appOpened, at: at, app: name)]
    }

    /// 「记录 App 关闭」：front = 关闭触发后等 2 秒再「获取当前 App」的结果（回到主屏幕为空）。
    mutating func closed(front raw: String?, at callAt: Date, _ f: Factory) -> [ActivityEvent] {
        let at = callAt.addingTimeInterval(-Self.settleSeconds)
        let front = Self.normalize(raw)
        let settle = ["settleSeconds": String(Int(Self.settleSeconds))]
        if let front, front == current {
            if let prev = previous, prev != front, let since = currentSince, since >= at.addingTimeInterval(-Self.switchWindow) {
                previous = nil   // 新 App 的打开先到了：这个关闭属于上一个 App
                return [f.make(.appClosed, at: at, app: prev, detail: settle.merging(["reason": "switch", "switchedTo": front]) { a, _ in a })]
            }
            overlayActive = true
            return [f.make(.other, at: at, app: front, detail: settle.merging(["signal": "overlay", "state": "started"]) { a, _ in a })]
        }
        let closing = current
        previous = current; current = nil; currentSince = nil; overlayActive = false
        if let front {   // 切到了另一个 App：它自己的「打开」会记，这里不记它
            return [f.make(.appClosed, at: at, app: closing, detail: settle.merging(["reason": "switch", "switchedTo": front]) { a, _ in a })]
        }
        return [f.make(.appClosed, at: at, app: closing, detail: settle.merging(["reason": "home"]) { a, _ in a })]
    }

    static func load(_ d: UserDefaults) -> PhoneAppSession {
        guard let data = d.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(PhoneAppSession.self, from: data) else { return .init() }
        return s
    }
    func save(_ d: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
    }
}
