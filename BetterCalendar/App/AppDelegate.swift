//
//  AppDelegate.swift
//  BetterCalendar
//
//  macOS 生命周期：
//  ① 关掉最后一个窗口**不退出** App → menu bar（NSStatusItem）常驻、计时继续。
//  ② 设置开「退出保留在菜单栏」后：⌘Q / Dock 右键退出 也**不真退**——拦下来、隐藏窗口 + 去掉 Dock 图标，
//     变成纯菜单栏 agent（计时不断）。真退出走菜单栏右键「退出 BetterCalendar」。防手滑误退。
//

#if os(macOS)
import AppKit

enum MenuBarSettings {
    /// 退出（⌘Q / Dock 右键退出）时不真退、收进菜单栏后台继续跑（计时不断）。默认关，进阶设置里开。
    static var keepRunningOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: "menubar.keepRunningOnQuit") }
        set { UserDefaults.standard.set(newValue, forKey: "menubar.keepRunningOnQuit") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 由菜单栏「退出 BetterCalendar」置 true → 真退出（绕过下面的拦截）。
    var reallyQuitting = false

    /// 关掉最后一个窗口不终止 App → 常驻 menu bar。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 拦截退出：设置开且非真退 → 取消退出、收进纯菜单栏后台（隐藏窗口 + 去 Dock 图标）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MenuBarSettings.keepRunningOnQuit, !reallyQuitting else { return .terminateNow }
        for w in NSApp.windows where w.styleMask.contains(.titled) { w.orderOut(nil) }
        NSApp.setActivationPolicy(.accessory)   // 去掉 Dock 图标 → 纯菜单栏 agent，也防再次误 Dock 退出
        DevLog.shared.info("menu bar", "退出被拦 → 收进菜单栏后台运行（计时继续；菜单栏右键→退出 才真退）")
        return .terminateCancel
    }

    /// Dock/Finder/Launchpad 重新打开 → 恢复窗口 + Dock 图标。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// 恢复主窗口 + Dock 图标（菜单栏右键「打开主窗口」/ 重新打开用）。
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.styleMask.contains(.titled) { w.makeKeyAndOrderFront(nil) }
    }

    /// 真退出（菜单栏右键「退出 BetterCalendar」）。
    func reallyQuit() {
        reallyQuitting = true
        NSApp.terminate(nil)
    }
}
#endif
