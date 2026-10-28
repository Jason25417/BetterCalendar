//
//  SentinelAsk.swift
//  BetterCalendar
//
//  W52（0.80，Jason 2026-10-27「要让哨兵根据它拿到的上下文判断，尽可能稳定地问我是否开始做某件事、某件事是否停下来了」）：
//  **判断的人是哨兵，问的人是 App，智能体不在环里**——智能体被叫醒后只会「通知一句」（规则硬性），从不问；
//  这里把「问」做成一条确定性的通道：
//    · 哨兵每次判断多答两个独立概率（Jev 一次请求里多两个问题）：started = 这块开始时间已过、他像是已经在做只是没计时；
//      stopped = 正在计时的这块像是停了（离开 / 锁屏 / 长时间切到别处）。摘要里给它具体候选与「问过他什么、他怎么答」。
//    · 概率过**提问线**（默认 0.6，低于叫醒线，所以更积极）→ 这里发一条带按钮的主动消息（打扰规则照旧）：
//      「在做「A」吗？」→ 在做 / 没在做；「「B」停下来了吗？」→ 停了 / 还在做。气泡与系统通知上都有按钮。
//    · 答案直接执行：在做 = 有自动顺延记录就撤回并从原开始时间起计时，没有就从那块开始时间起计时；停了 = 结束计时；
//      没在做 / 还在做 = 记下来：同一块冷却 90 分钟内不再问、两次说「没在做」当天不再问；每块每天最多问 3 次。
//    · 问过与答过都进摘要（哨兵不重复问）与决策日志（asked 字段）。所有跳过原因可见（DevLog）。
//

import Foundation
import Observation

nonisolated enum SentinelAskKind: String, Codable, Sendable {
    case started, stopped
}

/// 一次要问的事（由哨兵的事实候选 + 概率决定）。
nonisolated struct SentinelAsk: Equatable, Sendable {
    var kind: SentinelAskKind
    var blockId: UUID?
    var title: String
    /// started：那块的开始时间（「在做」= 从这里起计时）。
    var start: Date?
    /// 决策模型的把握（0–1）。
    var probability: Double
}

