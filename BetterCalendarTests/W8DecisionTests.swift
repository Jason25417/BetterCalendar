import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

/// SPEC §19 W8（Jason 2026-10-18 的决定）：一次挪多块 + 整组撤销；开始计时带回溯起点、开始不提供撤销；
/// 活动预报不再被暂停反复拉长。共用 ProposalActionTests 的两台「设备」+ 内存数据 + 注入时钟。
extension ProposalActionTests {

    // MARK: 一次挪多块（moveBlocks）

    func group(_ moves: [(UUID, Date, Date?)]) -> ProposalAction {
        .moveBlocks(moves: moves.map { ProposalBlockMove(id: $0.0, start: $0.1, end: $0.2, expectedRevision: nil) }, isUndo: false)
    }

    func blocks(_ r: Rig) throws -> [UUID: ScheduledBlock] {
        Dictionary(uniqueKeysWithValues: try r.plans.plannedBlocks(on: Calendar.current.startOfDay(for: r.clock.now)).map { ($0.id, $0) })
    }

    @Test func moveBlocksPushesAffectedBlockAlongShowsEveryChangeAndUndoesAsGroup() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        // 「整理笔记」挪到 18:00 会撞「跑步」→ 智能体把「跑步」一起顺延到 19:00（参照 reflow）
        let p = try await approve(r, group([(ids.flex, at(18, 0, c), nil), (ids.other, at(19, 0, c), nil)]))
        #expect(p.state == .applied && p.action.kind == "moveBlocks")
        #expect(p.changes.contains(ProposalChange(field: "「整理笔记」时间", before: "11:00–12:00", after: "18:00–19:00")))
        #expect(p.changes.contains(ProposalChange(field: "「跑步」时间", before: "18:00–19:00", after: "19:00–20:00")))
        #expect(p.notificationBody.contains("一起挪动 2 块"))
        var now = try blocks(r)
        #expect(now[ids.flex]?.start == at(18, 0, c) && now[ids.other]?.start == at(19, 0, c) && now[ids.other]?.end == at(20, 0, c))
        #expect(p.undoHint?.contains("整组挪回") == true && r.phone.canUndo(p))
        // 整组撤销（另一台设备发起，来源 = 你）
        #expect(await r.phone.undo(p.id))
        now = try blocks(r)
        #expect(now[ids.flex]?.start == at(11, 0, c) && now[ids.other]?.start == at(18, 0, c))
        let undone = try #require(r.ledger.values.last { $0.event == "undone" })
        #expect(undone.actor == .user && undone.detail.contains("整组挪回 2 块"))
    }

    @Test func moveBlocksValidatesTheFinalLayoutAsAWhole() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        func reason(_ action: ProposalAction) async -> String? {
            r.mac.clearError()
            _ = await r.mac.submit(draft(action))
            return r.mac.lastError
        }
        // 只挪一块撞上别的块：拒收，并提示把它一起放进提案
        #expect(await reason(.moveBlock(id: ids.flex, start: at(18, 0, c), end: nil, expectedRevision: nil))?.contains("要连带挪「跑步」") == true)
        // 同组挪完互相重叠
        #expect(await reason(group([(ids.flex, at(18, 0, c), nil), (ids.other, at(18, 30, c), nil)]))?.contains("挪完会互相重叠") == true)
        // 撞固定安排 / 想挪固定安排 / 越截止 / 重复 / 不变的块
        #expect(await reason(group([(ids.flex, at(14, 0, c), nil), (ids.other, at(20, 0, c), nil)]))?.contains("与固定安排「组会」") == true)
        #expect(await reason(group([(ids.fixed, at(20, 0, c), nil), (ids.other, at(21, 0, c), nil)]))?.contains("固定安排，按规则不挪") == true)
        #expect(await reason(group([(ids.ddl, at(16, 30, c), nil), (ids.other, at(20, 0, c), nil)]))?.contains("越过截止时间 17:00") == true)
        #expect(await reason(group([(ids.flex, at(20, 0, c), nil), (ids.flex, at(21, 0, c), nil)]))?.contains("不止一次") == true)
        // 全组都不变 → 无需挪动（10-22 起：组里只是顺手列了不变的块 → 跳过它，见 AgentRunFixTests）
        #expect(await reason(group([(ids.flex, at(11, 0, c), nil), (ids.other, at(18, 0, c), nil)]))?.contains("无需挪动") == true)
        // 「整组挪回」只用于撤销，智能体不能直接提
        #expect(await reason(.moveBlocks(moves: [ProposalBlockMove(id: ids.flex, start: at(20, 0, c), end: nil, expectedRevision: nil)], isUndo: true))?
            .contains("只用于撤销") == true)
        // 正在计时的块不挪
        r.progress.activePrediction = ActivePrediction(id: ids.other, start: at(10, 0, c), end: at(11, 0, c))
        #expect(await reason(group([(ids.other, at(20, 0, c), nil), (ids.flex, at(21, 0, c), nil)]))?.contains("正在计时") == true)
        r.progress.activePrediction = nil
        #expect(r.mac.proposals.isEmpty)   // 规则不通过的一律不进入审批
        // 对调两块：单看每一步会撞，但最终布局不重叠 → 通过
        let swap = try await approve(r, group([(ids.flex, at(18, 0, c), nil), (ids.other, at(11, 0, c), nil)]))
        #expect(swap.state == .applied)
        let now = try blocks(r)
        #expect(now[ids.flex]?.start == at(18, 0, c) && now[ids.other]?.start == at(11, 0, c))
    }

    @Test func moveBlocksUndoRefusedWhenAnyBlockChangedAndWholeGroupStays() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        let p = try await approve(r, group([(ids.flex, at(18, 0, c), nil), (ids.other, at(19, 0, c), nil)]))
        try r.plans.updatePlanned(id: ids.other, start: at(20, 0, c), end: at(21, 0, c), title: "跑步")   // 之后你又手动拖了「跑步」
        #expect(await r.mac.undo(p.id) == false)
        #expect(r.mac.lastError?.contains("被改过") == true && r.mac.lastError?.contains("整组") == true)
        let now = try blocks(r)
        #expect(now[ids.flex]?.start == at(18, 0, c) && now[ids.other]?.start == at(20, 0, c))   // 一块都没动
        #expect(r.ledger.values.contains { $0.event == "undo.failed" && $0.proposalId == p.id })
    }

    @Test func moveBlocksExecutionConflictWritesNothing() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        let p = try #require(await r.mac.submit(draft(group([(ids.flex, at(18, 0, c), nil), (ids.other, at(19, 0, c), nil)]), target: "mac")))
        try r.plans.updatePlanned(id: ids.other, start: at(20, 0, c), end: at(21, 0, c), title: "跑步")   // 审批前你先拖了一块
        await r.phone.decide(p.id, .approve); await r.mac.refresh()
        let failed = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(failed.state == .failed && failed.resultNote?.contains("被改过") == true)
        #expect(try blocks(r)[ids.flex]?.start == at(11, 0, c))   // 整组不写
    }

    @Test func undoRestoresOriginalLayoutEvenIfItOverlappedOrIsNowPast() async throws {
        let r = try rig()
        let c = r.clock
        let a = ScheduledBlock(title: "读论文", start: at(11, 0, c), end: at(12, 0, c))
        let b = ScheduledBlock(title: "改代码", start: at(11, 30, c), end: at(12, 30, c))   // 原本就和「读论文」叠着
        try r.plans.replacePlanned([a, b], on: Calendar.current.startOfDay(for: c.now))
        let p = try await approve(r, group([(a.id, at(16, 0, c), nil), (b.id, at(17, 0, c), nil)]))
        #expect(p.state == .applied)
        c.now = at(11, 15, c)   // 时间过了 11:00
        #expect(await r.mac.undo(p.id))   // 撤销 = 原样恢复：允许挪回已过去的起点与组内原有的重叠
        let now = try blocks(r)
        #expect(now[a.id]?.start == at(11, 0, c) && now[b.id]?.start == at(11, 30, c))
    }

    @Test func bridgeParsesMoveBlocksStrictly() throws {
        let a = UUID(), b = UUID()
        func file(_ action: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": UUID().uuidString, "title": "t", "reason": "r", "action": action])
        }
        let ok = try AgentBridgeIO.draft(from: file(["kind": "moveBlocks", "moves": [
            ["blockId": a.uuidString, "start": "2026-10-18T18:00:00+08:00", "expectedRevision": "r1"],
            ["blockId": b.uuidString, "start": "2026-10-18T19:00:00+08:00", "end": "2026-10-18T20:00:00+08:00"]]]))
        guard case let .moveBlocks(moves, isUndo) = ok.action else { Issue.record("应解析为 moveBlocks"); return }
        #expect(!isUndo && moves.count == 2 && moves[0].id == a && moves[0].expectedRevision == "r1" && moves[0].end == nil)
        #expect(moves[1].end.map { $0.timeIntervalSince(moves[1].start) } == 3600 && !ok.experiment)
        let bad: [[String: Any]] = [
            ["kind": "moveBlocks", "moves": []],
            ["kind": "moveBlocks"],
            ["kind": "moveBlocks", "moves": [["blockId": a.uuidString]]],                                          // 缺 start
            ["kind": "moveBlocks", "moves": [["blockId": a.uuidString, "start": "2026-10-18T18:00:00+08:00", "x": 1]]],
            ["kind": "moveBlocks", "moves": [["kind": "moveBlock", "blockId": a.uuidString, "start": "2026-10-18T18:00:00+08:00"]]],
            ["kind": "moveBlocks", "moves": [["blockId": a.uuidString, "start": "18:00"]]],
            ["kind": "moveBlocks", "moves": [["blockId": a.uuidString, "start": "2026-10-18T18:00:00+08:00"]], "isUndo": true],
            ["kind": "moveBlocks", "moves": Array(repeating: ["blockId": a.uuidString, "start": "2026-10-18T18:00:00+08:00"], count: PlanMoveRules.maxGroup + 1)],   // W10：只剩技术防失控上限
        ]
        for action in bad { #expect(throws: (any Error).self) { try AgentBridgeIO.draft(from: file(action)) } }
        do { _ = try AgentBridgeIO.draft(from: file(bad[2])); Issue.record("应拒收") } catch {
            #expect(error.localizedDescription.contains("moves[0]"))   // 指出是哪一项
        }
        // 撤销专用种类不对智能体开放
        #expect(throws: (any Error).self) { try AgentBridgeIO.draft(from: file(["kind": "itemDiscard", "itemId": a.uuidString])) }
    }

    @Test func moveBlocksActionRoundTripsThroughCodable() throws {
        let clock = Clock()
        let action = ProposalAction.moveBlocks(moves: [ProposalBlockMove(id: UUID(), start: clock.now, end: nil, expectedRevision: "r")], isUndo: true)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(ProposalAction.self, from: data) == action)
    }

    // MARK: 开始计时：回溯起点（像 Apple Watch 检测到运动），开始不提供撤销

    @Test func backdatedStartCountsFromInferredMomentWhenApprovedLater() async throws {
        let r = try rig()
        let c = r.clock
        let p = try #require(await r.mac.submit(draft(.timer(command: .start, blockId: nil, title: "回邮件", expectedRevision: nil,
                                                             startAt: at(9, 40, c)))))
        #expect(p.changes.contains { $0.after?.contains("从 09:40 开始计") == true })
        #expect(p.notificationBody.contains("从 09:40 开始计：什么时候批准都从这个时刻算"))
        #expect(r.timer.calls.isEmpty)   // 批准前什么都不写
        c.now = at(10, 8, c)             // 8 分钟后才批准
        await r.phone.decide(p.id, .approve); await r.mac.refresh()
        let done = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(done.state == .applied && done.resultNote?.contains("从 09:40 开始计") == true)
        #expect(r.timer.startedAts == [at(9, 40, c)] && r.timer.state.startedAt == at(9, 40, c))
        #expect(!r.mac.canUndo(done) && r.mac.undoBlockedReason(done) == "要结束计时请另提「结束计时」")
    }

    @Test func backdatedStartRulesGiveClearReasons() async throws {
        let r = try rig()
        let c = r.clock
        func reason(_ startAt: Date) async -> String? {
            r.mac.clearError()
            _ = await r.mac.submit(draft(.timer(command: .start, blockId: nil, title: "写报告", expectedRevision: nil, startAt: startAt)))
            return r.mac.lastError
        }
        #expect(await reason(at(10, 5, c))?.contains("在未来") == true)
        #expect(await reason(at(3, 50, c))?.contains("不在今天") == true)      // W10：不再限回溯时长，只守「在今天（逻辑日）」
        r.timer.busy = [ProposalBusySpan(title: "开会", start: at(9, 30, c), end: at(9, 50, c))]
        #expect(await reason(at(9, 40, c))?.contains("和已记下的「开会」") == true)
        r.timer.state = ProposalTimerState(phase: .running, title: "别的事", startedAt: at(9, 55, c))
        #expect(await reason(at(9, 55, c))?.contains("正在计时「别的事」") == true)
        #expect(r.mac.proposals.isEmpty)
        // 只有开始能带回溯起点
        _ = await r.mac.submit(draft(.timer(command: .stop, blockId: nil, title: nil, expectedRevision: nil, startAt: at(9, 0, c))))
        #expect(r.mac.lastError?.contains("只有开始计时") == true)
        // 紧贴着此刻（不到 1 分钟）= 从批准那刻起算，不算回溯
        r.timer.state = .idle
        let near = try #require(await r.mac.submit(draft(.timer(command: .start, blockId: nil, title: "写报告", expectedRevision: nil,
                                                                startAt: c.now.addingTimeInterval(-20)))))
        guard case let .timer(_, _, _, _, startAt) = near.action else { Issue.record("应为计时"); return }
        #expect(startAt == nil)
        // 起点放在已记下的实际之后：通过
        r.timer.busy = [ProposalBusySpan(title: "开会", start: at(9, 30, c), end: at(9, 50, c))]
        #expect(await r.mac.submit(draft(.timer(command: .start, blockId: nil, title: "写报告", expectedRevision: nil, startAt: at(9, 50, c)))) != nil)
    }

    @Test func declinedOrConflictingBackdatedStartRecordsNothing() async throws {
        let r = try rig()
        let c = r.clock
        let declined = try #require(await r.mac.submit(draft(.timer(command: .start, blockId: nil, title: "回邮件", expectedRevision: nil,
                                                                    startAt: at(9, 40, c)))))
        await r.phone.decide(declined.id, .decline); await r.mac.refresh()
        #expect(r.timer.calls.isEmpty)   // 拒绝 = 就像没发生
        // 审批期间你记下了一段和回溯起点重叠的实际 → 执行时再查一遍，拒绝执行
        let p = try #require(await r.mac.submit(draft(.timer(command: .start, blockId: nil, title: "回邮件", expectedRevision: nil,
                                                             startAt: at(9, 40, c)), target: "mac")))
        r.timer.busy = [ProposalBusySpan(title: "顺手打的电话", start: at(9, 45, c), end: at(9, 55, c))]
        await r.phone.decide(p.id, .approve); await r.mac.refresh()
        let failed = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(failed.state == .failed && failed.resultNote?.contains("重叠") == true && r.timer.calls.isEmpty)
    }

    @Test func bridgeParsesStartedAtOnlyForStart() throws {
        func file(_ action: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": UUID().uuidString, "title": "t", "reason": "r", "action": action])
        }
        let start = try AgentBridgeIO.draft(from: file(["kind": "timer", "command": "start", "title": "回邮件", "startedAt": "2026-10-18T09:40:00+08:00"]))
        guard case let .timer(command, blockId, title, revision, startAt) = start.action else { Issue.record("应为计时"); return }
        #expect(command == .start && blockId == nil && title == "回邮件" && revision == nil)
        #expect(startAt == Date(timeIntervalSince1970: 1792287600))
        #expect(throws: (any Error).self) { try AgentBridgeIO.draft(from: file(["kind": "timer", "command": "stop", "startedAt": "2026-10-18T09:40:00+08:00"])) }
        #expect(throws: (any Error).self) { try AgentBridgeIO.draft(from: file(["kind": "timer", "command": "start", "title": "x", "startedAt": "09:40"])) }
    }

    @Test func oldTimerPayloadWithoutStartAtStillDecodes() throws {
        let old = #"{"timer":{"command":"start","title":"写报告"}}"#
        let action = try JSONDecoder().decode(ProposalAction.self, from: Data(old.utf8))
        #expect(action == .timer(command: .start, blockId: nil, title: "写报告", expectedRevision: nil, startAt: nil))
    }

    @Test func executionLayerStartsLocalAndICloudTimersFromBackdatedMoment() async throws {
        let r = try rig()
        let execution = ExecutionViewModel(calendarStore: FakeCalendarStore(),
                                           reschedule: RescheduleService(planStore: r.plans, planner: NaivePlanningEngine()),
                                           planStore: r.plans, reminderStore: FakeReminderStore(),
                                           liveActivity: NoLiveActivity(), persistsRunState: false)
        let back = Date().addingTimeInterval(-600)
        try await execution.proposalStartTimer(blockId: nil, title: "回邮件", at: back)
        #expect(execution.active?.start == back && execution.currentElapsed >= 599)
        let spans = await execution.proposalBusySpans()
        #expect(spans.contains { $0.title == "回邮件" && $0.start == back })
        await execution.waitForPreview()

        // iCloud 共享计时：开始命令的 occurredAt 就是回溯起点
        final class T { var t = Date(timeIntervalSince1970: 1_790_000_000) }
        let clock = T(), cloud = MemorySharedTimerCloud()
        let tasks = BridgeTaskViewModel(service: ICloudSharedTimerService(store: MemorySharedTimerStore(cloud: cloud), deviceId: "mac", now: { clock.t }),
                                        persistence: BridgeTaskMemoryPersistence(), enabled: { true }, now: { clock.t },
                                        backend: .icloud, activePoll: 10, idlePoll: 30)
        await tasks.refresh()
        await tasks.start(title: "回邮件", startedAt: clock.t.addingTimeInterval(-600))
        #expect(tasks.sessions.first?.startedAt == clock.t.addingTimeInterval(-600))
        #expect((tasks.sessions.first.map { tasks.elapsed($0) } ?? 0) >= 599)
    }

    // MARK: 活动预报不再被暂停反复拉长（W7 发现，Jason 批准修）

    @Test func activePredictionDoesNotGrowWhenCoordinatorWritesPredictionBack() async throws {
        let r = try rig()
        let now0 = Date()
        let label = DayContext.logicalStartOfDay(now0)
        // 起点不早于今天的日界线（label 是日历日零点，不是 4 点日界线；4 点后 10 分钟内跑也不会落到前一个逻辑日）
        let start = max(PinSchedule.dayBoundary(atOrBefore: now0).addingTimeInterval(60), now0.addingTimeInterval(-600))
        let block = ScheduledBlock(title: "写报告", start: start, end: start.addingTimeInterval(3600))
        try r.plans.replacePlanned([block], on: label)
        let execution = ExecutionViewModel(calendarStore: FakeCalendarStore(),
                                           reschedule: RescheduleService(planStore: r.plans, planner: NaivePlanningEngine()),
                                           planStore: r.plans, reminderStore: FakeReminderStore(),
                                           liveActivity: NoLiveActivity(), persistsRunState: false)
        await execution.loadToday()
        let item = try #require(execution.planned.first { $0.id == block.id })
        await execution.startBlock(item)
        await execution.toggleBreak()   // 暂停中：已投入冻结
        for _ in 0..<3 {
            let prediction = try #require(execution.activePrediction)
            // 时间线协调器把预测结束写回计划块那一行（影子期行为）→ 执行层重读
            try r.plans.updatePlanned(id: block.id, start: block.start, end: prediction.end, title: block.title)
            await execution.loadToday()
        }
        let last = try #require(execution.activePrediction)
        #expect(last.end.timeIntervalSince(Date()) <= 3600 + 5)   // 仍是「计划 1 小时 − 已投入」，不会每轮再加
        #expect(execution.activePlannedDuration == 3600)
        await execution.waitForPreview()
    }
}

