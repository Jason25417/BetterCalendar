import Foundation

nonisolated struct BridgeBrowserSnapshot: Sendable {
    let observedAt: Date
    let value: BridgeJSON
}

nonisolated protocol StateBridgeBrowserReading: Sendable {
    func snapshot(bundleID: String?, at date: Date) async -> BridgeBrowserSnapshot
}

/// Keep unsupported/empty/error distinct, and strip URL credentials before any
/// value reaches the transport queue. Only known browser bundle IDs are scripted.
nonisolated enum BridgeBrowserProjection {
    static let supportedBundles: Set<String> = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser"]
    static func notFrontmost() -> BridgeJSON {
        .object(["schemaVersion": .number(2), "availability": .string("not-frontmost"), "reason": .string("foreground-app-is-not-a-supported-browser")])
    }
    static func failure(code: Int?) -> BridgeJSON {
        let reason: String
        switch code {
        case -1743: reason = "automation-permission-denied"
        case -600: reason = "browser-not-running"
        case -1712: reason = "browser-read-timeout"
        case -1728: reason = "browser-object-unavailable"
        default: reason = "browser-read-failed"
        }
        return .object(["schemaVersion": .number(2),
            "availability": .string(code == -1743 ? "not-authorized" : "read-unavailable"),
            "reason": .string(reason), "errorCode": code.map { .number(Double($0)) } ?? .null])
    }
    static func readable(url: String?, title: String?, noWindows: Bool = false) -> BridgeJSON {
        guard !noWindows else {
            return .object(["schemaVersion": .number(2), "availability": .string("available"),
                            "items": .array([]), "reason": .string("no-browser-window")])
        }
        guard let url, var parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased() else {
            return .object(["schemaVersion": .number(2), "availability": .string("read-unavailable"),
                            "reason": .string("browser-returned-invalid-url")])
        }
        guard ["http", "https"].contains(scheme), parts.host != nil else {
            return .object(["schemaVersion": .number(2), "availability": .string("available"),
                            "items": .array([]), "reason": .string("internal-or-non-web-page")])
        }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        guard let cleanURL = parts.string, cleanURL.utf8.count <= 4096 else {
            return .object(["schemaVersion": .number(2), "availability": .string("read-unavailable"),
                            "reason": .string("browser-url-too-large")])
        }
        return .object(["schemaVersion": .number(2), "availability": .string("available"),
                        "url": .string(cleanURL), "title": .text(title.map { String($0.prefix(300)) })])
    }
}

#if os(macOS)
/// NSAppleScript is synchronous. All execution and Apple-event descriptors stay
/// on this actor so a browser timeout cannot block the collector's UI thread.
actor AppleScriptBridgeBrowserReader: StateBridgeBrowserReading {
    func snapshot(bundleID: String?, at date: Date) async -> BridgeBrowserSnapshot {
        guard let bundleID, BridgeBrowserProjection.supportedBundles.contains(bundleID) else {
            return BridgeBrowserSnapshot(observedAt: date, value: BridgeBrowserProjection.notFrontmost())
        }
        let tab = bundleID == "com.apple.Safari" ? "current tab" : "active tab"
        let title = bundleID == "com.apple.Safari" ? "name" : "title"
        let scriptSource = """
        with timeout of 2 seconds
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return {}
                return {URL of \(tab) of front window, \(title) of \(tab) of front window}
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: scriptSource) else {
            return BridgeBrowserSnapshot(observedAt: date, value: BridgeBrowserProjection.failure(code: nil))
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let value: BridgeJSON
        if let error { value = BridgeBrowserProjection.failure(code: (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue) }
        else { value = BridgeBrowserProjection.readable(url: result.atIndex(1)?.stringValue,
            title: result.atIndex(2)?.stringValue, noWindows: result.numberOfItems == 0) }
        return BridgeBrowserSnapshot(observedAt: date, value: value)
    }
}
#endif
