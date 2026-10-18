import CloudKit
import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import BetterCalendar

/// SPEC §19 W11：审批卡上的可调参数（滑块 / 时间选择器）+ 两个判断类数字软化（单块 16 小时、提案有效期 5 分钟–24 小时）。
/// 两台「设备」（mac / phone）共用内存中转与内存 SwiftData（容器与 store 同寿命）；时钟注入；不碰系统通知中心。
@MainActor @Suite struct W11CardInputsTests {
    final class Clock { var now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 10))! }

    struct Rig {
        let container: ModelContainer
        let clock: Clock
        let plans: PlanStore
        let timer: ProposalActionTests.FakeTimer
        let scheduler: W8ReminderTests.FakeScheduler
        let mac: ProposalCenter, phone: ProposalCenter
        let ledger: MemoryOperationLedger
        let phoneExecutor: ProposalActionExecutor
    }

    func rig() throws -> Rig {
        let container = try ModelContainer(for: DataArchiveStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let clock = Clock()
        let items = LongTaskStore(context: container.mainContext)
        let plans = PlanStore(context: container.mainContext)
        let timer = ProposalActionTests.FakeTimer()
        let progress = ProposalActionTests.Progress()
        let mover = ApprovedPlanMover(planStore: plans, projection: nil, startedDays: nil, now: { clock.now })
        mover.progress = progress
        let devices = [KnownDevice(id: "mac", label: "Jason 的 Mac", platform: "macOS", seenAt: clock.now),
                       KnownDevice(id: "phone", label: "Jason 的 iPhone", platform: "iOS", seenAt: clock.now)]
        let scheduler = W8ReminderTests.FakeScheduler(alarms: false)
        let macExecutor = ProposalActionExecutor(items: items, timer: timer, mover: mover, deviceId: "mac", now: { clock.now })
        macExecutor.notifications = scheduler; macExecutor.knownDevices = { devices }
        let phoneExecutor = ProposalActionExecutor(items: items, timer: ProposalActionTests.FakeTimer(), mover: mover, deviceId: "phone", now: { clock.now })
        phoneExecutor.notifications = W8ReminderTests.FakeScheduler(alarms: true); phoneExecutor.knownDevices = { devices }
        let transport = InMemoryProposalTransport(), ledger = MemoryOperationLedger()
        let mac = ProposalCenter(transport: transport, executor: macExecutor, notifier: SilentProposalNotifier(), ledger: ledger,
                                 deviceId: "mac", deviceLabel: "Mac", now: { clock.now })
        let phone = ProposalCenter(transport: transport, executor: phoneExecutor, notifier: SilentProposalNotifier(), ledger: ledger,
                                   deviceId: "phone", deviceLabel: "iPhone", now: { clock.now })
        return Rig(container: container, clock: clock, plans: plans, timer: timer, scheduler: scheduler,
                   mac: mac, phone: phone, ledger: ledger, phoneExecutor: phoneExecutor)
    }

    func at(_ h: Int, _ m: Int = 0, _ c: Clock, dayOffset: Int = 0) -> Date {
        let base = Calendar.current.date(byAdding: .day, value: dayOffset, to: c.now)!
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: base)!
    }

    /// 今天：整理笔记 11–12、组会 14–15（固定）、跑步 18–19。
    func seedDay(_ r: Rig) throws -> (flex: UUID, fixed: UUID, other: UUID) {
        let c = r.clock
        let flex = ScheduledBlock(title: "整理笔记", start: at(11, 0, c), end: at(12, 0, c))
        let fixed = ScheduledBlock(title: "组会", start: at(14, 0, c), end: at(15, 0, c), isFixed: true)
        let other = ScheduledBlock(title: "跑步", start: at(18, 0, c), end: at(19, 0, c))
        try r.plans.replacePlanned([flex, fixed, other], on: Calendar.current.startOfDay(for: c.now))
        return (flex.id, fixed.id, other.id)
    }

    func draft(_ action: ProposalAction, parameters: [ProposalParameter] = [], alternatives: [ProposalAlternative] = [],
               lifetime: TimeInterval = 3600, target: String? = "mac") -> ProposalDraft {
        ProposalDraft(origin: .agent, originLabel: "BetterCalendar 智能体", targetDeviceId: target, title: "把「整理笔记」挪到下午",
                      changes: [], reason: "上午有课", action: action, experiment: false, lifetime: lifetime,
                      alternatives: alternatives, parameters: parameters)
    }

    func startParam(_ kind: ProposalParameterKind = .timeOfDay) -> ProposalParameter {
        ProposalParameter(id: "start", label: "挪到几点", kind: kind, bind: .start)
    }

    func block(_ r: Rig, _ id: UUID) throws -> ScheduledBlock? {
        try r.plans.plannedBlocks(on: Calendar.current.startOfDay(for: r.clock.now)).first { $0.id == id }
    }

    // MARK: 1. 声明校验：类型封闭、绑定显式，绑到没有的字段一律拒收

    @Test func declarationsAreTypedBoundedAndBindingToAMissingFieldIsRejected() throws {
        let move = ProposalAction.moveBlock(id: UUID(), start: .now, end: nil, expectedRevision: nil)
        let create = ProposalAction.itemCreate(id: UUID(), title: "t", note: nil)
        let reminder = ProposalAction.reminder(id: UUID(), title: "出门", body: nil, fireAt: .now, deviceId: nil)
        func reason(_ ps: [ProposalParameter], _ action: ProposalAction) -> String? {
            do { try ProposalParameterRules.validateDeclarations(ps, for: action); return nil } catch { return error.localizedDescription }
        }
        #expect(reason([startParam()], move) == nil)
        #expect(reason([startParam()], create)?.contains("这种改动没有可调的字段") == true)
        #expect(reason([ProposalParameter(id: "f", label: "几点", kind: .timeOfDay, bind: .fireAt)], move)?.contains("可绑：duration / end / start") == true)
        #expect(reason([startParam()], .timer(command: .pause, blockId: nil, title: nil, expectedRevision: nil)) != nil)   // 只有开始计时能调起点
        #expect(reason([ProposalParameter(id: "s", label: "几点", kind: .number, bind: .start, unit: .minute)], move)?.contains("只接受") == true)
        let duration = ProposalParameter(id: "d", label: "做多久", kind: .duration, bind: .duration, min: .number(15), max: .number(240), step: 15)
        let end = ProposalParameter(id: "e", label: "到几点", kind: .timeOfDay, bind: .end)
        #expect(reason([duration, end], move)?.contains("改同一个字段") == true)
        #expect(reason([startParam(), startParam()], move)?.contains("重复") == true)
        #expect(reason([ProposalParameter(id: "n", label: "做多久", kind: .number, bind: .duration, min: .number(1), max: .number(5))], move)?.contains("unit") == true)
        #expect(reason([ProposalParameter(id: "d", label: "做多久", kind: .duration, bind: .duration)], move)?.contains("min / max") == true)
        #expect(reason([ProposalParameter(id: "d", label: "做多久", kind: .duration, bind: .duration, min: .number(0), max: .number(1e6), step: 1)], move)?.contains("技术上限") == true)
        #expect(reason([ProposalParameter(id: "l", label: "提前", kind: .duration, bind: .leadTime, min: .number(0), max: .number(60))], reminder)?.contains("anchor") == true)
        #expect(reason(Array(repeating: startParam(), count: 6).enumerated().map { var p = $1; p.id = "p\($0)"; return p }, move)?.contains("最多 5 个") == true)
        #expect(reason([ProposalParameter(id: "bad id!", label: "x", kind: .timeOfDay, bind: .start)], move)?.contains("id") == true)
    }

    @Test func bridgeParsesParametersStrictlyIncludingOnAlternatives() throws {
        let c = Clock()
        let iso = ISO8601DateFormatter()
        func file(_ params: String, action: String? = nil, alternatives: String = "null", lifetime: String = "3600") -> Data {
            let fire = iso.string(from: at(20, 0, c)), anchor = iso.string(from: at(21, 0, c))
            let a = action ?? #"{"kind": "reminder", "title": "出门", "fireAt": "\#(fire)"}"#
            return Data(#"""
            {"schemaVersion": 1, "id": "\#(UUID().uuidString)", "title": "提醒出门", "reason": "他说的", "action": \#(a),
             "lifetimeSeconds": \#(lifetime), "alternatives": \#(alternatives),
             "parameters": \#(params.replacingOccurrences(of: "ANCHOR", with: anchor))}
            """#.utf8)
        }
        let lead = #"[{"id": "lead", "label": "提前多久", "type": "number", "unit": "minute", "bind": "leadTime", "anchor": "ANCHOR", "min": 0, "max": 120, "step": 5}]"#
        let draft = try AgentBridgeIO.draft(from: file(lead))
        let p = try #require(draft.parameters.first)
        #expect(p.kind == .number && p.bind == .leadTime && p.unit == .minute && p.step == 5 && p.min == .number(0) && p.anchor != nil)
        #expect(p.defaultValue == nil)   // 默认值 = action 里写的那个，由 prepare 算
        // 绑到这种改动没有的字段 → 拒收，原因写清
        #expect(throws: AgentBridgeError.self) {
            try AgentBridgeIO.draft(from: file(#"[{"id": "s", "label": "几点", "type": "timeOfDay", "bind": "start"}]"#))
        }
        do { _ = try AgentBridgeIO.draft(from: file(#"[{"id": "s", "label": "几点", "type": "timeOfDay", "bind": "start"}]"#)); Issue.record("应拒收") }
        catch { #expect(error.localizedDescription.contains("不属于") && error.localizedDescription.contains("可绑：fireAt / leadTime")) }
        // 不认识的键、类型不对都拒收
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.draft(from: file(#"[{"id": "x", "label": "几点", "type": "timeOfDay", "bind": "fireAt", "color": "red"}]"#)) }
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.draft(from: file(#"[{"id": "x", "label": "几点", "type": "slider", "bind": "fireAt"}]"#)) }
        #expect(throws: AgentBridgeError.self) { try AgentBridgeIO.draft(from: file(#"[{"id": "x", "label": "几点", "type": "timeOfDay", "bind": "fireAt", "default": 5}]"#)) }
        // 备选方案可以各自带参数（作用于那个方案）
        let alt = #"[{"label": "改成闹钟", "action": {"kind": "reminder", "title": "出门2", "fireAt": "\#(iso.string(from: at(19, 0, c)))"}, "parameters": [{"id": "t", "label": "几点", "type": "timeOfDay", "bind": "fireAt"}]}]"#
        let withAlt = try AgentBridgeIO.draft(from: file("null", alternatives: alt))
        #expect(withAlt.parameters.isEmpty && withAlt.alternatives.first?.parameters?.first?.bind == .fireAt)
    }

    @Test func prepareComputesDefaultsFromTheActionAndRejectsAMismatchedDefault() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        let move = ProposalAction.moveBlock(id: ids.flex, start: at(16, 0, c), end: nil, expectedRevision: nil)
        let duration = ProposalParameter(id: "len", label: "做多久", kind: .duration, bind: .duration, min: .number(15), max: .number(180), step: 15)
        let prepared = try await r.mac.prepare(draft(move, parameters: [startParam(), duration]))
        #expect(prepared.parameters.first?.defaultValue == .date(at(16, 0, c)))
        #expect(prepared.parameters.last?.defaultValue == .number(60))   // 没写 end = 保持原时长 1 小时
        #expect(try await r.mac.prepare(prepared).parameters == prepared.parameters)   // 幂等
        // 智能体写的默认值和 action 不一致 → 拒收
        var wrong = startParam(); wrong.defaultValue = .date(at(17, 0, c))
        await #expect(throws: ProposalExecutionError.self) { try await r.mac.prepare(draft(move, parameters: [wrong])) }
        r.mac.clearError()
        #expect(await r.mac.submit(draft(move, parameters: [wrong])) == nil)
        #expect(r.mac.lastError?.contains("默认值就是改动里写的那个") == true)
        // 默认值不在给的范围里 → 拒收
        var narrow = duration; narrow.min = .number(90)
        await #expect(throws: ProposalExecutionError.self) { try await r.mac.prepare(draft(move, parameters: [narrow])) }
        // 回溯起点参数需要 action 先写 startedAt
        r.timer.plan[ids.flex] = "整理笔记"
        let timer = ProposalAction.timer(command: .start, blockId: ids.flex, title: nil, expectedRevision: nil)
        await #expect(throws: ProposalExecutionError.self) {
            try await r.mac.prepare(draft(timer, parameters: [ProposalParameter(id: "from", label: "从几点算", kind: .timeOfDay, bind: .startedAt)]))
        }
    }

    // MARK: 2. 合法性归 App：最终值重新校验，不合法写明原因、批不了

    @Test func chosenValueIsRevalidatedAndAnInvalidOneIsRefusedWithAReason() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        let p = try #require(await r.mac.submit(draft(.moveBlock(id: ids.flex, start: at(16, 0, c), end: nil, expectedRevision: nil),
                                                       parameters: [startParam()])))
        await r.phone.refresh()
        // 预览：撞上固定安排 → 原因写清（范围只是提示，不夹值）
        await #expect(throws: ProposalExecutionError.self) { try await r.phone.checkTuning(p, option: 0, values: ["start": .date(at(13, 30, c))]) }
        do { _ = try await r.phone.checkTuning(p, option: 0, values: ["start": .date(at(13, 30, c))]) }
        catch { #expect(error.localizedDescription.contains("与固定安排「组会」")) }
        do { _ = try await r.phone.checkTuning(p, option: 0, values: ["start": .date(at(9, 0, c))]) }
        catch { #expect(error.localizedDescription.contains("已经过去了")) }
        // 批准时再查一次：不合法 → 不批准，原因可见，提案仍待确认
        #expect(await r.phone.decide(p.id, .approve, values: ["start": .date(at(13, 30, c))]) == nil)
        #expect(r.phone.lastError?.contains("没有批准") == true && r.phone.lastError?.contains("组会") == true)
        #expect(r.ledger.values.contains { $0.event == "tune.invalid" && $0.proposalId == p.id })
        await r.mac.refresh()
        #expect(r.mac.proposals.first { $0.id == p.id }?.state == .pending)
        #expect(try block(r, ids.flex)?.start == at(11, 0, c))   // 什么都没改
        // 未知参数 / 类型不对也拒绝
        await #expect(throws: ProposalExecutionError.self) { try await r.phone.checkTuning(p, option: 0, values: ["nope": .date(at(16, 0, c))]) }
        await #expect(throws: ProposalExecutionError.self) { try await r.phone.checkTuning(p, option: 0, values: ["start": .number(5)]) }
    }

    // MARK: 3. 「改动前 → 改动后」依据真实数据实时重算

    @Test func beforeAfterIsRecomputedLiveFromRealData() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        let duration = ProposalParameter(id: "len", label: "做多久", kind: .duration, bind: .duration, min: .number(15), max: .number(180), step: 15)
        let p = try #require(await r.mac.submit(draft(.moveBlock(id: ids.flex, start: at(16, 0, c), end: nil, expectedRevision: nil),
                                                       parameters: [startParam(), duration])))
        #expect(p.changes.first == ProposalChange(field: "「整理笔记」时间", before: "11:00–12:00", after: "16:00–17:00"))
        let moved = try await r.mac.checkTuning(p, option: 0, values: ["start": .date(at(20, 0, c))])
        #expect(moved.changes?.first == ProposalChange(field: "「整理笔记」时间", before: "11:00–12:00", after: "20:00–21:00"))   // 平移保持时长
        let longer = try await r.mac.checkTuning(p, option: 0, values: ["start": .date(at(15, 0, c)), "len": .number(150)])
        #expect(longer.changes?.first?.after == "15:00–17:30")
        // 改了真实数据（你在日历里先挪了跑步）→ 同样的值预览结果跟着变
        try r.plans.updatePlanned(id: ids.other, start: at(20, 30, c), end: at(21, 30, c), title: "跑步")
        do { _ = try await r.mac.checkTuning(p, option: 0, values: ["start": .date(at(20, 0, c))]); Issue.record("应和跑步重叠") }
        catch { #expect(error.localizedDescription.contains("和「跑步」")) }
        // 通知正文 / 卡片写默认值
        #expect(p.notificationBody.contains("可调：挪到几点 默认 16:00") && p.notificationBody.contains("可调：做多久 默认 1 小时"))
    }

    // MARK: 4. 留底记下最终值与改没改；执行的就是调好的；统计单列

    @Test func ledgerRecordsTheChangedValueExecutionUsesItAndStatsCountIt() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        let p = try #require(await r.mac.submit(draft(.moveBlock(id: ids.flex, start: at(16, 0, c), end: nil, expectedRevision: nil),
                                                       parameters: [startParam()])))
        await r.phone.refresh()
        guard case .won? = await r.phone.decide(p.id, .approve, values: ["start": .date(at(20, 0, c))]) else { Issue.record("应批准"); return }
        await r.mac.refresh(); await r.phone.refresh()
        let done = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(done.state == .applied)
        #expect(done.chosenValues?["start"] == .date(at(20, 0, c)) && done.tunedByUser)
        #expect(done.tuningSummary == ["挪到几点：16:00 → 你改成 20:00"])
        #expect(done.chosen.changes.first?.after == "20:00–21:00" && done.notificationBody.contains("你改成 20:00"))
        #expect(try block(r, ids.flex)?.start == at(20, 0, c))   // 执行的是调好的
        #expect(r.ledger.values.contains { $0.event == "decided" && $0.proposalId == p.id && $0.detail.contains("挪到几点：16:00 → 你改成 20:00") })
        let stats = AgentTranslationStatsCalculator.compute(proposals: r.mac.proposals, messages: [], ledger: r.ledger.values, window: .all, now: c.now)
        #expect(stats.approvedWithParameters == 1 && stats.tuned == 1 && stats.tuneRate.text == "1/1（100%）")
        // 结果文件给智能体：最终值 + 他改没改
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bc-w11-" + UUID().uuidString)
        let io = AgentBridgeIO(root: root); try io.prepare()
        try io.writeResult(done, at: c.now)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results/\(p.id.uuidString).json"))) as! [String: Any]
        let row = try #require((result["parameters"] as? [[String: Any]])?.first)
        #expect(row["default"] as? String == "16:00" && row["value"] as? String == "20:00" && row["changedByJason"] as? Bool == true)
        // 撤销照常（按调好的那份逆操作挪回原位）
        #expect(await r.phone.undo(p.id))
        #expect(try block(r, ids.flex)?.start == at(11, 0, c))
    }

    @Test func alternativesCanCarryTheirOwnParametersAndTheChosenOneRuns() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        let alt = ProposalAlternative(label: "晚上做", action: .moveBlock(id: ids.flex, start: at(20, 0, c), end: nil, expectedRevision: nil),
                                      parameters: [startParam()])
        let p = try #require(await r.mac.submit(draft(.moveBlock(id: ids.flex, start: at(16, 0, c), end: nil, expectedRevision: nil), alternatives: [alt])))
        #expect(p.options[0].parameters.isEmpty && p.options[1].parameters.first?.defaultValue == .date(at(20, 0, c)) && p.hasParameters)
        // 参数只作用于自己那个方案
        await #expect(throws: ProposalExecutionError.self) { try await r.mac.checkTuning(p, option: 0, values: ["start": .date(at(16, 30, c))]) }
        let category = LocalProposalNotifier.optionsCategory(for: p)
        #expect(category.actions.map(\.title).contains("2. 晚上做（按默认）") && category.actions.map(\.title).contains("1. 方案 1"))
        await r.phone.refresh()
        _ = await r.phone.decide(p.id, .approve, choice: 1, values: ["start": .date(at(21, 0, c))])
        await r.mac.refresh()
        let done = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(done.state == .applied && done.chosenOption == 1 && done.tuningSummary == ["挪到几点：20:00 → 你改成 21:00"])
        #expect(try block(r, ids.flex)?.start == at(21, 0, c))
    }

    // MARK: 5. 预授权规则永远不代批带参数的提案

    @Test func preauthRulesNeverAutoApplyProposalsWithParameters() {
        let at = Clock().now
        let action = ProposalAction.reminder(id: UUID(), title: "出门", body: nil, fireAt: at.addingTimeInterval(3600), deviceId: nil)
        var p = Proposal(id: UUID(), createdAt: at, expiresAt: at.addingTimeInterval(3600), origin: .agent, originLabel: "BetterCalendar 智能体",
                         originDeviceId: "mac", parentId: nil, targetDeviceId: nil, title: "提醒", changes: [], reason: "r",
                         action: action, experiment: false, state: .pending)
        func rule(_ effect: PreauthEffect) -> PreauthRule {
            PreauthRule(id: UUID(), createdAt: at, createdByDeviceId: "mac", origin: .agent, ruleKind: "reminder", kindLabel: "提醒",
                        scope: .kind, effect: effect, sourceProposalId: nil)
        }
        #expect(PreauthPolicy.evaluate(p, rules: [rule(.allow)]).route == .apply)   // 不带参数：照旧放行
        p.parameters = [ProposalParameter(id: "t", label: "几点", kind: .timeOfDay, bind: .fireAt, defaultValue: .date(at.addingTimeInterval(3600)))]
        for effect in PreauthEffect.allCases {
            let verdict = PreauthPolicy.evaluate(p, rules: [rule(effect)])
            #expect(verdict.route == .ask && verdict.note.contains("可调的数值"))   // 连 deny 也不自动拒绝：要他亲眼看到
        }
        // 越级照旧永远先问
        p.parameters = nil; p.escalation = "确有必要"
        #expect(PreauthPolicy.evaluate(p, rules: [rule(.allow)]).route == .ask)
    }

    @Test func submittingWithAnAllowRuleStillAsksWhenParametersArePresent() async throws {
        let r = try rig()
        let c = r.clock
        let rules = PreauthRuleStore(defaults: UserDefaults(suiteName: "bc-w11-" + UUID().uuidString)!, now: { c.now })
        _ = rules.upsert(origin: .agent, action: .reminder(id: UUID(), title: "x", body: nil, fireAt: c.now, deviceId: nil),
                         scope: .kind, effect: .allow, deviceId: "mac", sourceProposalId: nil)
        let macExecutor = ProposalActionExecutor(items: nil, deviceId: "mac", now: { c.now })
        macExecutor.notifications = r.scheduler
        let center = ProposalCenter(transport: InMemoryProposalTransport(), gate: PreauthRuleGate(store: rules), rules: rules, executor: macExecutor,
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(), deviceId: "mac", deviceLabel: "Mac", now: { c.now })
        let reminder = ProposalAction.reminder(id: UUID(), title: "出门", body: nil, fireAt: at(20, 0, c), deviceId: nil)
        let p = try #require(await center.submit(draft(reminder, parameters: [ProposalParameter(id: "t", label: "提醒时间", kind: .timeOfDay, bind: .fireAt)], target: nil)))
        #expect(p.state == .pending && p.preauth == nil && r.scheduler.calls.isEmpty)
        let plain = try #require(await center.submit(draft(.reminder(id: UUID(), title: "出门", body: nil, fireAt: at(20, 0, c), deviceId: nil), target: nil)))
        #expect(plain.preauth != nil)   // 对照：同类不带参数的照规则放行
    }

    // MARK: 6. 通知：按默认批准

    @Test func notificationOffersApproveWithDefaultsAndThatPathUsesTheDefaults() async throws {
        let r = try rig()
        let c = r.clock
        let reminder = ProposalAction.reminder(id: UUID(), title: "出门", body: nil, fireAt: at(20, 0, c), deviceId: "mac")
        let lead = ProposalParameter(id: "lead", label: "提前多久", kind: .number, bind: .leadTime, unit: .minute,
                                     min: .number(0), max: .number(120), step: 5, anchor: at(20, 30, c))
        let p = try #require(await r.mac.submit(draft(reminder, parameters: [lead], target: nil)))
        #expect(p.parameters?.first?.defaultValue == .number(30))
        // 通知：按默认批准 + 回一句 + 拒绝 + 打开调整；正文写默认值
        #expect(LocalProposalNotifier.categoryId(for: p) == LocalProposalNotifier.parametersCategory)
        let category = LocalProposalNotifier.parametersCategoryDefinition
        #expect(category.actions.map(\.title) == ["按默认批准", "回一句", "拒绝", "打开调整"])
        #expect(category.actions.count <= LocalProposalNotifier.maxActions)
        let request = LocalProposalNotifier.request(for: p)
        #expect(request.content.body.contains("可调：提前多久 默认 30 分钟（打开卡片可以调）"))
        let info = request.content.userInfo
        #expect(LocalProposalNotifier.response(userInfo: info, actionIdentifier: LocalProposalNotifier.approveAction, typedText: nil)?.response == .decide(.approve, choice: nil))
        #expect(LocalProposalNotifier.response(userInfo: info, actionIdentifier: UNNotificationDefaultActionIdentifier, typedText: nil)?.response == .open)
        // 按默认批准 = 不带数值的批准：记下默认值、执行原方案
        _ = await r.mac.decide(p.id, .approve)
        await r.mac.refresh()
        let done = try #require(r.mac.proposals.first { $0.id == p.id })
        #expect(done.state == .applied && done.chosenValues?["lead"] == .number(30) && done.tunedAction == nil && !done.tunedByUser)
        #expect(done.tuningSummary == ["提前多久：30 分钟（默认）"])
        #expect(r.scheduler.reminders.values.first?.fireAt == at(20, 0, c))
        let stats = AgentTranslationStatsCalculator.compute(proposals: r.mac.proposals, messages: [], ledger: r.ledger.values, window: .all, now: c.now)
        #expect(stats.approvedWithParameters == 1 && stats.tuned == 0)
        // 不带参数的提案仍用原来的类别（W10 动态类别逻辑不变）
        let plain = try #require(await r.mac.submit(draft(.reminder(id: UUID(), title: "喝水", body: nil, fireAt: at(21, 0, c), deviceId: "mac"), target: nil)))
        #expect(LocalProposalNotifier.categoryId(for: plain) == LocalProposalNotifier.category)
    }

    @Test func leadTimeTunedOnTheCardMovesTheFireTime() async throws {
        let r = try rig()
        let c = r.clock
        let lead = ProposalParameter(id: "lead", label: "提前多久", kind: .number, bind: .leadTime, unit: .minute,
                                     min: .number(0), max: .number(120), step: 5, anchor: at(20, 30, c))
        let p = try #require(await r.mac.submit(draft(.reminder(id: UUID(), title: "出门", body: nil, fireAt: at(20, 0, c), deviceId: "mac"),
                                                       parameters: [lead], target: nil)))
        let preview = try await r.mac.checkTuning(p, option: 0, values: ["lead": .number(45)])
        #expect(preview.changes?.contains { $0.field.contains("10月18日 19:45") } == true)
        // 不合法：提前量为负、或时刻已经过了 → 写明原因
        await #expect(throws: ProposalExecutionError.self) { try await r.mac.checkTuning(p, option: 0, values: ["lead": .number(-5)]) }
        do { _ = try await r.mac.checkTuning(p, option: 0, values: ["lead": .number(700)]); Issue.record("应拒绝") }
        catch { #expect(error.localizedDescription.contains("已经过了或太近")) }
        _ = await r.mac.decide(p.id, .approve, values: ["lead": .number(45)])
        await r.mac.refresh()
        #expect(r.scheduler.reminders.values.first?.fireAt == at(19, 45, c))
        #expect(r.mac.proposals.first { $0.id == p.id }?.tuningSummary == ["提前多久：30 分钟 → 你改成 45 分钟"])
    }

    // MARK: 计时：不在执行设备上调回溯起点（设备本地状态由执行设备再核对）

    @Test func backdatedStartTunedOnAnotherDeviceIsCheckedThereAndRunsOnTheExecutor() async throws {
        let r = try rig()
        let ids = try seedDay(r)
        let c = r.clock
        r.timer.plan[ids.flex] = "整理笔记"
        let from = ProposalParameter(id: "from", label: "从几点算", kind: .timeOfDay, bind: .startedAt)
        let p = try #require(await r.mac.submit(draft(.timer(command: .start, blockId: ids.flex, title: nil, expectedRevision: nil, startAt: at(9, 30, c)),
                                                       parameters: [from], target: nil)))
        #expect(p.targetDeviceId == "mac")
        await r.phone.refresh()
        let preview = try await r.phone.checkTuning(p, option: 0, values: ["from": .date(at(9, 45, c))])
        #expect(preview.changes?.contains { $0.field.contains("执行它的那台设备会再核对一次") } == true)
        #expect(preview.changes?.contains { $0.after?.contains("从 09:45 开始计") == true } == true)
        do { _ = try await r.phone.checkTuning(p, option: 0, values: ["from": .date(at(11, 0, c))]); Issue.record("未来的起点应拒绝") }
        catch { #expect(error.localizedDescription.contains("在未来")) }
        _ = await r.phone.decide(p.id, .approve, values: ["from": .date(at(9, 45, c))])
        await r.mac.refresh()
        #expect(r.mac.proposals.first { $0.id == p.id }?.state == .applied)
        #expect(r.timer.startedAts == [at(9, 45, c)])
    }

    // MARK: 「当天的几点」落在默认值同一个逻辑日

    @Test func timeOfDayStaysOnTheSameLogicalDayAsTheDefault() {
        let c = Clock()
        let lateDefault = at(0, 30, c, dayOffset: 1)        // 次日 0:30 = 今天这个逻辑日的深夜
        #expect(ProposalParameterRules.onSameDay(at(23, 0, c, dayOffset: 1), as: lateDefault) == at(23, 0, c))
        #expect(ProposalParameterRules.onSameDay(at(1, 15, c), as: lateDefault) == at(1, 15, c, dayOffset: 1))
        #expect(ProposalParameterRules.onSameDay(at(15, 0, c, dayOffset: 3), as: at(16, 0, c)) == at(15, 0, c))
    }

    // MARK: 持久化：只在 JSON 载荷里，旧记录照常解码

    @Test func parametersRoundTripInThePayloadAndOldRecordsDecode() throws {
        let at = Clock().now
        var p = Proposal(id: UUID(), createdAt: at, expiresAt: at.addingTimeInterval(3600), origin: .agent, originLabel: "a",
                         originDeviceId: "mac", parentId: nil, targetDeviceId: nil, title: "t", changes: [], reason: "r",
                         action: .moveBlock(id: UUID(), start: at, end: at.addingTimeInterval(3600), expectedRevision: "x"),
                         experiment: false, state: .applied)
        p.parameters = [ProposalParameter(id: "len", label: "做多久", kind: .duration, bind: .duration, defaultValue: .number(60), min: .number(15), max: .number(120))]
        p.chosenValues = ["len": .number(90)]
        p.tunedAction = .moveBlock(id: UUID(), start: at, end: at.addingTimeInterval(5400), expectedRevision: "x")
        p.tunedChanges = [ProposalChange(field: "f", before: "a", after: "b")]
        let decoded = try JSONDecoder().decode(Proposal.self, from: JSONEncoder().encode(p))
        #expect(decoded == p && decoded.executedAction == p.tunedAction && decoded.tunedByUser)
        // 旧记录（没有 W11 的键）
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        for k in ["parameters", "chosenValues", "tunedAction", "tunedChanges"] { old[k] = nil }
        let legacy = try JSONDecoder().decode(Proposal.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.parameters == nil && !legacy.hasParameters && legacy.tuningSummary.isEmpty && legacy.executedAction == p.action)
        // CloudKit 记录仍是同一套镜像字段（payload 是唯一真相）——不改 schema
        let record = CKRecordStub.encode(p)
        #expect(record.sorted() == ["body", "createdAtLocal", "expiresAt", "payload", "state", "title"])
    }

    // MARK: 判断类数字软化：有效期 1 分钟–7 天（技术稳定窗口）

    @Test func lifetimeOnlyKeepsTheOneMinuteToSevenDayStabilityWindow() async throws {
        let r = try rig()
        let c = r.clock
        let noop = ProposalAction.experimentNoop(note: "t")
        func submit(_ lifetime: TimeInterval) async -> Proposal? {
            r.mac.clearError()
            var d = draft(noop, lifetime: lifetime); d.changes = [ProposalChange(field: "x", before: nil, after: "y")]
            return await r.mac.submit(d)
        }
        #expect(await submit(59) == nil && r.mac.lastError?.contains("1 分钟到 7 天") == true)
        #expect(await submit(60)?.expiresAt == c.now.addingTimeInterval(60))
        #expect(await submit(7 * 86_400)?.expiresAt == c.now.addingTimeInterval(7 * 86_400))   // 以前上限 24 小时
        #expect(await submit(7 * 86_400 + 1) == nil)
        // 桥接：超出窗口拒收（不再悄悄夹值），省略 = 1 小时
        func bridge(_ lifetime: String?) throws -> ProposalDraft {
            let key = lifetime.map { #", "lifetimeSeconds": \#($0)"# } ?? ""
            return try AgentBridgeIO.draft(from: Data(#"""
            {"schemaVersion": 1, "id": "\#(UUID().uuidString)", "title": "t", "reason": "r", "action": {"kind": "experimentNoop"},
             "changes": [{"field": "x", "before": null, "after": "y"}]\#(key)}
            """#.utf8))
        }
        #expect(try bridge(nil).lifetime == 3600)
        #expect(try bridge("60").lifetime == 60 && bridge("120").lifetime == 120)   // 以前会被夹到 300
        #expect(try bridge("604800").lifetime == 604_800)
        #expect(throws: AgentBridgeError.self) { try bridge("59") }
        #expect(throws: AgentBridgeError.self) { try bridge("604801") }
        #expect(throws: AgentBridgeError.self) { try bridge("\"1h\"") }
    }

    // MARK: 判断类数字软化：单块不再限 16 小时（排布允许就行）

    @Test func blockLongerThanSixteenHoursIsAcceptedWhenTheLayoutAllows() async throws {
        let r = try rig()
        let c = r.clock
        let only = ScheduledBlock(title: "通宵赶论文", start: at(10, 30, c), end: at(11, 30, c))
        try r.plans.replacePlanned([only], on: Calendar.current.startOfDay(for: c.now))
        let end = at(3, 30, c, dayOffset: 1)   // 10:30 → 次日 3:30 = 17 小时，仍在今天这个逻辑日内
        let p = try #require(await r.mac.submit(draft(.moveBlock(id: only.id, start: at(10, 30, c), end: end, expectedRevision: nil))))
        _ = await r.phone.decide(p.id, .approve)
        await r.mac.refresh()
        #expect(r.mac.proposals.first { $0.id == p.id }?.state == .applied)
        #expect(try block(r, only.id)?.end == end)
        // 有效性照旧：结束须晚于开始；超出今天照旧拒绝
        r.mac.clearError()
        #expect(await r.mac.submit(draft(.moveBlock(id: only.id, start: at(12, 0, c), end: at(12, 0, c), expectedRevision: nil))) == nil)
        #expect(r.mac.lastError?.contains("结束须晚于开始") == true)
        #expect(await r.mac.submit(draft(.moveBlock(id: only.id, start: at(12, 0, c), end: at(5, 0, c, dayOffset: 1), expectedRevision: nil))) == nil)
        #expect(r.mac.lastError?.contains("超出今天") == true)
    }
}

/// 只看 ProposalRecordCodec 写了哪些字段（不连 iCloud）。
enum CKRecordStub {
    static func encode(_ p: Proposal) -> [String] {
        let record = CKRecord(recordType: ProposalRecordCodec.recordType, recordID: CKRecord.ID(recordName: p.id.uuidString))
        try? ProposalRecordCodec.encode(p, into: record)
        return record.allKeys()
    }
}
