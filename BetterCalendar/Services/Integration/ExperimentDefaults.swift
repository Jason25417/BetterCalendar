//
//  ExperimentDefaults.swift
//  BetterCalendar
//
//  SPEC §19 W8（Jason 2026-10-18：实验功能默认打开，让他自己测）。
//  规则：只改「从没设过时」的默认值——UserDefaults 里**没有这个键** = 从没设过，按新默认；
//  用户手动设过（键存在，不论开关）一律保留原值。不写回默认值（不制造「用户设过」的假象，也不触发设置同步）。
//  受影响的键（各自的读取处调用这里）：
//    · agentChat.eveningReview.enabled（晚间复盘，默认开，时刻仍 21:30）
//    · agentEvents.enabled（关键时刻唤醒智能体）
//    · attention.settings.v1（允许智能体主动通知；整份设置不存在时 enabled 默认开，频率上限见 AttentionSettings.capsEnabled）
//    · sharedTimer.icloud.enabled（iCloud 共享计时；启动闸门照旧）
//    · B5 iCloud 直接推送：用户没手动关过（approvals.alertPush.userDisabled 不存在）时启动自动开订阅
//

import Foundation

nonisolated enum ExperimentDefaults {
    /// 键不存在 → value；存在 → 用户设的值（非 Bool 的脏值按「从没设过」处理）。
    static func bool(_ key: String, default value: Bool, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    /// 是否从没设过（键不存在）。
    static func neverSet(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil
    }
}
