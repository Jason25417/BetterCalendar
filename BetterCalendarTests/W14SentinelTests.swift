#if os(macOS)
import Foundation
import Testing
@testable import BetterCalendar

/// SPEC §19 C1 W14 哨兵：摘要、节奏与防抖、安静时段、稳定性上限、叫醒事件、兜底可见、决策日志、心跳状态文件、结构化输出请求形状。
/// 全部注入时钟、内存活动记录与假 HTTP 层；**不真调 API**。
@MainActor @Suite struct W14SentinelTests {
    /// 固定的中午 12:00（本地），远离 4 点日界线与默认安静时段。
    static let noon: Date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_792_000_000))!

    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-sentinel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func defaults() -> UserDefaults { UserDefaults(suiteName: "bc-sentinel-" + UUID().uuidString)! }

    func noQuiet() -> AttentionSettings {
        var a = AttentionSettings(); a.quietStartHour = 0; a.quietEndHour = 0; return a
    }

    func context(_ now: Date) -> AgentContextInput {
        var c = AgentContextInput(now: now)
        c.today.items = [
            .init(title: "写论文", start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(40 * 60), id: UUID()),
            .init(title: "组会", start: now.addingTimeInterval(2 * 3600), end: now.addingTimeInterval(3 * 3600), isFixed: true, id: UUID()),
        ]
        c.todos.items = [.init(title: "N1 表格", deadline: now.addingTimeInterval(100 * 60), createdAt: now.addingTimeInterval(-86400 * 3))]
        return c
    }

    func activity(_ now: Date) -> [ActivityEvent] {
        let m: (Double) -> Date = { now.addingTimeInterval($0 * 60) }
        return [
            ActivityEvent(at: m(-50), kind: .appActivated, deviceId: "mac", platform: "macOS", appName: "Safari"),   // 窗口外：只用来知道起点状态
            ActivityEvent(at: m(-20), kind: .appActivated, deviceId: "mac", platform: "macOS", appName: "Xcode"),
            ActivityEvent(at: m(-12), kind: .browserPage, deviceId: "mac", platform: "macOS", url: "https://www.github.com/x"),
            ActivityEvent(at: m(-10), kind: .appActivated, deviceId: "mac", platform: "macOS", appName: "Safari"),
            ActivityEvent(at: m(-5), kind: .appActivated, deviceId: "mac", platform: "macOS", appName: "Xcode"),
            ActivityEvent(at: m(-3), kind: .appOpened, source: .shortcut, deviceId: "iphone", platform: "iOS", appName: "小红书"),
        ]
    }

    // MARK: 摘要

    @Test func digestFromInjectedClockAndMemoryActivityLog() async throws {
        let now = Self.noon
        let log = MemoryActivityLog(activity(now))
        let events = try await log.events(in: DateInterval(start: now.addingTimeInterval(-7200 - 1800), end: now))
        let input = SentinelDigestInput(now: now, context: context(now), activity: events, activityWindowMinutes: 30,
                                        recentWakes: [.init(at: now.addingTimeInterval(-600), kind: "block_finished", summary: "做完了「读论文」")],
                                        attention: noQuiet(), timeZone: TimeZone(identifier: "UTC")!)
        let d = SentinelDigestBuilder.build(input)
        #expect(d.text.contains("前台「Xcode」"))
        #expect(d.text.contains("Xcode 15 分") && d.text.contains("Safari 15 分"))   // 窗口起点前台是 Safari（-50 分钟起）
        #expect(d.text.contains("github.com 1"))
        #expect(d.text.contains("iPhone 打开：小红书 1 次"))
        #expect(d.text.contains("block_finished"))
        #expect(d.text.contains("「写论文」开始时间已过 20 分"))
        #expect(d.facts.overdueStart?.title == "写论文" && d.facts.overdueStart?.minutesLate == 20)
        #expect(d.facts.deadlineSoon?.title == "N1 表格" && d.facts.deadlineSoon?.minutesLeft == 100)
        #expect(d.hash.count == 64 && d.bytes == Data(d.text.utf8).count)
        #expect(SentinelDigestBuilder.build(input).hash == d.hash)   // 同输入同哈希
        // 正在计时「写论文」→ 不再算没开始；时间流逝不改变变化指纹，换前台才改变。
        var running = context(now)
        running.running.foreground = .init(title: "写论文", start: now.addingTimeInterval(-15 * 60))
        #expect(SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: running, activity: events)).facts.overdueStart == nil)
        let ctx = input.context
        let f1 = SentinelDigestBuilder.changeFingerprint(context: ctx, activity: events, now: now)
        let f2 = SentinelDigestBuilder.changeFingerprint(context: ctx, activity: events, now: now.addingTimeInterval(60))
        #expect(f1 == f2)
        let more = events + [ActivityEvent(at: now.addingTimeInterval(30), kind: .appActivated, deviceId: "mac", platform: "macOS", appName: "Notes")]
        #expect(SentinelDigestBuilder.changeFingerprint(context: ctx, activity: more, now: now.addingTimeInterval(60)) != f1)
    }

    // MARK: 节奏与防抖

    @Test func cadenceDebouncesChangesAndRunsIdleTicks() {
        var s = SentinelCadenceState(), set = SentinelSettings()
        let t0 = Self.noon
        let at: (Double) -> Date = { t0.addingTimeInterval($0) }
        SentinelCadence.observe(&s, fingerprint: "a", now: at(0))
        #expect(SentinelCadence.decide(s, settings: set, judge: .claude, now: at(30)) == .wait)          // 还没安静够 45 秒
        #expect(SentinelCadence.decide(s, settings: set, judge: .claude, now: at(45)) == .run(.change))
        SentinelCadence.ran(&s, at: at(45))
        SentinelCadence.observe(&s, fingerprint: "b", now: at(60))
        #expect(SentinelCadence.decide(s, settings: set, judge: .claude, now: at(150)) == .wait)         // 距上次判断不到 2 分钟
        #expect(SentinelCadence.decide(s, settings: set, judge: .claude, now: at(165)) == .run(.change))
        SentinelCadence.ran(&s, at: at(165))
        SentinelCadence.observe(&s, fingerprint: "b", now: at(200))                     // 没变化
        #expect(SentinelCadence.decide(s, settings: set, judge: .claude, now: at(700)) == .wait)
        #expect(SentinelCadence.decide(s, settings: set, judge: .claude, now: at(765)) == .run(.idle))   // 10 分钟例行
        // 连续变化：最多等 maxDebounce（5 分钟）。
        SentinelCadence.ran(&s, at: at(765))
        for i in 0..<12 { SentinelCadence.observe(&s, fingerprint: "c\(i)", now: at(900 + Double(i) * 30)) }
        #expect(SentinelCadence.decide(s, settings: set, judge: .claude, now: at(1190)) == .wait)
        #expect(SentinelCadence.decide(s, settings: set, judge: .claude, now: at(1200)) == .run(.change))
        set.debounceSeconds = 10
        #expect(SentinelCadence.decide(s, settings: set, judge: .claude, now: at(1240)) == .run(.change))
    }

    // MARK: 引擎

    func engine(judge: (any SentinelJudge)?, judges: [any SentinelJudge]? = nil, log: MemorySentinelDecisionLog? = nil, bridge: DirectorySentinelBridge,
                now: Date, clock: SentinelTestClock? = nil, attention: AttentionSettings? = nil) -> SentinelEngine {
        let ctx = context(now)
        let e = SentinelEngine(judges: judges ?? (judge.map { [$0] } ?? []), log: log ?? MemorySentinelDecisionLog(), bridge: bridge,
                               activity: MemoryActivityLog(activity(now)), defaults: defaults(),
                               now: clock.map { c in { c.t } } ?? { now }) { _ in ctx }
        let a = attention ?? noQuiet()
        e.attention = { a }
        return e
    }

    @Test func quietHoursSkipWithoutCallingModelAndStatusShowsIt() async throws {
        let root = try tempRoot(), bridge = DirectorySentinelBridge(root: root)
        let night = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Self.noon)!
        let judge = FakeJudge(wake: true)
        let e = engine(judge: judge, bridge: bridge, now: night, attention: AttentionSettings())   // 默认 23–8 安静时段
        await e.tick(); await e.runNow()
        #expect(judge.calls == 0 && e.today.isEmpty)
        #expect(e.gate.reason?.contains("安静时段") == true)
        let status = try readJSON(root.appendingPathComponent("runtime/sentinel.json"))
        #expect(status["state"] as? String == "skipped")
        #expect((status["gateReason"] as? String)?.contains("安静时段") == true)
        // 关掉总开关 = disabled；静音 = skipped。
        e.settings.enabled = false
        await e.tick()
        #expect(e.stateLabel == "disabled")
    }

    @Test func stabilityCapsHoldWakesAndStopSpendingVisibly() async throws {
        let now = Self.noon
        let log = MemorySentinelDecisionLog()
        for i in 0..<6 { try log.append(entry(at: now.addingTimeInterval(Double(-50 + i * 5) * 60), outcome: .woke, cost: 0.004)) }
        let judge = FakeJudge(wake: true)
        let e = engine(judge: judge, log: log, bridge: DirectorySentinelBridge(root: try tempRoot()), now: now)
        await e.runNow()
        // 每小时叫醒上限：照常判断（便宜），但不叫醒——攒着，原因可见
        #expect(judge.calls == 1 && log.rows.last?.outcome == .held)
        #expect(log.rows.last?.holdReason?.contains("稳定性上限") == true && e.pending?.reasons.count == 1)
        // 每日花费上限
        let log2 = MemorySentinelDecisionLog()
        try log2.append(entry(at: now.addingTimeInterval(-7200), outcome: .noWake, cost: 1.2))
        let judge2 = FakeJudge(wake: false)
        let e2 = engine(judge: judge2, log: log2, bridge: DirectorySentinelBridge(root: try tempRoot()), now: now)
        await e2.runNow()
        #expect(judge2.calls == 0 && e2.gate.reason?.contains("今天估算花费") == true && e2.stateLabel == "stopped")
        e2.settings.dailyBudgetUsd = 5
        await e2.runNow()
        #expect(judge2.calls == 1)
    }

    @Test func wakeVerdictWritesSentinelWakeEventAndDecisionLog() async throws {
        let root = try tempRoot(), bridge = DirectorySentinelBridge(root: root)
        let log = MemorySentinelDecisionLog()
        let judge = FakeJudge(wake: true)
        let e = engine(judge: judge, log: log, bridge: bridge, now: Self.noon)
        await e.runNow()
        #expect(judge.calls == 1 && bridge.contextWrites == 1)
        let events = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("events").path).filter { $0.hasSuffix(".json") }
        #expect(events.count == 1 && events[0].contains("sentinel_wake"))
        let event = try readJSON(root.appendingPathComponent("events/\(events[0])"))
        #expect(event["kind"] as? String == "sentinel_wake")
        let payload = event["payload"] as! [String: Any]
        #expect(payload["reason"] as? String == "计划块开始已过，没见开始")
        #expect(payload["urgency"] as? String == "normal")
        #expect(payload["signals"] as? [String] == ["planned_start_passed"])
        let ref = payload["digestRef"] as! String
        let digest = try readJSON(root.appendingPathComponent(ref))
        #expect((digest["text"] as? String)?.contains("写论文") == true && digest["hash"] as? String == payload["digestHash"] as? String)
        // 决策日志
        let row = try #require(log.rows.last)
        #expect(row.outcome == .woke && row.eventId == event["id"] as? String && row.judge == .jev)
        #expect(row.inputTokens == 3000 && row.outputTokens == 100 && abs(row.costUsd - 0.0035) < 1e-9)
        #expect(row.digestBytes > 0 && row.digestHash.count == 64 && row.error == nil && row.signature != nil)
        #expect(e.wakesToday.count == 1 && abs(e.costTodayUsd - 0.0035) < 1e-9)
        // 同一理由、情况没变 → 不再叫醒
        await e.runNow()
        #expect(log.rows.last?.outcome == .suppressedDuplicate)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("events").path).filter { $0.hasSuffix(".json") }.count == 1)
        // 不叫醒 = 只记日志
        judge.verdict.wake = false
        await e.runNow()
        #expect(log.rows.last?.outcome == .noWake && log.rows.count == 3)
    }

    @Test func decisionLogFilePersistsByMonthAndReadsBack() throws {
        let dir = try tempRoot()
        let log = FileSentinelDecisionLog(directory: dir)
        let now = Self.noon
        try log.append(entry(at: now.addingTimeInterval(-40 * 86400), outcome: .noWake, cost: 0.001))
        try log.append(entry(at: now.addingTimeInterval(-3600), outcome: .woke, cost: 0.004))
        try log.append(entry(at: now, outcome: .noWake, cost: 0.003))
        #expect(log.entries(since: now.addingTimeInterval(-7200)).map(\.outcome) == [.woke, .noWake])
        #expect(log.entries(since: now.addingTimeInterval(-50 * 86400)).count == 3)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("decisions-") }
        #expect(files.count >= 2)
        // 一行 = 一个完整 JSON，含评估要用的字段
        let line = try String(contentsOf: dir.appendingPathComponent(files.sorted().last!), encoding: .utf8).split(separator: "\n").last!
        let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        for key in ["at", "digestHash", "digestBytes", "verdict", "outcome", "latencyMs", "costUsd", "judge", "trigger"] { #expect(o[key] != nil, "缺 \(key)") }
        // 新引擎启动时读回最近 8 天
        let e = engine(judge: nil, log: MemorySentinelDecisionLog(), bridge: DirectorySentinelBridge(root: try tempRoot()), now: now)
        #expect(e.recent.isEmpty)
    }

    @Test func statusFileForHeartbeat() async throws {
        let root = try tempRoot(), bridge = DirectorySentinelBridge(root: root)
        let e = engine(judge: FakeJudge(wake: false), bridge: bridge, now: Self.noon)
        await e.tick()
        let s = try readJSON(root.appendingPathComponent("runtime/sentinel.json"))
        #expect(s["schemaVersion"] as? Int == 1 && s["app"] as? String == "BetterCalendar" && s["enabled"] as? Bool == true)
        #expect(s["state"] as? String == "ok" && s["lastTickAt"] is String && s["judge"] as? String == "jev")
        #expect((s["caps"] as? [String: Any])?["maxWakesPerHour"] as? Int == 6)
        #expect((s["attention"] as? [String: Any])?["quietStartHour"] as? Int == 0)
        #expect((s["today"] as? [String: Any])?["calls"] is Int)
        // 桥接没连：不调用、不写状态，原因可见
        bridge.isConnected = false
        await e.runNow()
        #expect(e.gate.reason?.contains("桥接") == true)
    }

    @Test func settingsFillMissingKeysWithDefaults() throws {
        let d = defaults()
        d.set(Data(#"{"enabled":false,"maxWakesPerHour":3}"#.utf8), forKey: SentinelSettings.key)
        let s = SentinelSettings.load(d)
        #expect(!s.enabled && s.maxWakesPerHour == 3 && s.minIntervalSeconds == 3 && s.llmMinIntervalSeconds == 120 && s.idleIntervalSeconds == 600 && s.preferredJudge == .jev && s.wakeThreshold == 0.75 && s.dailyBudgetUsd == 1)
        #expect(SentinelSettings.load(defaults()).enabled)   // 从没设过 = 实验期默认开
    }

    // MARK: 结构化输出请求形状（假 HTTP 层，不真调 API）

    @Test func claudeRequestUsesStructuredOutputsNotPrefill() async throws {
        var captured: URLRequest?
        let reply = #"{"wake":true,"reason":"截止临近","urgency":"high","signals":["deadline_near_no_progress","bogus"]}"#
        let response: [String: Any] = ["content": [["type": "text", "text": reply]], "stop_reason": "end_turn",
                                       "usage": ["input_tokens": 2800, "output_tokens": 60, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]]
        let claude = ClaudeSentinelJudge(apiKey: { "sk-test" }, cloudAllowed: { true }, transport: { req in
            captured = req
            return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let digest = SentinelDigestBuilder.build(SentinelDigestInput(now: Self.noon, context: context(Self.noon)))
        let j = try await claude.judge(digest)
        #expect(j.verdict.wake && j.verdict.urgency == .high && j.verdict.signals == ["deadline_near_no_progress", "other"])
        #expect(j.usage?.inputTokens == 2800 && j.model == "claude-haiku-4-5-20251001")
        let req = try #require(captured)
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages" && req.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "claude-haiku-4-5-20251001")
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 1 && messages[0]["role"] as? String == "user")   // 没有 assistant 预填
        #expect(!messages.contains { $0["role"] as? String == "assistant" })
        #expect((messages[0]["content"] as? String) == digest.text)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        let format = ((body["output_config"] as? [String: Any])?["format"]) as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        let schema = format?["schema"] as? [String: Any]
        #expect(schema?["additionalProperties"] as? Bool == false)
        #expect(Set(schema?["required"] as? [String] ?? []) == ["wake", "reason", "urgency", "signals"])
        let system = body["system"] as? [[String: Any]]
        #expect(system?.count == 1 && (system?[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect((system?[0]["text"] as? String) == ClaudeSentinelJudge.instructions)
    }

    // MARK: 决策模型（Jev / OpenAI，假 HTTP 层）

    func http(_ status: Int, _ object: [String: Any], capture: @escaping (URLRequest) -> Void = { _ in }) -> SentinelHTTP.Transport {
        let data = try! JSONSerialization.data(withJSONObject: object)
        nonisolated(unsafe) let cap = capture
        return { req in
            cap(req)
            return (data, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func jevRequestShapeAndAnswerParsing() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        let reply: [String: Any] = [
            "answers": ["wake": ["type": "noul", "noul": 0.91],
                        "category": ["type": "choice", "choice": "planned_start_passed", "probabilities": ["planned_start_passed": 0.8]],
                        "urgency": ["type": "score", "score": 1.2]],
            "model": "typesafe/jev-1.14-20261014", "usage": ["cost": 0.00002, "input_tokens": 480, "output_tokens": 70],
        ]
        let jev = JevSentinelJudge(apiKey: { "sk-or-test" }, transport: http(200, reply) { captured = $0 })
        let digest = SentinelDigestBuilder.build(SentinelDigestInput(now: Self.noon, context: context(Self.noon)))
        let j = try await jev.judge(digest)
        #expect(j.judge == .jev && j.model == "typesafe/jev-1.14-20261014")
        #expect(j.verdict.probability == 0.91 && j.verdict.category == "planned_start_passed" && j.verdict.signals == ["planned_start_passed"])
        #expect(j.verdict.urgency == .normal && j.verdict.reason.contains("计划的开始时间已过") && j.verdict.reason.contains("91%"))
        #expect(j.usage?.inputTokens == 480 && j.usage?.costUsd == 0.00002)
        let req = try #require(captured)
        #expect(req.url?.absoluteString == "https://openrouter.ai/api/alpha/decisions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "typesafe/jev-1.14" && body["state"] as? String == digest.text)
        let q = body["questions"] as! [String: Any]
        let wake = q["wake"] as! [String: Any], cat = q["category"] as! [String: Any], urg = q["urgency"] as! [String: Any]
        #expect(wake["type"] as? String == "noul" && (wake["criteria"] as? [String: String])?.keys.sorted() == ["false", "true"])
        #expect(cat["type"] as? String == "choice" && (cat["criteria"] as? [String: String])?.count == SentinelSignal.allCases.count)
        #expect(urg["type"] as? String == "score" && (urg["criteria"] as? [String])?.count == 3)
        // 没有 key：不可用（不发请求）；HTTP 402 → 带原因抛错
        #expect(JevSentinelJudge(apiKey: { nil }).unavailableReason()?.contains("OpenRouter") == true)
        let broke = JevSentinelJudge(apiKey: { "k" }, transport: http(402, ["error": ["message": "Insufficient credits"]]))
        await #expect(throws: (any Error).self) { try await broke.judge(digest) }
        do { _ = try await broke.judge(digest) } catch { #expect(error.localizedDescription.contains("402") && error.localizedDescription.contains("余额不足")) }
    }

    @Test func openAIDecisionsRequestShapeAndAnswerParsing() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        let reply: [String: Any] = ["answers": [
            ["type": "predicate", "name": "wake", "probability": 0.3],
            ["type": "choice", "name": "category", "choice": "other"],
            ["type": "score", "name": "urgency", "score": 0.1],
        ]]
        let oa = OpenAIDecisionsSentinelJudge(apiKey: { "sk-test" }, transport: http(200, reply) { captured = $0 })
        let digest = SentinelDigestBuilder.build(SentinelDigestInput(now: Self.noon, context: context(Self.noon)))
        let j = try await oa.judge(digest)
        #expect(j.judge == .openai && j.verdict.probability == 0.3 && j.verdict.signals.isEmpty && j.verdict.urgency == .low)
        #expect((j.usage?.inputTokens ?? 0) > 0 && (j.usage?.costUsd ?? 0) > 0)   // 没报用量：按字节估算
        let req = try #require(captured)
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/decisions")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "gpt-6-luna" && body["input"] as? String == digest.text)
        let qs = body["questions"] as! [[String: Any]]
        #expect(qs.map { $0["type"] as? String } == ["predicate", "choice", "score"])
        #expect(qs.map { $0["name"] as? String } == ["wake", "category", "urgency"])
        #expect((qs[1]["choices"] as? [[String: Any]])?.count == SentinelSignal.allCases.count && (qs[2]["levels"] as? [[String: Any]])?.count == 3)
        // 拒答 → 抛错（可见）
        let refused = OpenAIDecisionsSentinelJudge(apiKey: { "k" }, transport: http(200, ["answers": [["type": "refusal", "name": "wake"]]]))
        await #expect(throws: (any Error).self) { try await refused.judge(digest) }
    }

    @Test func probabilityThresholdDecidesWake() async throws {
        let judge = FakeJudge(wake: false)
        judge.verdict = SentinelDecisionQuestions.verdict(probability: 0.8, category: "seems_finished", urgencyScore: 0.2)
        let log = MemorySentinelDecisionLog()
        let e = engine(judge: judge, log: log, bridge: DirectorySentinelBridge(root: try tempRoot()), now: Self.noon)
        e.settings.wakeThreshold = 0.85   // 显式设门槛（默认值 10-19 起是 0.75）
        await e.runNow()
        #expect(log.rows.last?.outcome == .noWake && log.rows.last?.verdict.wake == false && log.rows.last?.verdict.probability == 0.8)
        e.settings.wakeThreshold = 0.75
        await e.runNow()
        #expect(log.rows.last?.outcome == .woke && log.rows.last?.verdict.wake == true)
    }

    // MARK: 原则 10：不设保险降级（Jason 2026-10-19）——只用选定判断器，不可用 / 失败就暂停并直说

    @Test func missingKeyPausesSentinelVisiblyInsteadOfFallingBack() async throws {
        let root = try tempRoot()
        let jev = JevSentinelJudge(apiKey: { nil })
        let backup = FakeJudge(wake: true, kind: .openai)   // 有可用的别家，也不许自动换过去
        let log = MemorySentinelDecisionLog()
        let e = engine(judge: nil, judges: [jev, backup], log: log, bridge: DirectorySentinelBridge(root: root), now: Self.noon)
        await e.runNow()
        #expect(backup.calls == 0 && log.rows.isEmpty)
        guard case let .stop(reason) = e.gate else { Issue.record("应暂停"); return }
        #expect(reason.contains("OpenRouter") && reason.contains("不会换别的判断器") && e.stateLabel == "stopped")
        let status = try readJSON(root.appendingPathComponent("runtime/sentinel.json"))
        #expect(status["state"] as? String == "stopped" && status["judge"] as? String == "jev")
    }

    @Test func callFailureSkipsThisTickWithoutSubstituteAndIsVisible() async throws {
        let root = try tempRoot()
        let jev = JevSentinelJudge(apiKey: { "k" }, transport: http(402, ["error": "no credits"]))
        let backup = FakeJudge(wake: true, kind: .openai)
        let log = MemorySentinelDecisionLog()
        let e = engine(judge: nil, judges: [jev, backup], log: log, bridge: DirectorySentinelBridge(root: root), now: Self.noon)
        await e.runNow()
        #expect(backup.calls == 0 && log.rows.isEmpty)
        #expect(e.consecutiveErrors == 1 && e.stateLabel == "error")
        #expect(e.lastError?.message.contains("402") == true && e.lastError?.message.contains("不换别的判断器") == true)
        // 手动切换到另一家（你的决定）才会用它
        e.settings.preferredJudge = .openai
        await e.runNow()
        #expect(backup.calls == 1 && log.rows.last?.judge == .openai && e.consecutiveErrors == 0)
    }

    // MARK: 防风暴

    @Test func burstOfWakeVerdictsYieldsOneWakeWithMergedReasons() async throws {
        let root = try tempRoot(), bridge = DirectorySentinelBridge(root: root)
        let clock = SentinelTestClock(Self.noon)
        let judge = FakeJudge(wake: true)
        let v: (String, SentinelUrgency) -> SentinelVerdict = { cat, u in
            var x = SentinelDecisionQuestions.verdict(probability: 0.95, category: cat, urgencyScore: u == .high ? 2 : 1); x.urgency = u; return x
        }
        judge.queue = [v("planned_start_passed", .normal), v("timer_over_plan", .normal), v("timer_over_plan", .normal),
                       v("deadline_near_no_progress", .high), v("seems_finished", .low)]
        let log = MemorySentinelDecisionLog()
        let e = engine(judge: judge, log: log, bridge: bridge, now: Self.noon, clock: clock)
        var busy = false
        e.agentBusy = { busy }
        func eventFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("events").path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        }
        // ① 第一次：直接叫醒
        await e.runNow()
        #expect(log.rows.last?.outcome == .woke && eventFiles().count == 1)
        // ② 几秒内智能体正在跑：不同理由 → 攒着；同一理由 → 只计数
        busy = true
        clock.t += 3; await e.runNow()
        #expect(log.rows.last?.outcome == .held && log.rows.last?.holdReason?.contains("正在处理") == true)
        clock.t += 3; await e.runNow()
        #expect(log.rows.last?.outcome == .merged && e.pending?.mergedCount == 1)
        clock.t += 3; await e.runNow()
        #expect(log.rows.last?.outcome == .held && e.pending?.reasons.count == 2)
        #expect(eventFiles().count == 1)   // 期间一个新叫醒都没写
        // ③ 智能体跑完，但离上次叫醒不到 5 分钟：继续攒
        busy = false
        clock.t += 30; await e.tick()
        #expect(e.pending != nil && e.pending?.holdReason?.contains("距上次叫醒") == true && eventFiles().count == 1)
        // ④ 5 分钟后：合并成一次叫醒发出，带全部理由，紧急程度取最高
        clock.t = Self.noon.addingTimeInterval(301); await e.tick()
        #expect(e.pending == nil)
        let files = eventFiles()
        #expect(files.count == 2)
        let event = try readJSON(root.appendingPathComponent("events/\(files.last!)"))
        let payload = event["payload"] as! [String: Any]
        #expect((payload["merged"] as? [[String: Any]])?.count == 2 && payload["urgency"] as? String == "high" && payload["trigger"] as? String == "flush")
        #expect((event["summary"] as? String)?.contains("合并 2 条理由") == true)
        let flush = try #require(log.rows.last)
        #expect(flush.trigger == .flush && flush.outcome == .woke && flush.mergedDecisionIds?.count == 2 && flush.mergedSignatures?.count == 2)
        #expect(e.wakesToday.count == 2 && e.judgmentsToday.count == 4)
        // ⑤ 冷却期内同一理由（截止临近）不再叫醒，即使条件都满足
        judge.queue = [v("deadline_near_no_progress", .high)]
        clock.t += 400; await e.runNow()
        #expect(log.rows.last?.outcome == .suppressedDuplicate && eventFiles().count == 2)
    }

    @Test func heldWakeExpiresWhenItWaitsTooLong() async throws {
        let root = try tempRoot()
        let clock = SentinelTestClock(Self.noon)
        let judge = FakeJudge(wake: true)
        let log = MemorySentinelDecisionLog()
        let e = engine(judge: judge, log: log, bridge: DirectorySentinelBridge(root: root), now: Self.noon, clock: clock)
        e.agentBusy = { true }
        await e.runNow()
        #expect(log.rows.last?.outcome == .held)
        clock.t += 21 * 60; await e.tick()
        #expect(e.pending == nil && log.rows.contains { $0.outcome == .expired && $0.trigger == .flush })
        let events = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("events").path)) ?? []
        #expect(!events.contains { $0.hasSuffix(".json") })
    }

    @Test func agentBusyReadsDispatcherStatusAndQueue() throws {
        let root = try tempRoot()
        #expect(!SentinelBridgeFiles.agentBusy(root: root))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try Data(#"{"state":"running"}"#.utf8).write(to: root.appendingPathComponent("runtime/status.json"))
        #expect(SentinelBridgeFiles.agentBusy(root: root))
        try Data(#"{"state":"idle"}"#.utf8).write(to: root.appendingPathComponent("runtime/status.json"))
        #expect(!SentinelBridgeFiles.agentBusy(root: root))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("events/x-block_finished.json"))
        #expect(SentinelBridgeFiles.agentBusy(root: root))
    }

    // MARK: 工具

    func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func entry(at: Date, outcome: SentinelOutcome, cost: Double) -> SentinelDecisionEntry {
        SentinelDecisionEntry(at: at, trigger: .idle, judge: .claude, model: "m", fallbackReason: nil, digestHash: String(repeating: "a", count: 64),
                              digestBytes: 100, verdict: .init(wake: outcome == .woke, reason: "r", urgency: .low, signals: []),
                              outcome: outcome, latencyMs: 10, inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0,
                              costUsd: cost, error: nil, eventId: nil)
    }
}

@MainActor final class FakeJudge: SentinelJudge {
    let kind: SentinelJudgeKind
    var verdict: SentinelVerdict
    /// 有值时依次给出（每次调用取下一个），用完后回到 verdict。
    var queue: [SentinelVerdict] = []
    var failure: Error?
    var calls = 0
    init(wake: Bool, kind: SentinelJudgeKind = .jev) {
        self.kind = kind
        verdict = .init(wake: wake, reason: wake ? "计划块开始已过，没见开始" : "一切照常", urgency: .normal,
                        signals: wake ? ["planned_start_passed"] : [])
    }
    func unavailableReason() -> String? { nil }
    func judge(_ digest: SentinelDigest) async throws -> SentinelJudgment {
        calls += 1
        if let failure { throw failure }
        let v = queue.isEmpty ? verdict : queue.removeFirst()
        return SentinelJudgment(verdict: v, judge: kind, model: "fake", usage: SentinelUsage(inputTokens: 3000, outputTokens: 100, costUsd: 0.0035))
    }
}

@MainActor final class SentinelTestClock { var t: Date; init(_ t: Date) { self.t = t } }
#endif
