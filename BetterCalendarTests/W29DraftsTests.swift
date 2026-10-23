import Foundation
import Testing
@testable import BetterCalendar

/// W29：① 输入框草稿重启后还在（本机 UserDefaults，plist 类型，发出去才清）② 健康数据去重安全网（跨重读、跨设备）
/// ③ 回复前连发几句都送到（Claude Code 桥接逐条转交；内置智能体一阵合并成一轮），一条不丢。
/// 时间一律固定时刻派生；UserDefaults 一律独立 suite；文件一律临时目录。
@MainActor @Suite struct W29DraftsTests {
    final class Clock: @unchecked Sendable { var now: Date; init(_ d: Date) { now = d } }
    static let base = ISO8601DateFormatter().date(from: "2026-10-19T08:00:00Z")!

    func suite() -> UserDefaults { UserDefaults(suiteName: "bc-w29-" + UUID().uuidString)! }
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-w29-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: ① 草稿

    @Test func draftSurvivesNewStoreInstanceAndClearsOnlyWhenAsked() {
        let d = suite(), c = Clock(Self.base)
        let a = TextDraftStore(defaults: d, now: { c.now })
        a.save("明天上午排三小时写论", for: TextDraftKey.agentChat)
        a.save("改成 9 点", for: TextDraftKey.proposalReply(UUID(uuidString: "5FCC2D9D-62D6-4C96-8A18-1B7A0FA02336")!))
        // 「重启」= 新实例读同一份 defaults
        let b = TextDraftStore(defaults: d, now: { c.now })
        #expect(b.load(TextDraftKey.agentChat) == "明天上午排三小时写论")
        #expect(b.load(TextDraftKey.todaySay) == nil)                 // 各框互不串
        #expect(b.keys().count == 2)
        b.save("   \n", for: TextDraftKey.agentChat)                 // 清成空白 = 清掉
        #expect(b.load(TextDraftKey.agentChat) == nil && b.keys().count == 1)
        b.clear(TextDraftKey.proposalReply(UUID(uuidString: "5FCC2D9D-62D6-4C96-8A18-1B7A0FA02336")!))
        #expect(b.keys().isEmpty && d.object(forKey: TextDraftStore.defaultsKey) == nil)
    }

    @Test func draftsArePlistOnlyLocalAndExpire() throws {
        let d = suite(), c = Clock(Self.base)
        let s = TextDraftStore(defaults: d, now: { c.now })
        s.save("长期：准备 GRE", for: TextDraftKey.longtermSay)
        let raw = try #require(d.dictionary(forKey: TextDraftStore.defaultsKey))
        #expect(PropertyListSerialization.propertyList(raw, isValidFor: .binary))   // 第六根因：只放 plist 类型
        // 草稿不进 iCloud 设置同步（本机）
        #expect(!SettingsSync.syncedKeys.contains(TextDraftStore.defaultsKey))
        c.now = Self.base.addingTimeInterval(TextDraftStore.maxAge + 60)
        #expect(s.load(TextDraftKey.longtermSay) == nil)              // 30 天没动 = 丢掉
        s.save("新的", for: TextDraftKey.todaySay)                    // 下一次写顺手清掉过期的
        #expect(s.keys() == [TextDraftKey.todaySay])
    }

    @Test func restoredProposalReplyReopensOnceAndCountsOneBeginNoAbandon() async throws {
        let w10 = W10ApprovalUXTests()
        let p = w10.pair()
        let w21 = W21FeatureUsageTests()
        let usage = try w21.store(W21FeatureUsageTests.Clock())
        p.phone.usage = usage
        let drafts = TextDraftStore(defaults: suite(), now: { Self.base })
        let one = try #require(await p.mac.submit(w10.draft(title: "挪笔记")))
        await p.phone.refresh()
        #expect(!p.phone.resumeReplyingIfDrafted(one.id, drafts: drafts))     // 没草稿：不展开
        drafts.save("改成 9 点吧", for: TextDraftKey.proposalReply(one.id))
        #expect(p.phone.resumeReplyingIfDrafted(one.id, drafts: drafts))      // 「重启后卡片出现」：展开
        #expect(p.phone.replying.contains(one.id) && usage.isOpen(.proposalReply, key: one.id.uuidString))
        #expect(!p.phone.resumeReplyingIfDrafted(one.id, drafts: drafts))     // 同一张卡出现在两处：不会被第二次「出现」收起
        #expect(p.phone.replying.contains(one.id))
        #expect(usage.records().filter { $0.f == "proposal.reply" }.isEmpty)  // 还原不算没做完
        #expect(await p.phone.reply(one.id, text: "改成 9 点吧"))
        #expect(usage.records().filter { $0.f == "proposal.reply" }.map(\.e) == [.used])
        // 已不在等的提案：草稿还在也不展开
        p.phone.replying.remove(one.id)
        #expect(!p.phone.resumeReplyingIfDrafted(one.id, drafts: drafts))
    }

