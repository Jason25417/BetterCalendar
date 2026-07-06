//
//  StartedDayStore.swift
//  BetterCalendar
//
//  「今天是否已开工」标记（绿色淡出，§5.10 原则6.4）：点过「开始今天」= 进实时 reflow 模式。
//  之后绿色计划从 Apple 日历常驻淡出（只留橙色预览 + 蓝色实际）；绿色仍留 PlanStore 供复盘。
//  本地 UserDefaults，按逻辑日 dayKey；跨天自动失效（新一天默认未开工=显绿）。
//

import Foundation
import Observation

@MainActor
@Observable
final class StartedDayStore {
    private let defaults = UserDefaults.standard
    private let key = "startedDays"
    private(set) var days: Set<String> = []

    init() { days = Set(defaults.array(forKey: key) as? [String] ?? []) }

    /// 某天是否已点「开始今天」（=实时 reflow 模式、绿色已淡出）。
    func isStarted(_ d: Date = .now) -> Bool { days.contains(DayContext.dayKey(d)) }

    /// 标记某天已开工（幂等）。
    func markStarted(_ d: Date = .now) {
        let k = DayContext.dayKey(d)
        guard !days.contains(k) else { return }
        days.insert(k)
        defaults.set(Array(days), forKey: key)
        DevLog.shared.info("绿色淡出", "开始今天 → 实时模式（绿色从日历淡出）")
    }
}
