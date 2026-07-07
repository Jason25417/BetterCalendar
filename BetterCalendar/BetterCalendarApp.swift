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
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    // 菜单栏项改由 AppKit NSStatusItem 自管（潮汐式直显计时），不再用 MenuBarExtra。
    @State private var menuBar: MenuBarController?
    // 关窗不退出 → 常驻 menu bar（见 AppDelegate）。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                handlePendingAppIntent()
            }
            #else
            .onAppear { handlePendingAppIntent() }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { handlePendingAppIntent() }
            }
            // 启动同步（0.20.2）：先对账（识别日历里攒的手改/新建/删除）再投影补章自愈；
            // 有待确认新建的日子暂缓投影（防止问都没问就清掉用户新建的事件）。幂等、无变更时零写入。
            .task { await container.reconcile.startupSync() }
            .userActivity(BetterCalendarHandoff.activityType, isActive: true) { activity in
                BetterCalendarHandoff.configure(activity,
                                                router: container.router,
                                                execution: container.execution)
            }
            .onContinueUserActivity(BetterCalendarHandoff.activityType) { activity in
                continueFromHandoff(activity)
            }
        }
        .modelContainer(SharedModelContainer.shared)

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }

    @MainActor
    private func handlePendingAppIntent() {
        let payload = AppIntentRequest.payload()
        guard let request = AppIntentRequest.consume() else { return }
        switch request {
        case .arrangeToday:
            container.router.selectedTab = .schedule
            container.router.scheduleRequest = .arrangeToday(payload)
        case .openSchedule:
            container.router.selectedTab = .schedule
        case .openToday:
            selectTodayTab()
        case .openJournal:
            container.router.selectedTab = .journal
        case .startToday:
            container.router.selectedTab = .schedule
            container.router.scheduleRequest = .startToday
        case .startFocus:
            selectTodayTab()
            startNextFromIntent()
        case .completeCurrent:
            selectTodayTab()
            completeOrStartFromIntent()
        case .markDone:
            selectTodayTab()
            if let title = payload, !title.isEmpty {
                let execution = container.execution
                Task { await execution.markDone(titleLike: title) }
            }
        case .review:
            container.router.selectedTab = .schedule
            container.router.scheduleRequest = .review
        }
    }

    @MainActor
    private func continueFromHandoff(_ activity: NSUserActivity) {
        guard let route = BetterCalendarHandoff.route(from: activity) else { return }
        switch route.tab {
        case .schedule:
            container.router.selectedTab = .schedule
        case .today:
            selectTodayTab()
        case .journal:
            container.router.selectedTab = .journal
            container.router.journalRequest = .now
        }
    }

    @MainActor
    private func selectTodayTab() {
        #if os(macOS)
        container.router.selectedTab = .schedule
        #else
        container.router.selectedTab = .today
        #endif
    }

    @MainActor
    private func startNextFromIntent() {
        let execution = container.execution
        Task {
            if !execution.loaded { await execution.loadToday() }
            if execution.active != nil { return }
            if execution.selected != nil {
                await execution.startSelected()
            } else if let next = execution.nextSuggested {
                await execution.startBlock(next)
            }
        }
    }

    @MainActor
    private func completeOrStartFromIntent() {
        let execution = container.execution
        Task {
            if !execution.loaded { await execution.loadToday() }
            if execution.active != nil {
                await execution.completeCurrent()
            } else if execution.selected != nil {
                await execution.startSelected()
            } else if let next = execution.nextSuggested {
                await execution.startBlock(next)
            }
        }
    }
}
