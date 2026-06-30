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
    enum Tab: Hashable { case schedule, journal }
    var selectedTab: Tab = .schedule
    /// 复盘「写下今天」请求打开某天的日记；JournalView 消费后清空。
    var journalRequest: Date?
}
