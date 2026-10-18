//
//  ActivityEvent.swift
//  BetterCalendar
//
//  SPEC §19 W13/W14 共用契约（2026-10-18，Jason：实验期数据源尽量宽，之后按使用日志删减）：
//  设备活动记录 = 被动信号的统一格式。W13 负责采集（Mac 前台 App/浏览器/空闲/锁屏，iPhone 快捷指令自动化的
//  App 打开/关闭，浏览器历史回填），W14 的哨兵读它判断要不要叫醒智能体。
//  只追加、不改写；来源与观察时刻写清楚（区分事实与推断）。App/网站名永不进复盘与留底（羞辱铁律）。
//

import Foundation

nonisolated struct ActivityEvent: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// Mac：前台 App 切换（appName/bundleID 有值）。
        case appActivated
        /// iPhone：快捷指令自动化报告的 App 打开 / 关闭。
        case appOpened, appClosed
        /// 浏览器当前页（url/pageTitle 有值）；回填的历史记录也用它，source 标 history。
        case browserPage
        /// 无键鼠输入开始 / 结束（Mac）。
        case idleStart, idleEnd
        case screenLocked, screenUnlocked
        case systemSleep, systemWake
        /// W13 新增：同一个 App 里前台窗口标题变了（windowTitle 有值；需要 Mac「辅助功能」权限）。
        case windowChanged
        /// 其他信号的扩展口（detail 里写清楚是什么）。W13 用到的 detail["signal"]：
        /// recorder（started/paused/resumed/stopped，标出记录覆盖的起止，空白≠没做事）、power、network、motion、sleep、workout、session。
        case other
    }

    /// 这条记录怎么来的：实时观察 / 事后回填（浏览器历史等）/ 快捷指令自动化。
    enum Source: String, Codable, Sendable { case live, history, shortcut }

    var id = UUID()
    /// 事情发生的时刻（回填记录 = 历史里记的时刻，不是读到的时刻）。
    var at: Date
    var kind: Kind
    var source: Source = .live
    /// 设备 id（ProposalDevice.id）与平台（"macOS" / "iOS"）。
    var deviceId: String
    var platform: String
    var appName: String? = nil
    var bundleID: String? = nil
    var url: String? = nil
    var pageTitle: String? = nil
    var windowTitle: String? = nil
    var detail: [String: String]? = nil
}

/// 活动记录存储：只追加；按时间窗读。实现由 W13 提供（Mac 本地按日文件），测试用内存版。
nonisolated protocol ActivityLog: Sendable {
    func append(_ events: [ActivityEvent]) async throws
    /// 时间窗内的记录，按 at 升序。
    func events(in window: DateInterval) async throws -> [ActivityEvent]
}

actor MemoryActivityLog: ActivityLog {
    private var rows: [ActivityEvent] = []
    init(_ rows: [ActivityEvent] = []) { self.rows = rows }
    func append(_ events: [ActivityEvent]) async throws { rows.append(contentsOf: events) }
    func events(in window: DateInterval) async throws -> [ActivityEvent] {
        rows.filter { window.contains($0.at) }.sorted { $0.at < $1.at }
    }
}
