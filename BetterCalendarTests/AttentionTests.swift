import Foundation
import Testing
@testable import BetterCalendar

/// SPEC §19 C2–C4：打扰规则由 App 强制执行；被拦下的消息仍保存且可见；反应被记录，静音生效。
@MainActor @Suite struct AttentionTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: h, minute: m))! }

    @Test func policyGatesByMasterSwitchMuteQuietHoursAndCaps() {
        var s = AttentionSettings()
        #expect(s.enabled && !s.capsOn)   // W8：从没设过 = 总开关开、频率上限关
        s.enabled = false
        #expect(AttentionPolicy.evaluate(s, at: at(14), recentDeliveries: []) == .suppress("智能体主动通知未开启"))
        s.enabled = true
        #expect(AttentionPolicy.evaluate(s, at: at(14), recentDeliveries: []) == .allow)
        #expect(AttentionPolicy.evaluate(s, at: at(23, 30), recentDeliveries: []) != .allow)   // 安静时段跨午夜
        #expect(AttentionPolicy.evaluate(s, at: at(7, 59), recentDeliveries: []) != .allow)
        #expect(AttentionPolicy.evaluate(s, at: at(8), recentDeliveries: []) == .allow)
        let two = [at(13, 20), at(13, 40)]
        #expect(AttentionPolicy.evaluate(s, at: at(14), recentDeliveries: two) == .allow)    // W8：上限默认关
        s.capsOn = true
        #expect(AttentionPolicy.evaluate(s, at: at(14), recentDeliveries: two) != .allow)    // 每小时上限 2
        #expect(AttentionPolicy.evaluate(s, at: at(14, 21), recentDeliveries: two) == .allow)
        s.mutedUntil = at(15)
        #expect(AttentionPolicy.evaluate(s, at: at(14), recentDeliveries: []) != .allow)
        #expect(AttentionPolicy.evaluate(s, at: at(15), recentDeliveries: []) == .allow)
    }

    @MainActor final class Bell: AgentMessageNotifying {
        var shown: [UUID] = [], withdrawn: [UUID] = []
        func show(_ message: AgentMessage) async { shown.append(message.id) }
        func withdraw(_ id: UUID) async { withdrawn.append(id) }
    }

    func center(_ transport: InMemoryAgentMessageTransport, _ bell: Bell, _ clock: @escaping () -> Date, enabled: Bool = true) -> AgentMessageCenter {
        let d = UserDefaults(suiteName: "bc-attention-" + UUID().uuidString)!
        let c = AgentMessageCenter(transport: transport, notifier: bell, ledger: MemoryOperationLedger(), deviceId: "mac", defaults: d, now: clock)
        c.settings.enabled = enabled
        c.settings.capsOn = true   // 这组测试验证上限本身（W8 起默认关）
        return c
    }

    @Test func deliveredMessageShowsOnceAndSuppressedIsKeptButSilent() async throws {
        let transport = InMemoryAgentMessageTransport(), bell = Bell()
        var now = at(14)
        let c = center(transport, bell, { now })
        let m1 = try #require(await c.receive(AgentMessageDraft(title: "下一步", body: "要不要先看一眼 N1 表格？", reason: "空档")))
        #expect(m1.delivery == .delivered && bell.shown == [m1.id])
        await c.refresh()
        #expect(bell.shown.count == 1)                       // 不重复弹
        now = at(14, 5)
        _ = await c.receive(AgentMessageDraft(title: "2", body: "b", reason: "r"))
        now = at(14, 10)
        let m3 = try #require(await c.receive(AgentMessageDraft(title: "3", body: "b", reason: "r")))
        #expect(m3.delivery == .suppressed && m3.suppressReason?.contains("每小时上限") == true)
        #expect(!bell.shown.contains(m3.id) && c.messages.contains { $0.id == m3.id })   // 拦下的仍可见
    }

    @Test func receiveIsIdempotentForSameAgentId() async throws {
        let transport = InMemoryAgentMessageTransport(), bell = Bell(), id = UUID()
        let c = center(transport, bell, { self.at(14) })
        _ = await c.receive(AgentMessageDraft(id: id, title: "t", body: "b", reason: "r"))
        _ = await c.receive(AgentMessageDraft(id: id, title: "t", body: "b", reason: "r"))
        #expect(c.messages.count == 1 && bell.shown.count == 1)
    }

    @Test func muteReactionWithdrawsAndSilencesForTwoHours() async throws {
        let transport = InMemoryAgentMessageTransport(), bell = Bell()
        var now = at(14)
        let c = center(transport, bell, { now })
        let m = try #require(await c.receive(AgentMessageDraft(title: "t", body: "b", reason: "r")))
        await c.react(m.id, .muted)
        #expect(bell.withdrawn.contains(m.id) && c.messages.first?.reaction == .muted)
        now = at(15)
        let later = try #require(await c.receive(AgentMessageDraft(title: "t2", body: "b", reason: "r")))
        #expect(later.delivery == .suppressed && later.suppressReason?.contains("静音") == true)
        #expect(c.ledger.records().contains { $0.event == "message.muted" && $0.actor == .user })
    }

    @Test func masterSwitchOffKeepsEverythingSilent() async throws {
        let transport = InMemoryAgentMessageTransport(), bell = Bell()
        let c = center(transport, bell, { self.at(14) }, enabled: false)
        let m = try #require(await c.receive(AgentMessageDraft(title: "t", body: "b", reason: "r")))
        #expect(m.delivery == .suppressed && bell.shown.isEmpty)
    }
}
