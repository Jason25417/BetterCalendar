//
//  MilestoneStore.swift
//  BetterCalendar
//
//  成就系统（#27 V1，2026-07-11 Jason 定方向）：总时间线 = 累计里程碑打点。
//  设计论证（Jason，原文落档在待讨论点子 #27）：初期里程碑高频触发=极强正反馈；
//  后期间隔自然拉长最终几乎消失——无所谓：半年后还在用的人习惯已成，不再需要外部激励
//  （前载激励曲线与习惯养成曲线 Lally ~66 天 天然互补）。
//  铁律（哲学审核）：只做**累计**（只涨不跌=数学上不可能失败=纯正反馈），绝不做连续 streak
//  （断签=损失厌恶=压力工具）；解锁**零通知**（日记页内静默出现一条，看过即收）；与完成率无关。
//  持久化：iCloud KV（免 CloudKit schema deploy，跨端同步；与 LooseDayStore 同款思路）。
//  具体成就集 = 下方 definitions 数据表（Jason 说具体成就再讨论——改表即可，机制不用动）。
//

import Foundation
import Observation
import SwiftData

struct Milestone: Identifiable, Equatable, Sendable {
    let id: String            // 稳定 id（持久化键），如 "days.7"
    let metric: MilestoneMetric
    let threshold: Int
    let title: String         // 「活跃 7 天」
    let line: String          // 一句温暖的正反馈（中性、不比较、不施压；禁比较级、禁「才/只/终于」）
    /// 首次体验类=true（B 区红线，审核 2026-07-11）：**绝不进「在路上」**——只做事后惊喜，
    /// 否则它就从「回声」变成「诱饵」（变相催用户把功能用全）。
    var hidden: Bool = false
    /// 事件键（非计数型解锁）：BehaviorLog 里出现过该 kind（可带 detail 前缀「kind|前缀」）即解锁。
    var eventKey: String? = nil
}

enum MilestoneMetric: String, CaseIterable, Sendable {
    case activeDays        // 活跃天数（DayRecord，跨端同步、只涨不跌）
    case completions       // 累计做成件数（行为日志「完成」，0.28 起攒）
    case investedHours     // 累计净投入小时（执行会话，跨端）
    case journalEntries    // 日记累计篇数（SwiftData，跨端）
    case pomodoroSegments  // 番茄工作段累计（执行会话，跨端）
    case tomorrowNotes     // 寄语累计（行为日志）
    case bonusCompletions  // 计划外 bonus 累计（行为日志「完成…（计划外）」）
    case anniversaryYears  // 相识年数（首个活跃日距今，跨端）
    case seasonsCovered    // 活跃月份覆盖的季节数 0–4（跨端）
    case firstTimes        // 首次体验类的占位指标（hidden，不进「在路上」）

    var label: String {
        switch self {
        case .activeDays: return "来过的日子"
        case .completions: return "做成的事"
        case .investedHours: return "投入的时间"
        case .journalEntries: return "写下的日子"
        case .pomodoroSegments: return "完整的番茄"
        case .tomorrowNotes: return "给明天的信"
        case .bonusCompletions: return "计划外的惊喜"
        case .anniversaryYears: return "相识"
        case .seasonsCovered: return "走过的季节"
        case .firstTimes: return "第一次"
        }
    }
    func format(_ value: Int) -> String {
        switch self {
        case .activeDays: return "\(value) 天"
        case .completions, .bonusCompletions: return "\(value) 件"
        case .investedHours: return "\(value) 小时"
        case .journalEntries: return "\(value) 篇"
        case .pomodoroSegments: return "\(value) 段"
        case .tomorrowNotes: return "\(value) 封"
        case .anniversaryYears: return "\(value) 年"
        case .seasonsCovered: return "\(value) 季"
        case .firstTimes: return "\(value)"
        }
    }
}

