//
//  SentinelFeedback.swift
//  BetterCalendar
//
//  W42（Jason 2026-10-24）：哨兵叫醒了，智能体必须发；「没用」只由 Jason 点，反馈回哨兵校准（纯函数，可单测）：
//  · 反馈键 = 哪类信号 + 关于哪件事（同一块同一类 = 同一个键，跨拍 / 跨设备稳定）。消息上记着它（AgentMessage.wakeSignature）。
//  · 今天点过「没用」的同一个键 → 当天不再叫醒。
//  · 某类信号近 14 天每个「没用」把它的门槛 +0.05（上限 0.95）；过了 14 天自动回落。
//  · 任一台设备刚为同一个键发过（冷却期内）→ 不重复叫醒（消息随 iCloud 同步，两台哨兵靠它去重）。
//

import Foundation

nonisolated enum SentinelFeedback {
    static let notUsefulStep = 0.05
    static let maxThreshold = 0.95
    static let windowDays = 14.0

    /// 反馈键：信号（排序）+ 主题（这几类信号各自关于的那件事的标题）。
    static func key(signals: [String], facts: SentinelFacts) -> String {
        var subjects: [String] = []
        let set = Set(signals)
        if set.contains(SentinelSignal.plannedStartPassed.rawValue), let t = facts.overdueStart?.title { subjects.append(t) }
        if set.contains(SentinelSignal.timerOverPlan.rawValue), let t = facts.timerOverrun?.title { subjects.append(t) }
        if set.contains(SentinelSignal.deadlineNearNoProgress.rawValue), let t = facts.deadlineSoon?.title { subjects.append(t) }
        if set.contains(SentinelSignal.untrackedContextSwitch.rawValue), let t = facts.activityStart?.title { subjects.append(t) }
        if set.contains(SentinelSignal.seemsFinished.rawValue), let t = facts.activityStop?.title { subjects.append(t) }
        return signals.sorted().joined(separator: ",") + "|" + subjects.joined(separator: "/")
    }

    /// 这次判断用的门槛：信号里门槛最低的那类（其他信号还新鲜就照常能叫醒）；没有信号 = 基础门槛。
    static func threshold(base: Double, signals: [String], notices: [SentinelRecentNotice], now: Date) -> Double {
        let since = now.addingTimeInterval(-windowDays * 86400)
        let dismissed = notices.filter { $0.reaction == AgentMessage.Reaction.notUseful.rawValue && $0.at >= since }
        guard !signals.isEmpty else { return base }
        return signals.map { s in
            let n = dismissed.filter { $0.wakeSignals.contains(s) }.count
            return min(maxThreshold, base + Double(n) * notUsefulStep)
        }.min() ?? base
    }

    /// 0.79 W49（C）：分问分阈值——wake 过线、或 started / finished 各自过线，都算该叫醒；过线的那题补进 signals，理由按事实点名那块。
    /// 每题的阈值同样吃「没用」校准（那类信号近 14 天每个「没用」+0.05）。
    static func apply(_ v: SentinelVerdict, facts: SentinelFacts, settings: SentinelSettings, notices: [SentinelRecentNotice], now: Date) -> SentinelVerdict {
        var out = v
        guard let p = v.probability else { return out }
        var signals = Set(v.signals)
        var reasons: [String] = []
        let wakeT = threshold(base: settings.wakeThreshold, signals: v.signals, notices: notices, now: now)
        var wake = p >= wakeT
        if let s = v.scores?["started"] {
            let sig = SentinelSignal.untrackedContextSwitch.rawValue
            if s >= threshold(base: settings.startThreshold, signals: [sig], notices: notices, now: now) {
                wake = true; signals.insert(sig)
                let pct = Int((s * 100).rounded())
                reasons.append(facts.activityStart.map { "最近的活动像是在做「\($0.title)」，但没在计时（把握 \(pct)%）" } ?? "像是开始了一件没记的事（把握 \(pct)%）")
            }
        }
        if let f = v.scores?["finished"] {
            let sig = SentinelSignal.seemsFinished.rawValue
            if f >= threshold(base: settings.finishThreshold, signals: [sig], notices: notices, now: now) {
                wake = true; signals.insert(sig)
                let pct = Int((f * 100).rounded())
                reasons.append(facts.activityStop.map { "像是停下了「\($0.title)」（把握 \(pct)%）" } ?? "像是做完了一件事（把握 \(pct)%）")
            }
        }
        out.wake = wake
        if !reasons.isEmpty {
            // wake 本身没过线时理由换成过线那题的；过线了就并列。
            out.reason = p >= wakeT ? ([v.reason] + reasons).joined(separator: "；") : reasons.joined(separator: "；")
            if out.urgency == .low { out.urgency = .normal }
        }
        out.signals = signals.sorted()
        return out
    }

    /// 今天（逻辑日，4 点日界线）你对同一个键点过「没用」。
    static func dismissedToday(key: String, notices: [SentinelRecentNotice], now: Date) -> Bool {
        let today = DayContext.logicalStartOfDay(now)
        return notices.contains {
            $0.reaction == AgentMessage.Reaction.notUseful.rawValue && $0.wakeSignature == key
                && DayContext.logicalStartOfDay($0.at) == today
        }
    }

    /// 冷却期内任一台设备已经为同一个键发过消息（跨设备去重）。
    static func notifiedRecently(key: String, notices: [SentinelRecentNotice], now: Date, cooldownMinutes: Double) -> Bool {
        notices.contains { $0.wakeSignature == key && now.timeIntervalSince($0.at) < cooldownMinutes * 60 && $0.at <= now }
    }

    /// W42（原则 11）：这台的哨兵此刻要不要判断。计时中 / 最近在用的是别的设备 → 由那台判断；判断不出你在哪台 → Mac 判断、iPhone 不判断
    ///（Mac 看得到设备活动，判断更准；iPhone 只在打开 App 时判断）。返回不判断的原因，nil = 判断。
    static func presenceSkip(_ p: Presence, myDeviceID: String, isMac: Bool) -> String? {
        switch p.basis {
        case .timer, .recentUse:
            return p.includes(myDeviceID) ? nil : "你此刻在「\(p.deviceLabel)」（\(p.basis.label)），由那台的哨兵判断"
        case .carriedDefault, .everyDevice:
            return isMac ? nil : "判断不出你在哪台：由 Mac 的哨兵判断"
        }
    }
}
