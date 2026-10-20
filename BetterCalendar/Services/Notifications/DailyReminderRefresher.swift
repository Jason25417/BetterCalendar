//
//  DailyReminderRefresher.swift
//  BetterCalendar
//
//  W26b：早晚两条通知（首块前 15 分钟「开始今天」/ 末块后 30 分钟「30 秒记录今天」）跟着计划走。
//  背景：这两条通知全 App 只有一份（固定 id，后排的覆盖先排的），只在「保存某一天」（HomeViewModel.confirm）时按**那一天**
//  的计划排。跨天挪（你在时间轴上拖、或批准智能体的跨天挪）是按块单写、不经过 confirm——挪走那天的第一件 / 最后一件，
//  或挪进来一件更早 / 更晚的，已排的通知就还是旧时刻。这里补上：记住已排的那一份属于哪一天；改动涉及那一天 → 按库重算重排。
//  （会前提醒不在这里：它挂在固定安排的日历事件上，由 CalendarSyncEngine 重投影时一并更新；固定安排本来也不能被挪。）
//

import Foundation

/// 已排的早晚通知属于哪一个逻辑日（本机状态：通知本来就是每台设备各自排的，不同步）。存 Double（plist 类型）。
nonisolated enum DailyReminderDay {
    static let key = "notifications.dailyReminders.dayLabel"

    /// 默认存处：App 里 = 标准存储；测试宿主里 = 本进程一次性的独立 suite（单测互不串、绝不碰 Jason 的标准存储）。
    static let defaultStore: UserDefaults = {
        guard TestHost.isActive else { return .standard }
        return UserDefaults(suiteName: "bc.test.dailyReminderDay.\(UUID().uuidString)") ?? .standard
    }()

    /// W30：本机记下一天时顺手发布给别的设备（组装点接 SharedDailyReminderDay.publish；开关关着时它什么都不做）。
    nonisolated(unsafe) static var onRecord: (@MainActor (Date) -> Void)?

    /// publish=false：是从别的设备接过来的，不再往外发。
    static func record(_ label: Date, in defaults: UserDefaults = .standard, publish: Bool = true) {
        defaults.set(label.timeIntervalSince1970, forKey: key)
        guard publish, let onRecord else { return }
        if Thread.isMainThread { MainActor.assumeIsolated { onRecord(label) } }
    }

    static func current(in defaults: UserDefaults = .standard) -> Date? {
        (defaults.object(forKey: key) as? Double).map(Date.init(timeIntervalSince1970:))
    }
}

/// 早晚通知的内容（纯函数、可单测；HomeViewModel.confirm 与重排共用一份口径）。
nonisolated enum DailyReminderContent {
    /// 早通知小总结（0.28.1）：件数只数任务（锚点不算）、有尽早则点名、落点 = 第一件任务；
    /// pooledFromYesterday（E5d）：待办区露脸计数——中性事实一行，不写「没做完」。
    static func morningSummary(for blocks: [ScheduledBlock], pooledFromYesterday: Int = 0) -> String {
        let tasks = blocks.filter { !$0.isAnchor }.sorted { $0.start < $1.start }
        guard !tasks.isEmpty else { return "今天安排好了，开始吧。" }
        var parts = ["今天 \(tasks.count) 件"]
        if let mit = tasks.first(where: { $0.priority == .important }) { parts.append("尽早：\(mit.title)") }
        if let first = tasks.first { parts.append("第一件：「\(first.title)」——准备好了就开始") }
        if pooledFromYesterday > 0 { parts.append("待办区有 \(pooledFromYesterday) 件昨天留下的") }
        return parts.joined(separator: " · ")
    }

    /// 早通知正文：小总结 +「给明天的一句话」（#23，昨晚写给这一天早上的；与 appendTomorrowNoteToMorning 同一行格式）。
    static func morningBody(summary: String, note: String?) -> String {
        guard let note, !note.isEmpty else { return summary }
        return summary + "\n昨晚的你说：\(note)"
    }
}

@MainActor
final class DailyReminderRefresher {
    private let plans: PlanReading
    private let notifier: NotificationScheduling
    private let isLoose: (Date) -> Bool
    private let pooledFromYesterday: () -> Int
    private let note: (Date) -> String?
    private let defaults: UserDefaults
    private let now: () -> Date

    init(plans: PlanReading, notifier: NotificationScheduling,
         isLoose: @escaping (Date) -> Bool = { _ in false },
         pooledFromYesterday: @escaping () -> Int = { 0 },
         note: @escaping (Date) -> String? = { TomorrowNote.note(for: $0.addingTimeInterval(12 * 3600)) },
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = { .now }) {
        self.plans = plans; self.notifier = notifier; self.isLoose = isLoose
        self.pooledFromYesterday = pooledFromYesterday; self.note = note
        self.defaults = defaults; self.now = now
    }

    /// 改动涉及这些逻辑日：已排的早晚通知若属于其中一天（且那天还没过去）→ 按库重算重排。返回是否重排了。
    /// 不属于这几天 = 已排的那份不受影响，不动（不把别的日子的通知换掉）。
    @discardableResult
    func refresh(affecting labels: Set<Date>, logs: Bool = true) async -> Bool {
        guard let day = DailyReminderDay.current(in: defaults), labels.contains(day),
              day >= DayContext.logicalStartOfDay(now()) else { return false }
        guard !isLoose(day) else {
            // 松散日：退场姿态，早晚通知本来就是静音的（confirm 同口径）
            await notifier.scheduleDailyReminders(morning: nil, evening: nil, summary: "")
            return true
        }
        let blocks: [ScheduledBlock]
        do { blocks = try plans.plannedBlocks(on: day) } catch {
            // 读不到计划：不瞎排（旧时刻可能已经不对）——可见
            DevLog.shared.warn("通知", "计划改动后重排早晚通知失败（读不到计划）：\(error.localizedDescription)")
            return false
        }
        let times = RescheduleService.reminderTimes(for: blocks)
        let t = now()
        // 已经过去的那条不再排（scheduleDailyReminders 会把它连同旧的一起清掉；不为过去的时刻报警告）
        let morning = times.morning.flatMap { $0 > t ? $0 : nil }
        let evening = times.evening.flatMap { $0 > t ? $0 : nil }
        let body = DailyReminderContent.morningBody(
            summary: DailyReminderContent.morningSummary(for: blocks, pooledFromYesterday: pooledFromYesterday()),
            note: note(day))
        await notifier.scheduleDailyReminders(morning: morning, evening: evening, summary: body)
        if logs { DevLog.shared.info("通知", "计划改动涉及 \(PlanEditRules.dayName(day))：早晚通知已按新计划重排") }
        return true
    }
}
