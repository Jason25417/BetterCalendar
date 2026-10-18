//
//  MacActivityProbe.swift
//  BetterCalendar
//
//  W13：Mac 上的系统观察实现（只在 macOS 编译）。
//  - 前台 App：NSWorkspace.frontmostApplication。
//  - 空闲：CGEventSource「任意输入」距今秒数（含合成输入，分不出是不是人——只当线索）。
//  - 电源：IOKit Power Sources（沙盒内可读）。
//  - 窗口标题：辅助功能（AX）API 读前台 App 的焦点窗口标题。沙盒 App 可以用，但必须由 Jason 在
//    「系统设置 → 隐私与安全性 → 辅助功能」里手动允许；没权限 = 明确返回 noPermission（不当成「没有标题」）。
//    AX 调用是同步的、目标 App 卡住时会等——放在独立 actor 上并设 0.5 秒超时，不压主线程。
//    （另一条路是「屏幕录制」权限下的 CGWindowList 窗口名：权限更重、读到的东西一样，故不用。）
//  - 浏览器当前页：AppleScript（NSAppleScript，放在独立 actor 上，2 秒超时）。
//    ⚠️ 2026-10-18 实测证据：Jason 机器上旧 StateBridge 用同样方式读浏览器 103 次全部 -600（procNotFound）——
//    浏览器明明在前台，这是 App 沙盒拦截 Apple 事件的典型表现：现有的 com.apple.security.automation.apple-events
//    只管 hardened runtime 的授权弹窗，沙盒还需要 com.apple.security.temporary-exception.apple-events（列出浏览器 bundle id）。
//    加不加这条 entitlement 交 Jason 决定（会顺带让已冻结、仍开着的 StateBridge 采集开始读到真实网址，见 W13 报告）；
//    没加之前，状态行明确显示「沙盒拦截」，窗口标题（辅助功能）与智能体侧的浏览历史回填兜底。
//

#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.ps

@MainActor final class MacActivityProbe: ActivityProbing {
    private let ax = AXWindowTitleReader()

    func frontApp() -> ActivityFrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return ActivityFrontApp(name: app.localizedName, bundleID: app.bundleIdentifier, pid: app.processIdentifier)
    }

    func idleSeconds() -> Double? {
        guard let any = CGEventType(rawValue: UInt32.max) else { return nil }
        let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        return s.isFinite && s >= 0 ? s : nil
    }

    func power() -> ActivityPowerState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let source = providing == kIOPMACPowerKey ? "ac" : providing == kIOPMBatteryPowerKey ? "battery" : "unknown"
        var charging: Bool?, percent: Int?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                charging = d[kIOPSIsChargingKey] as? Bool
                if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = Int((Double(cur) / Double(max) * 100).rounded())
                }
            }
        }
        return ActivityPowerState(source: source, charging: charging, percent: percent)
    }

    func windowTitle(of app: ActivityFrontApp) async -> ActivityWindowTitleRead {
        guard AXIsProcessTrusted() else { return .noPermission }
        guard app.pid > 0 else { return .title(nil) }
        return await ax.title(pid: app.pid)
    }

    /// 只由用户点击触发：弹系统的辅助功能授权提示，并打开对应设置页。
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }
}

/// AX 同步调用放这里（目标 App 无响应时最多等 0.5 秒，不卡界面）。
actor AXWindowTitleReader {
    func title(pid: Int32) -> ActivityWindowTitleRead {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var window: CFTypeRef?
        let r1 = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
        switch r1 {
        case .success: break
        case .noValue, .attributeUnsupported: return .title(nil)   // 没有焦点窗口（菜单栏 App、全屏切换中）
        case .apiDisabled: return .noPermission
        case .cannotComplete: return .failed("目标 App 没有响应（AX 超时）")
        default: return .failed("读焦点窗口失败（AXError \(r1.rawValue)）")
        }
        guard let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return .title(nil) }
        var title: CFTypeRef?
        let r2 = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard r2 == .success else { return r2 == .apiDisabled ? .noPermission : .title(nil) }
        return .title(title as? String)
    }
}

/// 浏览器当前页（AppleScript）。NSAppleScript 是同步的，放独立 actor 上。
actor AppleScriptActivityBrowserReader: ActivityBrowserReading {
    func page(bundleID: String) async -> ActivityBrowserRead {
        let safari = ActivityBrowsers.safariFamily.contains(bundleID)
        let tab = safari ? "current tab" : "active tab", title = safari ? "name" : "title"
        let source = """
        with timeout of 2 seconds
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return {}
                return {URL of \(tab) of front window, \(title) of \(tab) of front window}
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { return .failed(code: nil, reason: "脚本无法编译") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            return .failed(code: code, reason: Self.reason(code))
        }
        if result.numberOfItems == 0 { return .noWindow }
        return .page(url: result.atIndex(1)?.stringValue, title: result.atIndex(2)?.stringValue)
    }

    nonisolated static func reason(_ code: Int?) -> String {
        switch code {
        case -1743: "没有「自动化」授权：系统设置 → 隐私与安全性 → 自动化 → BetterCalendar 里打开对应浏览器"
        case -600: "沙盒拦截（-600）：App 沙盒不允许向浏览器发 Apple 事件，需要加 temporary-exception.apple-events 授权（待 Jason 决定）"
        case -1712: "浏览器 2 秒内没回应（超时）"
        case -1728: "浏览器没有可读的窗口/标签页"
        case let c?: "浏览器读取失败（错误 \(c)）"
        case nil: "浏览器读取失败"
        }
    }
}
#endif
