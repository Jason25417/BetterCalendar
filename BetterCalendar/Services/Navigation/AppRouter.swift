//
//  AppRouter.swift
//  BetterCalendar
//
//  跨标签页导航的轻量协调（复盘「写下今天」→ 切到日记页 + 打开当天）。
//

import Foundation
import Observation

@Observable
final class AppRouter {
    enum Tab: String, Hashable { case schedule, today, journal }   // today 仅 iOS（macOS 走 menu bar）
    var selectedTab: Tab = .schedule
    /// 复盘「写下今天」请求打开某天的日记；JournalView 消费后清空。
    var journalRequest: Date?

    /// 通知 deep-link 请求（点晚通知→复盘 等）；HomeView 消费后清空。
    /// （.startToday 已退役 0.23 A：早通知改走 primeNextStart——打开今天并把第一件设为待开始。）
    enum ScheduleRequest: Equatable { case arrangeToday(String?), review }
    var scheduleRequest: ScheduleRequest?

    /// 早通知 deep-link（0.23 A）：打开执行界面、把下一件设为「待开始」（**不自动开始计时**——
    /// 点通知可能是误触，开始必须是明确动作）。BetterCalendarApp 消费后清空。
    var primeNextStart = false
}
