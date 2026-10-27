#if os(macOS)
import Foundation
import Testing
@testable import BetterCalendar

/// 0.79 W49：哨兵看设备活动判断「像是开始了 / 像是做完了」。
/// B 最近转变段；A 活动签名（学 / 借 / 匹配 / 负样本）+ 开始 / 停下事实 + 「到点没开始」被活动迹象压掉；
/// C 决策模型分问分阈值（Jev / OpenAI 请求形状、解析、引擎按各自的线叫醒）、规则兜底用事实；引擎从实际记录学签名。
/// 全部注入时钟与内存活动记录；不真调 API。
@MainActor @Suite struct W49SentinelActivityTests {
    static let noon: Date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_792_000_000))!
    let utc = TimeZone(identifier: "UTC")!

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-w49-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func mac(_ at: Date, _ kind: ActivityEvent.Kind, app: String? = nil, url: String? = nil) -> ActivityEvent {
        ActivityEvent(at: at, kind: kind, deviceId: "mac", platform: "macOS", appName: app, url: url)
    }

    /// 一段「写论文」的样子：Pages 为主、Safari 查资料。
    func writingEvents(from start: Date, minutes: Double) -> [ActivityEvent] {
        let m: (Double) -> Date = { start.addingTimeInterval($0 * 60) }
        var e = [mac(m(0), .appActivated, app: "Pages")]
        var t = 0.0
        while t + 10 < minutes {
            e.append(mac(m(t + 8), .appActivated, app: "Safari"))
            e.append(mac(m(t + 8.5), .browserPage, url: "https://scholar.google.com/x"))
            e.append(mac(m(t + 10), .appActivated, app: "Pages"))
            t += 10
        }
        return e
    }

    func noQuiet() -> AttentionSettings { var a = AttentionSettings(); a.quietStartHour = 0; a.quietEndHour = 0; return a }

    // MARK: B 最近转变

    @Test func transitionsIgnoreFlickerAndKeepCurrentSegment() {
        let now = Self.noon
        let m: (Double) -> Date = { now.addingTimeInterval($0 * 60) }
        let events = [
            mac(m(-40), .appActivated, app: "Xcode"),
            mac(m(-20), .appActivated, app: "Finder"),     // 20 秒后就回去：一闪而过
            mac(m(-19.67), .appActivated, app: "Xcode"),
            mac(m(-8), .appActivated, app: "Safari"),
            mac(m(-0.5), .idleStart),                       // 当前段：虽短也保留
        ]
        let s = SentinelActivitySummary.summarize(events, window: DateInterval(start: m(-30), end: now), now: now)
        #expect(s.transitions.map(\.to) == [.app("Safari"), .idle])
        #expect(s.transitions.first?.from == .app("Xcode"))
        let d = SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: AgentContextInput(now: now), activity: events,
                                                                attention: noQuiet(), timeZone: utc))
        #expect(d.text.contains("【最近转变（Mac 前台）】"))
        #expect(d.text.contains("前台「Xcode」 → 前台「Safari」（持续 8 分）") || d.text.contains("前台「Xcode」 → 前台「Safari」（持续 7 分）"))
        #expect(d.text.contains("→ 无键鼠操作（持续 1 分，至今）"))
    }

    // MARK: A 签名

    @Test func profileSampleMatchAndNegativeLearning() {
        let start = Self.noon.addingTimeInterval(-3600)
        let writing = writingEvents(from: start, minutes: 60)
        let p = ActivityProfile.sample(writing, interval: DateInterval(start: start, duration: 3600), now: Self.noon)
        let profile = try! #require(p)
        #expect(profile.apps["Pages"]! > 0.7 && profile.apps["Safari"]! > 0.1)
        #expect(profile.hosts["scholar.google.com"] == 1)
        #expect(profile.match(profile) > 0.99)
        // 完全不同的活动：几乎不匹配
        let video = [mac(start, .appActivated, app: "IINA")]
        let v = ActivityProfile.sample(video, interval: DateInterval(start: start, duration: 600), now: Self.noon)!
        #expect(profile.match(v) == 0)
        // 没在用电脑的时段学不出画像
        let away = [mac(start, .screenLocked)]
        #expect(ActivityProfile.sample(away, interval: DateInterval(start: start, duration: 600), now: Self.noon) == nil)
        // EWMA：再学一段纯 Safari，Pages 占比下降但还在；负样本把 Safari 压回去
        var learned = profile
        let safariOnly = ActivityProfile.sample([mac(start, .appActivated, app: "Safari")], interval: DateInterval(start: start, duration: 600), now: Self.noon)!
        learned.learn(safariOnly, at: Self.noon)
        #expect(learned.samples == 2 && learned.apps["Pages"]! < profile.apps["Pages"]! && learned.apps["Safari"]! > profile.apps["Safari"]!)
        let before = learned.apps["Safari"]!
        learned.learn(safariOnly, positive: false, at: Self.noon)
        #expect(learned.apps["Safari"]! < before && learned.samples == 2)
    }

    @Test func storeLearnsIdempotentlyPersistsAndBorrowsByTokens() throws {
        let dir = try tempDir()
        let store = ActivitySignatureStore(directory: dir)
        let start = Self.noon.addingTimeInterval(-3600)
        let interval = DateInterval(start: start, duration: 3600)
        let events = writingEvents(from: start, minutes: 60)
        #expect(store.learn(title: "写 IFS 论文", interval: interval, events: events, now: Self.noon))
        #expect(!store.learn(title: "写 IFS 论文", interval: interval, events: events, now: Self.noon))   // 同一条只学一次
        #expect(!store.learn(title: "喝水", interval: DateInterval(start: start, duration: 120), events: events, now: Self.noon))   // 太短
        #expect(store.signature(for: "写 ifs 论文")?.borrowedFrom == nil)
        // 冷启动借签名：分词重合（「论文」）
        let hit = try #require(store.signature(for: "改论文引言"))
        #expect(hit.borrowedFrom == "写 ifs 论文")
        #expect(store.signature(for: "跑步") == nil)
        // 落盘再读回
        let again = ActivitySignatureStore(directory: dir)
        #expect(again.profiles["写 ifs 论文"]?.samples == 1)
        #expect(again.hasLearned(title: "写 IFS 论文", interval: interval))
        #expect(ActivitySignatureStore.tokens("写 BetterCalendar 0.79 发版") == ["bettercalendar", "发版", "79"])
    }

    func contextWithBlock(_ now: Date, title: String = "写 IFS 论文", timing: Bool = false) -> AgentContextInput {
        var c = AgentContextInput(now: now)
        c.today.items = [.init(title: title, start: now.addingTimeInterval(-25 * 60), end: now.addingTimeInterval(60 * 60), id: UUID())]
        if timing { c.running.foreground = .init(title: title, start: now.addingTimeInterval(-25 * 60)) }
        return c
    }

    func learnedStore() throws -> ActivitySignatureStore {
        let store = ActivitySignatureStore(directory: try tempDir())
        let start = Self.noon.addingTimeInterval(-6 * 3600)
        store.learn(title: "写 IFS 论文", interval: DateInterval(start: start, duration: 3600), events: writingEvents(from: start, minutes: 60), now: Self.noon)
        return store
    }

    @Test func activityStartFactSuppressesOverdueStartAndShowsMatch() throws {
        let now = Self.noon
        let store = try learnedStore()
        // 之前 15 分钟在看视频，最近 10 分钟像在写论文（Pages）
        let events = [mac(now.addingTimeInterval(-40 * 60), .appActivated, app: "IINA")] + writingEvents(from: now.addingTimeInterval(-10 * 60), minutes: 10)
        var input = SentinelDigestInput(now: now, context: contextWithBlock(now), activity: events, attention: noQuiet(), timeZone: utc)
        input.signatures = { store.signature(for: $0) }
        let d = SentinelDigestBuilder.build(input)
        #expect(d.facts.activityStart?.title == "写 IFS 论文" && (d.facts.activityStart?.matchPercent ?? 0) >= 60)
        #expect(d.facts.overdueStart == nil)   // 活动像在做它 = 有开始迹象，不再算「到点没开始」
        #expect(d.facts.activityStop == nil)
        #expect(d.text.contains("但最近的活动像在做它") && d.text.contains("分钟活动匹配"))
        #expect(d.text.contains("像是开始了"))
        // 没签名时照旧「没见开始迹象」
        input.signatures = { _ in nil }
        let plain = SentinelDigestBuilder.build(input)
        #expect(plain.facts.overdueStart?.title == "写 IFS 论文" && plain.facts.activityStart == nil)
        #expect(plain.situationKey != d.situationKey)
    }

    @Test func activityStopFactWhenMatchDropsEvenWhileTimerRuns() async throws {
        let now = Self.noon
        let store = try learnedStore()
        // 之前 15 分钟在写论文，最近 10 分钟切去看视频；计时还在走
        let events = writingEvents(from: now.addingTimeInterval(-25 * 60), minutes: 15) + [mac(now.addingTimeInterval(-10 * 60), .appActivated, app: "IINA")]
        var input = SentinelDigestInput(now: now, context: contextWithBlock(now, timing: true), activity: events, attention: noQuiet(), timeZone: utc)
        input.signatures = { store.signature(for: $0) }
        let d = SentinelDigestBuilder.build(input)
        let stop = try #require(d.facts.activityStop)
        #expect(stop.title == "写 IFS 论文" && stop.beforePercent >= 60 && stop.nowPercent < 25 && stop.timerRunning)
        #expect(d.text.contains("像是停下了") && d.text.contains("（计时还在走）"))
        // 规则兜底也能用这个事实叫醒
        let j = try await RuleSentinelJudge().judge(d)
        #expect(j.verdict.wake && j.verdict.signals == [SentinelSignal.seemsFinished.rawValue])
    }

    // MARK: C 分问分阈值

    @Test func decisionModelsAskStartedAndFinishedSeparately() throws {
        let digest = SentinelDigest(text: "x", hash: "h", bytes: 1, facts: SentinelFacts())
        let jev = JevSentinelJudge.body(digest)["questions"] as! [String: Any]
        #expect(Set(jev.keys) == ["wake", "started", "finished", "category", "urgency"])
        let openai = (OpenAIDecisionsSentinelJudge.body(digest)["questions"] as! [[String: Any]]).compactMap { $0["name"] as? String }
        #expect(openai == ["wake", "started", "finished", "category", "urgency"])
        let parsed = try JevSentinelJudge.parse(["answers": ["wake": ["noul": 0.3], "started": ["noul": 0.8], "finished": ["noul": 0.1],
                                                             "category": ["choice": "other"], "urgency": ["score": 0.5]]], digest: digest)
        #expect(parsed.verdict.scores?["started"] == 0.8 && parsed.verdict.scores?["wake"] == 0.3 && parsed.verdict.probability == 0.3)
        let old = try JevSentinelJudge.parse(["answers": ["wake": ["noul": 0.9], "category": ["choice": "other"], "urgency": ["score": 0.5]]], digest: digest)
        #expect(old.verdict.scores?["started"] == nil && old.verdict.probability == 0.9)   // 没问 / 没答也不炸
    }

    @Test func applyWakesOnStartedOrFinishedByTheirOwnThresholdsAndNamesTheBlock() {
        var settings = SentinelSettings()
        settings.wakeThreshold = 0.75; settings.startThreshold = 0.6; settings.finishThreshold = 0.6
        var facts = SentinelFacts()
        facts.activityStart = .init(title: "写 IFS 论文", matchPercent: 80, borrowed: false)
        let v = SentinelDecisionQuestions.verdict(probability: 0.3, category: "other", urgencyScore: 0.1, started: 0.7, finished: 0.1)
        let out = SentinelFeedback.apply(v, facts: facts, settings: settings, notices: [], now: Self.noon)
        #expect(out.wake && out.signals == [SentinelSignal.untrackedContextSwitch.rawValue] && out.urgency == .normal)
        #expect(out.reason.contains("写 IFS 论文") && out.reason.contains("70%"))
        // 都没过线 → 不叫；wake 单独过线照旧
        let low = SentinelFeedback.apply(SentinelDecisionQuestions.verdict(probability: 0.5, category: "other", urgencyScore: 0, started: 0.5, finished: 0.5),
                                         facts: facts, settings: settings, notices: [], now: Self.noon)
        #expect(!low.wake && low.signals.isEmpty)
        let timeOnly = SentinelFeedback.apply(SentinelDecisionQuestions.verdict(probability: 0.8, category: "planned_start_passed", urgencyScore: 1, started: 0.2, finished: 0.2),
                                              facts: facts, settings: settings, notices: [], now: Self.noon)
        #expect(timeOnly.wake && timeOnly.signals == [SentinelSignal.plannedStartPassed.rawValue] && timeOnly.reason.hasPrefix("计划的开始时间已过"))
        // 「没用」校准同样作用在 finished 的线上：两次 → 0.6 + 0.10 = 0.70，0.65 不再过线
        let dismissed = (0 ..< 2).map { i in
            SentinelRecentNotice(at: Self.noon.addingTimeInterval(Double(-i - 1) * 3600), title: "x", delivered: true, suppressReason: nil,
                                 reaction: AgentMessage.Reaction.notUseful.rawValue, wakeSignals: [SentinelSignal.seemsFinished.rawValue], wakeSignature: nil)
        }
        let fin = SentinelDecisionQuestions.verdict(probability: 0.2, category: "other", urgencyScore: 0, started: 0.1, finished: 0.65)
        #expect(SentinelFeedback.apply(fin, facts: facts, settings: settings, notices: [], now: Self.noon).wake)
        #expect(!SentinelFeedback.apply(fin, facts: facts, settings: settings, notices: dismissed, now: Self.noon).wake)
        // 反馈键带上这块的标题（同一块同一类当天「没用」不再叫）
        #expect(SentinelFeedback.key(signals: out.signals, facts: facts) == "untracked_context_switch|写 IFS 论文")
    }

    @Test func settingsKeepOldKeysAndFillNewThresholds() throws {
        let data = try JSONEncoder().encode(["wakeThreshold": 0.8])
        let s = try JSONDecoder().decode(SentinelSettings.self, from: data)
        #expect(s.wakeThreshold == 0.8 && s.startThreshold == 0.6 && s.finishThreshold == 0.6)
    }

    // MARK: 引擎：从实际记录学签名、按分线叫醒

    @Test func engineLearnsSignaturesFromActualsAndWakesOnStartedScore() async throws {
        let now = Self.noon
        let store = ActivitySignatureStore(directory: try tempDir())
        let yesterday = now.addingTimeInterval(-5 * 3600)
        var ctx = contextWithBlock(now)
        ctx.actuals.items = [.init(title: "写 IFS 论文", start: yesterday, end: yesterday.addingTimeInterval(3600)),
                             .init(title: "喝水", start: yesterday, end: yesterday.addingTimeInterval(60))]   // 太短，不学
        let activity = MemoryActivityLog(writingEvents(from: yesterday, minutes: 60)
                                         + [mac(now.addingTimeInterval(-40 * 60), .appActivated, app: "IINA")]
                                         + writingEvents(from: now.addingTimeInterval(-10 * 60), minutes: 10))
        let judge = FakeJudge(wake: false)
        judge.verdict = SentinelDecisionQuestions.verdict(probability: 0.2, category: "other", urgencyScore: 0.3, started: 0.7, finished: 0.05)
        let log = MemorySentinelDecisionLog()
        let e = SentinelEngine(judges: [judge], log: log, bridge: DirectorySentinelBridge(root: try tempDir()), activity: activity,
                               defaults: UserDefaults(suiteName: "bc-w49-" + UUID().uuidString)!, signatures: store, now: { now }) { _ in ctx }
        let a = noQuiet(); e.attention = { a }
        await e.runNow()
        #expect(store.profiles["写 ifs 论文"]?.samples == 1 && store.profiles["喝水"] == nil)
        let last = try #require(log.rows.last)
        #expect(last.outcome == .woke && last.verdict.signals == [SentinelSignal.untrackedContextSwitch.rawValue])
        #expect(last.verdict.reason.contains("写 IFS 论文") && last.verdict.scores?["started"] == 0.7)
        // 负样本回流
        let before = store.profiles["写 ifs 论文"]!.apps["Pages"]!
        await e.unlearn(title: "写 IFS 论文", start: now.addingTimeInterval(-10 * 60), end: now)
        #expect(store.profiles["写 ifs 论文"]!.apps["Pages"]! < before)
    }
}
#endif
