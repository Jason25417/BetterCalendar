//
//  PlanDriftMonitor.swift
//  BetterCalendar
//
//  W51（0.80，Jason 2026-10-27）：「智能体的自动 reflow 从来没启用过」的根因是**没有触发器**——RescheduleService.continuousReflow
//  自 0.23 A 起零调用方；哨兵只会叫智能体「到点提醒」（10 月 2033 次「开始时间已过」判断，0 份顺延提案）。这里补上本地的漂移监视器：
//    每 20 秒看一眼今天的计划 + 执行进展（本地、不上云、不花钱）：
//    · 一块弹性块开始时间已过 ≥10 分钟，没开始计时、没有实际记录 → 漂了（notStarted）；
//    · 正在计时的块超过计划结束 ≥10 分钟 → 后面的被压住（overrun）。
//    → 本地算顺延（PlanDriftRules.reflow）：弹性块**保持顺序、保持时长**，从现在起往后挪；固定安排 / 图钉 / 正在做的（按剩余时长估）/
//      你的日历是障碍，弹性块绕到它后面——算法 = PlanEditRules.cascadeMoves，与智能体提案的 cascade: true 同一套；
//    → 走审批中心提交一份 origin=.system 的 moveBlocks 提案，专用规则 PreauthPolicy.autoReflowRule 直接执行
//      （与智能体提案同一条执行 / 回报 / 撤销路径，审批记录里可查）；
//    → 发一条 App 的主动消息（打扰规则照旧）：按钮「我在做」= 撤回顺延 + 从那块原来的开始时间起计时——
//      这正是「没计时就不知道你在做」的兜底（W49 想用活动签名自动判断，已回退）；
//    → 只有**推过收工线**、或**同一块今天第二次漂**、或**放不下**时才发 plan_reflowed 叫智能体开口；其余情况智能体不说话。
//  不做的：同一块 10 分钟内不再推；每天最多 12 次；松散日不推；数据同步存疑（dataSync caution）不推；只有在场设备推
//  （同哨兵的 presenceGate，Mac 与 iPhone 不会各推一遍）；放不下（推过凌晨 4 点 / 越截止 / 超 20 块）→ 不改计划、只叫智能体。
//  开关 plan.autoReflow.enabled：W17 约定新功能 Dev 开、日用关（随设置同步）。所有跳过 / 失败原因可见（面板 lastSkipReason + DevLog）。
//

import Foundation
import Observation

