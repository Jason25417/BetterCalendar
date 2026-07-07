//
//  AppLifecycle.swift
//  BetterCalendar
//
//  App 生命周期控制缝（架构修缮 2026-07-08）：Features 不再直摸 App 层的 AppDelegate（反向依赖），
//  改依赖本协议；AppDelegate 启动时把自己挂到 `AppLifecycle.shared`。
//  MenuBarSettings 也从 AppDelegate.swift 挪来（SettingsView 引用它曾构成 Features→App 反向边）。
//

#if os(macOS)
import Foundation

/// 「打开主窗口 / 真退出」的能力面：菜单栏右键菜单、执行面板退出按钮用。
@MainActor
protocol AppLifecycleControlling: AnyObject {
    func showMainWindow()
    func reallyQuit()
}

/// 全局访问点（AppDelegate 启动时注入）。SettingsView/菜单栏这类没有构造注入通道的场景从这取。
@MainActor
enum AppLifecycle {
    static weak var shared: AppLifecycleControlling?
}

enum MenuBarSettings {
    /// 退出（⌘Q / Dock 右键退出）时不真退、收进菜单栏后台继续跑（计时不断）。默认关，进阶设置里开。
    static var keepRunningOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: "menubar.keepRunningOnQuit") }
        set { UserDefaults.standard.set(newValue, forKey: "menubar.keepRunningOnQuit") }
    }
}
#endif
