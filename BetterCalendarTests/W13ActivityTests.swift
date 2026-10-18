//
//  W13ActivityTests.swift
//  BetterCalendarTests
//
//  W13 设备活动记录：只记变化的状态机、日文件存取与 90 天保留、桥接镜像、快捷指令记一笔、iCloud 导入映射、
//  context 摘要截断、开关 / 暂停停止记录。全部用临时目录、内存假实现与固定时刻（不用 Date.now，不碰真 bridge/、真 iCloud）。
//

import CloudKit
import Foundation
import Testing
@testable import BetterCalendar

private let cal = Calendar.current
private func at(_ day: Int, _ h: Int, _ m: Int = 0, _ s: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m, second: s))!
}
private func tempDir(_ name: String = "w13") -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func suite() -> UserDefaults {
    let name = "w13-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d
}

/// 可变时钟（测试里推进时间）。
@MainActor final class W13Clock { var now: Date; init(_ d: Date) { now = d } }

@MainActor final class FakeActivityProbe: ActivityProbing {
    var front: ActivityFrontApp? = ActivityFrontApp(name: "Xcode", bundleID: "com.apple.dt.Xcode", pid: 1)
    var idle: Double? = 1
    var powerState: ActivityPowerState? = ActivityPowerState(source: "ac", charging: true, percent: 80)
    var title: ActivityWindowTitleRead = .title("BetterCalendar — AppContainer.swift")
    func frontApp() -> ActivityFrontApp? { front }
    func idleSeconds() -> Double? { idle }
    func power() -> ActivityPowerState? { powerState }
    func windowTitle(of app: ActivityFrontApp) async -> ActivityWindowTitleRead { title }
}

actor FakeBrowser: ActivityBrowserReading {
    var result: ActivityBrowserRead = .page(url: "https://example.com/a", title: "A")
    func set(_ r: ActivityBrowserRead) { result = r }
    func page(bundleID: String) async -> ActivityBrowserRead { result }
}

@MainActor
@Suite("W13ActivityTests")
struct W13ActivityTests {

    private func makeRecorder(_ clock: W13Clock, defaults: UserDefaults) -> (MacActivityRecorder, MemoryActivityLog, FakeActivityProbe, FakeBrowser, ActivityStatusBoard) {
        let log = MemoryActivityLog(), probe = FakeActivityProbe(), browser = FakeBrowser(), status = ActivityStatusBoard()
        status.logsFailures = false
        let r = MacActivityRecorder(log: log, probe: probe, browser: browser, status: status, deviceId: "mac-1",
                                    defaults: defaults, now: { clock.now })
        return (r, log, probe, browser, status)
    }

    private func all(_ log: MemoryActivityLog) async throws -> [ActivityEvent] {
        try await log.events(in: DateInterval(start: at(1, 0), end: at(30, 0)))
    }

    // MARK: 状态机：只记变化

