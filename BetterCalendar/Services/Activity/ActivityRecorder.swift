//
//  ActivityRecorder.swift
//  BetterCalendar
//
//  W13：Mac 常驻活动记录器（App 运行就在记，包括没有窗口、只剩菜单栏时）。
//  - 采集走协议（ActivityProbing / ActivityBrowserReading），判断走 ActivityRecorderCore（只记变化），写入走 ActivityLog。
//  - 触发：NSWorkspace 前台切换 / 睡眠唤醒 / 屏幕睡眠 + 分布式通知锁屏解锁（立即），外加 10 秒一次的轮询
//    （空闲秒数、浏览器当前页、窗口标题、电源；浏览器只在它在前台时才问，变化才记）。
//  - 与已冻结的 StateBridge 完全独立：不读它的状态、不调它的上传；只是参考了它的采集写法。
//  - 设置关 / 暂停：下一次轮询（或设置改动时立即）记 recorder 标记并停止记录；恢复后再记当前前台。
//

import Foundation

/// 窗口标题读取结果（权限与失败要能区分，不能当成「没有标题」）。
nonisolated enum ActivityWindowTitleRead: Equatable, Sendable {
    case title(String?)
    case noPermission
    case failed(String)
}

/// 浏览器当前页读取结果。
nonisolated enum ActivityBrowserRead: Equatable, Sendable {
    case page(url: String?, title: String?)
    case noWindow
    case failed(code: Int?, reason: String)
}

/// 系统观察（Mac 实现见 MacActivityProbe；测试用假的）。
@MainActor protocol ActivityProbing: AnyObject {
    func frontApp() -> ActivityFrontApp?
    /// 距最后一次键鼠输入的秒数（nil = 读不到）。
    func idleSeconds() -> Double?
    func power() -> ActivityPowerState?
    func windowTitle(of app: ActivityFrontApp) async -> ActivityWindowTitleRead
}

nonisolated protocol ActivityBrowserReading: Sendable {
    /// 只对支持的浏览器 bundle 调用。
    func page(bundleID: String) async -> ActivityBrowserRead
}

nonisolated enum ActivityBrowsers {
    /// AppleScript 能问当前页的浏览器（Safari 系用 current tab/name，Chromium 系用 active tab/title）。
    /// 与 BetterCalendar.entitlements 的 temporary-exception.apple-events 列表保持一致（不在列表里的会被沙盒拦成 -600）。
    static let safariFamily: Set<String> = ["com.apple.Safari"]
    static let chromiumFamily: Set<String> = ["com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser",
                                              "com.brave.Browser", "com.vivaldi.Vivaldi"]
    static func supports(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return safariFamily.contains(bundleID) || chromiumFamily.contains(bundleID)
    }
}

/// 系统信号（通知回调 → 记录器）。
nonisolated enum ActivitySystemSignal: Sendable {
    case appActivated, screenLocked, screenUnlocked, systemSleep, systemWake, screensSlept, screensWoke
    case sessionResigned, sessionActivated
}

@MainActor final class MacActivityRecorder {
    private var core: ActivityRecorderCore
    private let log: any ActivityLog
    private let probe: any ActivityProbing
    private let browser: any ActivityBrowserReading
    private let status: ActivityStatusBoard
    private let defaults: UserDefaults
    private let now: () -> Date
    /// 一次轮询还在跑时又来一次（定时器 + 通知撞车）→ 合并成「跑完再来一轮」。
    private var ticking = false
    private var again = false

    init(log: any ActivityLog, probe: any ActivityProbing, browser: any ActivityBrowserReading, status: ActivityStatusBoard,
         deviceId: String, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        core = ActivityRecorderCore(deviceId: deviceId, platform: "macOS")
        self.log = log; self.probe = probe; self.browser = browser; self.status = status; self.defaults = defaults; self.now = now
    }

    var isRecording: Bool { core.recording == true }

    /// 一次完整观察（定时器、通知、设置改动都走这里）。
    func tick() async {
        if ticking { again = true; return }
        ticking = true; defer { ticking = false }
        repeat { again = false; await tickOnce() } while again
    }

