import Foundation
import EventKit
#if os(macOS)
import AppKit
import CoreGraphics
#endif

@MainActor final class StateBridgeCollector {
    static let shared = StateBridgeCollector()
    private let calendar = EKEventStore()
    private var timer: Timer?
    private var sampling = false
    #if os(macOS)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var activityTimer: Timer?
    private var lastActivity: BridgeJSON?
    #endif
    var enabled: Bool { UserDefaults.standard.bool(forKey:"dotStateBridge.enabled") }
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled,forKey:"dotStateBridge.enabled")
        if enabled { start() } else { timer?.invalidate(); timer = nil
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
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { _ in Task { @MainActor in await StateBridgeCollector.shared.sample() } } }
        #if os(macOS)
        if workspaceObservers.isEmpty {
            for event in [NSWorkspace.didActivateApplicationNotification,NSWorkspace.didWakeNotification,NSWorkspace.willSleepNotification] {
                workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:event,object:nil,queue:.main) { note in
                    Task { @MainActor in
                        guard StateBridgeCollector.shared.enabled else { return }
                        if note.name == NSWorkspace.willSleepNotification { StateBridgeClient.shared.emit("device.status",value:.object(["availability":.string("sleeping")])) }
                        else { StateBridgeCollector.shared.sampleActivity(force:true) }
                    }
                })
            }
            activityTimer = Timer.scheduledTimer(withTimeInterval:15,repeats:true) { _ in Task { @MainActor in StateBridgeCollector.shared.sampleActivity() } }
        }
        #endif
        #if os(iOS)
        StateBridgePhone.shared.startIfAuthorized()
        #endif
    }
    func requestPermissions() async {
        guard !TestHost.isActive else { return }
        do { _ = try await calendar.requestFullAccessToEvents(); _ = try await calendar.requestFullAccessToReminders() }
        catch { StateBridgeClient.shared.emit("source.status",value:.object(["calendar":.string("permission-request-failed")]),validFor:3600) }
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
        sampleFiles()
        sampleHistory()
        #endif
        if EKEventStore.authorizationStatus(for:.event) == .fullAccess {
            let events = calendar.events(matching:calendar.predicateForEvents(withStart:now.addingTimeInterval(-86400),end:now.addingTimeInterval(14*86400),calendars:nil)).sorted { $0.startDate < $1.startDate }
            let f = ISO8601DateFormatter()
            client.emit("calendar.events",value:.object(["items":.array(events.prefix(120).map { .object(["id":.text($0.eventIdentifier),"title":.text($0.title),"start":.string(f.string(from:$0.startDate)),"end":.string(f.string(from:$0.endDate)),"allDay":.bool($0.isAllDay),"location":.text($0.location)]) }),"truncated":.bool(events.count > 120)]),validFor:3600)
        } else { client.emit("calendar.events",value:.object(["availability":.string("not-authorized")]),validFor:3600) }
        if EKEventStore.authorizationStatus(for:.reminder) == .fullAccess {
            let reminders: [EKReminder] = await withCheckedContinuation { c in calendar.fetchReminders(matching:calendar.predicateForIncompleteReminders(withDueDateStarting:nil,ending:nil,calendars:nil)) { c.resume(returning:$0 ?? []) } }
            let f = ISO8601DateFormatter()
            client.emit("reminders.items",value:.object(["items":.array(reminders.sorted { $0.calendarItemIdentifier < $1.calendarItemIdentifier }.prefix(100).map { r in .object(["id":.string(r.calendarItemIdentifier),"title":.text(r.title),"priority":.number(Double(r.priority)),"due":.text(r.dueDateComponents.flatMap { Calendar.current.date(from:$0) }.map { f.string(from:$0) })]) }),"truncated":.bool(reminders.count > 100)]),validFor:3600)
        } else { client.emit("reminders.items",value:.object(["availability":.string("not-authorized")]),validFor:3600) }
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
                StateBridgeClient.shared.emit("mac.history",value:.object(["contexts":.array(Array(contexts.suffix(20))),"captureStatus":.string("unknown-use-computer-history-status"),"boundedTail":.bool(true)]),validFor:180,observedAt:latestDate ?? Date())
                UserDefaults.standard.set(["segment":segment.lastPathComponent,"id":latestId],forKey:cursorKey)
            }
        } catch { StateBridgeClient.shared.emit("mac.history",value:.object(["availability":.string("history-directory-unavailable")]),validFor:180) }
    }
    func chooseFilesFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let bookmark = try? url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) { UserDefaults.standard.set(bookmark,forKey:"dotStateBridge.folder") }
    }
    private func sampleFiles() {
        guard let bookmark = UserDefaults.standard.data(forKey:"dotStateBridge.folder") else { return }
        do {
            var stale = false; let url = try URL(resolvingBookmarkData:bookmark,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale)
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }; defer { url.stopAccessingSecurityScopedResource() }
            let keys: Set<URLResourceKey> = [.contentModificationDateKey,.isRegularFileKey]
            let children = try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:Array(keys),options:[.skipsHiddenFiles])
            let recent = try children.compactMap { child -> (String,Date)? in let v = try child.resourceValues(forKeys:keys); guard v.isRegularFile == true, let date = v.contentModificationDate else { return nil }; return (child.lastPathComponent,date) }.sorted { $0.1 > $1.1 }.prefix(30)
            let f = ISO8601DateFormatter(); StateBridgeClient.shared.emit("files.activity",value:.array(recent.map { .object(["name":.string($0.0),"modifiedAt":.string(f.string(from:$0.1))]) }),validFor:3600)
        } catch { StateBridgeClient.shared.emit("files.activity",value:.object(["availability":.string("folder-unavailable")]),validFor:3600) }
    }
    #endif
}
