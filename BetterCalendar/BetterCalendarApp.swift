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
        Settings {
            SettingsView()
        }
        #endif
    }
}
