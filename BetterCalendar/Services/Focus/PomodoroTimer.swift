//
//  PomodoroTimer.swift
//  BetterCalendar
//
//  番茄钟分段的纯逻辑（确定、可单测）：原型期把番茄钟当「分段计时器」——
//  从一段已用时长推算现在处于 工作(25) 还是 休息(5) 段、段内已过/剩余多久，自动轮换。
//  （「工作段结束点确定才休息」是后续优化，见 SPEC；现在自动切。）
//

import Foundation

struct PomodoroPhase: Sendable {
    enum Kind: Sendable { case work, rest }
    var kind: Kind
    var elapsedInPhase: TimeInterval
    var phaseLength: TimeInterval
    var remaining: TimeInterval { max(0, phaseLength - elapsedInPhase) }
    /// 段已满、等用户点「确定」才切下一段（不自动切）。
    var pendingConfirm: Bool { elapsedInPhase >= phaseLength }
}

enum PomodoroTimer {
    static let work: TimeInterval = 25 * 60
    static let rest: TimeInterval = 5 * 60

    static func phase(elapsed: TimeInterval) -> PomodoroPhase {
        let cycle = work + rest
        let t = max(0, elapsed).truncatingRemainder(dividingBy: cycle)
        return t < work
            ? PomodoroPhase(kind: .work, elapsedInPhase: t, phaseLength: work)
            : PomodoroPhase(kind: .rest, elapsedInPhase: t - work, phaseLength: rest)
    }
}

/// 番茄「提前休息」的自设周上限（0.20.5，Jason 定；产品哲学：预先承诺必须是**自己选的**——
/// 默认不限次，想要硬约束的人自己设；硬性 App 限次已否（控制≠自主支持，紧急情况不能锁死）。
/// 重置**定死每周一零点**（不做重置周期设置——自由度过剩；懒重置：读的时候周键不同即视为新周）。
enum PomodoroDiscipline {
    private static let defaults = UserDefaults.standard

    /// 每周上限：0 = 不限（默认）。
    static var weeklyEarlyEndLimit: Int {
        get { defaults.integer(forKey: "pomo.earlyEndLimit") }
        set { defaults.set(newValue, forKey: "pomo.earlyEndLimit") }
    }

    /// ISO 周键（周一零点起新周），如 "2026-W28"。纯函数、可单测。
    static func weekKey(_ date: Date = .now) -> String {
        var cal = Calendar(identifier: .iso8601)   // ISO：周一为一周之始
        cal.timeZone = .current
        let year = cal.component(.yearForWeekOfYear, from: date)
        let week = cal.component(.weekOfYear, from: date)
        return "\(year)-W\(week)"
    }

    private static func usedThisWeek(now: Date) -> Int {
        guard defaults.string(forKey: "pomo.earlyEnd.weekKey") == weekKey(now) else { return 0 }
        return defaults.integer(forKey: "pomo.earlyEnd.used")
    }

    /// 本周还可提前休息几次；nil = 不限。
    static func remaining(now: Date = .now) -> Int? {
        let limit = weeklyEarlyEndLimit
        guard limit > 0 else { return nil }
        return max(0, limit - usedThisWeek(now: now))
    }

    /// 用掉一次（仅设了上限才计数——中途才设上限的人不背之前的账）。
    static func consume(now: Date = .now) {
        guard weeklyEarlyEndLimit > 0 else { return }
        let used = usedThisWeek(now: now) + 1
        defaults.set(weekKey(now), forKey: "pomo.earlyEnd.weekKey")
        defaults.set(used, forKey: "pomo.earlyEnd.used")
        DevLog.shared.info("番茄", "提前休息 本周已用 \(used)/\(weeklyEarlyEndLimit)")
    }
}