// MARK: - 默认值只作用于从没设过的键 / 设置同步白名单 / 智能体额度监控

@MainActor @Suite struct W8SettingsTests {
    func suite() -> UserDefaults { UserDefaults(suiteName: "bc-w8-" + UUID().uuidString)! }

    @Test func experimentDefaultsOnlyApplyToNeverSetKeys() {
        let d = suite()
        #expect(EveningReviewSettings.enabled(d) && EveningReviewSettings.minute(d) == 21 * 60 + 30)
        #expect(AgentEventSettings.enabled(in: d))
        #expect(SharedTimerSettings.requested(d))
        // 读默认值不写回（不制造「用户设过」的假象，也不会被设置同步推出去）
        for key in [EveningReviewSettings.enabledKey, AgentEventSettings.key, SharedTimerSettings.key] { #expect(d.object(forKey: key) == nil) }
        // 手动关过的保留
        d.set(false, forKey: EveningReviewSettings.enabledKey)
        d.set(false, forKey: AgentEventSettings.key)
        SharedTimerSettings.setRequested(false, d)
        #expect(!EveningReviewSettings.enabled(d) && !AgentEventSettings.enabled(in: d) && !SharedTimerSettings.requested(d))
        // 启动闸门照旧：默认开但旧通道还有进行中计时 → 本次仍用旧通道
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let running = BridgeTaskSession(id: "task_x", title: "旧计时", status: .running, startedAt: at, activeSince: at,
                                        elapsedMs: 0, updatedAt: at, revision: 1, provenance: "user")
        let file = BridgeTaskLocalFile(pending: [], state: BridgeTaskState(schemaVersion: 1, authority: "bettercalendar", readAt: at, sessions: [running], hasMore: false))
        #expect(SharedTimerSettings.launchDecision(requested: SharedTimerSettings.requested(suite()), legacy: { file }).backend == .stateBridge)
    }

    @Test func attentionDefaultsOnWithoutCapsButKeepsSavedChoice() throws {
        let d = suite()
        let fresh = AttentionSettings.load(d)
        #expect(fresh.enabled && !fresh.capsOn && fresh.quietStartHour == 23 && fresh.quietEndHour == 8)
        // 旧版本存的整份设置（没有 capsEnabled 字段、总开关关）：总开关保留关，上限按新默认关
        let old = #"{"enabled":false,"maxPerHour":3,"maxPerDay":10,"quietStartHour":22,"quietEndHour":7}"#
        d.set(Data(old.utf8), forKey: AttentionSettings.key)
        let kept = AttentionSettings.load(d)
        #expect(!kept.enabled && !kept.capsOn && kept.maxPerHour == 3 && kept.quietStartHour == 22)
        // 打开上限后按数字限；安静时段与静音不受上限开关影响
        var s = kept; s.enabled = true
        let cal = Calendar.current
        let two = cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
        let recent = [two.addingTimeInterval(-600), two.addingTimeInterval(-300), two.addingTimeInterval(-60)]
        #expect(AttentionPolicy.evaluate(s, at: two, recentDeliveries: recent) == .allow)
        s.capsOn = true
        #expect(AttentionPolicy.evaluate(s, at: two, recentDeliveries: recent) != .allow)
        s.capsOn = false; s.mutedUntil = two.addingTimeInterval(60)
        #expect(AttentionPolicy.evaluate(s, at: two, recentDeliveries: []) != .allow)
        s.save(d)
        #expect(AttentionSettings.load(d).capsEnabled == false)
    }

    actor FakePush: ProposalAlertPushing {
        var on = false
        var sets: [Bool] = []
        var failRead = false, failSet = false
        func configure(on: Bool = false, failRead: Bool = false, failSet: Bool = false) { self.on = on; self.failRead = failRead; self.failSet = failSet }
        func isAlertPushEnabled() async throws -> Bool { if failRead { throw URLError(.notConnectedToInternet) }; return on }
        func setAlertPush(enabled: Bool) async throws {
            sets.append(enabled)
            if failSet { throw URLError(.badServerResponse) }
            on = enabled
        }
    }

    @Test func alertPushAutoEnablesUnlessUserTurnedItOff() async {
        // 从没手动关过 + 云端没开 → 启动时自动打开（不写「手动关过」记号）
        let push = FakePush(), d = suite()
        let control = ProposalAlertPushControl(store: push, defaults: d)
        await control.autoEnableIfNeverDisabled()
        #expect(control.enabled && control.lastError == nil && d.object(forKey: ProposalAlertPushControl.userDisabledKey) == nil)
        var sets = await push.sets
        #expect(sets == [true])
        // 云端已经开着 → 什么都不做
        await control.autoEnableIfNeverDisabled()
        sets = await push.sets
        #expect(sets == [true])
        // 你在面板上手动关掉 → 记号写下，之后启动不再自动打开
        await control.set(false)
        #expect(d.bool(forKey: ProposalAlertPushControl.userDisabledKey))
        await control.autoEnableIfNeverDisabled()
        sets = await push.sets
        #expect(sets == [true, false] && !control.enabled)
        // 亲手再打开 → 记号清掉
        await control.set(true)
        #expect(d.object(forKey: ProposalAlertPushControl.userDisabledKey) == nil)
    }

    @Test func alertPushAutoEnableFailureIsVisibleAndRetriedNextLaunch() async {
        let push = FakePush(), d = suite()
        await push.configure(failSet: true)
        let control = ProposalAlertPushControl(store: push, defaults: d)
        await control.autoEnableIfNeverDisabled()
        #expect(!control.enabled && control.lastError?.contains("切换失败") == true)
        #expect(d.object(forKey: ProposalAlertPushControl.userDisabledKey) == nil)   // 下次启动还会再试
        let readFail = FakePush()
        await readFail.configure(failRead: true)
        let c2 = ProposalAlertPushControl(store: readFail, defaults: suite())
        await c2.autoEnableIfNeverDisabled()
        let none = await readFail.sets
        #expect(c2.lastError?.contains("读取推送状态失败") == true && none.isEmpty)
    }

    @Test func settingsSyncWhitelistCoversUserSettingsAndExcludesDeviceLocalOnes() {
        let synced = SettingsSync.syncedKeys
        let mustSync = [EveningReviewSettings.enabledKey, EveningReviewSettings.minuteKey, AgentEventSettings.key, AttentionSettings.key,
                        ProposalAlertPushControl.userDisabledKey, SharedTimerSettings.key, AgentContextSettings.allowJournalKey,
                        "execution.runRestorePolicy", "push.muted", "push.intensity", "integration.focusFollow", "theme.id"]
        for key in mustSync { #expect(synced.contains(key), "应同步：\(key)") }
        let local = Set(SettingsSync.deviceLocalKeys.keys)
        #expect(synced.isDisjoint(with: local))
        for key in ["integration.focusFollowDeviceID", "devicelog.deviceID", "agentBridge.folderBookmark", "focus.screenTimeSelection",
                    ProposalAlertPushControl.key, EveningReviewSettings.lastDayKey] {
            #expect(!synced.contains(key), "不应同步：\(key)")
        }
        #expect(SettingsSync.deviceLocalKeys.values.allSatisfy { !$0.isEmpty })   // 每条都写了理由
    }

    @Test func dispatcherUsageParsesAndRendersWithoutGuessingPercent() throws {
        let raw = #"{"schemaVersion":1,"dispatcherVersion":2,"state":"idle","thresholds":{},"usage7d":{"windowDays":7,"runs":12,"costUsd":3.456,"runsWithoutCost":1,"errors":0}}"#
        let st = try #require(AgentDispatcherStatus(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]))
        #expect(st.usage == .init(windowDays: 7, runs: 12, costUsd: 3.456, runsWithoutCost: 1, errors: 0))
        let line = AgentDispatcherStatus.usageLine(st.usage)
        #expect(line.contains("运行 12 次") && line.contains("$3.46") && line.contains("1 次没报成本") && !line.contains("%"))
        let legacy = try #require(AgentDispatcherStatus(["state": "idle"]))
        #expect(legacy.usage == nil && AgentDispatcherStatus.usageLine(nil).contains("还没提供"))
    }
}
