//
//  SentinelDigest.swift
//  BetterCalendar
//
//  SPEC §19 C1 W14：给哨兵看的紧凑摘要（纯函数，时钟与时区注入，单测直接构造）。
//  来源：设备活动（ActivityLog，最近 ~30 分钟汇总）+ 今天的计划与计时（复用 AgentContextGatherer 的 AgentContextInput）
//  + 接下来的块与截止 + 最近的唤醒与主动通知（避免为同一件事反复叫醒）+ 静音/安静时段。
//  同时算出「事实」（给规则兜底用）与「变化指纹」（调度用：只看计划/计时/当前前台状态，不看时间流逝）。
//

import CryptoKit
import Foundation

/// 摘要里能直接算出来的事实（规则兜底判断用；也帮模型少算）。
struct SentinelFacts: Equatable {
    struct Late: Equatable { var title: String; var minutesLate: Int }
    struct Overrun: Equatable { var title: String; var minutesOver: Int; var elapsedMinutes: Int }
    struct Deadline: Equatable { var title: String; var minutesLeft: Int }
    /// 计划块开始时间已过、没见开始迹象（没在计时、没有实际记录）。固定安排（课/会）不算。
    var overdueStart: Late?
    /// 正在计时的那件超过了它的计划结束时间。
    var timerOverrun: Overrun?
    /// 截止临近（3 小时内）且最近 24 小时没见推进、也没在计时。
    var deadlineSoon: Deadline?
    /// 当前空闲 / 锁屏 / 睡眠已持续多少分钟（nil = 在用电脑或不知道）。
    var idleMinutes: Int?
    var timerRunning = false
}

struct SentinelDigest {
    /// 给模型看的正文（中文，紧凑）。
    var text: String
    /// SHA-256（hex）。决策日志只记它与大小，不记原文。
    var hash: String
    var bytes: Int
    var facts: SentinelFacts
    /// 情况键：计划块 + 计时 + 事实（不含分钟数与设备活动）。
    var situationKey: String = ""
}

struct SentinelDigestInput {
    var now: Date
    var context: AgentContextInput
    /// 设备活动：窗口起点前的也可以给（用来知道窗口开始时前台是谁），汇总只算窗口内。
    var activity: [ActivityEvent] = []
    var activityWindowMinutes: Double = 30
    var recentWakes: [SentinelRecentWake] = []
    var recentNotices: [SentinelRecentNotice] = []
    var attention = AttentionSettings()
    var timeZone: TimeZone = .current
    /// W42 源头去误报：有待批提案正在动的计划块（id）——「开始时间已过」不算它。
    var pendingBlockIDs: Set<UUID> = []
    /// W42：你最近在对话里说的话（30 分钟内提过某块 = 你已经在处理 / 改口了）。
    var recentUserChat: [(at: Date, text: String)] = []
    // —— W51（0.80，Jason 2026-10-27）：哨兵以前缺的不是量，是智能体有、它没有的两样——共享记忆与对话；顺带待批提案与明天的计划。
    /// 智能体的共享记忆（他的偏好 / 在跟进的事 / 拒绝过什么）；nil 或空 = 不附这一节。
    var sharedMemory: String? = nil
    /// 最近 24 小时的对话（双方；最多取最近 12 条）。
    var recentChat: [(at: Date, fromUser: Bool, text: String)] = []
    /// 待你批的提案（发起时刻 + 一句「做什么」）。
    var pendingProposals: [(at: Date, title: String)] = []
    /// 明天（逻辑日）的计划块（来自 context.upcoming）。
    var tomorrow: [AgentContextInput.Block] = []
}