@MainActor @Observable final class SentinelAskCenter {
    struct Ledger: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var id: UUID
            var at: Date
            var kind: SentinelAskKind
            var blockId: UUID?
            var title: String
            /// started：那块的开始时间（「在做」从这里起计时）。
            var start: Date? = nil
            var answer: String? = nil   // yes / no
            var answeredAt: Date? = nil
        }
        var day = ""
        var history: [Entry] = []
    }
    static let ledgerKey = "sentinel.asks.v1"
    static let historyLimit = 40

    // 依赖（组装点注入）
    private let defaults: UserDefaults
    var now: () -> Date
    var notify: (AgentMessageDraft) async -> AgentMessage? = { _ in nil }
    var acknowledge: (UUID) async -> Void = { _ in }
    var startTimer: (_ blockId: UUID, _ at: Date) async throws -> Void = { _, _ in }
    var stopTimer: () async throws -> Void = {}
    /// 这块有没有一份已执行、未撤回的自动顺延（→「在做」= 撤回 + 从原开始时间起计时）。
    var reflowProposalFor: (UUID) -> UUID? = { _ in nil }
    var imDoing: (UUID) async -> String? = { _ in nil }

    private(set) var ledger: Ledger
    /// 答完后的一句结果（按消息 id；气泡下面显示）。
    private(set) var notes: [UUID: String] = [:]
    private(set) var lastError: String?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        ledger = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()
    }

    // MARK: 能不能问

    /// nil = 能问；否则 = 为什么不问（面板 / 日志可见）。
    func cannotAskReason(_ ask: SentinelAsk, settings: SentinelSettings) -> String? {
        let t = now()
        rollDay(t)
        let key = ask.blockId?.uuidString ?? ask.title
        let same = ledger.history.filter { ($0.blockId?.uuidString ?? $0.title) == key && $0.kind == ask.kind }
        if let open = same.last(where: { $0.answer == nil }), t.timeIntervalSince(open.at) < 6 * 3600 {
            return "「\(ask.title)」刚问过还没回答（\(open.at.formatted(date: .omitted, time: .shortened))）"
        }
        if let last = same.last, t.timeIntervalSince(last.at) < settings.askCooldownMinutes * 60 {
            return "「\(ask.title)」\(Int(settings.askCooldownMinutes)) 分钟内问过"
        }
        if same.filter({ $0.answer == "no" }).count >= 2 { return "「\(ask.title)」今天已两次说\(ask.kind == .started ? "没在做" : "还在做")，不再问" }
        if same.count >= settings.askDailyCap { return "「\(ask.title)」今天已问 \(same.count) 次，到上限" }
        return nil
    }

    // MARK: 问

    /// 发出问句（打扰规则由消息中心强制；拦下也算问过，气泡里能答）。
    @discardableResult
    func ask(_ ask: SentinelAsk, settings: SentinelSettings) async -> Bool {
        if let why = cannotAskReason(ask, settings: settings) {
            DevLog.shared.info("哨兵提问", "不问：\(why)"); return false
        }
        let t = now()
        let id = UUID()
        let hm = DateFormatter(); hm.locale = Locale(identifier: "en_US_POSIX"); hm.dateFormat = "HH:mm"
        let pct = Int((ask.probability * 100).rounded())
        let title: String, body: String
        switch ask.kind {
        case .started:
            title = "在做「\(ask.title)」吗？"
            body = (ask.start.map { "计划 \(hm.string(from: $0)) 开始，还没计时。" } ?? "还没计时。")
                + "点「在做」就从\(ask.blockId.flatMap(reflowProposalFor) != nil ? "原来的开始时间" : (ask.start.map { hm.string(from: $0) } ?? "现在"))起计时"
                + (ask.blockId.flatMap(reflowProposalFor) != nil ? "、顺延撤回" : "") + "；「没在做」就不再问。"
        case .stopped:
            title = "「\(ask.title)」停下来了吗？"
            body = "计时还在走，看起来你离开了一会儿。点「停了」就结束计时（做了多少都算数）；「还在做」就不再问。"
        }
        let draft = AgentMessageDraft(id: id, originLabel: "BetterCalendar", parentRef: Self.messageRef(ask.kind, blockId: ask.blockId),
                                      title: title, body: body, reason: "哨兵判断像是\(ask.kind == .started ? "开始了" : "停下了")（把握 \(pct)%）")
        guard await notify(draft) != nil else {
            lastError = "问句没有发出（消息中心没存进去）"
            DevLog.shared.error("哨兵提问", lastError!); return false
        }
        ledger.history.append(.init(id: id, at: t, kind: ask.kind, blockId: ask.blockId, title: ask.title, start: ask.start))
        if ledger.history.count > Self.historyLimit { ledger.history.removeFirst(ledger.history.count - Self.historyLimit) }
        save()
        DevLog.shared.info("哨兵提问", "已问：\(title)（把握 \(pct)%）")
        return true
    }

    // MARK: 答

    /// 气泡 / 通知按钮：yes = 在做 / 停了；no = 没在做 / 还在做。返回 nil = 成功，否则失败原因（也记进 notes）。
    @discardableResult
    func answer(messageId: UUID, yes: Bool) async -> String? {
        guard let i = ledger.history.firstIndex(where: { $0.id == messageId }) else {
            return note(messageId, "找不到这个问句的记录")
        }
        let entry = ledger.history[i]
        ledger.history[i].answer = yes ? "yes" : "no"
        ledger.history[i].answeredAt = now()
        save()
        await acknowledge(messageId)
        guard yes else {
            notes[messageId] = entry.kind == .started ? "记下了：没在做，今天不再反复问" : "记下了：还在做"
            return nil
        }
        switch entry.kind {
        case .started:
            guard let blockId = entry.blockId else { return note(messageId, "这块没有 id，没法计时") }
            if let pid = reflowProposalFor(blockId) {
                if let why = await imDoing(pid) { return note(messageId, why) }
                notes[messageId] = "已撤回顺延，「\(entry.title)」从原来的开始时间起计时"
            } else {
                let at = min(entry.start ?? entry.at, now())
                do { try await startTimer(blockId, at) } catch { return note(messageId, "开始计时失败：\(error.localizedDescription)") }
                notes[messageId] = "「\(entry.title)」已开始计时"
            }
        case .stopped:
            do { try await stopTimer() } catch { return note(messageId, "结束计时失败：\(error.localizedDescription)") }
            notes[messageId] = "「\(entry.title)」已结束计时"
        }
        DevLog.shared.info("哨兵提问", notes[messageId]!)
        return nil
    }

    /// 给摘要：最近 24 小时问过什么、他怎么答。
    func recentAsks() -> [(at: Date, kind: String, title: String, answer: String?)] {
        let cut = now().addingTimeInterval(-24 * 3600)
        return ledger.history.filter { $0.at >= cut }.map { ($0.at, $0.kind.rawValue, $0.title, $0.answer) }
    }

    /// 主动消息的 parentRef：ask:<started|stopped>:<块 id 或 ->。
    static func messageRef(_ kind: SentinelAskKind, blockId: UUID?) -> String { "ask:\(kind.rawValue):\(blockId?.uuidString ?? "-")" }
    nonisolated static func parseMessageRef(_ ref: String?) -> SentinelAskKind? {
        guard let ref, ref.hasPrefix("ask:") else { return nil }
        let parts = ref.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return nil }
        return SentinelAskKind(rawValue: parts[1])
    }

    // MARK: 内部

    private func rollDay(_ t: Date) {
        let day = DayContext.dayKey(t)
        guard ledger.day != day else { return }
        // 跨天：历史只留最近 24 小时的（摘要要用），每日计数随之归零
        let cut = t.addingTimeInterval(-24 * 3600)
        ledger = Ledger(day: day, history: ledger.history.filter { $0.at >= cut })
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.ledgerKey) }
    }

    private func note(_ id: UUID, _ text: String) -> String {
        notes[id] = text
        DevLog.shared.warn("哨兵提问", text)
        return text
    }
}
