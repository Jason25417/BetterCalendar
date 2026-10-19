//
//  BackgroundWork.swift
//  BetterCalendar
//
//  W20：iOS 上内置智能体正跑着一轮时你切走 App——向系统申请一段后台执行时间（系统给多少算多少，通常几十秒），
//  让这一轮把回复写完。时间到了系统收回：这一轮停在那里（日志可见；那条消息之后显示「超过 10 分钟没回复」，可以重说一次）。
//  macOS 不需要（App 常驻）。
//

#if os(iOS)
import UIKit

@MainActor enum BackgroundWork {
    @MainActor private final class Token { var id = UIBackgroundTaskIdentifier.invalid }

    /// 返回「结束」回调（必须调用；重复调用无害）。
    static func begin(_ name: String) -> () -> Void {
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                DevLog.shared.warn("内置智能体", "系统收回了后台执行时间：这一轮可能没写完（那条消息会显示没回复，可以重说一次）")
                end(token)
            }
        }
        return { end(token) }
    }

    private static func end(_ token: Token) {
        guard token.id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token.id)
        token.id = .invalid
    }
}
#endif