/// 设备活动汇总（Mac 前台状态机 + 浏览器域名 + iPhone / iPad 各自的打开次数；W28 起按设备类别分开，旧记录按 iPhone 计）。
nonisolated struct SentinelActivitySummary: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case unknown, app(String), idle, locked, asleep
        var label: String {
            switch self {
            case .unknown: "不知道（没有记录）"
            case let .app(name): "前台「\(name)」"
            case .idle: "无键鼠操作"
            case .locked: "锁屏"
            case .asleep: "睡眠"
            }
        }
        var isAway: Bool { self == .idle || self == .locked || self == .asleep }
    }
    var current: State = .unknown
    var currentSince: Date?
    /// 窗口内各 App 前台时长（秒），按时长降序。
    var appSeconds: [(name: String, seconds: Double)] = []
    var awaySeconds: Double = 0
    var switches = 0
    var hosts: [(host: String, count: Int)] = []
    var phoneOpens: [(name: String, count: Int)] = []
    /// W28：iPad 的打开次数（与 phoneOpens 分开；以前 iPad 的也会算进 iPhone）。
    var padOpens: [(name: String, count: Int)] = []
    var eventCount = 0

    static func == (a: Self, b: Self) -> Bool {
        a.current == b.current && a.currentSince == b.currentSince && a.switches == b.switches && a.eventCount == b.eventCount
            && a.appSeconds.map(\.name) == b.appSeconds.map(\.name) && a.appSeconds.map(\.seconds) == b.appSeconds.map(\.seconds)
            && a.awaySeconds == b.awaySeconds && a.hosts.map(\.host) == b.hosts.map(\.host) && a.hosts.map(\.count) == b.hosts.map(\.count)
            && a.phoneOpens.map(\.name) == b.phoneOpens.map(\.name) && a.phoneOpens.map(\.count) == b.phoneOpens.map(\.count)
            && a.padOpens.map(\.name) == b.padOpens.map(\.name) && a.padOpens.map(\.count) == b.padOpens.map(\.count)
    }

    static func summarize(_ events: [ActivityEvent], window: DateInterval, now: Date) -> SentinelActivitySummary {
        var s = SentinelActivitySummary()
        let sorted = events.filter { $0.at <= now }.sorted { $0.at < $1.at }
        var state: State = .unknown, since: Date? = nil, lastApp: String? = nil
        var perApp: [String: Double] = [:]
        func close(at t: Date) {
            let a = max(since ?? window.start, window.start), b = min(t, now)
            guard b > a else { return }
            switch state {
            case let .app(name): perApp[name, default: 0] += b.timeIntervalSince(a)
            case .idle, .locked, .asleep: s.awaySeconds += b.timeIntervalSince(a)
            case .unknown: break
            }
        }
        var hostCount: [String: Int] = [:], phone: [String: Int] = [:], pad: [String: Int] = [:]
        for e in sorted {
            let inWindow = e.at >= window.start
            if inWindow { s.eventCount += 1 }
            if e.platform != "macOS" {
                if inWindow, e.kind == .appOpened, let name = e.appName {
                    if e.resolvedDeviceKind.kind == .ipad { pad[name, default: 0] += 1 } else { phone[name, default: 0] += 1 }
                }
                continue
            }
            if e.kind == .browserPage {
                if inWindow, let raw = e.url, let host = URL(string: raw)?.host { hostCount[host.replacingOccurrences(of: "www.", with: ""), default: 0] += 1 }
                continue
            }
            let next: State?
            switch e.kind {
            case .appActivated: next = e.appName.map { .app($0) } ?? .unknown
            case .idleStart: next = .idle
            case .screenLocked: next = .locked
            case .systemSleep: next = .asleep
            case .idleEnd, .screenUnlocked, .systemWake: next = lastApp.map { .app($0) } ?? .unknown
            default: next = nil
            }
            guard let next, next != state else { continue }
            close(at: e.at)
            if case .app = next, e.kind == .appActivated, inWindow { s.switches += 1 }
            if case let .app(name) = next { lastApp = name }
            state = next; since = e.at
        }
        close(at: now)
        s.current = state
        s.currentSince = since
        s.appSeconds = perApp.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }   // 同时长按名字，保证哈希稳定
        s.hosts = hostCount.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        s.phoneOpens = phone.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        s.padOpens = pad.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return s
    }
}

enum SentinelDigestBuilder {
    static let lateThresholdMinutes = 10
    static let deadlineHorizonMinutes = 180

