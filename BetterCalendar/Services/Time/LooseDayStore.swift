//
//  LooseDayStore.swift
//  BetterCalendar
//
//  「松散日」标记（2026-07-06 Jason 定，见 SPEC §5.12）：给某个逻辑日贴一个可撕的轻标记。
//  贴上后 App 改的是"姿态"不是"数据"——原计划一件不删，只是收起催促（退场+见证）。
//  纯手动、随时撤；App 绝不自动判定"你今天该休息"。
//  存本地 UserDefaults（轻量、无 CloudKit schema）。
//  注：曾用 NSUbiquitousKeyValueStore 想跨端，但缺 ubiquity-kvstore entitlement 会刷错、且实际不生效
//  → 改纯本地（松散是设备当下的姿态，跨端非刚需）；日后要跨端再用 CloudKit @Model，不折腾 entitlement。
//  短时休息（半天/2小时）走「留白」不走这里；本标记只给半天以上/整天的姿态切换（先做整天）。
//

import Foundation
import Observation

@MainActor
@Observable
final class LooseDayStore {
    private let defaults = UserDefaults.standard
    private let key = "looseDays"   // 逻辑日 dayKey 集合（yyyy-MM-dd）

    /// 当前松散日集合（缓存，mutator 后刷新，UI 直接观察）。
    private(set) var days: Set<String> = []

    init() {
        days = Set(defaults.array(forKey: key) as? [String] ?? [])
    }

    /// 某逻辑日是否松散。
    func isLoose(_ date: Date = .now) -> Bool { days.contains(DayContext.dayKey(date)) }

    /// 贴 / 撕松散标记（同一天再点即撕；可逆姿态切换、不动任何计划数据）。
    func toggle(_ date: Date = .now) { setLoose(date, !isLoose(date)) }

    /// 显式置位（LLM 识别到"想松散"→置 true，幂等；再次排程不会翻掉）。
    func setLoose(_ date: Date = .now, _ loose: Bool) {
        let k = DayContext.dayKey(date)
        let had = days.contains(k)
        if loose { days.insert(k) } else { days.remove(k) }
        guard had != loose else { return }
        defaults.set(Array(days), forKey: key)
        DevLog.shared.info("松散日", "当前松散日 \(days.count) 个")
    }
}
