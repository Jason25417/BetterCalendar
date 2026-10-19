//
//  BuiltinAgentUsage.swift
//  BetterCalendar
//
//  W20 内置智能体的用量与估算成本（设置 → 智能体 显示），以及每日预算上限。
//  预算上限 = **稳定性上限**（不是产品规则）：碰到就停下、在对话与状态区直说，不降级、不换模型。
//  用量按设备本机记账（每台设备各自的调用；不同步，避免两台设备同时改同一份计数打架）；预算数字随 iCloud 设置同步。
//  成本是按官方价目的估算（DeepSeekPricing），以 DeepSeek 账单为准。
//

import Foundation
import Observation

nonisolated struct BuiltinAgentDayUsage: Codable, Equatable, Sendable {
    var day: String
    var calls = 0
    var runs = 0
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    var completionTokens = 0
    var costUSD = 0.0
}

nonisolated enum BuiltinAgentSettings {
    static let budgetKey = "agent.builtin.dailyBudgetUSD"
    static let modelKey = "agent.builtin.model"
    /// 默认每天 1 美元（flash 每次调用约 0.3–1 美分；1 美元 ≈ 一两百次调用，日用够、失控时也挡得住）。
    static let defaultBudget = 1.0
    static func budget(_ d: UserDefaults = .standard) -> Double {
        let v = d.object(forKey: budgetKey) as? Double ?? defaultBudget
        return v > 0 ? v : defaultBudget
    }
    static func model(_ d: UserDefaults = .standard) -> String {
        let v = d.string(forKey: modelKey) ?? DeepSeekPricing.defaultModel
        return DeepSeekPricing.models.contains(v) ? v : DeepSeekPricing.defaultModel
    }
}

@MainActor @Observable final class BuiltinAgentUsageStore {
    static let key = "agent.builtin.usage.v1"
    static let keepDays = 30
    private(set) var days: [BuiltinAgentDayUsage] = []
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([BuiltinAgentDayUsage].self, from: data) {
            days = saved
        }
    }

    var today: BuiltinAgentDayUsage {
        let key = DayContext.dayKey(now())
        return days.first { $0.day == key } ?? BuiltinAgentDayUsage(day: key)
    }

    /// 最近 7 天（含今天）合计成本。
    var last7DaysCost: Double {
        let cutoff = DayContext.dayKey(now().addingTimeInterval(-6 * 86400))
        return days.filter { $0.day >= cutoff }.map(\.costUSD).reduce(0, +)
    }

    /// 记一次模型调用。cost = nil（价目未知）不会发生：运行前已拦下不认识的模型。
    func record(_ usage: DeepSeekUsage, cost: Double) {
        mutateToday { d in
            d.calls += 1; d.cacheHitTokens += usage.cacheHitTokens; d.cacheMissTokens += usage.cacheMissTokens
            d.completionTokens += usage.completionTokens; d.costUSD += cost
        }
    }

    func recordRun() { mutateToday { $0.runs += 1 } }

    private func mutateToday(_ f: (inout BuiltinAgentDayUsage) -> Void) {
        let key = DayContext.dayKey(now())
        if let i = days.firstIndex(where: { $0.day == key }) { f(&days[i]) } else { var d = BuiltinAgentDayUsage(day: key); f(&d); days.append(d) }
        days = Array(days.sorted { $0.day < $1.day }.suffix(Self.keepDays))
        if let data = try? JSONEncoder().encode(days) { defaults.set(data, forKey: Self.key) }   // Data = plist 类型
    }
}