    static func build(_ input: SentinelDigestInput) -> SentinelDigest {
        let now = input.now, ctx = input.context
        var cal = Calendar(identifier: .gregorian); cal.timeZone = input.timeZone
        let hm = DateFormatter(); hm.locale = Locale(identifier: "en_US_POSIX"); hm.timeZone = input.timeZone; hm.dateFormat = "HH:mm"
        let full = DateFormatter(); full.locale = Locale(identifier: "zh_CN"); full.timeZone = input.timeZone; full.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        let mins: (TimeInterval) -> Int = { max(0, Int(($0 / 60).rounded())) }
        let window = DateInterval(start: now.addingTimeInterval(-input.activityWindowMinutes * 60), end: now)
        let activity = SentinelActivitySummary.summarize(input.activity, window: window, now: now)
        let facts = self.facts(input, activity: activity)
        var lines: [String] = []

        lines.append("现在：\(full.string(from: now))（时区 \(input.timeZone.identifier)）")
        let a = input.attention
        var attention = "打扰设置：安静时段 \(a.quietStartHour):00–\(a.quietEndHour):00"
        if let until = a.mutedUntil, until > now { attention += "；静音到 \(hm.string(from: until))" }
        lines.append(attention)

        // 计划（今天）：只列 3 小时前 → 6 小时后之间的块，其余给个数。
        let fg = ctx.running.foreground
        let runningTitles = Set(([fg].compactMap { $0 } + ctx.running.background).map { norm($0.title) })
        let near = ctx.today.items.filter { $0.end > now.addingTimeInterval(-3 * 3600) && $0.start < now.addingTimeInterval(6 * 3600) }
        lines.append("【今天的计划】共 \(ctx.today.items.count) 块" + (near.count < ctx.today.items.count ? "（下面只列前后几小时的 \(near.count) 块）" : ""))
        if let e = ctx.today.error { lines.append("（读取计划失败：\(e)）") }
        for b in near {
            var tags: [String] = []
            if b.isFixed { tags.append("固定") }
            if b.important { tags.append("要紧") }
            if let d = b.deadline { tags.append("截止 \(hm.string(from: d))") }
            let status: String
            if runningTitles.contains(norm(b.title)) { status = "正在计时" }
            else if hasActual(b, ctx.actuals.items) { status = "已有实际记录" }
            else if b.end <= now { status = "已过，没有实际记录" }
            else if b.start <= now { status = "应在进行中，没见开始迹象（已过开始 \(mins(now.timeIntervalSince(b.start))) 分）" }
            else { status = "未到（\(mins(b.start.timeIntervalSince(now))) 分后开始）" }
            lines.append("- \(hm.string(from: b.start))–\(hm.string(from: b.end)) \(clip(b.title))" + (tags.isEmpty ? "" : "（\(tags.joined(separator: "、"))）") + "：\(status)")
        }

        // 计时
        if let fg {
            let elapsed = mins(now.timeIntervalSince(fg.start) - fg.pausedSeconds)
            var line = "【计时】正在计时「\(clip(fg.title))」，自 \(hm.string(from: fg.start)) 起，净计 \(elapsed) 分"
            if let o = facts.timerOverrun { line += "；已超过计划结束 \(o.minutesOver) 分" }
            if ctx.running.onBreak { line += "；现在在休息" }
            lines.append(line)
        } else {
            lines.append("【计时】没有在计时" + (ctx.running.onBreak ? "（在休息）" : ""))
        }
        if !ctx.running.background.isEmpty {
            lines.append("同时在做（后台计时）：" + ctx.running.background.map { "「\(clip($0.title))」" }.joined(separator: "、"))
        }

        // 接下来：系统日历 3 小时内开始的
        let soonEvents = ctx.calendar.items.filter { !$0.isAllDay && $0.start > now && $0.start < now.addingTimeInterval(3 * 3600) }.prefix(4)
        if !soonEvents.isEmpty {
            lines.append("【接下来（系统日历）】" + soonEvents.map { "\(hm.string(from: $0.start)) \(clip($0.title))" }.joined(separator: "；"))
        }

        // 截止（24 小时内）
        let horizon = now.addingTimeInterval(24 * 3600)
        let pool = (ctx.todos.items + ctx.longterm.items).filter { ($0.deadline ?? .distantPast) > now && ($0.deadline ?? .distantFuture) <= horizon }
            .sorted { ($0.deadline ?? now) < ($1.deadline ?? now) }.prefix(5)
        if !pool.isEmpty {
            lines.append("【24 小时内截止】")
            for p in pool {
                let d = p.deadline!
                let worked = p.lastWorkedAt.map { "最近一次推进 \(hm.string(from: $0))" } ?? "最近 7 天没有计时"
                lines.append("- 「\(clip(p.title))」截止 \(hm.string(from: d))（还剩 \(mins(d.timeIntervalSince(now))) 分；最近 7 天投入 \(p.recentMinutes) 分；\(worked)）")
            }
        }

        // W51：明天的计划（只给个数与前几块；判断「今天放不下」「别催」时要用）
        if !input.tomorrow.isEmpty {
            let items = input.tomorrow.sorted { $0.start < $1.start }
            lines.append("【明天的计划】共 \(items.count) 块：" + items.prefix(6).map { "\(hm.string(from: $0.start)) \(clip($0.title))" }.joined(separator: "；")
                         + (items.count > 6 ? "…" : ""))
        }

        // 设备活动
        lines.append("【设备活动（最近 \(Int(input.activityWindowMinutes)) 分钟）】" + (activity.eventCount == 0 && activity.current == .unknown ? "没有记录" : ""))
        if activity.current != .unknown || activity.eventCount > 0 {
            var cur = "当前：\(activity.current.label)"
            if let since = activity.currentSince { cur += "，自 \(hm.string(from: since))（\(mins(now.timeIntervalSince(since))) 分）" }
            lines.append(cur)
            if !activity.appSeconds.isEmpty {
                lines.append("各 App 前台：" + activity.appSeconds.prefix(8).map { "\($0.name) \(max(1, mins($0.seconds))) 分" }.joined(separator: "、"))
            }
            lines.append("切换 App \(activity.switches) 次；离开（空闲/锁屏/睡眠）共 \(mins(activity.awaySeconds)) 分")
            if !activity.hosts.isEmpty {
                lines.append("浏览器（域名，打开页数）：" + activity.hosts.prefix(6).map { "\($0.host) \($0.count)" }.joined(separator: "、"))
            }
            if !activity.phoneOpens.isEmpty {
                lines.append("iPhone 打开：" + activity.phoneOpens.prefix(6).map { "\($0.name) \($0.count) 次" }.joined(separator: "、"))
            }
            if !activity.padOpens.isEmpty {
                lines.append("iPad 打开：" + activity.padOpens.prefix(6).map { "\($0.name) \($0.count) 次" }.joined(separator: "、"))
            }
        }

        // 最近的唤醒与通知
        let recentCut = now.addingTimeInterval(-3 * 3600)
        let wakes = input.recentWakes.filter { $0.at >= recentCut && $0.at <= now }.sorted { $0.at > $1.at }.prefix(8)
        lines.append("【最近 3 小时叫醒过智能体】" + (wakes.isEmpty ? "没有" : ""))
        for w in wakes { lines.append("- \(hm.string(from: w.at)) \(w.kind)：\(clip(w.summary, 100))") }
        let notices = input.recentNotices.filter { $0.at >= recentCut && $0.at <= now }.sorted { $0.at > $1.at }.prefix(5)
        lines.append("【最近 3 小时给 Jason 的主动通知】" + (notices.isEmpty ? "没有" : ""))
        for n in notices {
            var line = "- \(hm.string(from: n.at)) 「\(clip(n.title, 60))」" + (n.delivered ? "已弹出" : "被拦下（\(n.suppressReason ?? "")）")
            if let r = n.reaction { line += "，他选了\(r == "muted" ? "静音" : r == AgentMessage.Reaction.notUseful.rawValue ? "「没用」（这类叫醒他觉得没必要）" : "好")" }
            lines.append(line)
        }

        // W51：待批提案 / 最近对话 / 共享记忆（智能体看得到、哨兵以前看不到的那几样）
        let pendingNow = input.pendingProposals.filter { $0.at <= now }.sorted { $0.at > $1.at }.prefix(6)
        if !pendingNow.isEmpty {
            lines.append("【待 Jason 批的提案】" + pendingNow.map { "\(hm.string(from: $0.at)) \(clip($0.title, 60))" }.joined(separator: "；"))
        }
        let chatCut = now.addingTimeInterval(-24 * 3600)
        let chat = input.recentChat.filter { $0.at >= chatCut && $0.at <= now }.sorted { $0.at < $1.at }.suffix(12)
        if !chat.isEmpty {
            lines.append("【最近 24 小时的对话】")
            for c in chat { lines.append("- \(hm.string(from: c.at)) \(c.fromUser ? "Jason" : "智能体")：\(clip(c.text, 120))") }
        }
        if let memory = input.sharedMemory?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty {
            lines.append("【智能体的共享记忆（他的偏好 / 在跟进的事 / 拒绝过什么；与他说过的话冲突时以对话为准）】")
            lines.append(clip(memory, 2000))
        }

        // 预先算好的事实（帮模型少算；规则兜底也用它）
        var hints: [String] = []
        if let l = facts.overdueStart { hints.append("「\(clip(l.title))」开始时间已过 \(l.minutesLate) 分，没见开始迹象") }
        if let o = facts.timerOverrun { hints.append("「\(clip(o.title))」计时已超过计划结束 \(o.minutesOver) 分") }
        if let d = facts.deadlineSoon { hints.append("「\(clip(d.title))」\(d.minutesLeft) 分后截止，最近 24 小时没见推进") }
        if let idle = facts.idleMinutes, idle >= 1 { hints.append("已离开电脑 \(idle) 分") }
        lines.append("【已算出的事实】" + (hints.isEmpty ? "无" : hints.joined(separator: "；")))

        let text = lines.joined(separator: "\n")
        let data = Data(text.utf8)
        return SentinelDigest(text: text, hash: sha256(data), bytes: data.count, facts: facts,
                              situationKey: situationKey(context: ctx, facts: facts))
    }

