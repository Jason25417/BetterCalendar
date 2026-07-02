//
//  AppDelegate.swift
//  BetterCalendar
//
//  macOS 生命周期：关掉最后一个窗口后**不退出** App，让 menu bar（NSStatusItem）常驻、
//  计时继续、可交互（点图标弹执行面板）。需要窗口时点 Dock 图标重新打开。
//  说明：真正退出仍走 Cmd-Q / Dock 右键→退出——那会结束整个进程，menu bar 项也随之消失
//  （一个进程 = 窗口 + Dock 图标 + menu bar 项，是一体的，没有「退出了但 menu bar 还在」）。
//

#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 关掉最后一个窗口不终止 App → 常驻 menu bar。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
#endif