@MainActor
@Observable
final class MilestoneStore {
    private let reviewStore: ReviewLocalStore
    private let kv = NSUbiquitousKeyValueStore.default
    private static let kvKey = "milestones.unlocked"   // [id: 解锁时刻(epoch)]

    /// 本次 refresh 新解锁的（日记页静默条用；acknowledge 后清）。
    private(set) var freshlyUnlocked: [Milestone] = []
    /// 已解锁 id → 解锁日期。
    private(set) var unlocked: [String: Date] = [:]
    /// 最近一次 refresh 算出的指标值（成就页「下一个」进度用）。
    private(set) var currentValues: [MilestoneMetric: Int] = [:]

    init(reviewStore: ReviewLocalStore) {
        self.reviewStore = reviewStore
        load()
    }

    // MARK: 定义表（改这里=改成就集；id 一经发布别改，解锁记录按 id 存）

    static let definitions: [Milestone] = {
        func days(_ n: Int, _ line: String) -> Milestone {
            Milestone(id: "days.\(n)", metric: .activeDays, threshold: n, title: "来过 \(n) 天", line: line)
        }
        func done(_ n: Int, _ line: String) -> Milestone {
            Milestone(id: "done.\(n)", metric: .completions, threshold: n, title: "做成 \(n) 件", line: line)
        }
        func hours(_ n: Int, _ line: String) -> Milestone {
            Milestone(id: "hours.\(n)", metric: .investedHours, threshold: n, title: "投入 \(n) 小时", line: line)
        }
        return [
            days(1, "第一天——一切从这里起算。"),
            days(3, "三天了，这里开始有你的痕迹。"),
            days(7, "一整周的日子都被好好看见了。"),
            days(14, "两周——回看的习惯在长出来。"),
            days(30, "一个月的日子，攒成了一条线。"),
            days(60, "两个月。据说习惯大约在这附近安家。"),
            days(100, "第 100 天。这已经是生活的一部分了。"),
            days(180, "半年。往回翻，全是走过的路。"),
            days(365, "一年。三百多个被认真过掉的日子。"),
            days(1000, "一千天。时间自己会说话。"),
            done(1, "第一件做成的事，记下了。"),
            done(10, "十件了——每一件都算数。"),
            done(25, "二十五件。手感来了。"),
            done(50, "五十件做成的事，都在这儿。"),
            done(100, "一百件。这是一份很长的「做成了什么」。"),
            done(250, "两百五十件。日拱一卒的样子。"),
            done(500, "五百件。已经不需要谁来证明了。"),
            done(1000, "一千件。了不起，认真的。"),
            hours(1, "第一个专注小时。"),
            hours(10, "十小时的专注，攒起来了。"),
            hours(25, "二十五小时——一件大事的分量。"),
            hours(50, "五十小时的投入，都有去处。"),
            hours(100, "一百小时。复利开始显形。"),
            hours(250, "两百五十小时。这是真功夫。"),
            hours(500, "五百小时。安静而巨大的数字。"),
            hours(1000, "一千小时。你知道这意味着什么。"),
        ]
        + journalSet + pomoSet + noteSet + bonusSet + timeGiftSet + firstSet
    }()

    // 0.31 扩容（2026-07-11 Jason 圈选 A/B/D 全收，审核全文见 成就系统设计与哲学审核-20260711.md）
    private static let journalSet: [Milestone] = {
        func j(_ n: Int, _ line: String) -> Milestone {
            Milestone(id: "journal.\(n)", metric: .journalEntries, threshold: n, title: "写下 \(n) 篇", line: line)
        }
        return [
            j(1, "第一篇日记。今天被留住了。"),
            j(10, "十篇了——回看有了厚度。"),
            j(50, "五十篇。这本日记开始像一本书。"),
            j(100, "一百篇。未来的你会感谢这些。"),
            j(365, "三百六十五篇。一整年的自己都在。"),
        ]
    }()

