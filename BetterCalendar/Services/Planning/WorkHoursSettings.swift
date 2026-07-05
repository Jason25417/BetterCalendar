//
//  WorkHoursSettings.swift
//  BetterCalendar
//
//  「最晚工作时间 / 理想收工」（2026-07-06 Jason 拍板，见 SPEC §5.11）。
//  定位=**写进 prompt 给 LLM 的软限制**（非硬 cutoff/非闹钟）：排/reflow 时尽量别把弹性块排到收工后，
//  但略超 5–10 分钟正好能多完成一件大任务则可以；用户明确排在收工后的晚间块不受此限。
//  显式设置（进阶页）+ 当天可用自然语言临时改；不做被动机器学习（违原则6）。
//

import Foundation

enum WorkHoursSettings {
    private static let defaults = UserDefaults.standard

    /// 理想收工小时（0…24，默认 23）。写进排程/reflow 的 prompt 当软限制。
    static var windDownHour: Int {
        get { defaults.object(forKey: "workHours.windDown") as? Int ?? 23 }
        set { defaults.set(min(24, max(0, newValue)), forKey: "workHours.windDown") }
    }

    /// prompt 用的收工时间文案（"23:00"）。
    static var windDownText: String { String(format: "%02d:00", windDownHour) }
}
