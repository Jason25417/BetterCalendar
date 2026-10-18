//
//  IOSAppDelegate.swift
//  BetterCalendar
//
//  iOS 生命周期缝：注册远程静默推送并转给 FocusFollow（多端跟随专注 #30 的唤醒通道）。
//  SwiftData+CloudKit 的同步推送由 NSPersistentCloudKitContainer 自行处理，与此互不干扰。
//

#if os(iOS)
import UIKit

final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()   // 静默推送不需要用户授权（不弹任何框）
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            if CloudKitProposalStore.isProposalPush(userInfo) {
                await ProposalWake.onPush?()   // SPEC §19 多端审批：本 zone 推送 → 刷新提案
            } else if CloudKitSharedTimerStore.isTimerPush(userInfo) {
                await SharedTimerWake.onPush?()   // W5：iCloud 共享计时 zone 推送 → 刷新计时显示
            } else {
                await FocusFollow.handlePush(userInfo)
            }
            completionHandler(.newData)
        }
    }
}
#endif
