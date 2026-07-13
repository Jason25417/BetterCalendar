//
//  WrapUpSeal.swift
//  BetterCalendar
//
//  收尾章（#33 过审 2026-07-13，Jason 拍板）：一天工作环节的收尾仪式状态。
//  红线：仪式≠保存开关（正文实时保存不变）；「先不收尾」只管当天、零痕迹零审计。
//

import Foundation

enum WrapUpSeal {
    private static var sealKey: String { "wrapup.sealed." + DayContext.dayKey(DayContext.logicalDay(offset: 0)) }
    private static var dismissKey: String { "wrapup.dismissed." + DayContext.dayKey(DayContext.logicalDay(offset: 0)) }

    /// 今天（逻辑日）是否已盖收尾章。
    static var isSealedToday: Bool { UserDefaults.standard.bool(forKey: sealKey) }

    /// 盖章（幂等）。
    static func seal() {
        UserDefaults.standard.set(true, forKey: sealKey)
        BehaviorLog.record("收尾章", "今天的工作到此为止")
    }

    /// 「先不收尾」：收尾卡当天不再出现（只影响卡片曝光，入口/日记一切照旧）。
    static var dismissedToday: Bool { UserDefaults.standard.bool(forKey: dismissKey) }
    static func dismissToday() { UserDefaults.standard.set(true, forKey: dismissKey) }
}
