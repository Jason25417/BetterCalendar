//
//  W42ProactiveWakeTests.swift
//  BetterCalendarTests
//
//  W42（Jason 2026-10-24）：主动唤醒重做——哨兵叫醒了智能体必须发（不否决）；「没用」只由 Jason 点，反馈回哨兵：
//  同一件事当天不再叫醒、那类信号门槛升高、跨设备去重；「开始时间已过」源头去误报；只有在场设备判断。
//

import Foundation
import Testing
@testable import BetterCalendar

// MARK: 纯规则

@MainActor @Suite struct W42FeedbackRuleTests {
    let now: Date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_792_000_000))!

    func notice(_ minutesAgo: Double, reaction: AgentMessage.Reaction?, signals: [String], key: String?) -> SentinelRecentNotice {
        SentinelRecentNotice(at: now.addingTimeInterval(-minutesAgo * 60), title: "t", delivered: true, suppressReason: nil,
                             reaction: reaction?.rawValue, wakeSignals: signals, wakeSignature: key)
    }

    @Test func feedbackKeyIsSignalPlusSubject() {
        var f = SentinelFacts()
        f.overdueStart = .init(title: "写论文", minutesLate: 12)
        #expect(SentinelFeedback.key(signals: ["planned_start_passed"], facts: f) == "planned_start_passed|写论文")
        f.overdueStart = .init(title: "写论文", minutesLate: 30)   // 晚了多少分钟不影响键
        #expect(SentinelFeedback.key(signals: ["planned_start_passed"], facts: f) == "planned_start_passed|写论文")
        #expect(SentinelFeedback.key(signals: ["seems_finished"], facts: f) == "seems_finished|")
    }

    @Test func notUsefulRaisesOnlyThatSignalsThresholdForTwoWeeks() {
        let start = "planned_start_passed", done = "seems_finished"
        let notices = [notice(60, reaction: .notUseful, signals: [start], key: "a"),
                       notice(60 * 24 * 3, reaction: .notUseful, signals: [start], key: "b"),
                       notice(60 * 24 * 20, reaction: .notUseful, signals: [start], key: "c"),   // 超过 14 天：不算
                       notice(30, reaction: .acknowledged, signals: [done], key: "d")]
        #expect(abs(SentinelFeedback.threshold(base: 0.75, signals: [start], notices: notices, now: now) - 0.85) < 1e-9)
        #expect(SentinelFeedback.threshold(base: 0.75, signals: [done], notices: notices, now: now) == 0.75)
        #expect(SentinelFeedback.threshold(base: 0.75, signals: [start, done], notices: notices, now: now) == 0.75)   // 另一类还新鲜
        let many = (0..<10).map { notice(Double($0), reaction: .notUseful, signals: [start], key: "x") }
        #expect(SentinelFeedback.threshold(base: 0.75, signals: [start], notices: many, now: now) == SentinelFeedback.maxThreshold)
    }

    @Test func dismissedTodayAndCrossDeviceDedupe() {
        let today = [notice(90, reaction: .notUseful, signals: ["planned_start_passed"], key: "planned_start_passed|写论文")]
        #expect(SentinelFeedback.dismissedToday(key: "planned_start_passed|写论文", notices: today, now: now))
        #expect(!SentinelFeedback.dismissedToday(key: "planned_start_passed|跑步", notices: today, now: now))
        let yesterday = [notice(60 * 24, reaction: .notUseful, signals: [], key: "planned_start_passed|写论文")]
        #expect(!SentinelFeedback.dismissedToday(key: "planned_start_passed|写论文", notices: yesterday, now: now))
        // 另一台刚发过同一件事（没反应也算）→ 冷却期内不重复叫醒
        let sent = [notice(10, reaction: nil, signals: [], key: "k")]
        #expect(SentinelFeedback.notifiedRecently(key: "k", notices: sent, now: now, cooldownMinutes: 30))
        #expect(!SentinelFeedback.notifiedRecently(key: "k", notices: sent, now: now, cooldownMinutes: 5))
    }

    @Test func onlyThePresentDeviceJudges() {
        func p(_ id: String?, _ basis: PresenceBasis) -> Presence { Presence(deviceID: id, deviceLabel: id ?? "每台", kind: nil, basis: basis, why: "") }
        #expect(SentinelFeedback.presenceSkip(p("mac", .recentUse), myDeviceID: "mac", isMac: true) == nil)
        #expect(SentinelFeedback.presenceSkip(p("iphone", .timer), myDeviceID: "mac", isMac: true)?.contains("iphone") == true)
        #expect(SentinelFeedback.presenceSkip(p("iphone", .recentUse), myDeviceID: "iphone", isMac: false) == nil)
        // 判断不出你在哪台：Mac 判断、iPhone 不判断
        #expect(SentinelFeedback.presenceSkip(p("iphone", .carriedDefault), myDeviceID: "mac", isMac: true) == nil)
        #expect(SentinelFeedback.presenceSkip(p("iphone", .carriedDefault), myDeviceID: "iphone", isMac: false) != nil)
        #expect(SentinelFeedback.presenceSkip(p(nil, .everyDevice), myDeviceID: "iphone", isMac: false) != nil)
    }

    @Test func proposalsKnowWhichBlocksTheyTouch() {
        let a = UUID(), b = UUID()
        #expect(ProposalAction.moveBlock(id: a, start: now, end: nil, expectedRevision: nil).touchedBlockIDs == [a])
        #expect(ProposalAction.moveBlocks(moves: [.init(id: a, start: now, end: nil, expectedRevision: nil),
                                                  .init(id: b, start: now, end: nil, expectedRevision: nil)], isUndo: false).touchedBlockIDs == [a, b])
        #expect(ProposalAction.itemCreate(id: a, title: "x", note: "").touchedBlockIDs.isEmpty)
    }

    @Test func notUsefulIsANotificationAction() {
        let id = UUID()
        let route = LocalAgentMessageNotifier.route(userInfo: [LocalAgentMessageNotifier.userInfoKey: id.uuidString],
                                                    actionIdentifier: LocalAgentMessageNotifier.notUsefulAction)
        #expect(route?.id == id && route?.reaction == .notUseful)
    }
}