    // 智能体页 / 今天页「说一句」点发送时清草稿是安全的：这句话第一步就进持久化发件箱，失败留在对话里可重试、重启不丢——
    // 已由 AgentChatTests.failedSendStaysInOutboxVisibleAndRetries 覆盖。

    // MARK: ② 健康去重

    func iso(_ d: Date) -> String { ActivityCodec.iso(d) }
    func at(_ h: Double) -> Date { Self.base.addingTimeInterval(h * 3600) }

    func sleep(_ start: Date, _ end: Date, device: String = "iphone-1") -> ActivityEvent {
        PhoneActivityTransforms.sleepEvents([.init(start: start, end: end)], now: end.addingTimeInterval(7200), deviceId: device)[0]
    }

    func workout(uuid: String, _ start: Date, _ end: Date, device: String = "iphone-1") -> ActivityEvent {
        ActivityEvent(id: ActivityStableID.make("workout-" + uuid), at: start, kind: .other, source: .history, deviceId: device, platform: "iOS",
                      detail: ["signal": "workout", "activityType": "37", "end": iso(end), "minutes": String(Int(end.timeIntervalSince(start) / 60))])
    }

    @Test func rereadingSameHealthWindowIsIdempotent() async throws {
        let log = FileActivityLog(root: try tempDir())
        let night = sleep(at(-9), at(-1.5))
        let run = workout(uuid: "A1B2", at(-20), at(-19.5))
        for _ in 0..<3 {   // 每次回前台都回看 48 小时
            _ = try await log.appendNew([night, run])
        }
        let all = try await log.events(in: DateInterval(start: at(-48), end: at(1)))
        #expect(all.count == 2)
        #expect(try lineCount(log) == 2)                              // 日文件里也只有两行
    }

    @Test func sameSleepFromAnotherDeviceOrShiftedReadIsNotWrittenTwice() async throws {
        let log = FileActivityLog(root: try tempDir())
        let iphone = sleep(at(-9), at(-1.5))
        _ = try await log.appendNew([iphone])
        // 另一台设备（老版本 iPad / 换机后的新 iPhone）读到同一段：id 同内容 → 不写
        #expect(try await log.appendNew([sleep(at(-9), at(-1.5), device: "ipad-1")]).isEmpty)
        // 同一段睡眠的另一种合并（手表数据晚到，起点挪了 10 分钟、更短）→ 语义重复，不写
        #expect(try await log.appendNew([sleep(at(-8.8), at(-1.6))]).isEmpty)
        // 同一锻炼：HealthKit UUID 不同但类型 + 起止相同（两个来源各记了一份）→ 只留一条
        _ = try await log.appendNew([workout(uuid: "W-1", at(-20), at(-19.5))])
        #expect(try await log.appendNew([workout(uuid: "W-2", at(-20), at(-19.5), device: "iphone-2")]).isEmpty)
        // 读到了更完整的一段（更长）→ 写；读的时候只留最长那段
        let longer = sleep(at(-9.5), at(-1.5))
        #expect(try await log.appendNew([longer]).map(\.id) == [longer.id])
        let read = try await log.events(in: DateInterval(start: at(-48), end: at(1)))
        let sleeps = read.filter { $0.detail?["signal"] == "sleep" }
        #expect(sleeps.map(\.id) == [longer.id])
        #expect(read.filter { $0.detail?["signal"] == "workout" }.count == 1)
        // 再回填一遍（短的那段又被读到）：不会每次都再写一行
        let before = try lineCount(log)
        _ = try await log.appendNew([iphone, longer])
        #expect(try lineCount(log) == before)
        // 不相干的两晚不会被误合并
        _ = try await log.appendNew([sleep(at(-33), at(-25))])
        #expect(try await log.events(in: DateInterval(start: at(-48), end: at(1))).filter { $0.detail?["signal"] == "sleep" }.count == 2)
    }

    @Test func readTimeCleanCollapsesLegacyDuplicatesKeepsOthers() {
        let a = sleep(at(-9), at(-1.5)), b = sleep(at(-8.8), at(-1.6), device: "ipad-1")
        let w1 = workout(uuid: "X", at(-20), at(-19.5)), w2 = workout(uuid: "Y", at(-20), at(-19.5))
        let app = ActivityEvent(at: at(-2), kind: .appOpened, source: .shortcut, deviceId: "iphone-1", platform: "iOS", appName: "备忘录")
        let cleaned = ActivityHealthDedupe.clean([a, w1, app, b, w2, a, app])
        #expect(cleaned.map(\.id) == [a.id, w1.id, app.id])   // 顺序保持；非健康记录只按 id 去重
    }