    @Test func recorderRecordsOnlyChanges() async throws {
        let clock = W13Clock(at(20, 9)), d = suite()
        let (r, log, probe, browser, _) = makeRecorder(clock, defaults: d)
        await r.tick()                                   // 开始 + 前台 Xcode + 窗口标题 + 电源
        clock.now = at(20, 9, 0, 10); await r.tick()     // 什么都没变
        var e = try await all(log)
        #expect(e.filter { $0.kind == .appActivated }.count == 1)
        #expect(e.filter { $0.kind == .windowChanged }.count == 1)
        #expect(e.first?.detail?["signal"] == "recorder" && e.first?.detail?["state"] == "started")
        #expect(e.filter { $0.detail?["signal"] == "power" }.count == 1)

        // 切到 Edge：记 appActivated + 当前页；同一页再问一次不重复；标题变了再记
        probe.front = ActivityFrontApp(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", pid: 2)
        clock.now = at(20, 9, 1); await r.tick()
        clock.now = at(20, 9, 1, 10); await r.tick()
        await browser.set(.page(url: "https://example.com/a?token=abc&q=swift#frag", title: "A (1)"))
        clock.now = at(20, 9, 1, 20); await r.tick()
        e = try await all(log)
        let pages = e.filter { $0.kind == .browserPage }
        #expect(e.filter { $0.kind == .appActivated }.count == 2)
        #expect(pages.count == 2)
        #expect(pages.last?.url == "https://example.com/a?token=REDACTED&q=swift")   // 凭据抹掉、锚点去掉、搜索词保留
        #expect(pages.last?.bundleID == "com.microsoft.edgemac")
        // 浏览器读页成功时不重复记它的窗口标题
        #expect(e.filter { $0.kind == .windowChanged }.count == 1)
    }

    @Test func browserFailureFallsBackToWindowTitleAndIsVisible() async throws {
        let clock = W13Clock(at(20, 9)), d = suite()
        let (r, log, probe, browser, status) = makeRecorder(clock, defaults: d)
        probe.front = ActivityFrontApp(name: "Safari", bundleID: "com.apple.Safari", pid: 3)
        await browser.set(.failed(code: -600, reason: AppleScriptActivityBrowserReader.reason(-600)))
        probe.title = .title("Example Domain")
        await r.tick()
        let e = try await all(log)
        #expect(e.contains { $0.kind == .windowChanged && $0.windowTitle == "Example Domain" })
        guard case let .failed(why)? = status.states[.browser] else { Issue.record("浏览器失败要可见"); return }
        #expect(why.contains("沙盒"))
        probe.title = .noPermission
        probe.front = ActivityFrontApp(name: "Notes", bundleID: "com.apple.Notes", pid: 4)
        clock.now = at(20, 9, 0, 10); await r.tick()
        guard case .noPermission? = status.states[.windowTitle] else { Issue.record("没有辅助功能权限要明确显示"); return }
    }

    @Test func idleLockAndSleepPairUp() async throws {
        let clock = W13Clock(at(20, 10)), d = suite()
        let (r, log, probe, _, _) = makeRecorder(clock, defaults: d)
        await r.tick()
        probe.idle = 200; clock.now = at(20, 10, 5); await r.tick()        // 200 秒没输入 → idleStart 在最后一次输入时
        probe.idle = 210; clock.now = at(20, 10, 5, 10); await r.tick()    // 仍空闲，不重复
        var e = try await all(log)
        let start = e.filter { $0.kind == .idleStart }
        #expect(start.count == 1 && start.first?.at == at(20, 10, 5).addingTimeInterval(-200))
        probe.idle = 2; clock.now = at(20, 10, 6); await r.tick()           // 回来了
        e = try await all(log)
        #expect(e.filter { $0.kind == .idleEnd }.count == 1)

        // 锁屏：记锁屏；锁着时切前台不记；解锁后重新记当前前台
        probe.idle = 300; clock.now = at(20, 10, 20); await r.tick()        // 又空闲
        clock.now = at(20, 10, 21); await r.handle(.screenLocked)
        e = try await all(log)
        #expect(e.last?.kind == .screenLocked)
        #expect(e.filter { $0.kind == .idleEnd }.last?.detail?["reason"] == "screenLocked")   // 锁屏结束空闲段
        probe.front = ActivityFrontApp(name: "Finder", bundleID: "com.apple.finder", pid: 5); probe.idle = 1
        clock.now = at(20, 10, 22); await r.tick()
        #expect(try await all(log).filter { $0.kind == .appActivated }.count == 1)
        clock.now = at(20, 10, 30); await r.handle(.screenUnlocked)
        e = try await all(log)
        #expect(e.contains { $0.kind == .screenUnlocked })
        #expect(e.filter { $0.kind == .appActivated }.last?.bundleID == "com.apple.finder")
        // 睡眠 / 唤醒
        clock.now = at(20, 11); await r.handle(.systemSleep)
        clock.now = at(20, 12); await r.handle(.systemWake)
        e = try await all(log)
        #expect(e.contains { $0.kind == .systemSleep } && e.contains { $0.kind == .systemWake })
        #expect(e.filter { $0.kind == .appActivated }.count == 3)   // 唤醒后重新记前台
    }

    // MARK: 开关 / 暂停

    @Test func settingsSwitchAndPauseStopRecording() async throws {
        let clock = W13Clock(at(20, 14)), d = suite()
        #expect(ActivitySettings.enabled(d))   // 实验期默认开
        let (r, log, probe, _, status) = makeRecorder(clock, defaults: d)
        await r.tick()
        ActivitySettings.setEnabled(false, d)
        clock.now = at(20, 14, 1); await r.tick()
        probe.front = ActivityFrontApp(name: "Music", bundleID: "com.apple.Music", pid: 9)
        clock.now = at(20, 14, 2); await r.tick()
        var e = try await all(log)
        #expect(e.last?.detail?["state"] == "paused" && e.last?.detail?["reason"] == "disabled")
        #expect(!e.contains { $0.bundleID == "com.apple.Music" })
        guard case .off? = status.states[.frontApp] else { Issue.record("关掉后状态行要显示未在记录"); return }

        // 打开但暂停 1 小时：照样不记；过了暂停期自动恢复
        ActivitySettings.setEnabled(true, d)
        ActivitySettings.pause(until: at(20, 15, 2), d)
        clock.now = at(20, 14, 30); await r.tick()
        #expect(try await all(log).filter { $0.detail?["state"] == "resumed" }.isEmpty)
        clock.now = at(20, 15, 3); await r.tick()
        e = try await all(log)
        #expect(e.contains { $0.detail?["state"] == "resumed" })
        #expect(e.last(where: { $0.kind == .appActivated })?.bundleID == "com.apple.Music")

        // ActivityRecording 的按钮写的是同一组键
        let hub = ActivityRecording(log: FileActivityLog(root: tempDir()), deviceId: "mac-1", defaults: d)
        hub.pauseOneHour(now: at(20, 16))
        #expect(ActivitySettings.pausedUntil(d) == at(20, 17) && !ActivitySettings.isRecording(at: at(20, 16, 30), d))
        hub.resumeNow()
        #expect(ActivitySettings.isRecording(at: at(20, 16, 30), d))
        #expect(SettingsSync.syncedKeys.isSuperset(of: [ActivitySettings.enabledKey, ActivitySettings.pausedUntilKey]))
    }

    // MARK: 日文件

    @Test func dayFileLogAppendReadAndRetention() async throws {
        let root = tempDir("w13-log")
        let log = FileActivityLog(root: root)
        let a = ActivityEvent(at: at(20, 23, 59), kind: .appActivated, deviceId: "m", platform: "macOS", appName: "Xcode")
        let b = ActivityEvent(at: at(21, 0, 1), kind: .browserPage, deviceId: "m", platform: "macOS", url: "https://x.y/z")
        try await log.append([b, a])
        #expect(log.files.allDays() == ["2026-10-20", "2026-10-21"])   // 按本地日期分文件
        let both = try await log.events(in: DateInterval(start: at(20, 0), end: at(22, 0)))
        #expect(both.map(\.id) == [a.id, b.id])                         // 按时间升序
        // 坏行跳过、计数
        let fh = try FileHandle(forWritingTo: log.files.url(forDay: "2026-10-21"))
        try fh.seekToEnd(); try fh.write(contentsOf: Data("{not json\n".utf8)); try fh.close()
        #expect(try await log.events(in: DateInterval(start: at(21, 0), end: at(21, 1))).count == 1)
        #expect(await log.lastBadLines == 1)
        // 日文件是 ISO 8601 时间（智能体侧 Node 直接读）
        let text = try String(contentsOf: log.files.url(forDay: "2026-10-20"), encoding: .utf8)
        #expect(text.contains("\"at\":\"2026-10-"))
        // 按 id 去重追加
        #expect(try await log.appendNew([a, b]).isEmpty)
        // 90 天保留
        let old = ActivityEvent(at: at(20, 12).addingTimeInterval(-100 * 86_400), kind: .idleStart, deviceId: "m", platform: "macOS")
        try await log.append([old])
        let removed = try await log.prune(now: at(21, 12))
        #expect(removed.count == 1 && log.files.allDays() == ["2026-10-20", "2026-10-21"])
    }

    // MARK: 桥接镜像

    @Test func bridgeMirrorCopiesChangedDaysAndPrunes() async throws {
        let local = tempDir("w13-local"), bridge = tempDir("w13-bridge")   // 临时目录：绝不碰真 bridge/
        let log = FileActivityLog(root: local)
        try await log.append([ActivityEvent(at: at(20, 9), kind: .appActivated, deviceId: "m", platform: "macOS", appName: "Xcode")])
        let mirror = ActivityBridgeMirror(localRoot: local, bridgeRoot: bridge)
        let first = try mirror.mirror(now: at(20, 10), status: ["recording": true])
        #expect(first.copied == ["2026-10-20"])
        let copied = try Data(contentsOf: bridge.appendingPathComponent("activity/2026-10-20.jsonl"))
        #expect(ActivityCodec.decodeLines(copied).events.first?.appName == "Xcode")
        #expect(FileManager.default.fileExists(atPath: bridge.appendingPathComponent("activity/status.json").path))
        #expect(try mirror.mirror(now: at(20, 10)).copied.isEmpty)     // 没变化不拷
        try await log.append([ActivityEvent(at: at(20, 9, 5), kind: .idleStart, deviceId: "m", platform: "macOS")])
        #expect(try mirror.mirror(now: at(20, 10)).copied == ["2026-10-20"])
        // bridge 里过期的日文件删掉
        try Data().write(to: bridge.appendingPathComponent("activity/2026-01-01.jsonl"))
        #expect(try mirror.mirror(now: at(20, 10)).pruned == ["2026-01-01"])
    }

    // MARK: 快捷指令记一笔

    @Test func shortcutIntentWritesEventAndQueuesUpload() async throws {
        let d = suite(), cloud = MemoryActivityCloud()
        let sink = ActivityPhoneSink(log: FileActivityLog(root: tempDir()), outbox: ActivityOutbox(url: nil), transport: cloud)
        let r = try await ActivityShortcutRecorder.record(opened: true, appName: "  微信 ", at: at(20, 8), deviceId: "phone-1",
                                                          platform: "iOS", sink: sink, defaults: d, extra: ["batteryPercent": "55"])
        guard case let .recorded(o) = r else { Issue.record("应记下"); return }
        #expect(o.written == 1 && o.uploaded == 1 && o.pendingUpload == 0)
        let e = try await sink.log.events(in: DateInterval(start: at(20, 0), end: at(21, 0)))
        #expect(e.count == 1 && e[0].kind == .appOpened && e[0].source == .shortcut && e[0].appName == "微信")
        #expect(e[0].detail?["batteryPercent"] == "55")
        #expect(await cloud.stored[e[0].id] != nil)
        // 「所有 App」自动化：不知道是哪个 App → appName 空 + 标记
        let unknown = ActivityShortcutRecorder.event(opened: false, appName: nil, at: at(20, 9), deviceId: "p", platform: "iOS")
        #expect(unknown.kind == .appClosed && unknown.appName == nil && unknown.detail?["appUnknown"] == "true")
        // 传不上：本机照记，留在队列里
        await cloud.setFailUpload(true)
        let r2 = try await ActivityShortcutRecorder.record(opened: false, appName: nil, at: at(20, 9), deviceId: "phone-1",
                                                           platform: "iOS", sink: sink, defaults: d)
        guard case let .recorded(o2) = r2 else { Issue.record("应记下"); return }
        #expect(o2.written == 1 && o2.pendingUpload == 1 && o2.uploadError != nil)
        // 暂停时什么都不记
        ActivitySettings.pause(until: at(20, 11), d)
        #expect(try await ActivityShortcutRecorder.record(opened: true, appName: "X", at: at(20, 10), deviceId: "p",
                                                          platform: "iOS", sink: sink, defaults: d) == .notRecording)
        // 意图本身：后台运行、不打开 App
        #expect(RecordAppActivityIntent.openAppWhenRun == false)
    }

    // MARK: iCloud 导入映射

    @Test func cloudRecordMappingAndImport() async throws {
        let e = ActivityEvent(at: at(20, 8), kind: .appOpened, source: .shortcut, deviceId: "phone-1", platform: "iOS", appName: "微信")
        let record = try ActivityCloudCodec.record(e)
        #expect(record.recordType == "BCActivityEvent" && record.recordID.zoneID.zoneName == "BCActivity")
        #expect(record.recordID.recordName == "act-" + e.id.uuidString)
        #expect(record["kind"] as? String == "appOpened" && record["platform"] as? String == "iOS" && record["appName"] as? String == "微信")
        #expect(ActivityCloudCodec.event(record) == e)
        let bad = CKRecord(recordType: "BCActivityEvent", recordID: record.recordID); bad["payload"] = "{" as CKRecordValue
        #expect(ActivityCloudCodec.event(bad) == nil)

        let cloud = MemoryActivityCloud(), d = suite(), status = ActivityStatusBoard()
        status.logsFailures = false
        let log = FileActivityLog(root: tempDir())
        let importer = ActivityCloudImporter(transport: cloud, log: log, status: status, defaults: d)
        let mac = ActivityEvent(at: at(20, 8, 1), kind: .appActivated, deviceId: "mac", platform: "macOS")
        try await cloud.upload([e, mac])
        #expect(await importer.importOnce(now: at(20, 9)) == 1)          // Mac 自己的不经云端导入
        #expect(await importer.importOnce(now: at(20, 9, 2)) == 0)       // 增量：没新的
        d.removeObject(forKey: ActivityCloudImporter.tokenKey)            // 令牌丢了重拉：按 id 去重
        #expect(await importer.importOnce(now: at(20, 9, 3)) == 0)
        guard case .working? = status.states[.shortcut] else { Issue.record("收到快捷指令记录后状态应为正常"); return }
        // 14 天后清理云端副本（本机已有）
        _ = await importer.importOnce(now: at(20, 9).addingTimeInterval(15 * 86_400))
        #expect(await cloud.stored.isEmpty)
        #expect(try await log.events(in: DateInterval(start: at(20, 0), end: at(21, 0))).count == 1)
    }

    // MARK: context 摘要

    @Test func contextSummaryIsCompactAndTruncated() throws {
        var events: [ActivityEvent] = []
        let now = at(20, 12)
        for i in 0..<12 {   // 12 个 App，每个 5 分钟
            events.append(ActivityEvent(at: now.addingTimeInterval(Double(-60 + i * 5) * 60), kind: .appActivated,
                                        deviceId: "m", platform: "macOS", appName: "App\(i)", bundleID: "b.\(i)"))
        }
        events.append(ActivityEvent(at: now.addingTimeInterval(-60), kind: .browserPage, deviceId: "m", platform: "macOS",
                                    appName: "App11", bundleID: "b.11", url: "https://www.example.com/x", pageTitle: String(repeating: "长", count: 200)))
        for i in 0..<15 {
            events.append(ActivityEvent(at: now.addingTimeInterval(Double(-i) * 600), kind: .appOpened, source: .shortcut,
                                        deviceId: "p", platform: "iOS", appName: "P\(i)"))
        }
        let s = ActivityContextSummary.build(events: events, now: now, recording: true, pausedUntil: nil,
                                             sources: [["source": "browser", "state": "failed", "reason": "沙盒"]])
        let window = s["lastWindow"] as! [String: Any]
        let apps = window["apps"] as! [String: Any]
        #expect((apps["items"] as! [[String: Any]]).count == ActivityContextSummary.topApps)
        #expect(apps["truncated"] as? Bool == true && apps["total"] as? Int == 12)
        let current = s["current"] as! [String: Any]
        #expect(current["state"] as? String == "active" && current["app"] as? String == "App11")
        let page = current["page"] as! [String: Any]
        #expect(page["domain"] as? String == "example.com" && (page["title"] as! String).count == ActivityContextSummary.titleChars + 1)
        let iphone = s["iphone"] as! [String: Any]
        #expect((iphone["items"] as! [Any]).count == ActivityContextSummary.iphoneEvents && iphone["truncated"] as? Bool == true)
        #expect(s["sourceProblems"] != nil && s["redLine"] != nil && s["asOf"] != nil && s["source"] != nil)
        // 进 context.json
        var input = AgentContextInput(now: now); input.activity = s
        #expect(AgentBridgeContext.snapshot(input)["recentActivity"] != nil)
        #expect(AgentBridgeContext.snapshot(AgentContextInput(now: now))["recentActivity"] == nil)
        // 空闲 / 锁屏断段
        let segs = ActivityContextSummary.segments([
            ActivityEvent(at: at(20, 9), kind: .appActivated, deviceId: "m", platform: "macOS", appName: "A"),
            ActivityEvent(at: at(20, 9, 10), kind: .idleStart, deviceId: "m", platform: "macOS"),
            ActivityEvent(at: at(20, 9, 40), kind: .idleEnd, deviceId: "m", platform: "macOS"),
            ActivityEvent(at: at(20, 9, 50), kind: .screenLocked, deviceId: "m", platform: "macOS"),
        ], now: at(20, 10))
        #expect(segs.map { Int($0.end.timeIntervalSince($0.start) / 60) } == [10, 10])
    }

    // MARK: 其他

    @Test func launchAtLoginDefaultsOnOnceForInstalledBuildOnly() {
        #expect(ActivityLaunchAtLogin.decide(alreadyAutoRegistered: false, isEnabled: false, bundlePath: "/Applications/BetterCalendar.app") == .register)
        if case .skip = ActivityLaunchAtLogin.decide(alreadyAutoRegistered: true, isEnabled: false, bundlePath: "/Applications/BetterCalendar.app") {} else { Issue.record("关过就不再替你打开") }
        if case .skip = ActivityLaunchAtLogin.decide(alreadyAutoRegistered: false, isEnabled: false, bundlePath: "/Users/x/DerivedData/B.app") {} else { Issue.record("调试版不注册") }
    }

    @Test func urlCleaningKeepsContextDropsSecrets() {
        #expect(ActivityURL.clean("https://u:p@www.google.com/search?q=swift+actor&code=123&keyword=a#x") == "https://www.google.com/search?q=swift+actor&code=REDACTED&keyword=a")
        #expect(ActivityURL.clean("https://x.com/cb?access_token=abc&sessionId=1")?.contains("abc") == false)
        #expect(ActivityURL.host("https://www.Example.com/a") == "example.com")
    }

    @Test func phoneTransformsMotionChangesAndSleepSessions() {
        let m = PhoneActivityTransforms.motionEvents([
            .init(start: at(20, 8), activity: "stationary", confidence: "high"),
            .init(start: at(20, 8, 5), activity: "stationary", confidence: "high"),
            .init(start: at(20, 8, 10), activity: "walking", confidence: "medium"),
        ], deviceId: "p")
        #expect(m.map { $0.detail?["activity"] } == ["stationary", "walking"])
        #expect(m[1].id == ActivityStableID.make("motion-\(Int(at(20, 8, 10).timeIntervalSince1970 * 1000))-walking"))   // 重读同一样本 = 同一个 id
        let s = PhoneActivityTransforms.sleepEvents([
            .init(start: at(19, 23), end: at(20, 2)), .init(start: at(20, 2, 20), end: at(20, 7)),   // 中间醒 20 分钟 = 同一段
            .init(start: at(20, 13), end: at(20, 13, 30)),                                           // 午睡：刚结束不到 1 小时，先不收
        ], now: at(20, 14), deviceId: "p")
        #expect(s.count == 1 && s[0].detail?["minutes"] == "480")
    }
}