// MARK: 源头去误报

extension W14SentinelTests {
    @Test func plannedStartPassedSkipsMeetingsPendingProposalsAndWhatYouJustMentioned() {
        let now = Self.noon
        let base = context(now)
        #expect(SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: base)).facts.overdueStart?.title == "写论文")
        // 此刻在日历的会里
        var meeting = base
        meeting.calendar.items = [.init(title: "Megahit Sync", start: now.addingTimeInterval(-10 * 60), end: now.addingTimeInterval(20 * 60))]
        #expect(SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: meeting)).facts.overdueStart == nil)
        // 全天事件不算在开会
        var allDay = base
        allDay.calendar.items = [.init(title: "假日", start: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(6 * 3600), isAllDay: true)]
        #expect(SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: allDay)).facts.overdueStart != nil)
        // 这块有待批提案
        let id = base.today.items[0].id!
        #expect(SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: base, pendingBlockIDs: [id])).facts.overdueStart == nil)
        // 30 分钟内在对话里提过它；更早提过的不算
        #expect(SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: base,
                recentUserChat: [(at: now.addingTimeInterval(-5 * 60), text: "写论文先吃完饭再说")])).facts.overdueStart == nil)
        #expect(SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: base,
                recentUserChat: [(at: now.addingTimeInterval(-45 * 60), text: "写论文先吃完饭再说")])).facts.overdueStart != nil)
    }
}

// MARK: 智能体不否决

extension W20BuiltinAgentTests {
    func wakeEvent(_ e: Env) -> AgentEvent {
        AgentEvent(kind: "sentinel_wake", summary: "哨兵：计划的开始时间已过（把握 80%）",
                   payload: ["signals": ["planned_start_passed"], "signature": "planned_start_passed|写论文"], at: e.clock.now)
    }

    @Test func sentinelWakeIsAlwaysSentAndCarriesTheWakeKey() async throws {
        let e = env()
        e.selection.select(.builtin)
        // 第一次想静默结束 → 运行时追问一次 → 发了
        e.model.script = [FakeModel.done("看起来是误报，不打扰他"),
                          FakeModel.call("notify_jason", ["title": "写论文", "body": "要不要现在开个头？", "reason": "哨兵：开始时间已过"]),
                          FakeModel.done()]
        await e.runtime.run([wakeEvent(e)])
        let m = try #require(e.messages.messages.first)
        #expect(m.wakeSignals == ["planned_start_passed"] && m.wakeSignature == "planned_start_passed|写论文")
        #expect(e.model.requests.count == 3)   // 追问过一次
        #expect(e.model.requests[1].last?.content?.contains("必须用 notify_jason") == true)
    }

    @Test func sentinelWakeStillUnsentAfterTheNudgeIsReported() async throws {
        let e = env()
        e.selection.select(.builtin)
        e.model.script = [FakeModel.done(), FakeModel.done()]
        let mark = Date()
        await e.runtime.run([wakeEvent(e)])
        #expect(e.messages.messages.isEmpty)
        #expect(DevLog.shared.entries.contains { $0.source == "智能体上报" && $0.time >= mark && $0.message.hasPrefix("【哨兵叫醒没发】") })
    }

    @Test func otherEventsAreNotForcedToNotify() async throws {
        let e = env()
        e.selection.select(.builtin)
        e.model.script = [FakeModel.done()]
        await e.runtime.run([AgentEvent(kind: "block_finished", summary: "做完了", at: e.clock.now)])
        #expect(e.model.requests.count == 1 && e.messages.messages.isEmpty)
    }
}