nonisolated enum AutoReflowSettings {
    static let key = "plan.autoReflow.enabled"
    static func enabled(in d: UserDefaults = .standard) -> Bool { ExperimentDefaults.newFeature(key, in: d) }
    static var enabled: Bool {
        get { enabled() }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    /// 弹性块开始时间过了多久没开始算「漂了」；正在计时的超过计划结束多久算「压住后面的」。
    static let lateMinutes = 10
    static let overrunMinutes = 10
    /// 同一块两次顺延至少隔多久；一天最多顺延几次（稳定性上限，不是产品规则）。
    static let perBlockCooldownMinutes = 10
    static let dailyCap = 12
}

/// 纯函数（可单测）：漂没漂 + 怎么顺延。
enum PlanDriftRules {
    enum Drift: Equatable, Sendable {
        case notStarted(id: UUID, title: String, minutesLate: Int)
        case overrun(id: UUID, title: String, minutesOver: Int)

        var id: UUID { switch self { case let .notStarted(id, _, _), let .overrun(id, _, _): id } }
        var title: String { switch self { case let .notStarted(_, t, _), let .overrun(_, t, _): t } }
        var kind: String { switch self { case .notStarted: "notStarted"; case .overrun: "overrun" } }
    }

    struct Input {
        /// 今天（逻辑日）的全部计划块。
        var blocks: [ScheduledBlock]
        var now: Date
        /// 已完成 / 后台并行中（不挪、不当障碍）。
        var settledIDs: Set<UUID> = []
        /// 前台正在做的块的活预报（不挪；它此刻占着的时间段是障碍）。
        var active: ActivePrediction? = nil
        /// 你的日历（已占用，只读）。
        var occupied: [PlanEditRules.Occupied] = []
    }

    struct Plan: Equatable {
        var moves: [ProposalBlockMove]
        /// 顺延后结束时间越过收工线 + 宽限的块（原本没越的）——交给智能体问你怎么办。
        var beyondWindDown: [UUID]
    }

    /// 此刻漂了的那块（nil = 一切按计划）。正在计时的超时优先；其余取开始最早的那块。
    static func detect(_ i: Input, lateMinutes: Int = AutoReflowSettings.lateMinutes,
                       overrunMinutes: Int = AutoReflowSettings.overrunMinutes) -> Drift? {
        if let a = i.active, let b = i.blocks.first(where: { $0.id == a.id }) {
            let over = i.now.timeIntervalSince(b.end) / 60
            if over >= Double(overrunMinutes) { return .overrun(id: b.id, title: b.title, minutesOver: Int(over)) }
        }
        let late = i.blocks.filter {
            !$0.isFixed && !$0.isPinned(at: i.now) && !i.settledIDs.contains($0.id) && $0.id != i.active?.id
                && $0.end > i.now && $0.start <= i.now.addingTimeInterval(-Double(lateMinutes) * 60)
        }.sorted { $0.start < $1.start }
        guard let b = late.first else { return nil }
        return .notStarted(id: b.id, title: b.title, minutesLate: Int(i.now.timeIntervalSince(b.start) / 60))
    }

    /// 从现在起的顺延：保持顺序、保持时长；障碍 = 过去的时间、正在做的（到预报结束）、固定安排、图钉、你的日历。
    /// nil = 没有要挪的，或放不下（推过凌晨 4 点 / 越截止 / 超过 20 块）。
    static func reflow(_ i: Input, windDown: Date) -> Plan? {
        let from = ceilToMinute(i.now)
        let label = DayContext.logicalStartOfDay(i.now)
        var ctx = PlanEditRules.Context(blocks: i.blocks, now: i.now, window: DayContext.logicalWindow(forLabel: label),
                                        settledIDs: i.settledIDs.subtracting(i.active.map { [$0.id] } ?? []),
                                        active: i.active.map { ($0.id, $0.start, $0.end) })
        ctx.occupied = i.occupied
        var obstacles: [PlanEditRules.Obstacle] = [("现在之前", label, from, true, false, nil)]
        if let a = i.active, let b = i.blocks.first(where: { $0.id == a.id }) {
            obstacles.append((b.title, a.start, max(a.end, from), true, false, nil))
        }
        for b in i.blocks where b.isFixed && b.id != i.active?.id && !i.settledIDs.contains(b.id) && b.end > i.now {
            obstacles.append((b.title, b.start, b.end, true, false, nil))
        }
        for o in i.occupied { obstacles.append((o.title, o.start, o.end, true, true, o.linkedBlockID)) }
        guard let moves = PlanEditRules.cascadeMoves(placed: [], obstacles: obstacles, changedIDs: [], in: ctx) else { return nil }
        let line = windDown.addingTimeInterval(Double(WorkHoursSettings.graceMinutes) * 60)
        return Plan(moves: moves.map { ProposalBlockMove(id: $0.block.id, start: $0.start, end: $0.end, expectedRevision: nil) },
                    beyondWindDown: moves.filter { $0.end > line && $0.block.end <= line }.map(\.block.id))
    }

    static func ceilToMinute(_ d: Date) -> Date {
        let t = d.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / 60).rounded(.up) * 60)
    }

    /// 主动消息的 parentRef：reflow:<提案 id>:<notStarted|overrun>。
    static func messageRef(proposalId: UUID, drift: Drift) -> String { "reflow:\(proposalId.uuidString):\(drift.kind)" }
    static func parseMessageRef(_ ref: String?) -> (proposalId: UUID, kind: String)? {
        guard let ref, ref.hasPrefix("reflow:") else { return nil }
        let parts = ref.split(separator: ":").map(String.init)
        guard parts.count == 3, let id = UUID(uuidString: parts[1]) else { return nil }
        return (id, parts[2])
    }
}

@MainActor @Observable final class PlanDriftMonitor {
    enum Outcome: Equatable, Sendable {
        case disabled
        case skipped(String)
        case idle
        case reflowed(proposalId: UUID, moved: Int)
        case couldNotFit(String)
        case failed(String)
    }

    /// 本机账本（不同步）：今天推了几次、每块上次推 / 今天漂了几次。
    struct Ledger: Codable, Equatable {
        var day = ""
        var count = 0
        var lastByBlock: [String: Date] = [:]
        var driftsByBlock: [String: Int] = [:]
    }
    static let ledgerKey = "plan.autoReflow.ledger.v1"

