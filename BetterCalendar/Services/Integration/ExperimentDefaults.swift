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
//  （上面这些是 W8 时代已上线的开关，保持原默认，不追溯改关。）
//
//  —— W17 新功能开关约定（2026-10-19 起，Jason 开始拿日用版过真实生活）——
//  日用版里任何**新的、用户看得到的行为**一律默认关，放在一个同步设置后面，由 Jason 在设置里自己打开：
//    1. 读取一律走 `ExperimentDefaults.newFeature(键)`：键不存在 → Dev 版默认开（方便测）、日用版默认关；
//       用户设过（键存在）→ 两个通道都按用户设的值。
//    2. 键加进 `SettingsSync.syncedKeys`（Mac 打开、iPhone 也开）；Dev 版与日用版的 iCloud 键值存储天然分开，互不影响。
//    3. 设置页给一个开关，文案写清「这是什么、打开后会怎样」；开关关着时行为必须与没有这个功能时完全一致。
//    4. 不写回默认值（同上：不制造「用户设过」的假象）。转正（改成默认开）= 一次单独的、在发版说明里写明的决定。
//  只改内部实现、用户感觉不到的修复不需要开关。
//

import Foundation

nonisolated enum ExperimentDefaults {
    /// 键不存在 → value；存在 → 用户设的值（非 Bool 的脏值按「从没设过」处理）。
    static func bool(_ key: String, default value: Bool, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    /// W17 新功能开关：键不存在 → Dev 版开、日用版关；存在 → 用户设的值。约定见文件头。
    static func newFeature(_ key: String, in defaults: UserDefaults = .standard, channel: AppChannel = .current) -> Bool {
        bool(key, default: channel.isDev, in: defaults)
    }

    /// 是否从没设过（键不存在）。
    static func neverSet(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil
    }
}
