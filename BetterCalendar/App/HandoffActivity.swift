//
//  HandoffActivity.swift
//  BetterCalendar
//
//  NSUserActivity bridge for Handoff / Continuity. It keeps the payload small:
//  which surface the user is on, plus the current execution title when useful.
//

import Foundation

enum BetterCalendarHandoff {
    static let activityType = "com.jason.BetterCalendar.handoff"

    private enum Key {
        static let tab = "tab"
        static let activeTitle = "activeTitle"
        static let timestamp = "timestamp"
    }

    struct Route: Equatable {
        var tab: AppRouter.Tab
        var activeTitle: String?
    }

    @MainActor
    static func configure(_ activity: NSUserActivity,
                          router: AppRouter,
                          execution: ExecutionViewModel) {
        let activeTitle = execution.active?.title ?? execution.selected?.title
        activity.title = title(for: router.selectedTab, activeTitle: activeTitle)
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = userInfo(tab: router.selectedTab, activeTitle: activeTitle)
        activity.needsSave = true
    }

    static func route(from activity: NSUserActivity) -> Route? {
        route(from: activity.userInfo)
    }

    static func route(from userInfo: [AnyHashable: Any]?) -> Route? {
        guard let rawTab = userInfo?[Key.tab] as? String,
              let tab = AppRouter.Tab(rawValue: rawTab) else {
            return nil
        }
        return Route(tab: tab, activeTitle: userInfo?[Key.activeTitle] as? String)
    }

    static func userInfo(tab: AppRouter.Tab, activeTitle: String?) -> [String: Any] {
        var info: [String: Any] = [
            Key.tab: tab.rawValue,
            Key.timestamp: Date().timeIntervalSince1970
        ]
        if let activeTitle, !activeTitle.isEmpty {
            info[Key.activeTitle] = activeTitle
        }
        return info
    }

    private static func title(for tab: AppRouter.Tab, activeTitle: String?) -> String {
        switch tab {
        case .schedule:
            return "BetterCalendar - 排日程"
        case .today:
            if let activeTitle, !activeTitle.isEmpty {
                return "BetterCalendar - 正在做：\(activeTitle)"
            }
            return "BetterCalendar - 今天"
        case .longterm:
            return "BetterCalendar - 长期"
        case .journal:
            return "BetterCalendar - 日记"
        }
    }
}