    // 依赖（组装点注入；测试各自注入假实现）
    private let planStore: any PlanReading
    private let defaults: UserDefaults
    var now: () -> Date
    weak var progress: (any ExecutionProgressReading)?
    /// 你的日历（已占用）；nil = 不接（测试）。读失败 = 这一拍不推、明说。
    var occupiedEvents: ((DateInterval) async throws -> [SystemCalendarEvent])?
    var enabled: () -> Bool = { AutoReflowSettings.enabled }
    var isLooseDay: (Date) -> Bool = { _ in false }
    /// 这台此刻不该推的原因（别的设备在场）；nil = 推。与哨兵同一套。
    var presenceGate: () -> String? = { nil }
    var syncCaution: (Date) async -> String? = { _ in nil }
    var windDown: (Date) -> Date = { WorkHoursSettings.windDownDate(for: $0) }
    /// 审批中心：提交（自动顺延规则直接执行）/ 查 / 撤销。
    var submit: (ProposalDraft) async -> Proposal? = { _ in nil }
    var proposal: (UUID) -> Proposal? = { _ in nil }
    var undo: (UUID) async -> Bool = { _ in false }
    /// 主动消息（打扰规则照旧）：回执 + 「我在做」入口。
    var notify: (AgentMessageDraft) async -> AgentMessage? = { _ in nil }
    var message: (UUID) -> AgentMessage? = { _ in nil }
    var acknowledge: (UUID) async -> Void = { _ in }
    /// 叫醒智能体（只在推过收工线 / 二次漂 / 放不下时）。
    var emit: (_ kind: String, _ summary: String, _ payload: [String: Any]) -> Void = { _, _, _ in }
    /// 顺延写入后（哨兵的计划缓存要作废，否则它继续对推走的块报「开始时间已过」）。
    var afterApplied: () -> Void = {}
    /// 「我在做」：从那块原来的开始时间起计时。
    var startTimer: (_ blockId: UUID, _ at: Date) async throws -> Void = { _, _ in }

    private(set) var ledger: Ledger
    private(set) var lastTickAt: Date?
    private(set) var lastOutcome: Outcome?
    private(set) var lastError: String?
    /// 「我在做」/ 撤回后的一句结果（按提案 id；回执气泡下面显示）。
    private(set) var notes: [UUID: String] = [:]
    private var loop: Task<Void, Never>?
    private var ticking = false

    init(planStore: any PlanReading, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.planStore = planStore; self.defaults = defaults; self.now = now
        ledger = (defaults.data(forKey: Self.ledgerKey)).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()
    }

    func start(every seconds: Double = 20) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.tick()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    // MARK: 一拍

    @discardableResult
    func tick() async -> Outcome {
        guard !ticking else { return lastOutcome ?? .idle }
        ticking = true; defer { ticking = false }
        let t = now()
        lastTickAt = t
        let outcome = await evaluate(at: t)
        lastOutcome = outcome
        return outcome
    }

