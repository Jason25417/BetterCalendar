//
//  EventKitWriteGuard.swift
//  BetterCalendar
//
//  W23b（2026-10-19）：测试宿主里**绝不写真 EventKit**。
//  事故：W23 截图测试在测试宿主里建 AppContainer，它接的是真 EventKit，保存 / 计时把测试块写进了 Jason 日用版的
//  「BetterCalendar · 计划 / 实际 (Dev)」日历。两道防线：
//    ① 最底层：EventKitCalendarStore / EventKitReminderStore 的每个写入口第一行就过这道闸——测试宿主里直接抛错 + DevLog.error；
//    ② 组装点：AppContainer 在测试宿主里注入内存日历 / 内存提醒列表（TestHostCalendarStore / TestHostReminderList），根本不碰真 EventKit。
//  只按 TestHost 判断，**不是设置开关**：生产恒为真 EventKit（见记忆「日历后端退役=生产恒真日历」）。
//

import Foundation

nonisolated struct EventKitWriteRefused: Error, LocalizedError, Equatable {
    var what: String
    var errorDescription: String? { "测试宿主里拒绝写真 EventKit：\(what)" }
}

nonisolated enum EventKitWriteGuard {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refused: [String] = []

    /// 这个进程里被拒的写入（测试断言用）。
    static var refusedWrites: [String] { lock.withLock { refused } }

    /// 写真 EventKit 之前调：测试宿主里记一笔、写错误日志、抛错；生产里什么都不做。
    static func refuseIfTestHost(_ what: String) async throws {
        guard TestHost.isActive else { return }
        lock.withLock { refused.append(what) }
        await DevLog.shared.error("测试宿主", "拒绝写真 EventKit：\(what)")
        throw EventKitWriteRefused(what: what)
    }
}
