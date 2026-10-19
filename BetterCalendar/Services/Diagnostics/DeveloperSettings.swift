//
//  DeveloperSettings.swift
//  BetterCalendar
//
//  「开发者选项」总开关（W16，2026-10-19）：开发 / 测试用的控件（发测试改动、CloudKit 播种、算法试验台、
//  皮肤试衣间、引擎观察窗、已冻结的 BC 审批入口、可观测性内部数据）统一收在它后面。默认关；
//  按「设置默认多端同步」原则进 SettingsSync 白名单——一端打开，两端都看得到开发控件。
//  只藏入口、不删功能；失败可见（横幅 / 🐞 日志）与它无关，关着也照常可见。
//

import Foundation

nonisolated enum DeveloperSettings {
    static let key = "developer.optionsEnabled"
    /// W17：从没设过时，Dev 版默认开（开发控件就是它的用途）、日用版默认关；设过一律按设的值。@AppStorage 的默认值也用它。
    static let defaultValue = AppChannel.current.isDev
    static var enabled: Bool {
        get { ExperimentDefaults.bool(key, default: defaultValue) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
