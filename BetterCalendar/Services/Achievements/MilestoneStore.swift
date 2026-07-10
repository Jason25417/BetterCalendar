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
    let line: String          // 一句温暖的正反馈（中性、不比较、不施压）
}

enum MilestoneMetric: String, CaseIterable, Sendable {
    case activeDays       // 活跃天数（DayRecord，跨端同步、只涨不跌）
    case completions      // 累计做成件数（行为日志「完成」，0.28 起攒）
    case investedHours    // 累计净投入小时（执行会话）

    var label: String {
        switch self {
        case .activeDays: return "来过的日子"
        case .completions: return "做成的事"
        case .investedHours: return "投入的时间"
        }
    }
    func format(_ value: Int) -> String {
        switch self {
        case .activeDays: return "\(value) 天"
        case .completions: return "\(value) 件"
        case .investedHours: return "\(value) 小时"
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
    }()

    // MARK: 检查与解锁

    /// 重算三个累计指标并解锁新达标的里程碑（幂等；调用时机=日记页出现/回到前台，天级节奏够用）。
    func refresh() {
        var values: [MilestoneMetric: Int] = [:]
        values[.activeDays] = reviewStore.activeDayCount
        let sessions = (try? SharedModelContainer.shared.mainContext.fetch(FetchDescriptor<ExecutionSession>())) ?? []
        let seconds = sessions.reduce(0.0) { $0 + max(0, ($1.end ?? $1.start).timeIntervalSince($1.start)) }
        values[.investedHours] = Int(seconds / 3600)
        values[.completions] = BehaviorLog.events(from: .distantPast, to: .distantFuture)
            .filter { $0.kind == "完成" }.count
        currentValues = values

        var newly: [Milestone] = []
        for def in Self.definitions where unlocked[def.id] == nil {
            if let v = values[def.metric], v >= def.threshold {
                unlocked[def.id] = .now
                newly.append(def)
                BehaviorLog.record("成就", "解锁：\(def.title)")
            }
        }
        if !newly.isEmpty {
            freshlyUnlocked = newly
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

    /// 某指标的下一个里程碑（成就页「在路上」区）。
    func next(for metric: MilestoneMetric) -> Milestone? {
        Self.definitions
            .filter { $0.metric == metric && unlocked[$0.id] == nil }
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
