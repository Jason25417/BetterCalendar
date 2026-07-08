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

    // MARK: 收工线硬执法（0.23 B，SPEC §11 ②：候补方案毕业）

    /// 收工线宽限（分钟）——**算法内部参数，不进设置页**（2026-07-08 拍板：两个旋钮控一条边界违原则6；
    /// 用户契约只有收工线本身）。定值依据：试验台 F 组用例 10min 全绿；后续实验可在试验台调后再改此值。
    static let graceMinutes = 10

    /// 收工线时刻：锚到 reference 所在**逻辑日**（hour=24 → 次日零点）。
    static func windDownDate(for reference: Date) -> Date {
        DayContext.logicalStartOfDay(reference).addingTimeInterval(TimeInterval(windDownHour) * 3600)
    }

    /// 生效收工线：还没到线 → 用线；**已过线仍在开工 = 用户自己选择的加班**（原则7：软件不夺权），
    /// 此时退回逻辑日尾（凌晨 4 点）作为绝对上限——别把加班者的剩余日程全轰进候补。
    static func effectiveWindDown(from: Date) -> Date {
        let line = windDownDate(for: from)
        return from < line ? line : DayContext.endOfPlannableDay(from)
    }
}