    private static let pomoSet: [Milestone] = {
        func p(_ n: Int, _ line: String) -> Milestone {
            Milestone(id: "pomo.\(n)", metric: .pomodoroSegments, threshold: n, title: "走完 \(n) 个番茄段", line: line)
        }
        return [
            p(10, "十个完整的番茄段。选择刚性并走完，是另一种温柔。"),
            p(100, "一百段。硬仗都这么打下来的。"),
            p(500, "五百段。专注已经是你的一种能力。"),
        ]
    }()

    private static let noteSet: [Milestone] = {
        func n(_ k: Int, _ line: String) -> Milestone {
            Milestone(id: "note.\(k)", metric: .tomorrowNotes, threshold: k, title: "给明天写过 \(k) 封信", line: line)
        }
        return [
            n(1, "第一句给明天的话。明早的你会收到。"),
            n(10, "十封了。昨晚的你，一直很可靠。"),
            n(50, "五十封。这是你和自己的长期通信。"),
            n(200, "两百封。没有谁比你更懂怎么叫醒你。"),
        ]
    }()

    private static let bonusSet: [Milestone] = {
        func b(_ n: Int, _ line: String) -> Milestone {
            Milestone(id: "bonus.\(n)", metric: .bonusCompletions, threshold: n, title: "计划外做成 \(n) 件", line: line)
        }
        return [
            b(1, "计划之外的第一件——生活给的加分题。"),
            b(10, "十件计划外的事。你比计划更辽阔。"),
            b(50, "五十件。即兴也是你的强项。"),
            b(200, "两百件计划外的赢。计划只是起点。"),
        ]
    }()

    private static let timeGiftSet: [Milestone] = [
        Milestone(id: "year.1", metric: .anniversaryYears, threshold: 1, title: "相识一年", line: "一年前的今天，你第一次来。"),
        Milestone(id: "year.2", metric: .anniversaryYears, threshold: 2, title: "相识两年", line: "两年了。老朋友。"),
        Milestone(id: "year.3", metric: .anniversaryYears, threshold: 3, title: "相识三年", line: "三年。时间替我们记着一切。"),
        Milestone(id: "year.5", metric: .anniversaryYears, threshold: 5, title: "相识五年", line: "五年。谢谢你一直在。"),
        Milestone(id: "seasons.4", metric: .seasonsCovered, threshold: 4, title: "四季都来过", line: "春夏秋冬，每一季都有你的日子。"),
    ]

    /// 首次体验类（B 区）：hidden=true——绝不进「在路上」，只做事后惊喜（红线，审核 2026-07-11）。
    /// 完成/日记/寄语的「第一次」由对应系列的第 1 档覆盖，这里只收系列没有的。
    private static let firstSet: [Milestone] = [
        Milestone(id: "first.confirm", metric: .firstTimes, threshold: 1, title: "第一次排好一天",
                  line: "说了一天、排了一天、写进了日历——闭环从这里开始。", hidden: true, eventKey: "确认写入"),
        Milestone(id: "first.also", metric: .firstTimes, threshold: 1, title: "第一次同时做",
                  line: "一心可以二用——后台的那件也在被好好计着。", hidden: true, eventKey: "同时做"),
        Milestone(id: "first.loose", metric: .firstTimes, threshold: 1, title: "第一个松散日",
                  line: "会休息，也是会生活。今天不用排满。", hidden: true, eventKey: "松散日|标记"),
        Milestone(id: "first.autojournal", metric: .firstTimes, threshold: 1, title: "第一篇自动日记",
                  line: "十五秒也算收尾。今天的做成替你记下了。", hidden: true, eventKey: "自动日记"),
    ]

    // MARK: 检查与解锁

