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
