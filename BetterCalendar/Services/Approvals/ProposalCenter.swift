//
//  ProposalCenter.swift
//  BetterCalendar
//
//  SPEC §19 B 组的协调者：发起 → 闸门 → 各端通知 → 首个决定生效 → 指定设备执行 → 各端收起通知。
//  通知、App 内列表、对话卡片都指向这里的同一份提案状态（B3）。
//  W10：三种回应（批准 / 拒绝 / 回一句话）、备选方案（你选哪个执行哪个）、分层预授权（规则代你决定，留底来源 = 规则 id）。
//  只依赖协议；CloudKit / 内存中转、真实 / 假通知在组装点注入。
//

import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// 本机在多端审批里的身份（复用多端跟随的安装级 ID）。
@MainActor enum ProposalDevice {
    static var id: String { FocusFollow.deviceID }
    static var label: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}

@MainActor @Observable final class ProposalCenter {
    private(set) var proposals: [Proposal] = []
    private(set) var lastError: String?

    let deviceId: String
    let deviceLabel: String
    private let transport: any ProposalTransport
    private let gate: any ProposalGate
    /// W10：预授权规则（面板查看/删除；审批时「以后同类…」写进来）。nil = 没接规则存储（测试 / 旧环境）。
    let rules: PreauthRuleStore?
    /// W10：你对提案回的一句话 → 转给智能体（组装点接到对话 AgentChatCenter）。返回这句话是否已存进 iCloud。
    var forwardReply: ((Proposal, String) async -> Bool)?
    /// W30：本机通知对齐之后（闹钟镜像：别的设备上设好的闹钟，本机到点安静放一份）。
    var afterNotificationsReconciled: (([Proposal]) async -> Void)?
    private let executor: any ProposalExecuting
    private let notifier: any ProposalNotifying
    let ledger: any OperationLedger
    private let now: () -> Date
    /// 正在执行的提案，防止同一台设备并发重复执行。
    /// 卡片上「回一句」展开了输入框的提案（冒烟 2026-10-18：macOS List 行里的 @State 展开后行高不更新、输入框看不见——
    /// 状态放到这里，面板用它改行的 id 强制重排；对话卡片同样复用）。
    var replying: Set<UUID> = []
    /// W21：展开「回一句」= 开了头；没发就收起 = 没做完（功能使用探针）。
    func toggleReplying(_ id: UUID) {
        if replying.contains(id) {
            replying.remove(id)
            usage.abandonIfOpen(.proposalReply, key: id.uuidString)
        } else {
            replying.insert(id)
            usage.begin(.proposalReply, key: id.uuidString)
        }
    }
    /// W29：这份提案上次「回一句」打了一半（App 重启过）→ 还在等你拍板就把回复框重新展开（卡片出现时调）。
    /// 走 toggleReplying 同一条路：记一次「开了头」（上个进程的开头随进程没了，没记成没做完）；已开着 / 不在等 / 没草稿 → 什么都不做。
    @discardableResult
    func resumeReplyingIfDrafted(_ id: UUID, drafts: TextDraftStore = .shared) -> Bool {
        guard !replying.contains(id), pending.contains(where: { $0.id == id }), drafts.has(TextDraftKey.proposalReply(id)) else { return false }
        toggleReplying(id)
        return true
    }
    /// W21 功能使用探针（只记哪个功能、什么事件；本机）。测试注入自己的实例。
    var usage: FeatureUsageStore = FeatureUsage.shared
    /// W21：卡片上开始调某个方案的数值（第一次改值时由 ProposalTuner 调）= 开了头；批准了这个方案 = 做完；
    /// 拒绝 / 选了别的 / 提案作废 = 没做完。
    func noteTuningStarted(_ id: UUID, option: Int) { usage.begin(.proposalTune, key: Self.tuneKey(id, option)) }
    nonisolated static func tuneKey(_ id: UUID, _ option: Int) -> String { "\(id.uuidString)#\(option)" }
    /// 关掉这份提案上还开着的「回一句 / 调数值」开头（记为没做完）。
    private func abandonOpenAttempts(_ id: UUID) {
        usage.abandonIfOpen(.proposalReply, key: id.uuidString)
        for k in usage.openKeys(.proposalTune) where k.hasPrefix(id.uuidString + "#") { usage.abandonIfOpen(.proposalTune, key: k) }
    }
    private var executing: Set<UUID> = []
    /// 冒烟 2026-10-18 bug A：本机已执行成功、但「已完成」回报没落地的提案（网络抖动 / 超时）。
    /// 留在这里（并持久化），刷新时只**补回报**、绝不重新执行；补上后移除。
    private var unreported: [UUID: PendingReport] = [:]
    nonisolated struct PendingReport: Codable, Sendable { var note: String; var undo: ProposalUndoInfo?; var at: Date }
    static let unreportedKey = "approvals.unreported.v1"
    /// 回报的单次超时与重试次数（稳定性参数，不是产品规则）。
    static let reportTimeout: TimeInterval = 30
    static let reportAttempts = 3