    func lineCount(_ log: FileActivityLog) throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(at: log.files.root, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "jsonl" }
            .map { try Data(contentsOf: $0).split(separator: UInt8(ascii: "\n")).count }.reduce(0, +)
    }

    // MARK: ③ 回复前连发几句

    @Test func claudeCodeBridgeForwardsEveryPendingMessageAndOneReplyAnswersAll() async throws {
        let t = AgentChatTests()
        let root = try t.tempRoot(), io = AgentBridgeIO(root: root)
        try io.prepare()
        let cloud = InMemoryAgentChatTransport(), clock = AgentChatTests.Clock(Self.base)
        let phone = t.device("iphone", cloud, AgentChatTests.Bell(), clock), mac = t.device("mac", cloud, AgentChatTests.Bell(), clock)
        let bridge = AgentBridge(center: t.proposalCenter(), defaults: suite()) { ["schemaVersion": 1, "synthetic": true] }
        bridge.eventsEnabled = { false }
        bridge.chat = mac
        bridge.now = { clock.now }
        // 发送键在等回复时不锁：连发两句（中间智能体还没回）
        let first = try #require(await phone.send("把跑步挪到晚上"))
        clock.now = Self.base.addingTimeInterval(5)
        let second = try #require(await phone.send("再把阅读放到睡前"))
        await bridge.sync(io: io)
        let names = try t.events(root).map(\.lastPathComponent)
        let written = try t.events(root).filter { $0.lastPathComponent.contains("user_message") }
        #expect(written.count == 2, "\(names)")
        let ids = try Set(written.map { url -> String in
            let o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            return try #require((o["payload"] as? [String: Any])?["messageId"] as? String)
        })
        #expect(ids == [first.id.uuidString, second.id.uuidString])
        await bridge.sync(io: io)
        #expect(try t.events(root).filter { $0.lastPathComponent.contains("user_message") }.count == 2)   // 不重复转交
        await phone.refresh()
        #expect(phone.status(of: first) == .withAgent(overdue: false) && phone.status(of: second) == .withAgent(overdue: false))
        // 智能体一次回了两句（只 replyTo 后一句）：两句都算已回应
        clock.now = Self.base.addingTimeInterval(60)
        let rid = UUID()
        try io.writeAtomic(Data(#"{"schemaVersion":1,"id":"\#(rid)","text":"两件都挪好了。","replyTo":"\#(second.id)"}"#.utf8), to: "chat/\(rid).json")
        await bridge.sync(io: io)
        await phone.refresh()
        #expect(phone.status(of: first) == .replied && phone.status(of: second) == .replied)
    }

    @Test func builtinAgentCoalescesBurstIntoOneRoundAndAnswersAll() async throws {
        let w20 = W20BuiltinAgentTests()
        let e = w20.env()
        e.selection.select(.builtin)
        let first = try #require(await e.chat.send("把跑步挪到晚上"))
        await e.hub.pumpMessages()   // W35：Mac 先在 iCloud 认领再排队；测试里直接 pump（userMessageStored 是异步认领）
        e.clock.now = W20BuiltinAgentTests.sunday.addingTimeInterval(5)
        let second = try #require(await e.chat.send("再把阅读放到睡前"))
        await e.hub.pumpMessages()   // W35：Mac 先在 iCloud 认领再排队；测试里直接 pump（userMessageStored 是异步认领）
        #expect(e.runtime.queuedCount == 2)                            // 两句都排上了，没有覆盖
        e.model.script = [W20BuiltinAgentTests.FakeModel.call("reply_jason", ["text": "两件都挪好了", "replyTo": second.id.uuidString]),
                          W20BuiltinAgentTests.FakeModel.done()]
        await e.runtime.processPending()
        #expect(e.model.requests.filter { $0.count == 2 }.count == 1)   // 一阵合并成一轮（每轮从「系统 + 本轮事件」两条开始）
        let text = try #require(e.model.requests.first?[1].content)
        #expect(text.contains(first.id.uuidString) && text.contains(second.id.uuidString))
        #expect(e.chat.status(of: first) == .replied && e.chat.status(of: second) == .replied)
        #expect(e.runtime.queuedCount == 0)
    }

    @Test func builtinAgentFailureStillAnswersEveryWaitingMessage() async throws {
        let w20 = W20BuiltinAgentTests()
        let e = w20.env()
        e.selection.select(.builtin)
        let first = try #require(await e.chat.send("一"))
        await e.hub.pumpMessages()   // W35：Mac 先在 iCloud 认领再排队；测试里直接 pump（userMessageStored 是异步认领）
        let second = try #require(await e.chat.send("二"))
        await e.hub.pumpMessages()   // W35：Mac 先在 iCloud 认领再排队；测试里直接 pump（userMessageStored 是异步认领）
        e.model.error = DeepSeekError(kind: .network, message: "断网", hint: "稍后再说一次")
        await e.runtime.processPending()
        // 没能回：直说（不假装回了），两句都不会一直挂在「正在想」
        #expect(e.chat.messages.contains { $0.author == .agent && $0.text.contains("没能回复") })
        #expect(e.chat.status(of: first) == .replied && e.chat.status(of: second) == .replied)
    }
}
