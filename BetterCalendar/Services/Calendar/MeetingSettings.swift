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

    /// 固定块会前多少分钟提醒（提醒你收尾当前事、准备赴会）。默认 5 分钟。0 = 准点。
    static var leadMinutes: Int {
        get { defaults.object(forKey: "meeting.lead") as? Int ?? 5 }
        set { defaults.set(newValue, forKey: "meeting.lead") }
    }
}