    private func tickOnce() async {
        let at = now()
        let on = ActivitySettings.isRecording(at: at, defaults)
        var out = core.setRecording(on, at: at, reason: on ? "settings" : (ActivitySettings.enabled(defaults) ? "paused" : "disabled"))
        guard on else {
            await write(out)
            let why = ActivitySettings.enabled(defaults) ? "已暂停（到 \(ActivitySettings.pausedUntil(defaults).map { Self.hm($0) } ?? "?")）" : "总开关已关"
            for s in [ActivitySource.frontApp, .browser, .windowTitle, .idle, .lockSleep, .power] { status.set(s, .off(why)) }
            return
        }
        let app = probe.frontApp()
        out += core.observeFront(app, at: at)
        if app != nil { status.working(.frontApp, at: at) } else { status.set(.frontApp, .waiting("读不到前台 App")) }

        let idle = probe.idleSeconds()
        out += core.observeIdle(seconds: idle, at: at)
        if idle == nil { status.set(.idle, .failed("系统没有返回空闲秒数")) } else { status.working(.idle, at: at) }
        status.keepWorking(.lockSleep)

        out += core.observePower(probe.power(), at: at)
        status.keepWorking(.power)

        // 空闲、锁屏、睡眠时不问浏览器/窗口（人不在，问了也是旧页面，还会唤起浏览器脚本）。
        var browserOK = false
        if let app, core.idleSince == nil, core.suspended == nil {
            if let bundle = app.bundleID, ActivityBrowsers.supports(bundle) {
                switch await browser.page(bundleID: bundle) {
                case let .page(url, title):
                    out += core.observePage(url: url, title: title, at: now())
                    browserOK = true
                    status.working(.browser, at: at)
                case .noWindow:
                    browserOK = true; status.working(.browser, at: at)
                case let .failed(code, reason):
                    status.set(.browser, code == -1743 ? .noPermission(reason) : .failed(reason))
                }
            }
            if !browserOK {
                switch await probe.windowTitle(of: app) {
                case let .title(t):
                    out += core.observeWindowTitle(t, at: now()); status.working(.windowTitle, at: at)
                case .noPermission:
                    status.set(.windowTitle, .noPermission("需要在「系统设置 → 隐私与安全性 → 辅助功能」里允许 BetterCalendar"))
                case let .failed(why):
                    status.set(.windowTitle, .failed(why))
                }
            }
        }
        await write(out)
    }

    func handle(_ signal: ActivitySystemSignal) async {
        let at = now()
        var out: [ActivityEvent] = []
        switch signal {
        case .appActivated: await tick(); return
        case .screenLocked: out = core.suspend(.screenLocked, at: at)
        case .screenUnlocked: out = core.resume(.screenUnlocked, at: at)
        case .systemSleep: out = core.suspend(.systemSleep, at: at)
        case .systemWake: out = core.resume(.systemWake, at: at)
        case .screensSlept, .screensWoke, .sessionResigned, .sessionActivated:
            let name: String = switch signal {
            case .screensSlept: "screensSlept"; case .screensWoke: "screensWoke"
            case .sessionResigned: "sessionResigned"; default: "sessionActivated" }
            if core.recording == true {
                out = [ActivityEvent(at: at, kind: .other, deviceId: core.deviceId, platform: core.platform,
                                     detail: ["signal": "session", "state": name])]
            }
        }
        if core.recording == true { status.working(.lockSleep, at: at) }
        await write(out)
        if signal == .screenUnlocked || signal == .systemWake { await tick() }
    }

    /// 网络变化（NWPathMonitor 回调转过来）。
    func network(_ n: ActivityNetworkState) async {
        await write(core.observeNetwork(n, at: now()))
    }

    /// App 即将退出：记覆盖结束（尽力而为；被强杀时收不到，日志里就没有 stopped——空白 ≠ 没做事）。
    func stop() async { await write(core.stop(at: now())) }

    private func write(_ events: [ActivityEvent]) async {
        guard !events.isEmpty else { return }
        do {
            try await log.append(events)
            status.working(.storage, at: events.last?.at)
        } catch {
            status.set(.storage, .failed("写本机日文件失败：\(error.localizedDescription)（这几条丢了）"))
        }
    }

    private static func hm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
}
