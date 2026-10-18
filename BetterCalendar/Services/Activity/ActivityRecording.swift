//
//  ActivityRecording.swift
//  BetterCalendar
//
//  W13：设备活动记录的总装（组装点建一份，设置页经 ActivityRecording.current 读写）。
//  Mac：常驻记录器（10 秒轮询 + 系统通知）、每 2 分钟从 iCloud 导入 iPhone 记录、每轮桥接同步镜像日文件、开机自启默认开。
//  iPhone：回到前台时把待上传队列传完 + 回填运动/健康；网络变化随手记。
//  测试环境不启动任何定时器 / 通知 / 网络监听（各组件单测各自注入假实现）。
//

import Foundation
import Network
import Observation
#if os(macOS)
import AppKit
import ServiceManagement
#endif
#if os(iOS)
import UIKit
#endif

/// 开机自启「实验期默认开」的判定（纯函数，可单测）。只自动打开一次：之后你在设置里关掉，就不再替你打开。
nonisolated enum ActivityLaunchAtLogin {
    static let autoKey = "activity.launchAtLogin.autoRegistered"
    enum Decision: Equatable { case register, skip(String) }

    static func decide(alreadyAutoRegistered: Bool, isEnabled: Bool, bundlePath: String) -> Decision {
        if alreadyAutoRegistered { return .skip("已自动打开过一次（之后以你的设置为准）") }
        if isEnabled { return .skip("已经开着") }
        // 只对装在「应用程序」里的正式版（TestFlight）注册；Xcode 跑的调试版在 DerivedData 里，注册它会让登录时启动一个旧调试包。
        guard bundlePath.hasPrefix("/Applications/") else { return .skip("不是装在「应用程序」里的版本（调试版不自动注册）") }
        return .register
    }
}

@MainActor @Observable final class ActivityRecording {
    /// 设置页入口（组装点设置；测试环境也会有一份，但不启动）。
    static weak var current: ActivityRecording?

    let status = ActivityStatusBoard()
    let log: FileActivityLog
    private(set) var enabled: Bool
    private(set) var pausedUntil: Date?
    /// Mac：开机自启状态的说明（设置页显示）。
    private(set) var launchAtLoginNote: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let deviceId: String
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastNetwork: ActivityNetworkState?
    #if os(macOS)
    /// 防 App Nap：只剩菜单栏时系统会把定时器拖到几分钟一次，持续记录就断了。不阻止系统睡眠。
    @ObservationIgnored private var napToken: NSObjectProtocol?
    @ObservationIgnored private(set) var recorder: MacActivityRecorder?
    @ObservationIgnored private var importer: ActivityCloudImporter?
    #endif
    #if os(iOS)
    @ObservationIgnored private var phoneSources: PhoneActivitySources?
    #endif
    @ObservationIgnored private var sink: ActivityPhoneSink?

    init(log: FileActivityLog, deviceId: String, defaults: UserDefaults = .standard) {
        self.log = log; self.deviceId = deviceId; self.defaults = defaults
        enabled = ActivitySettings.enabled(defaults); pausedUntil = ActivitySettings.pausedUntil(defaults)
    }

    // MARK: 开关（设置页）

    var isRecordingNow: Bool { ActivitySettings.isRecording(at: .now, defaults) }

    func setEnabled(_ on: Bool) {
        ActivitySettings.setEnabled(on, defaults)
        if on { ActivitySettings.pause(until: nil, defaults) }
        reloadSettings()
        DevLog.shared.info("设备活动", on ? "记录已打开" : "记录已关闭（之前记下的保留在本机，按 90 天自动清理）")
    }

    func pauseOneHour(now: Date = .now) {
        ActivitySettings.pause(until: now.addingTimeInterval(ActivitySettings.pauseSeconds), defaults)
        reloadSettings()
        DevLog.shared.info("设备活动", "暂停 1 小时")
    }

    func resumeNow() { ActivitySettings.pause(until: nil, defaults); reloadSettings() }

    /// 设置变了（本机或另一台设备经 iCloud 设置同步）→ 刷新显示，并立刻让记录器补一次观察（记暂停 / 恢复标记）。
    func reloadSettings() {
        enabled = ActivitySettings.enabled(defaults); pausedUntil = ActivitySettings.pausedUntil(defaults)
        #if os(macOS)
        if let recorder { Task { await recorder.tick() } }
        #endif
    }

    // MARK: 启动（生产）

    #if os(macOS)
    func startMac() {
        startMac(probe: MacActivityProbe(), browser: AppleScriptActivityBrowserReader(), cloud: CloudKitActivityStore())
    }

