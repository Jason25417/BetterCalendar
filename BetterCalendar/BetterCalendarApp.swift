//
//  BetterCalendarApp.swift
//  BetterCalendar
//
//  @main + 组装点：建 AppContainer、注入 SwiftData 容器与首页。
//

import SwiftUI
import SwiftData

@main
struct BetterCalendarApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            HomeView(container: container)
        }
        .modelContainer(SharedModelContainer.shared)

        #if os(macOS)
        // menu bar 单键导航：当前块·已用时长·下一件 + 完成/换一件/休息（记录=导航）
        // label 用静态 systemImage（动态计时只在点开的小窗里显示）——
        // 菜单栏 label 里放 TimelineView 会失控、卡死、内存溢出，绝不可。
        MenuBarExtra("BetterCalendar", systemImage: "calendar.badge.clock") {
            MenuBarView(model: container.execution)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
        #endif
    }
}
