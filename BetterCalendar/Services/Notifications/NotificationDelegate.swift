//
//  NotificationDelegate.swift
//  BetterCalendar
//
//  通知 deep-link：点早通知 → 开始今天、点晚通知 → 复盘。点击事件 → 设 AppRouter，UI 跟着跳。
//

import Foundation
import UserNotifications

@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let router: AppRouter

    init(router: AppRouter) {
        self.router = router
        super.init()
    }

    // id 对应 UNNotificationService 里的 morning/evening
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        switch response.notification.request.identifier {
        case "bc.reminder.morning":
            router.selectedTab = .schedule
            router.scheduleRequest = .startToday
        case "bc.reminder.evening":
            router.selectedTab = .schedule
            router.scheduleRequest = .review
        default:
            break
        }
    }

    // App 在前台时也把通知显出来（否则前台不弹）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
