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
    // today 仅 iOS（macOS 走 menu bar）；longterm=#40 周期态（2026-07-15 S1 修订四 tab 终局）
    enum Tab: String, Hashable { case schedule, today, longterm, journal }
    var selectedTab: Tab = .schedule
    var openNativeApprovals = false
    var nativeApprovalCommandId: String?
    var nativeApprovalPreviewRequest: UUID?
    /// 复盘「写下今天」请求打开某天的日记；JournalView 消费后清空。
    var journalRequest: Date?

    /// 通知 deep-link 请求；HomeView 消费后清空。
    /// （.startToday 已退役 0.23 A；.review 已退役 0.28：晚通知直达日记页复盘头。）
    /// insertLongTask（#40 批1）：长期页「排进今天」→ 切排日程页智能插空档。
    enum ScheduleRequest: Equatable { case arrangeToday(String?), planTomorrow, insertLongTask(UUID) }
    var scheduleRequest: ScheduleRequest?

    /// 收尾流程请求（0.38，#33）：随 journalRequest 一起置 true → 日记页进入分步收尾；消费后清空。
    var wrapUpRequest = false

    /// 成就 toast 点击 → 日记页打开成就全景（#36）；消费后清空。
    var openAchievements = false

    /// 早通知 deep-link（0.23 A）：打开执行界面、把下一件设为「待开始」（**不自动开始计时**——
    /// 点通知可能是误触，开始必须是明确动作）。BetterCalendarApp 消费后清空。
    var primeNextStart = false
}
