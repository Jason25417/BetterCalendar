//
//  LooseDayStore.swift
//  BetterCalendar
//
//  「松散日」标记（2026-07-06 Jason 定，见 SPEC §5.12）：给某个逻辑日贴一个可撕的轻标记。
//  贴上后 App 改的是"姿态"不是"数据"——原计划一件不删，只是收起催促（退场+见证）。
//  纯手动、随时撤；App 绝不自动判定"你今天该休息"。
//  存 iCloud 键值（NSUbiquitousKeyValueStore）：跨端、轻量、**不加 CloudKit schema**（不增 deploy 负担）。
//  注：短时休息（半天/2小时）走「留白」不走这里；本标记只给半天以上/整天的姿态切换（先做整天）。
//

import Foundation
import Observation

@MainActor
@Observable
final class LooseDayStore {
    private let kv = NSUbiquitousKeyValueStore.default
    private let localKey = "looseDays"   // 逻辑日 dayKey 集合（yyyy-MM-dd）

    /// 当前松散日集合（缓存，mutator 后刷新，UI 直接观察）。
    private(set) var days: Set<String> = []

    init() {
        reload()
        kv.synchronize()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
    }

    private func reload() {
        let fromCloud = kv.array(forKey: localKey) as? [String]
        let fromLocal = UserDefaults.standard.array(forKey: localKey) as? [String]
        days = Set(fromCloud ?? fromLocal ?? [])
    }

    /// 某逻辑日是否松散。
    func isLoose(_ date: Date = .now) -> Bool { days.contains(DayContext.dayKey(date)) }

    /// 贴 / 撕松散标记（同一天再点即撕；可逆姿态切换、不动任何计划数据）。
    func toggle(_ date: Date = .now) {
        let key = DayContext.dayKey(date)
        if days.contains(key) { days.remove(key) } else { days.insert(key) }
        persist()
    }

    private func persist() {
        let arr = Array(days)
        kv.set(arr, forKey: localKey)
        kv.synchronize()
        UserDefaults.standard.set(arr, forKey: localKey)   // 本地兜底（iCloud 不可用时也生效）
        DevLog.shared.info("松散日", "当前松散日 \(days.count) 个")
    }
}