    static func facts(_ input: SentinelDigestInput, activity: SentinelActivitySummary) -> SentinelFacts {
        let now = input.now, ctx = input.context
        var f = SentinelFacts()
        let fg = ctx.running.foreground
        f.timerRunning = fg != nil
        let running = Set(([fg].compactMap { $0 } + ctx.running.background).map { norm($0.title) })
        // 计划开始已过、没见开始：最近开始的那块（开始在 90 分钟内、还没结束、不是固定安排）。
        // W42 源头去误报（10/21–10/23 的 13 次叫醒多是这三种）：此刻你在日历的会 / 课里、这块有待批提案、你 30 分钟内在对话里提过它。
        let inEvent = ctx.calendar.items.contains { !$0.isAllDay && $0.start <= now && $0.end > now }
        let chat = input.recentUserChat.filter { now.timeIntervalSince($0.at) < 30 * 60 && $0.at <= now }.map { norm($0.text) }
        func mentioned(_ title: String) -> Bool { let t = norm(title); return t.count >= 2 && chat.contains { $0.contains(t) } }
        if !inEvent,
           let b = ctx.today.items.filter({ !$0.isFixed && $0.start <= now.addingTimeInterval(-Double(lateThresholdMinutes) * 60)
                                            && $0.start > now.addingTimeInterval(-90 * 60) && $0.end > now })
            .sorted(by: { $0.start > $1.start }).first,
           !running.contains(norm(b.title)), !hasActual(b, ctx.actuals.items),
           !(b.id.map(input.pendingBlockIDs.contains) ?? false), !mentioned(b.title) {
            f.overdueStart = .init(title: b.title, minutesLate: Int(now.timeIntervalSince(b.start) / 60))
        }
        // 计时超计划：按标题对上今天的块。
        if let fg, let b = ctx.today.items.first(where: { norm($0.title) == norm(fg.title) }), now > b.end {
            f.timerOverrun = .init(title: fg.title, minutesOver: Int(now.timeIntervalSince(b.end) / 60),
                                   elapsedMinutes: Int((now.timeIntervalSince(fg.start) - fg.pausedSeconds) / 60))
        }
        // 截止临近、没见推进。
        let horizon = now.addingTimeInterval(Double(deadlineHorizonMinutes) * 60)
        let candidates = (ctx.todos.items + ctx.longterm.items).compactMap { p -> (String, Date, Date?)? in
            guard let d = p.deadline, d > now, d <= horizon else { return nil }
            return (p.title, d, p.lastWorkedAt)
        } + ctx.today.items.compactMap { b -> (String, Date, Date?)? in
            guard let d = b.deadline, d > now, d <= horizon, !hasActual(b, ctx.actuals.items) else { return nil }
            return (b.title, d, nil)
        }
        if let c = candidates.filter({ !running.contains(norm($0.0)) && ($0.2 ?? .distantPast) < now.addingTimeInterval(-24 * 3600) })
            .sorted(by: { $0.1 < $1.1 }).first {
            f.deadlineSoon = .init(title: c.0, minutesLeft: Int(c.1.timeIntervalSince(now) / 60))
        }
        if activity.current.isAway, let since = activity.currentSince { f.idleMinutes = Int(now.timeIntervalSince(since) / 60) }
        return f
    }