    func startMac(probe: any ActivityProbing, browser: any ActivityBrowserReading, cloud: any ActivityCloudTransport) {
        guard recorder == nil else { return }
        let recorder = MacActivityRecorder(log: log, probe: probe, browser: browser, status: status, deviceId: deviceId, defaults: defaults)
        self.recorder = recorder
        let importer = ActivityCloudImporter(transport: cloud, log: log, status: status, defaults: defaults)
        self.importer = importer
        sink = ActivityPhoneSink(log: log, outbox: nil, transport: nil)
        status.set(.cloudImport, .waiting("等第一次拉取"))
        status.set(.shortcut, .waiting("还没收到 iPhone 的快捷指令记录（iPhone 上设置自动化后会出现）"))
        status.set(.bridgeMirror, .waiting("等智能体桥接连接后镜像"))

        let tick = Timer(timeInterval: 10, repeats: true) { _ in Task { @MainActor in await recorder.tick() } }
        let pull = Timer(timeInterval: 120, repeats: true) { _ in Task { @MainActor in await importer.importOnce(now: .now) } }
        let prune = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in Task { @MainActor in await self?.pruneLocal() } }
        tick.tolerance = 2
        for t in [tick, pull, prune] { RunLoop.main.add(t, forMode: .common) }
        napToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "设备活动记录（实验）：只剩菜单栏时也持续记录")
        timers = [tick, pull, prune]

        let ws = NSWorkspace.shared.notificationCenter
        let map: [(Notification.Name, ActivitySystemSignal)] = [
            (NSWorkspace.didActivateApplicationNotification, .appActivated), (NSWorkspace.willSleepNotification, .systemSleep),
            (NSWorkspace.didWakeNotification, .systemWake), (NSWorkspace.screensDidSleepNotification, .screensSlept),
            (NSWorkspace.screensDidWakeNotification, .screensWoke), (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
        ]
        for (name, signal) in map {
            observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in await recorder.handle(signal) }
            }))
        }
        // 锁屏 / 解锁：系统只发分布式通知（沙盒 App 可以收）。
        let dnc = DistributedNotificationCenter.default()
        for (name, signal) in [("com.apple.screenIsLocked", ActivitySystemSignal.screenLocked), ("com.apple.screenIsUnlocked", .screenUnlocked)] {
            observers.append((dnc, dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                Task { @MainActor in await recorder.handle(signal) }
            }))
        }
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.writeStoppedMarker() }
            }))
        startNetworkMonitor()
        observeRemoteSettings()
        ensureLaunchAtLogin()
        Task { await recorder.tick(); await importer.importOnce(now: .now); await pruneLocal() }
    }

    /// 退出前同步写「记录结束」（等不了 actor；被强杀时收不到——日志里没有 stopped，空白 ≠ 没做事）。
    private func writeStoppedMarker() {
        guard recorder?.isRecording == true else { return }
        log.appendSync([ActivityEvent(at: .now, kind: .other, deviceId: deviceId, platform: "macOS",
                                      detail: ["signal": "recorder", "state": "stopped", "reason": "appTerminating"])])
    }

    private func ensureLaunchAtLogin() {
        let service = SMAppService.mainApp
        let decision = ActivityLaunchAtLogin.decide(alreadyAutoRegistered: defaults.bool(forKey: ActivityLaunchAtLogin.autoKey),
                                                    isEnabled: service.status == .enabled, bundlePath: Bundle.main.bundlePath)
        switch decision {
        case .register:
            do {
                try service.register()
                defaults.set(true, forKey: ActivityLaunchAtLogin.autoKey)
                DevLog.shared.info("设备活动", "实验期默认：已打开「开机自动启动」（设置里可关，关了不会再替你打开）")
            } catch {
                status.set(.launchAtLogin, .failed("自动打开开机自启失败：\(error.localizedDescription)"))
                return
            }
        case .skip: break
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: status.set(.launchAtLogin, .working(lastAt: nil)); launchAtLoginNote = nil
        case .requiresApproval:
            status.set(.launchAtLogin, .noPermission("系统设置 → 通用 → 登录项 里允许 BetterCalendar"))
        case .notRegistered:
            status.set(.launchAtLogin, .off("开机自启没开：重启 / 注销后要手动打开 App 才会继续记录"))
        default:
            status.set(.launchAtLogin, .failed("登录项状态未知"))
        }
        // TestFlight 更新后系统会关掉旧进程、不会自动重新打开（无常驻守护时没有办法拉起），只能等下次登录或手动打开。
        launchAtLoginNote = "TestFlight 更新后 App 会被系统关掉且不会自动重开——要等下次登录或你手动打开；智能体侧的心跳（W14）会发现并告诉你。"
    }
    #endif

    #if os(iOS)
    func startPhone() {
        guard sink == nil else { return }
        let sink = ActivityPhoneSink.shared
        self.sink = sink
        let sources = PhoneActivitySources(sink: sink, status: status, deviceId: deviceId)
        phoneSources = sources
        status.set(.shortcut, .waiting("还没收到快捷指令调用（按设置页里的步骤建自动化）"))
        let nc = NotificationCenter.default
        observers.append((nc, nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.phoneForeground() }
        }))
        startNetworkMonitor()
        observeRemoteSettings()
        Task { await phoneForeground() }
    }

    private func phoneForeground() async {
        guard let sink else { return }
        // 快捷指令可能在后台把进程拉起来（同时建了组装点）：后台只传队列，回填（会弹运动/健康授权）等真正回到前台。
        let active = UIApplication.shared.applicationState == .active
        let o = await sink.flush()
        if let e = o.uploadError { status.set(.cloudUpload, .failed("上传 iCloud 失败（\(o.pendingUpload) 条待传，稍后重试）：\(e)")) }
        else { status.working(.cloudUpload, at: .now) }
        if let last = try? await log.events(in: DateInterval(start: Date.now.addingTimeInterval(-7 * 86_400), end: .now))
            .last(where: { $0.source == .shortcut }) {
            status.working(.shortcut, at: last.at)
        }
        if active { await phoneSources?.backfill(now: .now) }
        await pruneLocal()
    }
    #endif

    private func observeRemoteSettings() {
        let nc = NotificationCenter.default
        observers.append((nc, nc.addObserver(forName: SettingsSync.didSyncRemotely, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSettings() }
        }))
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let type: String = path.status != .satisfied ? "none" : path.usesInterfaceType(.wifi) ? "wifi"
                : path.usesInterfaceType(.cellular) ? "cellular" : path.usesInterfaceType(.wiredEthernet) ? "wired" : "other"
            let state = ActivityNetworkState(type: type, expensive: path.isExpensive, constrained: path.isConstrained)
            Task { @MainActor [weak self] in await self?.networkChanged(state) }
        }
        monitor.start(queue: DispatchQueue(label: "com.jason.BetterCalendar.Activity.Network"))
        pathMonitor = monitor
    }

    private func networkChanged(_ n: ActivityNetworkState) async {
        guard n != lastNetwork else { return }
        lastNetwork = n
        status.working(.network, at: .now)
        #if os(macOS)
        await recorder?.network(n)
        #else
        guard ActivitySettings.isRecording(at: .now, defaults), let sink else { return }
        _ = try? await sink.record([ActivityEvent(at: .now, kind: .other, deviceId: deviceId, platform: "iOS",
                                                  detail: ["signal": "network", "type": n.type, "expensive": n.expensive ? "true" : "false",
                                                           "constrained": n.constrained ? "true" : "false"])])
        #endif
    }

    private func pruneLocal() async {
        do {
            let removed = try await log.prune(now: .now)
            if !removed.isEmpty { DevLog.shared.info("设备活动", "按 90 天保留期清理了 \(removed.count) 个日文件") }
        } catch { status.set(.storage, .failed("清理旧日文件失败：\(error.localizedDescription)")) }
    }

    // MARK: 智能体（Mac）

    /// 桥接每轮同步时调用：镜像日文件 + 写状态。
    func mirror(to io: AgentBridgeIO, now: Date = .now) async {
        let m = ActivityBridgeMirror(localRoot: log.files.root, bridgeRoot: io.root)
        do {
            _ = try m.mirror(now: now, status: bridgeStatus(now: now))
            status.working(.bridgeMirror, at: now)
        } catch {
            status.set(.bridgeMirror, .failed("镜像到桥接目录失败：\(error.localizedDescription)"))
        }
    }

    func bridgeStatus(now: Date) -> [String: Any] {
        ["schemaVersion": 1, "writtenAt": ActivityCodec.iso(now), "recording": ActivitySettings.isRecording(at: now, defaults),
         "enabled": ActivitySettings.enabled(defaults), "pausedUntil": ActivitySettings.pausedUntil(defaults).map(ActivityCodec.iso) ?? NSNull(),
         "retentionDays": FileActivityLog.retentionDays, "sources": status.snapshot(),
         "note": "recording=false 时没有记录 ≠ 没发生；日文件里 detail.signal=recorder 的行标出每段记录的起止"]
    }

    /// context.json 的 recentActivity（读最近 12 小时，算摘要）。
    func contextSummary(now: Date) async -> [String: Any]? {
        do {
            let events = try await log.events(in: ActivityContextSummary.readWindow(now: now))
            return ActivityContextSummary.build(events: events, now: now, recording: ActivitySettings.isRecording(at: now, defaults),
                                                pausedUntil: ActivitySettings.pausedUntil(defaults), sources: status.snapshot())
        } catch {
            status.set(.storage, .failed("读本机日文件失败：\(error.localizedDescription)"))
            return ["source": "BetterCalendar 设备活动记录", "asOf": ActivityCodec.iso(now), "error": "读本机日文件失败：\(error.localizedDescription)"]
        }
    }
}
