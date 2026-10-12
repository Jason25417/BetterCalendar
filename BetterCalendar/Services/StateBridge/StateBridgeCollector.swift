import Foundation
import Network
#if os(macOS)
import AppKit
import CoreGraphics
import CryptoKit
#endif

@MainActor final class StateBridgeCollector {
    static let shared = StateBridgeCollector()
    private let scheduleReader: any StateBridgeScheduleReading
    init(scheduleReader: any StateBridgeScheduleReading = EventKitBridgeScheduleReader()) {
        self.scheduleReader = scheduleReader
    }
    private var timer: Timer?
    private var sampling = false
    private var networkMonitor: NWPathMonitor?
    #if os(macOS)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var activityTimer: Timer?
    private var lastActivity: BridgeJSON?
    #endif
    var enabled: Bool { UserDefaults.standard.bool(forKey:"dotStateBridge.enabled") }
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled,forKey:"dotStateBridge.enabled")
        if enabled { start() } else { timer?.invalidate(); timer = nil
            networkMonitor?.cancel(); networkMonitor = nil
            #if os(macOS)
            activityTimer?.invalidate(); activityTimer = nil
            workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers.removeAll()
            #endif
            #if os(iOS)
            StateBridgePhone.shared.stop()
            #endif
        }
    }
    func start() {
        guard enabled, StateBridgeClient.shared.configured, !TestHost.isActive else { return }
        let newlyStarted = timer == nil
        if newlyStarted {
            let t = Timer(timeInterval:60,repeats:true) { _ in Task { @MainActor in await StateBridgeCollector.shared.sample() } }
            RunLoop.main.add(t,forMode:.common); timer = t
        }
        if networkMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else { return }
                Task { @MainActor in await StateBridgeCollector.shared.recover() }
            }
            monitor.start(queue:DispatchQueue(label:"com.jason.BetterCalendar.StateBridge.Network")); networkMonitor = monitor
        }
        #if os(macOS)
        if workspaceObservers.isEmpty {
            for event in [NSWorkspace.didActivateApplicationNotification,NSWorkspace.didWakeNotification,NSWorkspace.willSleepNotification] {
                workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:event,object:nil,queue:.main) { note in
                    Task { @MainActor in
                        guard StateBridgeCollector.shared.enabled else { return }
                        if note.name == NSWorkspace.willSleepNotification {
                            StateBridgeClient.shared.emit("device.status",value:.object(["availability":.string("sleeping")]))
                            await StateBridgeClient.shared.uploadAndFlush()
                        } else if note.name == NSWorkspace.didWakeNotification { await StateBridgeCollector.shared.recover() }
                        else { StateBridgeCollector.shared.sampleActivity(force:true) }
                    }
                })
            }
            let t = Timer(timeInterval:15,repeats:true) { _ in Task { @MainActor in StateBridgeCollector.shared.sampleActivity() } }
            RunLoop.main.add(t,forMode:.common); activityTimer = t
        }
        #endif
        #if os(iOS)
        StateBridgePhone.shared.startIfAuthorized()
        #endif
        if newlyStarted { Task { await recover() } }
    }
    /// Recover old observations with their original identities before collecting
    /// a new snapshot. A wake/network event does not mean the person changed task.
    func recover() async {
        guard enabled, !TestHost.isActive else { return }
        await StateBridgeClient.shared.uploadAndFlush()
        await sample()
    }
    func requestPermissions() async {
        guard !TestHost.isActive else { return }
        let failures = await scheduleReader.requestPermissions()
        if !failures.isEmpty {
            StateBridgeClient.shared.emit("source.status",value:.object(failures.mapValues { .string($0) }),validFor:3600)
            DevLog.shared.warn("StateBridge","日历/提醒事项授权未全部完成，请检查采集来源状态")
        }
        #if os(iOS)
        await StateBridgePhone.shared.requestPermissions()
        #endif
        await sample()
    }
    func sample() async {
        guard enabled, !sampling, StateBridgeClient.shared.configured, !TestHost.isActive else { return }; sampling = true; defer { sampling = false }
        let client = StateBridgeClient.shared, now = Date()
        #if os(macOS)
        let app = NSWorkspace.shared.frontmostApplication
        sampleActivity(force:true)
        if let bundle = app?.bundleIdentifier {
            let command: String?
            if bundle == "com.apple.Safari" { command = "tell application \"Safari\" to return {URL of current tab of front window, name of current tab of front window}" }
            else if ["com.google.Chrome","com.microsoft.edgemac","company.thebrowser.Browser"].contains(bundle), let name = app?.localizedName { command = "tell application \"\(name.replacingOccurrences(of:"\"",with:""))\" to return {URL of active tab of front window, title of active tab of front window}" }
            else { command = nil }
            if let command, let script = NSAppleScript(source:command) {
                var error: NSDictionary?; let result = script.executeAndReturnError(&error)
                if error == nil { var url = URLComponents(string:result.atIndex(1)?.stringValue ?? ""); url?.query = nil; url?.fragment = nil
                    client.emit("mac.browser",value:.object(["url":.text(url?.string),"title":.text(result.atIndex(2)?.stringValue)]))
                } else { client.emit("mac.browser",value:.object(["availability":.string("permission-or-browser-unavailable")])) }
            } else { client.emit("mac.browser",value:.object(["availability":.string("not-frontmost")])) }
        }
        await sampleFiles()
        guard enabled else { return }
        sampleHistory()
        #endif
        let schedule = await scheduleReader.snapshot(at: now)
        guard enabled else { return }
        client.emit("calendar.events",value:schedule.calendar,validFor:3600,observedAt:schedule.observedAt)
        client.emit("reminders.items",value:schedule.reminders,validFor:3600,observedAt:schedule.observedAt)
        #if os(iOS)
        await StateBridgePhone.shared.readHealth()
        #endif
        client.emit("device.status",value:.object(["availability":.string("online"),"platform":.string(ProcessInfo.processInfo.operatingSystemVersionString)]))
        await client.uploadAndFlush()
    }
    #if os(macOS)
    private func sampleActivity(force: Bool = false) {
        guard enabled, !TestHost.isActive else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.null)
        let value = BridgeJSON.object(["bundleId":.text(app?.bundleIdentifier),"app":.text(app?.localizedName),"idle":.string(idle < 60 ? "active" : idle < 300 ? "1-5min" : idle < 1800 ? "5-30min" : "over30min")])
        if force || value != lastActivity { StateBridgeClient.shared.emit("mac.activity",value:value); lastActivity = value }
    }
    func chooseHistoryFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/Library/Caches/ComputerUse/Skysight")
        if panel.runModal() == .OK, let url = panel.url, let bookmark = try? url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) { UserDefaults.standard.set(bookmark,forKey:"dotStateBridge.historyFolder") }
    }
    private func sampleHistory() {
        guard let bookmark = UserDefaults.standard.data(forKey:"dotStateBridge.historyFolder") else { return }
        do {
            var stale = false; let root = try URL(resolvingBookmarkData:bookmark,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale)
            guard root.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }; defer { root.stopAccessingSecurityScopedResource() }
            let segments = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("segments"),includingPropertiesForKeys:nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let segment = segments.last else { return }
            let handle = try FileHandle(forReadingFrom:segment.appendingPathComponent("events.jsonl")); defer { try? handle.close() }
            let length = try handle.seekToEnd(), offset = length > 512000 ? length - 512000 : 0
            try handle.seek(toOffset:offset); let data = try handle.readToEnd() ?? Data()
            let lines = String(decoding:data,as:UTF8.self).split(separator:"\n")
            let cursorKey = "dotStateBridge.historyCursor", prior = UserDefaults.standard.dictionary(forKey:cursorKey)
            let oldId = prior?["segment"] as? String == segment.lastPathComponent ? (prior?["id"] as? Int ?? -1) : -1
            var contexts: [BridgeJSON] = [], latestId = oldId, latestDate: Date?
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            for line in lines.suffix(100) {
                guard let record = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any], let id = record["id"] as? Int, id > oldId, let timestamp = record["timestamp"] as? String, let app = record["app"] as? [String:Any] else { continue }
                let window = record["window"] as? [String:Any] ?? [:]
                var url = URLComponents(string:window["url"] as? String ?? ""); url?.query = nil; url?.fragment = nil; url?.user = nil; url?.password = nil
                contexts.append(.object(["id":.number(Double(id)),"timestamp":.string(timestamp),"app":.text(app["name"] as? String),"bundleId":.text(app["bundleIdentifier"] as? String),"window":.text((window["title"] as? String).map { String($0.prefix(300)) }),"url":.text(url?.string)]))
                latestId = max(latestId,id); latestDate = formatter.date(from:timestamp) ?? ISO8601DateFormatter().date(from:timestamp)
            }
            if !contexts.isEmpty {
                // Exclude AX contents and keyboard text. File activity is not proof that capture is running.
                if StateBridgeClient.shared.emit("mac.history",value:.object(["contexts":.array(Array(contexts.suffix(20))),"captureStatus":.string("unknown-use-computer-history-status"),"boundedTail":.bool(true)]),validFor:180,observedAt:latestDate ?? Date()) {
                    UserDefaults.standard.set(["segment":segment.lastPathComponent,"id":latestId],forKey:cursorKey)
                }
            }
        } catch { StateBridgeClient.shared.emit("mac.history",value:.object(["availability":.string("history-directory-unavailable")]),validFor:180) }
    }
    var selectedFolderCount: Int { fileBookmarks.count }
    private var fileBookmarks: [Data] {
        if let bookmarks = UserDefaults.standard.array(forKey:"dotStateBridge.folders") as? [Data] { return bookmarks }
        return UserDefaults.standard.data(forKey:"dotStateBridge.folder").map { [$0] } ?? []
    }
    func chooseFilesFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "可多选学习、开发、文档、桌面与下载目录（最多12个）；包括子文件夹，只读取名称与修改时间。"
        guard panel.runModal() == .OK else { return }
        do {
            let bookmarks = try panel.urls.prefix(12).map { try $0.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) }
            UserDefaults.standard.set(bookmarks,forKey:"dotStateBridge.folders")
        } catch {
            DevLog.shared.warn("StateBridge", "无法保存所选文件夹权限；原配置保留。")
            StateBridgeClient.shared.emit("files.activity",value:.object(["availability":.string("folder-selection-failed")]),validFor:3600)
        }
    }
    private func sampleFiles() async {
        let bookmarks = fileBookmarks
        guard !bookmarks.isEmpty else {
            StateBridgeClient.shared.emit("files.activity",value:.object(["availability":.string("not-configured")]),validFor:3600)
            return
        }
        var roots: [URL] = [], refreshed = bookmarks, unavailable = 0
        for (index, bookmark) in bookmarks.prefix(12).enumerated() {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData:bookmark,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale)
                guard url.startAccessingSecurityScopedResource() else { unavailable += 1; continue }
                roots.append(url)
                if stale, let updated = try? url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) { refreshed[index] = updated }
            } catch { unavailable += 1 }
        }
        defer { roots.forEach { $0.stopAccessingSecurityScopedResource() } }
        if refreshed != bookmarks { UserDefaults.standard.set(refreshed,forKey:"dotStateBridge.folders") }
        let accessibleRoots = roots
        let snapshot = await StateBridgeFileMonitor.shared.scan(roots:accessibleRoots)
        guard enabled else { return }
        let f = ISO8601DateFormatter()
        StateBridgeClient.shared.emit("files.activity",value:.object([
            "schemaVersion":.number(2),
            "availability":.string(roots.isEmpty ? "unavailable" : unavailable > 0 ? "partial" : "available"),
            "unavailableRoots":.number(Double(unavailable)),
            "roots":.array(snapshot.roots.map { .object(["path":.string(String($0.path.prefix(200))),"coverage":.string($0.status),"inspected":.number(Double($0.inspected))]) }),
            "items":.array(snapshot.items.map { .object(["id":.string(SHA256.hash(data:Data((snapshot.roots[$0.root].path + "/" + $0.relativePath).utf8)).map { String(format:"%02x",$0) }.joined()),"root":.number(Double($0.root)),"path":.string(String($0.relativePath.prefix(180))),"modifiedAt":.string(f.string(from:$0.modifiedAt))]) }),
            "omittedItems":.bool(snapshot.omittedItems),
            "metadataOnly":.bool(true)
        ]),validFor:3600)
    }
    #endif
}