    private func evaluate(at t: Date) async -> Outcome {
        guard enabled() else { return .disabled }
        rollDay(t)
        if let why = presenceGate() { return .skipped(why) }
        if isLooseDay(t) { return .skipped("今天是松散日，不自动顺延") }
        let label = DayContext.logicalStartOfDay(t)
        let blocks: [ScheduledBlock]
        do { blocks = try planStore.plannedBlocks(on: label) } catch {
            return fail("读今天的计划失败：\(error.localizedDescription)")
        }
        var input = PlanDriftRules.Input(blocks: blocks, now: t, settledIDs: progress?.settledPlannedIDs ?? [], active: progress?.activePrediction)
        guard let drift = PlanDriftRules.detect(input) else { return .idle }
        // 同一块 10 分钟内只推一次；一天上限
        if let last = ledger.lastByBlock[drift.id.uuidString], t.timeIntervalSince(last) < Double(AutoReflowSettings.perBlockCooldownMinutes) * 60 {
            return .skipped("「\(drift.title)」\(AutoReflowSettings.perBlockCooldownMinutes) 分钟内刚顺延过")
        }
        if ledger.count >= AutoReflowSettings.dailyCap { return skip("今天已自动顺延 \(ledger.count) 次，到上限了（稳定性上限）") }
        if let caution = await syncCaution(t) { return skip("数据可能不全，不自动顺延：\(caution)") }
        if let occupiedEvents {
            do {
                let events = try await occupiedEvents(DayContext.logicalWindow(forLabel: label))
                let busy = events.filter { !$0.isAllDay && $0.end > $0.start }
                let links = ExternalEventLinker.links(blocks: blocks, events: busy)
                input.occupied = busy.map { e in
                    PlanEditRules.Occupied(title: e.title, start: e.start, end: e.end, calendar: e.calendarTitle,
                                           linkedBlockID: links.first { $0.value == e }?.key)
                }
            } catch {
                return fail("读不到你的日历，这一拍不顺延：\(error.localizedDescription)")
            }
        }
        // 这块今天第几次漂（第二次起叫智能体问一句是不是卡住了）
        ledger.driftsByBlock[drift.id.uuidString, default: 0] += 1
        ledger.lastByBlock[drift.id.uuidString] = t
        let driftCount = ledger.driftsByBlock[drift.id.uuidString] ?? 1
        guard let plan = PlanDriftRules.reflow(input, windDown: windDown(t)) else {
            ledger.count += 1; save()
            let why = "「\(drift.title)」\(driftDescription(drift))，但后面的放不下（会推过凌晨 4 点、越截止或要挪超过 20 块）"
            DevLog.shared.warn("自动顺延", why + "：没改计划，交给智能体")
            emit("plan_reflowed", "自动顺延放不下：\(why)",
                 ["applied": false, "reason": why, "blockId": drift.id.uuidString, "title": drift.title, "kind": drift.kind,
                  "driftCountToday": driftCount])
            return .couldNotFit(why)
        }
        guard !plan.moves.isEmpty else { return .idle }
        ledger.count += 1; save()
        let hm = DateFormatter(); hm.locale = Locale(identifier: "en_US_POSIX"); hm.dateFormat = "HH:mm"
        let from = PlanDriftRules.ceilToMinute(t)
        let reason: String
        switch drift {
        case let .notStarted(_, title, late):
            reason = "「\(title)」开始时间已过 \(late) 分钟，没开始计时也没有实际记录 → 从 \(hm.string(from: from)) 起按原顺序顺延，各块时长不变"
        case let .overrun(_, title, over):
            reason = "「\(title)」的计时已超过计划结束 \(over) 分钟 → 后面的从它预计结束起按原顺序顺延，各块时长不变"
        }
        var draft = ProposalDraft(origin: .system, originLabel: "BetterCalendar 自动顺延", title: "自动顺延 \(plan.moves.count) 块",
                                  changes: [], reason: reason, action: .moveBlocks(moves: plan.moves, isUndo: false), experiment: false,
                                  lifetime: 3600)
        draft.autoReflow = drift.id.uuidString
        guard let p = await submit(draft) else { return fail("自动顺延没提交成（\(reason)）") }
        let applied = proposal(p.id) ?? p
        guard applied.state == .applied else {
            return fail("自动顺延提案没有执行（状态 \(applied.state.label)）：\(applied.resultNote ?? "")")
        }
        afterApplied()
        let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let moved = plan.moves.compactMap { m -> [String: Any]? in
            guard let b = byID[m.id] else { return nil }
            return ["id": m.id.uuidString, "title": b.title, "from": hm.string(from: b.start), "to": hm.string(from: m.start)]
        }
        let beyond = plan.beyondWindDown.compactMap { id -> [String: Any]? in
            guard let b = byID[id], let m = plan.moves.first(where: { $0.id == id }) else { return nil }
            return ["id": id.uuidString, "title": b.title, "newEnd": hm.string(from: m.end ?? m.start)]
        }
        DevLog.shared.info("自动顺延", "已顺延 \(plan.moves.count) 块：\(reason)" + (beyond.isEmpty ? "" : "；有 \(beyond.count) 块推过了收工线"))
        // 回执 + 「我在做」入口（打扰规则由消息中心强制）
        let firstNew = plan.moves.first.map { hm.string(from: $0.start) } ?? hm.string(from: from)
        let title: String, body: String
        switch drift {
        case let .notStarted(_, name, _):
            title = "已顺延：「\(name)」→ \(firstNew)"
            body = "后面共 \(plan.moves.count) 块按原顺序往后挪了，时长不变（可撤回）。其实已经在做的话点「我在做」：从原来的开始时间起计时，顺延撤回。"
        case let .overrun(_, name, _):
            title = "已顺延：「\(name)」还在进行，后面的往后挪"
            body = "后面共 \(plan.moves.count) 块从它预计结束起按原顺序往后挪了，时长不变（可撤回）。"
        }
        _ = await notify(AgentMessageDraft(originLabel: "BetterCalendar", parentRef: PlanDriftRules.messageRef(proposalId: p.id, drift: drift),
                                           title: title, body: body, reason: reason))
        // 智能体只在该开口时被叫：推过收工线 / 同一块今天第二次漂
        if !beyond.isEmpty || driftCount >= 2 {
            let summary = !beyond.isEmpty ? "自动顺延后有 \(beyond.count) 块推过了收工线，要问 Jason 怎么办"
                                          : "「\(drift.title)」今天第 \(driftCount) 次漂（已再次顺延），像是卡住了"
            emit("plan_reflowed", summary,
                 ["applied": true, "proposalId": p.id.uuidString, "blockId": drift.id.uuidString, "title": drift.title, "kind": drift.kind,
                  "driftCountToday": driftCount, "moved": moved, "beyondWindDown": beyond, "windDown": hm.string(from: windDown(t))])
        }
        return .reflowed(proposalId: p.id, moved: plan.moves.count)
    }