    /// 变化指纹（调度用）：计划块、计时状态、当前前台状态。时间流逝本身不算变化（那是例行检查的事）。
    static func changeFingerprint(context ctx: AgentContextInput, activity: [ActivityEvent], now: Date) -> String {
        var parts: [String] = []
        for b in ctx.today.items { parts.append("b:\(b.id?.uuidString ?? b.title)|\(Int(b.start.timeIntervalSince1970))|\(Int(b.end.timeIntervalSince1970))") }
        if let fg = ctx.running.foreground { parts.append("t:\(fg.title)|\(Int(fg.start.timeIntervalSince1970))|\(Int(fg.pausedSeconds / 60))") }
        parts.append("bg:" + ctx.running.background.map(\.title).sorted().joined(separator: ","))
        parts.append("brk:\(ctx.running.onBreak)")
        let summary = SentinelActivitySummary.summarize(activity, window: DateInterval(start: now.addingTimeInterval(-3600), end: now), now: now)
        parts.append("a:\(summary.current.label)")
        let lastHost = activity.last(where: { $0.kind == .browserPage && $0.at <= now })?.url.flatMap { URL(string: $0)?.host } ?? ""
        parts.append("h:\(lastHost)")
        // W28：iPhone / iPad 各看各的最近一条（以前同一个槽，两台交替会互相覆盖）；旧记录按 iPhone 计
        for kind in [ActivityDeviceKind.iphone, .ipad] {
            let last = activity.last(where: { $0.platform != "macOS" && $0.at <= now && $0.resolvedDeviceKind.kind == kind })
                .map { "\($0.kind.rawValue)|\($0.appName ?? "")" } ?? ""
            parts.append((kind == .iphone ? "p:" : "pad:") + last)
        }
        return sha256(Data(parts.joined(separator: "\n").utf8))
    }

    static func situationKey(context ctx: AgentContextInput, facts f: SentinelFacts) -> String {
        var parts = ctx.today.items.map { "\($0.id?.uuidString ?? $0.title)|\(Int($0.start.timeIntervalSince1970))|\(Int($0.end.timeIntervalSince1970))" }
        parts.append("t:\(ctx.running.foreground?.title ?? "")|\(ctx.running.onBreak)")
        parts.append("f:\(f.overdueStart?.title ?? "")|\(f.timerOverrun?.title ?? "")|\(f.deadlineSoon?.title ?? "")|\(f.idleMinutes != nil)")
        return String(sha256(Data(parts.joined(separator: "\n").utf8)).prefix(16))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private static func hasActual(_ b: AgentContextInput.Block, _ actuals: [AgentContextInput.Actual]) -> Bool {
        actuals.contains { $0.end > b.start.addingTimeInterval(-10 * 60) && $0.start < b.end && ($0.start >= b.start.addingTimeInterval(-10 * 60) || norm($0.title) == norm(b.title)) }
    }

    private static func clip(_ s: String, _ n: Int = 40) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
}
