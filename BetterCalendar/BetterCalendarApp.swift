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
    #if os(macOS)
    // 菜单栏项改由 AppKit NSStatusItem 自管（潮汐式直显计时），不再用 MenuBarExtra。
    @State private var menuBar: MenuBarController?
    #endif

    var body: some Scene {
        WindowGroup {
            TabView(selection: Binding(get: { container.router.selectedTab },
                                       set: { container.router.selectedTab = $0 })) {
                HomeView(container: container)
                    .tag(AppRouter.Tab.schedule)
                    .tabItem { Label("排日程", systemImage: "calendar") }
                #if !os(macOS)
                // iOS 没 menu bar → 执行陪伴单独一个「今天」标签页
                NavigationStack {
                    ScrollView { ExecutionPanel(model: container.execution) }
                        .navigationTitle("今天")
                }
                .tag(AppRouter.Tab.today)
                .tabItem { Label("今天", systemImage: "play.circle") }
                #endif
                JournalView(container: container)
                    .tag(AppRouter.Tab.journal)
                    .tabItem { Label("日记", systemImage: "book") }
            }
            #if os(macOS)
            .onAppear {
                if menuBar == nil { menuBar = MenuBarController(model: container.execution) }
            }
            #endif
        }
        .modelContainer(SharedModelContainer.shared)

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