    private func driftDescription(_ d: PlanDriftRules.Drift) -> String {
        switch d {
        case let .notStarted(_, _, late): "开始时间已过 \(late) 分钟没开始"
        case let .overrun(_, _, over): "计时已超过计划结束 \(over) 分钟"
        }
    }

    // MARK: 「我在做」/ 撤回

    /// 通知按钮 / 气泡按钮：撤回顺延 + 从那块原来的开始时间起计时。返回 nil = 成功；否则失败原因（也记进 notes 与 DevLog）。
    @discardableResult
    func imDoing(proposalId: UUID) async -> String? {
        guard let p = proposal(proposalId), let raw = p.autoReflow, let blockId = UUID(uuidString: raw) else {
            return note(proposalId, "找不到这次顺延的记录")
        }
        if p.undoneAt == nil, p.state == .applied {
            guard await undo(p.id) else { return note(proposalId, "撤回顺延失败（看审批记录里的原因）") }
        }
        let label = DayContext.logicalStartOfDay(now())
        guard let b = (try? planStore.plannedBlocks(on: label))?.first(where: { $0.id == blockId }) else {
            return note(proposalId, "顺延已撤回，但那块已不在今天的计划里，没开始计时")
        }
        do { try await startTimer(blockId, b.start) } catch {
            return note(proposalId, "顺延已撤回，但开始计时失败：\(error.localizedDescription)")
        }
        let hm = DateFormatter(); hm.locale = Locale(identifier: "en_US_POSIX"); hm.dateFormat = "HH:mm"
        notes[proposalId] = "已撤回顺延，「\(b.title)」从 \(hm.string(from: b.start)) 起计时"
        DevLog.shared.info("自动顺延", notes[proposalId]!)
        return nil
    }

    /// 从通知按钮来（只有消息 id）：找到对应提案再做；顺手把消息记为「好」，通知收起。
    func imDoing(messageId: UUID) async {
        guard let m = message(messageId), let ref = PlanDriftRules.parseMessageRef(m.parentRef) else {
            DevLog.shared.warn("自动顺延", "通知上的「我在做」找不到对应的顺延记录"); return
        }
        _ = await imDoing(proposalId: ref.proposalId)
        await acknowledge(messageId)
    }

    /// 气泡上的「撤回顺延」（不开始计时）。
    @discardableResult
    func undoReflow(proposalId: UUID) async -> String? {
        guard let p = proposal(proposalId) else { return note(proposalId, "找不到这次顺延的记录") }
        if p.undoneAt != nil { notes[proposalId] = "已撤回顺延"; return nil }
        guard await undo(p.id) else { return note(proposalId, "撤回顺延失败（看审批记录里的原因）") }
        notes[proposalId] = "已撤回顺延"
        return nil
    }

    // MARK: 内部

    private func rollDay(_ t: Date) {
        let day = DayContext.dayKey(t)
        guard ledger.day != day else { return }
        ledger = Ledger(day: day)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.ledgerKey) }
    }

    private func skip(_ why: String) -> Outcome {
        if lastOutcome != .skipped(why) { DevLog.shared.info("自动顺延", why) }
        return .skipped(why)
    }

    private func fail(_ why: String) -> Outcome {
        lastError = why
        DevLog.shared.error("自动顺延", why)
        return .failed(why)
    }

    private func note(_ id: UUID, _ text: String) -> String {
        notes[id] = text
        DevLog.shared.warn("自动顺延", text)
        return text
    }
}
