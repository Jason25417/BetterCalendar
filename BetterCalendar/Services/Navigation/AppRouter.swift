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
    // W19（S-v2）：两端四页 = schedule（「今天」首页）/ chat（智能体）/ longterm / journal。
    // today 已并入 schedule，枚举值保留只为读旧 Handoff（路由到首页）。
    enum Tab: String, Hashable { case schedule, today, longterm, journal, chat }
    var selectedTab: Tab = .schedule
    var openNativeApprovals = false
    /// SPEC §19 多端审批：通知「查看详情」置位 → 根视图切到「智能体」页（W19：待确认卡置顶在那里）；
    /// proposalFocusId = 要高亮的提案。
    var openProposals = false
    var proposalFocusId: UUID?
    /// SPEC §19 A1：打开对话 = 切到「智能体」页（W19 起两端主窗口都有这一页；Mac 独立对话窗口只在「窗口」菜单里）。
    func openChat() { selectedTab = .chat }
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
