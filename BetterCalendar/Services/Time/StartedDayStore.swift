//
//  StartedDayStore.swift
//  BetterCalendar
//
//  「今天是否已开工」标记（绿色淡出，§5.10 原则6.4）：点过「开始今天」= 进实时 reflow 模式。
//  之后绿色计划由投影层淡出（不投绿、投橙）；绿色仍留 PlanStore 供复盘。
//  重构 P3（2026-07-07，Jason 定「日程状态都要跨设备」）：存 **iCloud KV**（NSUbiquitousKeyValueStore）——
//  Mac 点了「开始今天」，iPhone 的投影规则同步淡出，两端画面一致。需 ubiquity-kvstore entitlement（已加）。
//  键 = **逻辑日标签**（yyyy-MM-dd，取 startOfDay，不再过 dayKey 的凌晨偏移——调用方传的就是标签）。
//

import Foundation
import Observation

@MainActor
@Observable
final class StartedDayStore {
    private let kv: NSUbiquitousKeyValueStore?
    private let key = "startedDays"
    private(set) var days: Set<String> = []

    /// persisted=false → 纯内存（单测用，不碰 iCloud KV）。
    init(persisted: Bool = true) {
        kv = persisted ? .default : nil
        guard let kv else { return }
        days = Set(kv.array(forKey: key) as? [String] ?? [])
        // 另一台设备改了 → 本机跟着刷（投影/UI 观察 days 自动更新）
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadFromKV() }
        }
        if !kv.synchronize() {
            DevLog.shared.warn("绿色淡出", "iCloud KV synchronize 返回 false（无 iCloud 账号/entitlement？）——标记可能仅本机生效")
        }
    }

    private func reloadFromKV() {
        guard let kv else { return }
        let fresh = Set(kv.array(forKey: key) as? [String] ?? [])
        guard fresh != days else { return }
        days = fresh
        DevLog.shared.info("绿色淡出", "iCloud 同步到「已开始」标记 \(days.count) 个")
    }

    /// 逻辑日标签 → 存储键（yyyy-MM-dd）。⚠️ 传**标签**（该日零点/白天时刻），凌晨时刻先转标签。
    private static func labelKey(_ label: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Calendar.current.startOfDay(for: label))
    }

    /// 某逻辑日是否已点「开始今天」（=实时 reflow 模式、绿色已淡出）。
    func isStarted(_ label: Date) -> Bool { days.contains(Self.labelKey(label)) }

    /// 标记某逻辑日已开工（幂等）。
    func markStarted(_ label: Date) {
        let k = Self.labelKey(label)
        guard !days.contains(k) else { return }
        days.insert(k)
        kv?.set(Array(days), forKey: key)
        kv?.synchronize()
        DevLog.shared.info("绿色淡出", "开始今天 → 实时模式（绿色从日历淡出；iCloud 同步两端）")
    }
}