    /// 「做完告诉你」已在本机通知过的提案（持久化防重启重弹；nil defaults = 只在内存）。
    private let informDefaults: UserDefaults?
    private var informedHere: Set<UUID>
    static let informedKey = "approvals.informedHere"
    /// 只为最近这么久内自动执行的提案补发结果通知（新装 / 久未打开时不翻旧账刷屏）。
    static let informWindow: TimeInterval = 6 * 3600

    init(transport: any ProposalTransport, gate: any ProposalGate = AskAlwaysGate(), rules: PreauthRuleStore? = nil,
         executor: any ProposalExecuting, notifier: any ProposalNotifying, ledger: any OperationLedger,
         deviceId: String, deviceLabel: String, informDefaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.transport = transport; self.gate = gate; self.rules = rules; self.executor = executor
        self.notifier = notifier; self.ledger = ledger
        self.deviceId = deviceId; self.deviceLabel = deviceLabel; self.now = now
        self.informDefaults = informDefaults
        informedHere = Set((informDefaults?.stringArray(forKey: Self.informedKey) ?? []).compactMap(UUID.init))
        if let data = informDefaults?.data(forKey: Self.unreportedKey),
           let saved = try? JSONDecoder().decode([String: PendingReport].self, from: data) {
            unreported = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
    }

    private func saveUnreported() {
        guard let d = informDefaults else { return }
        if unreported.isEmpty { d.removeObject(forKey: Self.unreportedKey); return }
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: unreported.map { ($0.key.uuidString, $0.value) })) {
            d.set(data, forKey: Self.unreportedKey)
        }
    }

    /// 面板 / 测试：还有几份「做完了但没回报」。
    var unreportedCount: Int { unreported.count }

    /// App 在前台时为 true：前台每 20 秒兜底刷新一次（推送丢失也能收敛）。
    var isForeground = false
    private var pollTask: Task<Void, Never>?

    /// 前台兜底轮询（测试环境不要启动：游离任务会拖垮 test host）。
    func startPolling(every seconds: Double = 20) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                if self.isForeground { await self.refresh() }
            }
        }
    }

    /// 报错一直显示到用户主动关掉（失败必须可见，不因下一次成功刷新而静默消失）。
    func clearError() { lastError = nil }

    /// SPEC §19 B2 延迟埋点（本机视角）：提交 → 本机弹通知、决定 → 本机收起。
    /// 跨设备时含两台设备的时钟差，只作观察值，不是保证值。
    func latency(for id: UUID) -> (notify: TimeInterval?, withdraw: TimeInterval?) {
        guard let p = proposals.first(where: { $0.id == id }) else { return (nil, nil) }
        let mine = ledger.records().filter { $0.proposalId == id && $0.deviceId == deviceId }
        let notified = mine.first { $0.event == "notified" }?.at
        let withdrawn = mine.first { $0.event == "withdrawn" }?.at
        return (notified.map { $0.timeIntervalSince(p.createdAt) },
                withdrawn.flatMap { w in p.decidedAt.map { w.timeIntervalSince($0) } })
    }

    func notificationPermission() async -> Bool? { await notifier.permission() }
    func requestNotificationPermission() async -> Bool { await notifier.requestPermission() }

    var pending: [Proposal] { proposals.filter { $0.effectiveState(at: now()) == .pending } }

    // MARK: 发起

    /// 提交前准备（严格校验 + 补全基线版本 + 由 App 依据真实数据算「改动前 → 改动后」）。
    /// 抛错 = 这份提案不能提交，错误里带给人看的原因（桥接据此把文件移进 rejected/）。
    /// 对同一份已准备好的草稿再调一次结果不变（幂等），submit 内部也会调。
    /// W10：备选方案逐个同样 prepare（严格校验 + App 算改动前后）；越级理由必须写明；各方案须能在同一台设备执行。
    func prepare(_ draft: ProposalDraft) async throws -> ProposalDraft {
        var draft = draft
        if draft.id == nil { draft.id = UUID() }
        try ProposalLifetime.check(draft.lifetime)   // W11：只守技术稳定窗口（1 分钟–7 天），多久合适由发起者判断
        if let raw = draft.escalation {
            let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { throw ProposalExecutionError.invalid("越级提案必须写明理由（为什么确有必要动你的东西或你亲手放的位置）") }
            draft.escalation = reason
        }
        if let raw = draft.primaryLabel {
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.count <= ProposalDraft.optionLabelLimit else { throw ProposalExecutionError.invalid("方案名字不超过 \(ProposalDraft.optionLabelLimit) 字") }
            draft.primaryLabel = label.isEmpty ? nil : label
        }
        guard draft.alternatives.count <= Proposal.maxAlternatives else {
            throw ProposalExecutionError.invalid("备选方案最多 \(Proposal.maxAlternatives) 个（这次 \(draft.alternatives.count) 个）")
        }
        let prepared = try await executor.prepare(draft.action, escalation: draft.escalation)
        draft.action = prepared.action
        if let changes = prepared.changes { draft.changes = changes }
        // W11：可调参数——绑定必须是这种动作有的字段，默认值 = 准备好的动作里写的那个。
        draft.parameters = try ProposalParameterRules.normalize(draft.parameters, for: draft.action)
        var required = prepared.requiredDeviceId
        var seen = [draft.action]
        for (i, alt) in draft.alternatives.enumerated() {
            let label = alt.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= ProposalDraft.optionLabelLimit else {
                throw ProposalExecutionError.invalid("备选方案 \(i + 1) 要有名字（不超过 \(ProposalDraft.optionLabelLimit) 字）")
            }
            let p: PreparedProposalAction
            do { p = try await executor.prepare(alt.action, escalation: draft.escalation) } catch {
                throw ProposalExecutionError.invalid("备选方案 \(i + 1)「\(label)」：\(error.localizedDescription)")
            }
            guard !seen.contains(p.action) else { throw ProposalExecutionError.invalid("备选方案 \(i + 1)「\(label)」和前面的方案完全一样") }
            seen.append(p.action)
            let params = try ProposalParameterRules.normalize(alt.parameters ?? [], for: p.action, where: "备选方案 \(i + 1) 的参数")
            if let r = p.requiredDeviceId {
                if let req = required, req != r { throw ProposalExecutionError.invalid("各个方案必须能在同一台设备上执行（备选方案 \(i + 1) 要求的设备不同）") }
                required = r
            }
            draft.alternatives[i] = ProposalAlternative(label: label, action: p.action, changes: p.changes ?? alt.changes,
                                                        parameters: params.isEmpty ? nil : params)
        }
        if seen.contains(where: \.touchesRealData) { draft.experiment = false }
        draft.autoPassBlocker = await executor.autoPassBlocker(draft.action)   // W32d：依据真实数据（图钉等）
        if let required {
            if let target = draft.targetDeviceId, target != required {
                throw ProposalExecutionError.invalid("这项改动只能在读取状态的那台设备执行（指定设备与之不符）")
            }
            draft.targetDeviceId = required
        }
        return draft
    }

    @discardableResult
    func submit(_ draftInput: ProposalDraft) async -> Proposal? {
        let at = now()
        let draft: ProposalDraft
        do { draft = try await prepare(draftInput) } catch {
            let message = "提案未提交：\(error.localizedDescription)"
            lastError = message
            DevLog.shared.error("多端审批", message)
            ledger.append(OperationRecord(at: at, actor: draftInput.origin, actorLabel: draftInput.originLabel, deviceId: deviceId,
                                          event: "rejected", proposalId: draftInput.id, parentId: draftInput.parentId,
                                          parentRef: draftInput.parentRef, detail: "\(draftInput.title)：\(error.localizedDescription)"))
            return nil
        }
        var proposal = Proposal(id: draft.id ?? UUID(), createdAt: at, expiresAt: at.addingTimeInterval(draft.lifetime),
                                origin: draft.origin, originLabel: draft.originLabel, originDeviceId: deviceId,
                                parentId: draft.parentId, targetDeviceId: draft.targetDeviceId,
                                title: draft.title, changes: draft.changes, reason: draft.reason,
                                action: draft.action, experiment: draft.experiment, state: .pending, parentRef: draft.parentRef)
        proposal.escalation = draft.escalation
        proposal.primaryLabel = draft.primaryLabel
        proposal.alternatives = draft.alternatives.isEmpty ? nil : draft.alternatives
        proposal.parameters = draft.parameters.isEmpty ? nil : draft.parameters
        proposal.agentKey = draft.agentKey   // W20：哪种实现提的（追溯用）
        proposal.askFirst = draft.askFirst ? true : nil   // W32d
        proposal.autoPassBlocker = draft.autoPassBlocker
        // W10 分层预授权（A3a）：规则命中「直接做 / 做完告诉你 / 不做」时，提案建出来就带着规则的决定（原子：
        // 不会先在别的端弹「待确认」再被收起）；默认一律先问你。越级 / 动你的东西 / 删除类永远不被自动放行（PreauthPolicy）。
        let verdict = gate.verdict(for: proposal)
        if verdict.route != .ask, let rule = verdict.rule {
            proposal.preauth = ProposalPreauthStamp(ruleId: rule.id, effect: rule.effect, ruleLabel: rule.label)
            proposal.state = verdict.route == .decline ? .declined : .approved
            proposal.decidedAt = at; proposal.decidedByDeviceId = deviceId
        }
        do {
            try await transport.submit(proposal)
            record(proposal.origin, proposal.originLabel, "submitted", proposal, "发起：\(proposal.title)")
            if let stamp = proposal.preauth {
                record(.system, "预授权规则", "decided", proposal, "\(verdict.note)（规则 \(stamp.ruleId.uuidString.prefix(8))，在 \(deviceLabel)）")
                DevLog.shared.info("预授权规则", "「\(proposal.title)」\(verdict.note)")
            } else if verdict.rule != nil {
                record(.system, "预授权闸门", "gate.ask", proposal, verdict.note)   // 有规则命中但仍先问你（如保护类）：留底讲得出为什么
            }
            await refresh()
            return proposals.first { $0.id == proposal.id } ?? proposal
        } catch {
            fail("提交提案失败", error, proposal)
            return nil
        }
    }

    // MARK: 同步（推送唤醒 / 回到前台 / 轮询时调用）

    func refresh() async {
        do {
            proposals = try await transport.fetchRecent()
        } catch {
            fail("读取提案失败", error, nil)
            return
        }
        DevLog.shared.resolve(source: "多端审批")   // W16：拉取成功 = 之前的短暂失败自动消除
        // W21：提案已有结论（别处处理 / 过期）而这里还开着「回一句 / 调数值」→ 没做完
        let t = now()
        for p in proposals where p.effectiveState(at: t).isClosed { abandonOpenAttempts(p.id) }
        await reconcileNotifications()
        for p in proposals where p.state == .approved && p.isExecutor(deviceId) && !executing.contains(p.id) {
            if let pending = unreported[p.id] { await reportApplied(p, note: pending.note, undo: pending.undo) }   // 已做完：只补回报
            else { await execute(p) }
        }
        didRefresh?()
    }

    /// W20：每次成功刷新后（组装点接到当前智能体：内置智能体据此发 proposal_resolved）。
    var didRefresh: (() -> Void)?

    // MARK: 决定（通知按钮 / App 内按钮）

    /// choice = 选第几个方案（0 = 主方案；nil = 主方案）。remember = 审批时顺手「以后同类…」：本次决定生效后写一条预授权规则。
    /// values（W11）= 你在卡片上调好的参数值：批准前对套回新值的动作**再完整校验一次**（不只信卡片上的预览），
    /// 不合法就不批准、原因可见；nil = 按默认（通知上的「按默认批准」）。
    @discardableResult
    func decide(_ id: UUID, _ decision: ProposalDecision, choice: Int? = nil,
                values: [String: ProposalParameterValue]? = nil,
                remember: (scope: PreauthScope, effect: PreauthEffect)? = nil,
                actor: ProposalOrigin = .user, actorLabel: String = "你") async -> ProposalDecisionOutcome? {
        var tuning: ProposalTuning?
        if decision == .approve, let values {
            // 你调过的值绝不悄悄降级成默认值：本机列表里找不到这份提案就先刷新，仍找不到 = 不批准、原因可见。
            if !proposals.contains(where: { $0.id == id }) { await refresh() }
            guard let p = proposals.first(where: { $0.id == id }) else {
                lastError = "没有批准：找不到这份提案（可能还没同步过来），你调的数值没有提交"
                DevLog.shared.warn("多端审批", lastError!)
                return nil
            }
            let index = choice ?? 0
            if p.options.indices.contains(index), !p.options[index].parameters.isEmpty {
                do {
                    let checked = try await checkTuning(p, option: index, values: values)
                    tuning = ProposalTuning(values: values, action: checked.action, changes: checked.changes ?? p.options[index].changes)
                } catch {
                    lastError = "没有批准：\(error.localizedDescription)"
                    DevLog.shared.warn("多端审批", lastError!)
                    record(actor, actorLabel, "tune.invalid", p, "你调的数值不合法，未批准：\(error.localizedDescription)")
                    return nil
                }
            }
        }
        do {
            let outcome = try await transport.decide(id: id, decision: decision, choice: choice, tuning: tuning, deviceId: deviceId, at: now())
            switch outcome {
            case let .won(p):
                let picked = p.hasAlternatives && decision == .approve ? "，选了【\(p.chosen.index + 1). \(p.chosen.label)】" : ""
                let tuned = p.tuningSummary.isEmpty ? "" : "；" + p.tuningSummary.joined(separator: "，")   // W11：记下最终值、改没改默认
                record(actor, actorLabel, "decided", p, "\(decision == .approve ? "同意" : "拒绝")\(picked)（在 \(deviceLabel)）\(tuned)")
                if decision == .approve, tuning != nil { usage.complete(.proposalTune, key: Self.tuneKey(id, choice ?? 0)) }
                abandonOpenAttempts(id)
                if let remember { self.remember(p, scope: remember.scope, effect: remember.effect) }
            case let .alreadyClosed(p):
                record(actor, actorLabel, "lost", p, "已被处理：\(p.effectiveState(at: now()).label)；本次点击不重复执行")
            }
            await refresh()
            return outcome
        } catch {
            usage.record(decision == .approve ? .proposalApprove : .proposalDecline, .failed)
            fail("提交决定失败", error, proposals.first { $0.id == id })
            return nil
        }
    }

    // MARK: 可调参数（W11）

    /// 你在卡片上调的值 → 套回选中方案的动作 → 重新走同一套校验；返回将要执行的动作与依据真实数据重算的「改动前 → 改动后」。
    /// 抛错 = 这个值不合法（错误里是给人看的原因）。卡片实时预览和批准前都调它。不夹范围、不悄悄改值。
    func checkTuning(_ p: Proposal, option index: Int, values: [String: ProposalParameterValue]) async throws -> PreparedProposalAction {
        let options = p.options
        guard options.indices.contains(index) else { throw ProposalExecutionError.invalid("没有第 \(index + 1) 个方案") }
        let o = options[index]
        guard !o.parameters.isEmpty else { throw ProposalExecutionError.invalid("这个方案没有可调的数值") }
        let action = try ProposalParameterRules.apply(values, o.parameters, to: o.action)
        return try await executor.recheck(action, escalation: p.escalation, executingDeviceId: p.targetDeviceId)
    }

    // MARK: 预授权规则（W10，SPEC §19 A3a）

    /// 这份提案能不能「以后同类…」（nil = 可以）。
    func cannotRemember(_ p: Proposal, effect: PreauthEffect) -> String? {
        guard rules != nil else { return "这台设备没有接入预授权规则" }
        return PreauthPolicy.cannotRemember(p, effect: effect)
    }

    /// 从一份提案生成（或改写）一条规则：匹配它的发起者 + 你选中方案的那一类改动 + 范围。保护类（越级/动你的东西/删除）不能放行。
    @discardableResult
    func remember(_ p: Proposal, scope: PreauthScope, effect: PreauthEffect) -> PreauthRule? {
        if let why = cannotRemember(p, effect: effect) {
            lastError = "没有记成规则：\(why)"
            DevLog.shared.warn("预授权规则", lastError!)
            record(.user, "你", "rule.refused", p, lastError!)
            return nil
        }
        guard let rules else { return nil }
        let rule = rules.upsert(origin: p.origin, action: p.executedAction, scope: scope, effect: effect,
                                deviceId: deviceId, sourceProposalId: p.id)
        ledger.append(OperationRecord(at: now(), actor: .user, actorLabel: "你", deviceId: deviceId, event: "rule.added",
                                      proposalId: p.id, parentId: p.parentId, parentRef: p.parentRef,
                                      detail: "以后同类：\(rule.label)", ruleId: rule.id))
        return rule
    }

    func removeRule(_ id: UUID) {
        guard let rules, let rule = rules.rules.first(where: { $0.id == id }) else { return }
        rules.remove(id)
        ledger.append(OperationRecord(at: now(), actor: .user, actorLabel: "你", deviceId: deviceId, event: "rule.removed",
                                      proposalId: rule.sourceProposalId, parentId: nil, detail: "删除规则：\(rule.label)", ruleId: id))
    }

    func setRuleEffect(_ id: UUID, _ effect: PreauthEffect) {
        guard let rules, let rule = rules.rules.first(where: { $0.id == id }), rule.effect != effect else { return }
        rules.setEffect(id, effect)
        ledger.append(OperationRecord(at: now(), actor: .user, actorLabel: "你", deviceId: deviceId, event: "rule.changed",
                                      proposalId: rule.sourceProposalId, parentId: nil,
                                      detail: "规则改为「\(effect.label)」：\(rule.label)", ruleId: id))
    }

    // MARK: 第三种回应：回一句话（W10）

    /// 你对某个提案用自然语言回了一句（如「改成 9 点吧」）：提案停止等待（不执行、不算拒绝，首个回应生效），
    /// 这句话作为对话消息转给智能体（关联提案 id），由它撤回并重新提案。提案已被别的端处理时，这句话照样转交。
    /// 返回这句话是否已发出（存进 iCloud）；失败原因可见（lastError + 留底 + DevLog）。
    @discardableResult
    func reply(_ id: UUID, text raw: String) async -> Bool {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !text.isEmpty else { return false }
        let reply = ProposalUserReply(text: text, at: now(), deviceId: deviceId)
        let target: Proposal
        // W21：卡片上展开过输入框的这句 = 卡片「回一句」（通知上的直接回复另记）；先关掉开头，免得下面 refresh 把它算成没做完
        let fromCard = usage.end(.proposalReply, key: id.uuidString)
        do {
            switch try await transport.respond(id: id, reply: reply, at: now()) {
            case let .won(p):
                target = p
                record(.user, "你", "replied", p, "回了一句（在 \(deviceLabel)）：\(text.prefix(60))；提案停止等待，转给智能体")
            case let .alreadyClosed(p):
                target = p
                record(.user, "你", "lost", p, "回一句时提案已被处理（\(p.effectiveState(at: now()).label)）；你的话照常转给智能体")
            }
        } catch {
            usage.record(.proposalReply, .failed)
            if fromCard { usage.begin(.proposalReply, key: id.uuidString) }   // 没发出去：输入框还开着，开头照旧算
            fail("回复提案失败", error, proposals.first { $0.id == id })
            return false
        }
        await refresh()
        guard let forwardReply else {
            lastError = "提案已停止等待，但这台设备没有接入对话，你的话没转给智能体"
            DevLog.shared.error("多端审批", lastError!)
            return false
        }
        guard await forwardReply(target, text) else {
            lastError = "提案已停止等待，但你的话没发出去：到对话页重试（已留在本机）"
            DevLog.shared.error("多端审批", lastError!)
            record(.system, "BetterCalendar（\(deviceLabel)）", "reply.forward.failed", target, lastError!)
            usage.record(.proposalReply, .failed)
            return false
        }
        if fromCard { usage.complete(.proposalReply, key: id.uuidString) }
        return true
    }

    // MARK: 撤销（SPEC §19 A3 后半）

    /// 不能撤销时的原因；nil = 可以撤销（面板据此显示「撤销」按钮或一行说明）。
    func undoBlockedReason(_ p: Proposal) -> String? {
        guard p.state == .applied else { return "只有已完成的改动才能撤销" }
        if p.undoneAt != nil { return "已撤销" }
        guard p.undoAction != nil else { return p.undoUnavailableReason ?? (p.action.touchesRealData ? "这项改动不支持撤销" : "测试改动没有可撤销的内容") }
        if let device = p.undoDeviceId, device != deviceId { return "只能在执行它的那台设备上撤销（计时是设备本地状态）" }
        return nil
    }

    func canUndo(_ p: Proposal) -> Bool { undoBlockedReason(p) == nil }

    /// 撤销 = 一条来源为「你」的操作：执行逆操作（目标版本已变则拒绝）→ 记下已撤销 → 写操作留底。
    /// 返回是否撤销成功；失败原因可见（lastError + 留底 undo.failed + DevLog）。
    @discardableResult
    func undo(_ id: UUID, actorLabel: String = "你") async -> Bool {
        if let latest = try? await transport.fetchRecent() { proposals = latest }
        guard let p = proposals.first(where: { $0.id == id }) else {
            undoFailed(nil, actorLabel, "找不到这份提案"); return false
        }
        if let reason = undoBlockedReason(p) { undoFailed(p, actorLabel, reason); return false }
        guard !executing.contains(p.id), let action = p.undoAction else {
            undoFailed(p, actorLabel, "这项改动正在处理中，请稍后再试"); return false
        }
        executing.insert(p.id); defer { executing.remove(p.id) }
        do {
            let outcome = try await executor.perform(action)
            let marked = try await transport.markUndone(id: p.id, deviceId: deviceId, note: outcome.note, at: now())
            record(.user, actorLabel, "undone", marked, "撤销「\(p.title)」（在 \(deviceLabel)）：\(outcome.note)")
            usage.record(.proposalApprove, .undone)   // W21：批准后的结果被撤销（常被撤销 = 结果不合预期）
            if let latest = try? await transport.fetchRecent() { proposals = latest }
            return true
        } catch {
            undoFailed(p, actorLabel, error.localizedDescription)
            return false
        }
    }

    private func undoFailed(_ p: Proposal?, _ actorLabel: String, _ reason: String) {
        let message = "撤销失败：\(reason)"
        lastError = message
        DevLog.shared.error("多端审批", message)
        record(.user, actorLabel, "undo.failed", p, message)
        usage.record(.proposalUndo, .failed)
    }

    // MARK: 内部

    private func execute(_ p: Proposal) async {
        executing.insert(p.id); defer { executing.remove(p.id) }
        do {
            DevLog.shared.info("多端审批", "执行「\(p.title)」（\(p.executedAction.kind)）…")
            let outcome = try await executor.execute(p)
            DevLog.shared.info("多端审批", "已执行「\(p.title)」，回报中：\(outcome.note.prefix(80))")
            await reportApplied(p, note: outcome.note, undo: outcome.undo)
            return
        } catch {
            let note = "执行失败：\(error.localizedDescription)"
            if let failed = try? await transport.report(id: p.id, state: .failed, note: note, at: now()) {
                record(.system, "BetterCalendar（\(deviceLabel)）", "failed", failed, note)
            }
            fail("执行提案失败", error, p)
        }
        if let latest = try? await transport.fetchRecent() { proposals = latest }
        await reconcileNotifications()
    }

    /// 执行成功后的回报：超时 + 重试；仍失败 → 记进 unreported（持久化），之后每次刷新只补回报、不再执行，失败可见。
    private func reportApplied(_ p: Proposal, note: String, undo: ProposalUndoInfo?) async {
        executing.insert(p.id); defer { executing.remove(p.id) }
        let transport = self.transport, id = p.id, at = now()
        var lastError: Error?
        for attempt in 1...Self.reportAttempts {
            do {
                let done = try await Self.withTimeout(Self.reportTimeout) {
                    try await transport.report(id: id, state: .applied, note: note, undo: undo, at: at)
                }
                if unreported.removeValue(forKey: p.id) != nil { saveUnreported(); DevLog.shared.info("多端审批", "「\(p.title)」的「已完成」已补报") }
                record(.system, "BetterCalendar（\(deviceLabel)）", "applied", done, "[\(p.executedAction.kind)] " + note)
                if let latest = try? await transport.fetchRecent() { proposals = latest }
                await reconcileNotifications()
                return
            } catch let e as ProposalTransportError {
                // 状态机拒绝（例如另一端已撤销 / 已回报）：不是网络问题，不再重试，也不留账
                lastError = e
                if case .invalidTransition = e { break }
            } catch {
                lastError = error
                if attempt < Self.reportAttempts { try? await Task.sleep(for: .seconds(Double(attempt) * 2)) }
            }
        }
        if unreported[p.id] == nil { unreported[p.id] = PendingReport(note: note, undo: undo, at: at); saveUnreported() }
        let message = "「\(p.title)」已执行成功，但「已完成」没回报到 iCloud（\(lastError?.localizedDescription ?? "未知")）；会在下次刷新时补报，不会重复执行"
        self.lastError = message
        DevLog.shared.error("多端审批", message)
        record(.system, "BetterCalendar（\(deviceLabel)）", "report.pending", p, message)
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ReportTimeout(seconds: seconds)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
    nonisolated struct ReportTimeout: LocalizedError {
        var seconds: TimeInterval
        var errorDescription: String? { "回报超过 \(Int(seconds)) 秒没有返回" }
    }

    /// 待决定的都挂一条通知；不再待决定的都收起（B2：一端决定后其他端收起）。
    private func reconcileNotifications() async {
        let shown = await notifier.shownIds()
        let open = Set(pending.map(\.id))
        for p in pending where !shown.contains(p.id) {
            await notifier.show(p)
            record(.system, "BetterCalendar（\(deviceLabel)）", "notified", p, "已在本机显示审批通知")
        }
        for id in shown where !open.contains(id) {
            await notifier.withdraw(id)
            if let p = proposals.first(where: { $0.id == id }) {
                record(.system, "BetterCalendar（\(deviceLabel)）", "withdrawn", p, "已收起：\(p.effectiveState(at: now()).label)")
            }
        }
        // W10：预授权规则自动执行的结果——「做完告诉你」的发一条结果通知（可撤销）；自动执行失败的不论哪种规则都告诉你
        //（失败必须可见）。每台设备各一次；撤销后收起。
        let cutoff = now().addingTimeInterval(-Self.informWindow)
        var informedChanged = false
        for p in proposals where Self.shouldInform(p) && !informedHere.contains(p.id) && (p.appliedAt ?? p.createdAt) > cutoff {
            await notifier.showResult(p)
            informedHere.insert(p.id); informedChanged = true
            record(.system, "BetterCalendar（\(deviceLabel)）", "informed", p,
                   p.state == .failed ? "按规则自动执行没成功，已通知你：\(p.resultNote ?? "")" : "按规则自动完成，已通知你（可撤销）")
        }
        if informedChanged { informDefaults?.set(Array(informedHere.map(\.uuidString).suffix(300)), forKey: Self.informedKey) }
        for id in await notifier.shownResultIds() {
            if proposals.first(where: { $0.id == id })?.undoneAt != nil { await notifier.withdrawResult(id) }
        }
        await afterNotificationsReconciled?(proposals)
    }

    /// 要不要发结果通知：规则代你放行的提案，「做完告诉你」完成时 / 任何放行规则执行失败时。
    nonisolated static func shouldInform(_ p: Proposal) -> Bool {
        guard let stamp = p.preauth, stamp.effect.autoApplies else { return false }
        if p.state == .failed { return true }
        return p.state == .applied && stamp.effect == .allowAndInform && p.undoneAt == nil
    }

    private func record(_ actor: ProposalOrigin, _ label: String, _ event: String, _ p: Proposal?, _ detail: String) {
        ledger.append(OperationRecord(at: now(), actor: actor, actorLabel: label, deviceId: deviceId, event: event,
                                      proposalId: p?.id, parentId: p?.parentId, parentRef: p?.parentRef, detail: detail,
                                      ruleId: p?.preauth?.ruleId))
    }

    private func fail(_ what: String, _ error: Error, _ p: Proposal?) {
        let message = "\(what)：\(error.localizedDescription)"
        lastError = message
        DevLog.shared.error("多端审批", message)
        record(.system, "BetterCalendar（\(deviceLabel)）", "error", p, message)
    }
}
