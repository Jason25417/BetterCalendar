//
//  MeetingSettings.swift
//  BetterCalendar
//
//  会议/固定块设置（⑤会议自动化）：会前多少分钟弹系统提醒（挂在固定块的日历事件上）。
//  原则4「仅固定块提醒」：只有固定块（会议/外部承诺）配会前 EKAlarm，普通工作块永不弹。
//

import Foundation

enum MeetingSettings {
    private static let defaults = UserDefaults.standard

    /// 固定块会前提醒分钟数（提醒你收尾当前事、准备赴会）。
    /// 死代码审计（2026-07-22）：原 UserDefaults 键 "meeting.lead" 从未有 UI、任何设备从未写过 → 收成常量；
    /// 日后真要做设置再开缝（届时进 SettingsSync 白名单）。
    static let leadMinutes = 5

    /// 固定块（会议等）时间过了是否自动记为完成（§5.13 收窄：工作块坚持手动、固定块=外部承诺按墙钟真实发生、可自动）。
    /// 默认开；关掉则固定块也彻底手动。删掉自动记的会议蓝块会 stick（对账 tombstone），与本开关正交。
    static var autoCompleteFixedBlocks: Bool {
        get { defaults.object(forKey: "meeting.autoComplete") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "meeting.autoComplete") }
    }
}