    /// 重算累计指标并解锁新达标的里程碑（幂等；调用时机=日记页出现/回到前台，天级节奏够用）。
    func refresh() {
        var values: [MilestoneMetric: Int] = [:]
        values[.activeDays] = reviewStore.activeDayCount
        let ctx = SharedModelContainer.shared.mainContext
        let sessions = (try? ctx.fetch(FetchDescriptor<ExecutionSession>())) ?? []
        let seconds = sessions.reduce(0.0) { $0 + max(0, ($1.end ?? $1.start).timeIntervalSince($1.start)) }
        values[.investedHours] = Int(seconds / 3600)
        values[.pomodoroSegments] = sessions.reduce(0) { $0 + ($1.completedCount ?? 0) }
        values[.journalEntries] = (try? ctx.fetchCount(FetchDescriptor<JournalEntry>())) ?? 0
        let events = BehaviorLog.events(from: .distantPast, to: .distantFuture)
        values[.completions] = events.filter { $0.kind == "完成" }.count
        values[.bonusCompletions] = events.filter { $0.kind == "完成" && $0.detail.contains("（计划外）") }.count
        values[.tomorrowNotes] = events.filter { $0.kind == "寄语" && $0.detail.hasPrefix("今晚写了") }.count
        // 时间馈赠（D 区）：相识年数（首个活跃日距今整年）+ 季节覆盖（活跃月份→季，3–5=春 6–8=夏 9–11=秋 12/1/2=冬）
        if let firstKey = reviewStore.firstActiveDayKey {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            if let first = df.date(from: firstKey) {
                values[.anniversaryYears] = Calendar.current.dateComponents([.year], from: first, to: .now).year ?? 0
            }
        }
        values[.seasonsCovered] = Set(reviewStore.activeMonths.map { m -> Int in
            switch m { case 3...5: return 0; case 6...8: return 1; case 9...11: return 2; default: return 3 }
        }).count
        currentValues = values

        // 首次体验（B 区，eventKey）：kind 或「kind|detail 前缀」出现过即达成
        func eventSeen(_ key: String) -> Bool {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let kind = parts[0]
            let prefix = parts.count > 1 ? parts[1] : nil
            return events.contains { e in
                guard e.kind == kind else { return false }
                guard let p = prefix else { return true }
                return e.detail.hasPrefix(p)
            }
        }

        var newly: [Milestone] = []
        for def in Self.definitions where unlocked[def.id] == nil {
            let achieved: Bool
            if let key = def.eventKey {
                achieved = eventSeen(key)
            } else {
                achieved = (values[def.metric] ?? 0) >= def.threshold
            }
            if achieved {
                unlocked[def.id] = .now
                newly.append(def)
                BehaviorLog.record("成就", "解锁：\(def.title)")
            }
        }
        if !newly.isEmpty {
            freshlyUnlocked = newly
            // #36（0.39.0）：解锁改走应用内 toast（顶部 8 秒自动收起）；日记页静默条退役
            AchievementToastCenter.shared.push(newly)
            save()
        }
    }

    /// 日记页的静默解锁条被看过/收起。
    func acknowledgeFresh() { freshlyUnlocked = [] }

    /// 成就带（按解锁时间正序=一条时间线）。
    var timeline: [(milestone: Milestone, date: Date)] {
        Self.definitions.compactMap { def in
            unlocked[def.id].map { (def, $0) }
        }.sorted { $0.1 < $1.1 }
    }

    /// 某指标的下一个里程碑（成就页「在路上」区）。hidden（首次体验类）**永不出现在这里**——红线。
    func next(for metric: MilestoneMetric) -> Milestone? {
        Self.definitions
            .filter { $0.metric == metric && !$0.hidden && unlocked[$0.id] == nil }
            .min { $0.threshold < $1.threshold }
    }

    // MARK: 持久化（iCloud KV）

    private func load() {
        kv.synchronize()
        guard let data = kv.data(forKey: Self.kvKey),
              let raw = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else { return }
        unlocked = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func save() {
        let raw = unlocked.mapValues { $0.timeIntervalSince1970 }
        if let data = try? JSONEncoder().encode(raw) {
            kv.set(data, forKey: Self.kvKey)
            kv.synchronize()
        }
    }
}
