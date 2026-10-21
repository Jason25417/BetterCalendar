//
//  AgentBridge.swift
//  BetterCalendar
//
//  SPEC §19 P2：App ⇄ BetterCalendar 智能体（Claude Code 专用会话）的桥接目录（协议见智能体工作区 bridge/README.md）。
//  App 在沙盒里，靠用户选一次目录（安全书签）获得读写权：
//    - 写 context.json（今天的安排、计时、待办池与长期事项、系统日历、最近实际、可选日记；见 AgentContext.swift），供智能体 read_context；
//    - 导入 proposals/*.json → 交给 ProposalCenter 走多端审批（来源=智能体），导入后移入 proposals/imported/；
//    - 回写 results/<id>.json（提案最新状态），供智能体 read_proposals。
//  不认识的改动种类一律拒绝导入（移入 proposals/rejected/）并记错误，绝不猜测。
//

import CryptoKit
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

nonisolated enum AgentBridgeError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
}

/// 桥接目录的文件读写与校验（与书签/计时解耦，便于用临时目录测试）。
nonisolated struct AgentBridgeIO: Sendable {
    let root: URL
    private var fm: FileManager { .default }

    func prepare() throws {
        for sub in ["events", "proposals/imported", "proposals/rejected", "results/messages", "messages/imported", "messages/rejected"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    func writeAtomic(_ data: Data, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try data.write(to: url, options: .atomic)
    }

    func writeContext(_ object: [String: Any]) throws {
        try writeAtomic(SafeJSON.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), to: "context.json")
    }

    func pendingProposalFiles() throws -> [URL] {
        try fm.contentsOfDirectory(at: root.appendingPathComponent("proposals"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func move(_ file: URL, to sub: String, note: String? = nil, kind: String = "proposals") throws {
        let dest = root.appendingPathComponent("\(kind)/\(sub)/\(file.lastPathComponent)")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: file, to: dest)
        if let note { try writeAtomic(Data(note.utf8), to: "\(kind)/\(sub)/\(file.deletingPathExtension().lastPathComponent).reason.txt") }
    }

    func pendingMessageFiles() throws -> [URL] {
        try fm.contentsOfDirectory(at: root.appendingPathComponent("messages"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 一条主动消息的结果（桥接 results/messages/ 与 W20 内置智能体 read_messages 共用同一份形状）。
    static func messageResultObject(_ m: AgentMessage) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return ["id": m.id.uuidString, "title": m.title, "delivery": m.delivery.rawValue,
                "suppressReason": m.suppressReason ?? NSNull(), "reaction": m.reaction?.rawValue ?? NSNull(),
                "reactedAt": m.reactedAt.map { iso.string(from: $0) } ?? NSNull(), "createdAt": iso.string(from: m.createdAt)]
    }

    func writeMessageResult(_ m: AgentMessage) throws {
        let object = Self.messageResultObject(m)
        let data = try SafeJSON.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let relative = "results/messages/\(m.id.uuidString).json"
        if (try? Data(contentsOf: root.appendingPathComponent(relative))) != data { try writeAtomic(data, to: relative) }
    }

    /// 写一个事件文件（调度器监听 events/ 唤醒智能体）。文件名按时间排序。返回事件 id（W14 哨兵记进决策日志）。
    @discardableResult
    func writeEvent(kind: String, summary: String, payload: [String: Any], at now: Date) throws -> String {
        let id = UUID().uuidString
        let stamp = Self.eventStamp.string(from: now)
        let eventId = "\(kind)-\(id.prefix(8))"
        let object: [String: Any] = ["schemaVersion": 1, "id": eventId, "at": ISO8601DateFormatter().string(from: now),
                                     "kind": kind, "summary": summary, "payload": payload]
        try writeAtomic(SafeJSON.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                        to: "events/\(stamp)-\(kind)-\(id.prefix(8)).json")
        return eventId
    }

    // MARK: 当前智能体状态标记（W24）

    /// 桥接目录里的「当前智能体」状态标记（相对路径）。读者 = 智能体工作区的心跳 heartbeat/heartbeat.mjs。
    static let activeAgentMarkerPath = "runtime/active-agent.json"

    /// 标记内容：只说现在接通的是哪个实现、哪个通道、何时写的。**不是通道**（产品原则 9）：不带上下文、不带事件，App 从不读回。
    static func activeAgentMarkerObject(_ kind: AgentKind, channel: AppChannel, at now: Date) -> [String: Any] {
        ["schemaVersion": 1, "app": "BetterCalendar", "channel": channel.rawValue, "activeAgent": kind.rawValue,
         "writtenAt": ISO8601DateFormatter().string(from: now),
         "note": "状态标记：App 在切换当前智能体时与启动时各写一次；不是通道（不带上下文 / 事件，App 不读回）。供心跳区分「切到内置智能体」与「App 没在运行」"]
    }

    /// 只写这一个文件（只建 runtime/，不建 events/ 等通道目录）。
    func writeActiveAgentMarker(_ kind: AgentKind, channel: AppChannel = .current, at now: Date) throws {
        try fm.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try writeAtomic(SafeJSON.data(withJSONObject: Self.activeAgentMarkerObject(kind, channel: channel, at: now),
                                               options: [.prettyPrinted, .sortedKeys]), to: Self.activeAgentMarkerPath)
    }

    private static let eventStamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss"; return f
    }()

    /// 智能体消息文件 → 草稿（一句话、可忽略；理由必填）。
    static func messageDraft(from data: Data) throws -> AgentMessageDraft {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], o["schemaVersion"] as? Int == 1 else {
            throw AgentBridgeError.invalid("不是 v1 消息文件")
        }
        guard let raw = o["id"] as? String, let id = UUID(uuidString: raw) else { throw AgentBridgeError.invalid("消息 id 缺失或不是 UUID") }
        guard let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count <= 60 else {
            throw AgentBridgeError.invalid("消息标题缺失或过长（≤60 字）")
        }
        guard let body = (o["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty, body.count <= 300 else {
            throw AgentBridgeError.invalid("消息正文缺失或过长（≤300 字）")
        }
        guard let reason = (o["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw AgentBridgeError.invalid("缺少理由（为什么此刻值得说）")
        }
        return AgentMessageDraft(id: id, originLabel: (o["originLabel"] as? String) ?? "BetterCalendar 智能体",
                                 parentRef: o["parentEventId"] as? String, title: title, body: body, reason: reason)
    }

    static func changesJSON(_ changes: [ProposalChange]) -> [[String: Any]] {
        changes.map { c in ["field": c.field, "before": c.before ?? NSNull(), "after": c.after ?? NSNull()] }
    }

    /// 只在内容变化时重写，避免无谓的文件抖动。
    /// W10：kind/changes = 你选中（或默认主）方案的；另附全部方案、你回的一句话（state = replied）、越级理由、代你决定的规则。
    func writeResult(_ p: Proposal, at now: Date) throws {
        let object = Self.resultObject(p, at: now)
        let data = try SafeJSON.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let relative = "results/\(p.id.uuidString).json"
        if (try? Data(contentsOf: root.appendingPathComponent(relative))) != data { try writeAtomic(data, to: relative) }
    }

    /// 一份提案的最新状态（桥接 results/<id>.json 与 W20 内置智能体 read_proposals 共用同一份形状）。
    static func resultObject(_ p: Proposal, at now: Date) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = ["id": p.id.uuidString, "title": p.title, "state": p.effectiveState(at: now).rawValue,
                                     "kind": p.executedAction.kind, "changes": Self.changesJSON(p.chosen.changes),
                                     "decidedByDeviceId": p.decidedByDeviceId ?? NSNull(), "resultNote": p.resultNote ?? NSNull(),
                                     "undoAvailable": p.state == .applied && p.undoAction != nil && p.undoneAt == nil,
                                     "undoUnavailableReason": p.undoUnavailableReason ?? NSNull(),
                                     "undoHint": p.undoHint ?? NSNull(),
                                     "undoneAt": p.undoneAt.map { iso.string(from: $0) } ?? NSNull(), "undoNote": p.undoNote ?? NSNull(),
                                     "updatedAt": iso.string(from: p.undoneAt ?? p.appliedAt ?? p.decidedAt ?? p.createdAt)]
        if p.hasAlternatives {
            object["options"] = p.options.map { o -> [String: Any] in
                ["index": o.index, "label": o.label, "kind": o.action.kind, "changes": Self.changesJSON(o.changes)]
            }
            object["chosenOption"] = p.chosenOption ?? NSNull()
        }
        if let reply = p.userReply {
            object["userReply"] = ["text": reply.text, "at": iso.string(from: reply.at), "deviceId": reply.deviceId]
        }
        if let escalation = p.escalation { object["escalation"] = escalation }
        if let stamp = p.preauth { object["ruleId"] = stamp.ruleId.uuidString; object["ruleLabel"] = stamp.ruleLabel }   // W10：规则代决定的，带上规则 id（冒烟 2026-10-18 补）
        // W11：可调参数——已批准：选中方案每个参数的默认值、最终值、你改没改；未决定：主方案的声明与默认值。
        let shownParams = p.chosenValues != nil ? p.chosen.parameters : (p.parameters ?? [])
        if !shownParams.isEmpty {
            object["parameters"] = shownParams.map { q -> [String: Any] in
                var row: [String: Any] = ["id": q.id, "label": q.label, "type": q.kind.rawValue, "bind": q.bind.rawValue]
                if let d = q.defaultValue { row["default"] = ProposalParameterRules.format(d, q) }
                if let v = p.chosenValues?[q.id] {
                    row["value"] = ProposalParameterRules.format(v, q)
                    row["changedByJason"] = ProposalParameterRules.isChanged(q, v)
                }
                return row
            }
            if !p.tuningSummary.isEmpty { object["tuningSummary"] = p.tuningSummary }
        }
        if let stamp = p.preauth {
            object["preauth"] = ["ruleId": stamp.ruleId.uuidString, "effect": stamp.effect.rawValue, "rule": stamp.ruleLabel]
        }
        return object
    }

    /// 智能体提案文件 → 草稿。严格校验：种类与字段都必须认识，多一个不认识的键也拒绝；不认识的种类一律拒绝。
    /// 这里只校验格式；目标存在与否、规则是否允许、版本是否一致，由 ProposalCenter.prepare 依据真实数据再查一遍。
    static func draft(from data: Data) throws -> ProposalDraft {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["schemaVersion"] as? Int == 1 else { throw AgentBridgeError.invalid("不是 v1 提案文件") }
        guard let raw = o["id"] as? String, let id = UUID(uuidString: raw) else { throw AgentBridgeError.invalid("提案 id 缺失或不是 UUID") }
        guard let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count <= 80
        else { throw AgentBridgeError.invalid("标题缺失或过长") }
        guard let reason = (o["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty
        else { throw AgentBridgeError.invalid("缺少理由（每个改动都必须讲得出依据）") }
        guard let rawAction = o["action"] as? [String: Any] else { throw AgentBridgeError.invalid("缺少 action") }
        let action = try Self.action(from: rawAction, proposalId: id, targetDevice: o["targetDevice"] as? String)
        // 真改动的「改动前 → 改动后」由 App 依据真实数据计算（智能体写的 changes 可省略，写了也会被替换）；
        // 测试改动沿用智能体写的 changes（必填）。
        let changes: [ProposalChange]
        if let rawChanges = o["changes"] as? [[String: Any]] {
            guard rawChanges.count <= 10 else { throw AgentBridgeError.invalid("changes 最多 10 条") }
            changes = try rawChanges.map { c -> ProposalChange in
                guard let field = c["field"] as? String, !field.isEmpty else { throw AgentBridgeError.invalid("改动缺少字段名") }
                return ProposalChange(field: field, before: c["before"] as? String, after: c["after"] as? String)
            }
        } else if action.touchesRealData, o["changes"] == nil || o["changes"] is NSNull {
            changes = []
        } else {
            throw AgentBridgeError.invalid("changes 格式错误")
        }
        // W11：有效期多久由智能体按上下文判断；这里只守技术稳定窗口（1 分钟–7 天，7 天防僵尸提案，不是产品规则）。
        // 超出不再悄悄夹到范围里，而是拒收并写明原因（失败可见）。省略 = 1 小时。
        let lifetime: TimeInterval
        if let raw = o["lifetimeSeconds"], !(raw is NSNull) {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw AgentBridgeError.invalid("lifetimeSeconds 必须是秒数") }
            lifetime = n.doubleValue
            do { try ProposalLifetime.check(lifetime) } catch { throw AgentBridgeError.invalid("lifetimeSeconds：" + error.localizedDescription) }
        } else {
            lifetime = 3600
        }
        // W10：越级理由（可选；有就必须是非空字符串）。
        var escalation: String?
        if let raw = o["escalation"], !(raw is NSNull) {
            guard let e = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty, e.count <= 300 else {
                throw AgentBridgeError.invalid("escalation 必须是 1–300 字的越级理由")
            }
            escalation = e
        }
        var primaryLabel: String?
        if let raw = o["primaryLabel"], !(raw is NSNull) {
            guard let l = raw as? String, l.count <= ProposalDraft.optionLabelLimit else {
                throw AgentBridgeError.invalid("primaryLabel 必须是不超过 \(ProposalDraft.optionLabelLimit) 字的字符串")
            }
            primaryLabel = l
        }
        // W10：备选方案（最多 3 个）：每个 {label, action}，action 与主方案同一套严格规则；改动前后由 App 计算。
        var alternatives: [ProposalAlternative] = []
        if let raw = o["alternatives"], !(raw is NSNull) {
            guard let list = raw as? [[String: Any]] else { throw AgentBridgeError.invalid("alternatives 必须是数组，每项 {label, action}") }
            guard list.count <= Proposal.maxAlternatives else { throw AgentBridgeError.invalid("alternatives 最多 \(Proposal.maxAlternatives) 个") }
            alternatives = try list.enumerated().map { i, item in
                let unknown = Set(item.keys).subtracting(["label", "action", "changes", "parameters"])
                guard unknown.isEmpty else { throw AgentBridgeError.invalid("alternatives[\(i)] 不认识的字段：\(unknown.sorted().joined(separator: ", "))") }
                guard let label = (item["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                      label.count <= ProposalDraft.optionLabelLimit else {
                    throw AgentBridgeError.invalid("alternatives[\(i)].label 必填，且不超过 \(ProposalDraft.optionLabelLimit) 字")
                }
                guard let rawAlt = item["action"] as? [String: Any] else { throw AgentBridgeError.invalid("alternatives[\(i)] 缺少 action") }
                let altAction: ProposalAction
                do { altAction = try Self.action(from: rawAlt, proposalId: id, targetDevice: o["targetDevice"] as? String) }
                catch let AgentBridgeError.invalid(why) { throw AgentBridgeError.invalid("alternatives[\(i)]：" + why) }
                var altChanges: [ProposalChange] = []
                if let rc = item["changes"] as? [[String: Any]] {
                    altChanges = rc.compactMap { c in (c["field"] as? String).map { ProposalChange(field: $0, before: c["before"] as? String, after: c["after"] as? String) } }
                }
                if !altAction.touchesRealData, altChanges.isEmpty { throw AgentBridgeError.invalid("alternatives[\(i)] 是测试改动，需要 changes") }
                let altParams = try Self.parameters(from: item["parameters"], action: altAction, path: "alternatives[\(i)].parameters")
                return ProposalAlternative(label: label, action: altAction, changes: altChanges, parameters: altParams.isEmpty ? nil : altParams)
            }
        }
        // W11：主方案的可调参数（备选方案的挂在各自身上）。
        let parameters = try Self.parameters(from: o["parameters"], action: action, path: "parameters")
        // W32d：智能体拿不准、想让 Jason 先看一眼 → askFirst: true（低风险自动通过不放行）。
        var askFirst = false
        if let raw = o["askFirst"], !(raw is NSNull) {
            guard let flag = Self.isBool(raw) else { throw AgentBridgeError.invalid("askFirst 必须是 true / false") }
            askFirst = flag
        }
        let anyReal = action.touchesRealData || alternatives.contains { $0.action.touchesRealData }
        return ProposalDraft(id: id, parentRef: o["parentEventId"] as? String, origin: .agent,
                             originLabel: (o["originLabel"] as? String) ?? "BetterCalendar 智能体",
                             targetDeviceId: o["targetDevice"] as? String, title: title, changes: changes, reason: reason,
                             action: action, experiment: !anyReal, lifetime: lifetime,
                             escalation: escalation, primaryLabel: primaryLabel, alternatives: alternatives, parameters: parameters,
                             askFirst: askFirst)
    }

    /// W11：可调参数声明（严格：每项只认这些键；类型 / 绑定字段 / 单位 / 范围都校验；绑到这种改动没有的字段 → 拒收）。
    /// 默认值可省略（= action 里写的那个）；写了就必须一致——由 ProposalCenter.prepare 依据准备好的动作核对。
    static func parameters(from raw: Any?, action: ProposalAction, path: String) throws -> [ProposalParameter] {
        guard let raw, !(raw is NSNull) else { return [] }
        guard let list = raw as? [[String: Any]] else { throw AgentBridgeError.invalid("\(path) 必须是数组，每项 {id, label, type, bind, default?, min?, max?, step?, unit?, anchor?}") }
        guard list.count <= ProposalParameterRules.maxPerOption else {
            throw AgentBridgeError.invalid("\(path) 最多 \(ProposalParameterRules.maxPerOption) 个（技术上限；卡片上建议不超过 2 个）")
        }
        let params = try list.enumerated().map { i, item -> ProposalParameter in
            let at = "\(path)[\(i)]"
            let unknown = Set(item.keys.filter { !(item[$0] is NSNull) }).subtracting(["id", "label", "type", "bind", "default", "min", "max", "step", "unit", "anchor", "target"])
            guard unknown.isEmpty else { throw AgentBridgeError.invalid("\(at) 不认识的字段：\(unknown.sorted().joined(separator: ", "))") }
            guard let id = item["id"] as? String else { throw AgentBridgeError.invalid("\(at).id 必填") }
            guard let label = item["label"] as? String else { throw AgentBridgeError.invalid("\(at).label 必填") }
            guard let rawType = item["type"] as? String, let kind = ProposalParameterKind(rawValue: rawType) else {
                throw AgentBridgeError.invalid("\(at).type 必须是 " + ProposalParameterKind.allCases.map(\.rawValue).joined(separator: " / "))
            }
            guard let rawBind = item["bind"] as? String, let bind = ProposalParameterBinding(rawValue: rawBind) else {
                throw AgentBridgeError.invalid("\(at).bind 必须是 " + ProposalParameterBinding.allCases.map(\.rawValue).joined(separator: " / "))
            }
            func value(_ key: String) throws -> ProposalParameterValue? {
                guard let v = item[key], !(v is NSNull) else { return nil }
                if kind.isDate {
                    guard let s = v as? String, let d = isoFractional.date(from: s) ?? isoPlain.date(from: s) else {
                        throw AgentBridgeError.invalid("\(at).\(key) 必须是带时区的 ISO 8601 时间")
                    }
                    return .date(d)
                }
                guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw AgentBridgeError.invalid("\(at).\(key) 必须是数字") }
                return .number(n.doubleValue)
            }
            var unit: ProposalParameterUnit?
            if let u = item["unit"], !(u is NSNull) {
                guard let s = u as? String, let parsed = ProposalParameterUnit(rawValue: s) else { throw AgentBridgeError.invalid("\(at).unit 必须是 minute / hour") }
                unit = parsed
            }
            var step: Double?
            if let v = item["step"], !(v is NSNull) {
                guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw AgentBridgeError.invalid("\(at).step 必须是数字") }
                step = n.doubleValue
            }
            var anchor: Date?
            if let v = item["anchor"], !(v is NSNull) {
                guard let s = v as? String, let d = isoFractional.date(from: s) ?? isoPlain.date(from: s) else {
                    throw AgentBridgeError.invalid("\(at).anchor 必须是带时区的 ISO 8601 时间")
                }
                anchor = d
            }
            var target: UUID?
            if let v = item["target"], !(v is NSNull) {
                guard let s = v as? String, let t = UUID(uuidString: s) else { throw AgentBridgeError.invalid("\(at).target 必须是方案里那一块的 id（UUID）") }
                target = t
            }
            return ProposalParameter(id: id, label: label, kind: kind, bind: bind, unit: unit, defaultValue: try value("default"),
                                     min: try value("min"), max: try value("max"), step: step, anchor: anchor, target: target)
        }
        do { try ProposalParameterRules.validateDeclarations(params, for: action, where: path) }
        catch { throw AgentBridgeError.invalid(error.localizedDescription) }
        return params
    }

    /// 桥接协议 action → ProposalAction（严格：每种只认自己的键；itemDiscard / timerDiscard / 整组挪回只用于撤销，不接受）。
    /// targetDevice = 提案级的执行设备（提醒/闹钟没在 action.device 里写设备时沿用它）。
    static func action(from a: [String: Any], proposalId: UUID, targetDevice: String? = nil) throws -> ProposalAction {
        guard let kind = a["kind"] as? String else { throw AgentBridgeError.invalid("action.kind 缺失") }
        let allowed: [String: Set<String>] = [
            "experimentNoop": ["note"],
            "itemCreate": ["title", "note"],
            "itemEdit": ["itemId", "title", "note", "expectedRevision"],
            "itemSetDone": ["itemId", "done", "expectedRevision"],
            "timer": ["command", "blockId", "title", "expectedRevision", "startedAt"],
            "moveBlock": ["blockId", "start", "end", "expectedRevision"],
            "moveBlocks": ["moves"],
            "reminder": ["title", "body", "fireAt", "device"],
            "alarm": ["title", "fireAt", "device"],
            // W18 时间线排程
            "blockCreate": ["day", "blocks"],
            "blockEdit": ["blockId", "title", "durationMinutes", "fixed", "important", "deadline", "clearDeadline", "expectedRevision"],
            "blockDelete": ["blockId", "expectedRevision"],
            "planDay": ["day", "steps"],
            // W32 越级审批你的东西（必须带 escalation；永远要 Jason 亲自批）
            "yourEventEdit": ["eventId", "occurrenceStart", "span", "title", "start", "end", "notes", "expectedRevision"],
            "yourEventDelete": ["eventId", "occurrenceStart", "span", "expectedRevision"],
            "yourReminderEdit": ["reminderId", "title", "due", "done", "expectedRevision"],
            "yourReminderDelete": ["reminderId", "expectedRevision"],
            "itemDelete": ["itemId", "expectedRevision"],
            "checkpointDelete": ["itemId", "checkpointId", "expectedRevision"],
            // W34 给长期事项加阶段（普通审批；新阶段 id = 提案 id）
            "checkpointCreate": ["itemId", "title", "estimateMinutes", "position", "expectedRevision"],
            // W32b 日记（「允许智能体提议写日记」开着才收）
            "journalAppend": ["day", "text", "expectedRevision"],
            "journalEdit": ["entryId", "find", "replace", "expectedRevision"],
        ]
        guard let keys = allowed[kind] else {
            throw AgentBridgeError.invalid("不支持的改动种类「\(kind)」（可用：\(allowed.keys.sorted().joined(separator: " / "))）")
        }
        let present = Set(a.keys.filter { $0 != "kind" && !(a[$0] is NSNull) })
        let unknown = present.subtracting(keys)
        guard unknown.isEmpty else { throw AgentBridgeError.invalid("\(kind) 不认识的字段：\(unknown.sorted().joined(separator: ", "))") }
        func string(_ key: String, max: Int) throws -> String? {
            guard let v = a[key], !(v is NSNull) else { return nil }
            guard let s = v as? String, s.count <= max else { throw AgentBridgeError.invalid("\(kind).\(key) 必须是不超过 \(max) 字的字符串") }
            return s
        }
        func uuid(_ key: String) throws -> UUID? {
            guard let s = try string(key, max: 64) else { return nil }
            guard let id = UUID(uuidString: s) else { throw AgentBridgeError.invalid("\(kind).\(key) 不是 UUID") }
            return id
        }
        func required<T>(_ value: T?, _ key: String) throws -> T {
            guard let value else { throw AgentBridgeError.invalid("\(kind) 缺少 \(key)") }
            return value
        }
        func date(_ key: String) throws -> Date? {
            guard let s = try string(key, max: 40) else { return nil }
            guard let d = Self.isoFractional.date(from: s) ?? Self.isoPlain.date(from: s) else {
                throw AgentBridgeError.invalid("\(kind).\(key) 必须是带时区的 ISO 8601 时间（如 2026-10-18T15:00:00+08:00）")
            }
            return d
        }
        let revision = try string("expectedRevision", max: 64)
        switch kind {
        case "experimentNoop":
            return .experimentNoop(note: try string("note", max: 200) ?? "智能体测试提案")
        case "itemCreate":
            return .itemCreate(id: proposalId, title: try required(string("title", max: 200), "title"), note: try string("note", max: 2000))
        case "itemEdit":
            let title = try string("title", max: 200), note = try string("note", max: 2000)
            guard title != nil || note != nil else { throw AgentBridgeError.invalid("itemEdit 至少要改 title 或 note 之一") }
            return .itemEdit(id: try required(uuid("itemId"), "itemId"), title: title, note: note, expectedRevision: revision)
        case "itemSetDone":
            guard let flag = a["done"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                throw AgentBridgeError.invalid("itemSetDone.done 必须是 true / false")
            }
            return .itemSetDone(id: try required(uuid("itemId"), "itemId"), done: flag.boolValue, expectedRevision: revision)
        case "timer":
            guard let raw = try string("command", max: 10), let command = ProposalTimerCommand(rawValue: raw) else {
                throw AgentBridgeError.invalid("timer.command 必须是 start / pause / resume / stop")
            }
            let blockId = try uuid("blockId"), title = try string("title", max: 200)
            // W8：startedAt = 回溯起点（智能体推断你大概从这一刻起就在做），只用于 start；合法性（不在未来、≤2 小时前、
            // 不与已记下的实际/计时重叠）由 App 依据真实数据再查。
            let startedAt = try date("startedAt")
            if command == .start {
                guard (blockId == nil) != (title == nil) else { throw AgentBridgeError.invalid("timer start 需要二选一：blockId 或 title") }
            } else {
                guard blockId == nil, title == nil else { throw AgentBridgeError.invalid("timer \(raw) 不带 blockId / title（作用于执行设备上正在计的那件）") }
                guard startedAt == nil else { throw AgentBridgeError.invalid("只有 timer start 能带 startedAt（回溯起点）") }
            }
            return .timer(command: command, blockId: blockId, title: title, expectedRevision: revision, startAt: startedAt)
        case "moveBlock":
            return .moveBlock(id: try required(uuid("blockId"), "blockId"), start: try required(date("start"), "start"),
                              end: try date("end"), expectedRevision: revision)
        case "moveBlocks":
            // W8：一次挪多块（撞到别的块时连带挪）。每项只认 blockId / start / end / expectedRevision；最终布局由 App 整体校验。
            guard let raw = a["moves"] as? [[String: Any]], !raw.isEmpty else {
                throw AgentBridgeError.invalid("moveBlocks.moves 必须是非空数组，每项 {blockId, start, end?, expectedRevision?}")
            }
            // W10：只有技术防失控上限（不是产品规则）；一次挪多少块以最终整体布局合法为准。
            guard raw.count <= PlanMoveRules.maxGroup else { throw AgentBridgeError.invalid("moveBlocks 超过技术防失控上限 \(PlanMoveRules.maxGroup) 块，疑似文件出错") }
            let moves = try raw.enumerated().map { i, m -> ProposalBlockMove in
                guard m["kind"] == nil else { throw AgentBridgeError.invalid("moveBlocks.moves[\(i)] 不认识的字段：kind") }
                var item = m
                item["kind"] = "moveBlock"
                do {
                    guard case let .moveBlock(id, start, end, rev) = try Self.action(from: item, proposalId: proposalId) else {
                        throw AgentBridgeError.invalid("moveBlocks.moves[\(i)] 格式错误")
                    }
                    return ProposalBlockMove(id: id, start: start, end: end, expectedRevision: rev)
                } catch let AgentBridgeError.invalid(why) {
                    throw AgentBridgeError.invalid("moveBlocks.moves[\(i)]：" + why)
                }
            }
            return .moveBlocks(moves: moves, isUndo: false)
        case "reminder":
            // W8 D3 / W12：提醒 = 写进提醒事项，iPhone 和 Mac 都会响（不保证叫醒）。device 只为兼容保留，不再决定执行设备。
            let device = try string("device", max: 80) ?? targetDevice
            if let device, let targetDevice, device != targetDevice { throw AgentBridgeError.invalid("reminder.device 与 targetDevice 不一致") }
            return .reminder(id: proposalId, title: try required(string("title", max: 150), "title"), body: try string("body", max: 500),
                             fireAt: try required(date("fireAt"), "fireAt"), deviceId: device)
        case "alarm":
            // W8 D3：iPhone 系统闹钟（会响铃）。必须指定 iPhone：device 或 targetDevice（actionTargets.devices 里 platform=iOS 的那台）。
            let device = try string("device", max: 80) ?? targetDevice
            if let device, let targetDevice, device != targetDevice { throw AgentBridgeError.invalid("alarm.device 与 targetDevice 不一致") }
            guard let device else { throw AgentBridgeError.invalid("alarm 必须指定 iPhone：device（或 targetDevice）填 actionTargets.devices 里 platform=iOS 的 id") }
            return .alarm(id: proposalId, title: try required(string("title", max: 150), "title"),
                          fireAt: try required(date("fireAt"), "fireAt"), deviceId: device)
        case "blockCreate":
            let day = try required(Self.day(a["day"], "blockCreate.day"), "day")
            guard let raw = a["blocks"] as? [[String: Any]], !raw.isEmpty else {
                throw AgentBridgeError.invalid("blockCreate.blocks 必须是非空数组，每项 {title, start, end 或 durationMinutes, fixed?, important?, deadline?, linkedItemId?, id?}")
            }
            guard raw.count <= PlanEditRules.maxGroup else { throw AgentBridgeError.invalid("blockCreate 超过技术防失控上限 \(PlanEditRules.maxGroup) 块，疑似文件出错") }
            return .blockCreate(day: day, blocks: try raw.enumerated().map { i, b in
                try Self.newBlock(b, path: "blockCreate.blocks[\(i)]", proposalId: proposalId, index: i)
            })
        case "blockEdit":
            return .blockEdit(try Self.blockEdit(a, path: "blockEdit"))
        case "blockDelete":
            return .blockDelete(id: try required(uuid("blockId"), "blockId"), expectedRevision: revision)
        case "planDay":
            let day = try required(Self.day(a["day"], "planDay.day"), "day")
            guard let raw = a["steps"] as? [[String: Any]], !raw.isEmpty else {
                throw AgentBridgeError.invalid("planDay.steps 必须是非空数组，每项 {op: create|move|edit|delete, …}")
            }
            guard raw.count <= PlanEditRules.maxGroup else { throw AgentBridgeError.invalid("planDay 超过技术防失控上限 \(PlanEditRules.maxGroup) 步，疑似文件出错") }
            var seen = Set<UUID>()
            let steps = try raw.enumerated().map { i, item -> ProposalPlanStep in
                let path = "planDay.steps[\(i)]"
                guard item["kind"] == nil else { throw AgentBridgeError.invalid("\(path) 用 op 不用 kind") }
                var rest = item; rest["op"] = nil
                let step: ProposalPlanStep
                do {
                    switch item["op"] as? String {
                    case "create": step = .create(try Self.newBlock(rest, path: path, proposalId: proposalId, index: i))
                    case "move":
                        rest["kind"] = "moveBlock"
                        guard case let .moveBlock(id, start, end, rev) = try Self.action(from: rest, proposalId: proposalId) else { throw AgentBridgeError.invalid("格式错误") }
                        step = .move(ProposalBlockMove(id: id, start: start, end: end, expectedRevision: rev))
                    case "edit":
                        step = .edit(try Self.blockEdit(rest, path: "edit"))
                    case "delete":
                        rest["kind"] = "blockDelete"
                        guard case let .blockDelete(id, rev) = try Self.action(from: rest, proposalId: proposalId) else { throw AgentBridgeError.invalid("格式错误") }
                        step = .delete(id: id, expectedRevision: rev)
                    default:
                        throw AgentBridgeError.invalid("op 必须是 create / move / edit / delete")
                    }
                } catch let AgentBridgeError.invalid(why) {
                    throw AgentBridgeError.invalid(why.hasPrefix(path) ? why : "\(path)：" + why)
                }
                guard seen.insert(step.blockID).inserted else { throw AgentBridgeError.invalid("\(path)：同一块在 steps 里出现了不止一次") }
                return step
            }
            return .planDay(day: day, steps: steps, isUndo: false)
        case "yourEventEdit", "yourEventDelete":
            let ref = YourEventRef(externalID: try required(string("eventId", max: 512), "eventId"),
                                   occurrenceStart: try required(date("occurrenceStart"), "occurrenceStart"))
            var span = YourEventSpan.thisOccurrence
            if let raw = try string("span", max: 20) {
                guard let s = YourEventSpan(rawValue: raw) else { throw AgentBridgeError.invalid("\(kind).span 必须是 thisOccurrence / futureEvents") }
                span = s
            }
            if kind == "yourEventDelete" { return .yourEventDelete(ref: ref, expectedRevision: revision, span: span) }
            let edit = YourEventEdit(ref: ref, span: span, title: try string("title", max: 200), start: try date("start"), end: try date("end"),
                                     notes: try string("notes", max: 2000), expectedRevision: revision)
            guard !edit.isEmpty else { throw AgentBridgeError.invalid("yourEventEdit 至少要改 title / start / end / notes 之一") }
            return .yourEventEdit(edit)
        case "yourReminderEdit":
            var done: Bool? = nil
            if let raw = a["done"], !(raw is NSNull) {
                guard let flag = Self.isBool(raw) else { throw AgentBridgeError.invalid("yourReminderEdit.done 必须是 true / false") }
                done = flag
            }
            let edit = YourReminderEdit(externalID: try required(string("reminderId", max: 512), "reminderId"), title: try string("title", max: 200),
                                        due: try date("due"), done: done, expectedRevision: revision)
            guard !edit.isEmpty else { throw AgentBridgeError.invalid("yourReminderEdit 至少要改 title / due / done 之一") }
            return .yourReminderEdit(edit)
        case "yourReminderDelete":
            return .yourReminderDelete(externalID: try required(string("reminderId", max: 512), "reminderId"), expectedRevision: revision)
        case "checkpointCreate":
            var position: Int? = nil
            if let raw = a["position"], !(raw is NSNull) {
                guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(),
                      n.intValue >= 0, n.intValue <= 10_000 else { throw AgentBridgeError.invalid("checkpointCreate.position 必须是 ≥0 的整数") }
                position = n.intValue
            }
            return .checkpointCreate(itemId: try required(uuid("itemId"), "itemId"), checkpointId: proposalId,
                                     title: try required(string("title", max: YourItemRules.titleLimit), "title"),
                                     estimatedMinutes: try Self.minutes(a["estimateMinutes"], "checkpointCreate.estimateMinutes"),
                                     position: position, expectedRevision: revision)
        case "itemDelete":
            return .itemDelete(id: try required(uuid("itemId"), "itemId"), expectedRevision: revision)
        case "checkpointDelete":
            return .checkpointDelete(itemId: try required(uuid("itemId"), "itemId"), checkpointId: try required(uuid("checkpointId"), "checkpointId"),
                                     expectedRevision: revision)
        case "journalAppend":
            return .journalAppend(day: try required(Self.day(a["day"], "journalAppend.day"), "day"),
                                  text: try required(string("text", max: ProposalActionExecutor.journalTextLimit), "text"),
                                  newEntryID: proposalId, expectedRevision: revision)
        case "journalEdit":
            guard let replace = try string("replace", max: ProposalActionExecutor.journalTextLimit) else {
                throw AgentBridgeError.invalid("journalEdit 缺少 replace（改成什么；空串 = 删掉这段）")
            }
            return .journalEdit(entryID: try required(uuid("entryId"), "entryId"), find: try required(string("find", max: 2000), "find"),
                                replace: replace, expectedRevision: revision)
        default:
            throw AgentBridgeError.invalid("不支持的改动种类「\(kind)」")
        }
    }

    /// W18：逻辑日「yyyy-MM-dd」（本地时区）→ 该日零点（= 逻辑日标签）。
    static func day(_ raw: Any?, _ path: String) throws -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard let s = raw as? String, s.count == 10, let d = f.date(from: s) else {
            throw AgentBridgeError.invalid("\(path) 必须是逻辑日 yyyy-MM-dd（如 2026-10-20；凌晨 0–4 点属于前一天）")
        }
        return Calendar.current.startOfDay(for: d)
    }

    /// W18：新块的 id——智能体给了就用（要挂可调参数时得给）；没给就由提案 id + 序号推出（重复导入同一文件得到同样的 id）。
    static func derivedBlockID(_ proposalId: UUID, _ index: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("block|\(proposalId.uuidString)|\(index)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func isBool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    private static func minutes(_ v: Any?, _ path: String) throws -> Int? {
        guard let v, !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(),
              n.intValue >= 1, n.intValue <= 24 * 60 else {
            throw AgentBridgeError.invalid("\(path) 必须是 1–1440 的整数分钟")
        }
        return n.intValue
    }
    private static func isoDate(_ v: Any?, _ path: String) throws -> Date? {
        guard let v, !(v is NSNull) else { return nil }
        guard let s = v as? String, let d = isoFractional.date(from: s) ?? isoPlain.date(from: s) else {
            throw AgentBridgeError.invalid("\(path) 必须是带时区的 ISO 8601 时间（如 2026-10-20T09:00:00-04:00）")
        }
        return d
    }
    private static func uuidField(_ v: Any?, _ path: String) throws -> UUID? {
        guard let v, !(v is NSNull) else { return nil }
        guard let s = v as? String, let id = UUID(uuidString: s) else { throw AgentBridgeError.invalid("\(path) 不是 UUID") }
        return id
    }

    /// W18：新块（严格：只认这些键；end 与 durationMinutes 二选一；title 省略时必须关联事项）。
    static func newBlock(_ b: [String: Any], path: String, proposalId: UUID, index: Int) throws -> ProposalNewBlock {
        let keys: Set<String> = ["id", "title", "start", "end", "durationMinutes", "fixed", "important", "deadline", "linkedItemId"]
        let unknown = Set(b.keys.filter { !(b[$0] is NSNull) }).subtracting(keys)
        guard unknown.isEmpty else { throw AgentBridgeError.invalid("\(path) 不认识的字段：\(unknown.sorted().joined(separator: ", "))") }
        let id = try uuidField(b["id"], "\(path).id") ?? derivedBlockID(proposalId, index)
        let linked = try uuidField(b["linkedItemId"], "\(path).linkedItemId")
        var title = ""
        if let raw = b["title"], !(raw is NSNull) {
            guard let t = raw as? String, t.count <= 200 else { throw AgentBridgeError.invalid("\(path).title 必须是不超过 200 字的字符串") }
            title = t
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || linked != nil else {
            throw AgentBridgeError.invalid("\(path) 缺少 title（或用 linkedItemId 关联一条事项，沿用它的标题）")
        }
        guard let start = try isoDate(b["start"], "\(path).start") else { throw AgentBridgeError.invalid("\(path) 缺少 start") }
        let end = try isoDate(b["end"], "\(path).end")
        let duration = try minutes(b["durationMinutes"], "\(path).durationMinutes")
        guard (end == nil) != (duration == nil) else { throw AgentBridgeError.invalid("\(path) 的 end 与 durationMinutes 二选一（必须写其中一个）") }
        for k in ["fixed", "important"] where b[k] != nil && !(b[k] is NSNull) && isBool(b[k]) == nil {
            throw AgentBridgeError.invalid("\(path).\(k) 必须是 true / false")
        }
        return ProposalNewBlock(id: id, title: title, start: start, end: end ?? start.addingTimeInterval(Double(duration!) * 60),
                                isFixed: isBool(b["fixed"]) ?? false, important: isBool(b["important"]) ?? false,
                                deadline: try isoDate(b["deadline"], "\(path).deadline"), linkedTaskID: linked)
    }

    /// W18：改块（严格：至少改一项；deadline 与 clearDeadline 不同时出现）。
    static func blockEdit(_ a: [String: Any], path: String) throws -> ProposalBlockEdit {
        let keys: Set<String> = ["kind", "blockId", "title", "durationMinutes", "fixed", "important", "deadline", "clearDeadline", "expectedRevision"]
        let unknown = Set(a.keys.filter { !(a[$0] is NSNull) }).subtracting(keys)
        guard unknown.isEmpty else { throw AgentBridgeError.invalid("\(path) 不认识的字段：\(unknown.sorted().joined(separator: ", "))") }
        guard let id = try uuidField(a["blockId"], "\(path).blockId") else { throw AgentBridgeError.invalid("\(path) 缺少 blockId") }
        var edit = ProposalBlockEdit(id: id)
        if let raw = a["title"], !(raw is NSNull) {
            guard let t = raw as? String, t.count <= 200 else { throw AgentBridgeError.invalid("\(path).title 必须是不超过 200 字的字符串") }
            edit.title = t
        }
        edit.duration = try minutes(a["durationMinutes"], "\(path).durationMinutes").map { Double($0) * 60 }
        for k in ["fixed", "important", "clearDeadline"] where a[k] != nil && !(a[k] is NSNull) && isBool(a[k]) == nil {
            throw AgentBridgeError.invalid("\(path).\(k) 必须是 true / false")
        }
        edit.isFixed = isBool(a["fixed"]); edit.important = isBool(a["important"])
        let deadline = try isoDate(a["deadline"], "\(path).deadline")
        let clear = isBool(a["clearDeadline"]) ?? false
        if isBool(a["clearDeadline"]) == false { throw AgentBridgeError.invalid("\(path).clearDeadline 只写 true（不清就别写）") }
        guard !(deadline != nil && clear) else { throw AgentBridgeError.invalid("\(path) 的 deadline 与 clearDeadline 只能二选一") }
        edit.deadline = deadline.map { .set($0) } ?? (clear ? .clear : nil)
        if let raw = a["expectedRevision"], !(raw is NSNull) {
            guard let r = raw as? String, r.count <= 64 else { throw AgentBridgeError.invalid("\(path).expectedRevision 必须是不超过 64 字的字符串") }
            edit.expectedRevision = r
        }
        guard !edit.isEmpty else { throw AgentBridgeError.invalid("\(path) 至少要改一项（title / durationMinutes / fixed / important / deadline / clearDeadline）") }
        return edit
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
}

@MainActor @Observable final class AgentBridge {
    static let bookmarkKey = "agentBridge.folderBookmark"
    private(set) var folderPath: String?
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var importedCount = 0
    /// SPEC §19 批次 11：调度器运行时（最近运行、死信、越权记录），每轮同步时读取；告警 = 调度失败（醒目可见）。
    private(set) var runtime: AgentRuntimeSnapshot?
    private(set) var runtimeAlerts: [AgentRuntimeAlert] = []
    private var reportedRuntimeAlerts: Set<String> = []

    private let center: ProposalCenter
    private let messages: AgentMessageCenter?
    private let contextProvider: () async -> [String: Any]
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?
    /// SPEC §19 A1 / F1：对话（组装点设置；nil = 不桥接对话）。晚间复盘的事实素材由组装点提供。
    var chat: AgentChatCenter?
    var eveningFacts: () -> [String: Any] = { [:] }
    /// W13：设备活动镜像（本机日文件 → bridge/activity/YYYY-MM-DD.jsonl），每轮同步时跑；失败由它自己记 DevLog，不打断同步。
    var activityMirror: ((AgentBridgeIO) async -> Void)?
    /// W21：功能使用汇总镜像（bridge/usage.json，开关关着时组装点不写）；失败由它自己记 DevLog，不打断同步。
    var usageMirror: ((AgentBridgeIO) -> Void)?
    /// W20：只有「当前智能体 = Claude Code」时桥接才是通道（产品原则 9：没接通的实现没有任何通道）。
    /// false → 不同步、不写任何桥接文件、不写事件、哨兵也拿不到目录。组装点接到 AgentSelection。
    var isActive: () -> Bool = { true }
    /// W20：智能体共享记忆（属于角色、各实现共用）：每轮写 bridge/shared-memory.md，导入 Claude Code 写的 shared-memory.update.json。
    var sharedMemory: AgentSharedMemoryStore?
    /// 同步互斥：推送唤醒与定时轮询可能撞在一起；进行中再来的请求合并成「做完再跑一轮」，避免重复转交。
    private var syncing = false
    private var resyncRequested = false

    init(center: ProposalCenter, messages: AgentMessageCenter? = nil, defaults: UserDefaults = .standard,
         contextProvider: @escaping () async -> [String: Any]) {
        self.center = center; self.messages = messages; self.defaults = defaults; self.contextProvider = contextProvider
        folderPath = resolveFolder()?.path
    }

    var connected: Bool { folderPath != nil }

    #if os(macOS)
    /// 只由用户点击按钮触发：选择智能体工作区里的 bridge 目录。
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择 BetterCalendar 智能体工作区里的 bridge 文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // W17：日用版只连日用工作区、Dev 版只连 Dev 工作区（bridge/CHANNEL 标记），两套数据绝不混。
        if let mismatch = AppChannel.current.bridgeMismatch(url) {
            report("没有连接", AgentBridgeError.invalid(mismatch)); return
        }
        do {
            defaults.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: Self.bookmarkKey)
            folderPath = url.path; lastError = nil
            DevLog.shared.info("智能体桥接", "已连接：\(url.path)")
            Task { await sync() }
        } catch { report("保存目录授权失败", error) }
    }
    #endif

    func disconnect() {
        defaults.removeObject(forKey: Self.bookmarkKey); folderPath = nil
        DevLog.shared.info("智能体桥接", "已断开")
    }

    /// 每 20 秒同步一次（测试环境不要启动）。
    func start(every seconds: Double = 20) {
        guard loop == nil, isActive() else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sync()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// W20：切到别的智能体时停掉轮询（没接通就不轮询）。
    func stop() {
        loop?.cancel(); loop = nil
    }

    func sync() async {
        guard isActive(), let url = resolveFolder() else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // W17：已连的目录后来被标成别的通道（或连错）→ 不同步、醒目报错（同一原因只记一次日志，不每 20 秒刷屏）。
        if let mismatch = AppChannel.current.bridgeMismatch(url) {
            let text = "桥接目录通道不符，已暂停同步：\(mismatch)"
            if lastError != text { lastError = text; DevLog.shared.error("智能体桥接", text) }
            return
        }
        await sync(io: AgentBridgeIO(root: url))
    }

    /// 一轮同步（可直接用临时目录测试）。
    func sync(io: AgentBridgeIO) async {
        guard isActive() else { return }
        if syncing { resyncRequested = true; return }
        syncing = true; defer { syncing = false }
        repeat { resyncRequested = false; await syncOnce(io: io) } while resyncRequested
    }

    private func syncOnce(io: AgentBridgeIO) async {
        do {
            try io.prepare()
            try io.writeContext(await contextProvider())
            if let sharedMemory { syncSharedMemory(io: io, store: sharedMemory) }
            let files = try io.pendingProposalFiles()
            if !files.isEmpty { await center.refresh() }
            for file in files {
                do {
                    let parsed = try AgentBridgeIO.draft(from: Data(contentsOf: file))
                    if let id = parsed.id, center.proposals.contains(where: { $0.id == id }) {
                        try io.move(file, to: "imported")   // 已导入过（上次崩在移动前）：幂等
                        continue
                    }
                    // 依据真实数据校验（目标存在、规则允许、版本一致）并算出改动前后；不通过 → 移入 rejected/ 并写明原因。
                    let draft = try await center.prepare(parsed)
                    guard await center.submit(draft) != nil else { continue }   // 失败留在原处，下轮重试；错误已在 center 里可见
                    try io.move(file, to: "imported")
                    importedCount += 1
                } catch {
                    try? io.move(file, to: "rejected", note: error.localizedDescription)
                    report("拒绝导入智能体提案 \(file.lastPathComponent)", error)
                }
            }
            for p in center.proposals where p.origin == .agent { try io.writeResult(p, at: .now) }
            if let messages {
                for file in try io.pendingMessageFiles() {
                    do {
                        let draft = try AgentBridgeIO.messageDraft(from: Data(contentsOf: file))
                        guard await messages.receive(draft) != nil else { continue }   // 失败留原处下轮重试
                        try io.move(file, to: "imported", kind: "messages")
                    } catch {
                        try? io.move(file, to: "rejected", note: error.localizedDescription, kind: "messages")
                        report("拒绝导入智能体消息 \(file.lastPathComponent)", error)
                    }
                }
                for m in messages.messages { try io.writeMessageResult(m) }
            }
            if let chat {
                try await AgentChatBridgeStep.run(io: io, chat: chat, proposals: center.proposals, defaults: defaults,
                                                  eveningFacts: eveningFacts, now: .now, report: report)
            }
            try emitResolvedProposals(io: io)
            await activityMirror?(io)
            usageMirror?(io)
            lastSync = .now
        } catch { report("桥接同步失败", error) }
        refreshRuntime(io: io)
    }

    /// W20：共享记忆——先导入 Claude Code 的整份改写（坏的 / 超上限的移到 shared-memory.rejected.json 并写原因），再写只读快照。
    private func syncSharedMemory(io: AgentBridgeIO, store: AgentSharedMemoryStore) {
        do {
            if let text = try io.pendingSharedMemoryUpdate() {
                do {
                    try store.replace(text, by: "\(AgentKind.claudeCode.shortLabel)（\(ProposalDevice.label)）")
                    try io.finishSharedMemoryUpdate(rejected: nil)
                } catch {
                    try io.finishSharedMemoryUpdate(rejected: error.localizedDescription)
                    report("拒绝导入共享记忆更新", error)
                }
            }
        } catch {
            try? io.finishSharedMemoryUpdate(rejected: error.localizedDescription)
            report("拒绝导入共享记忆更新", error)
        }
        do { try io.writeSharedMemory(store.memory) } catch { report("写共享记忆快照失败", error) }
    }

    // MARK: 智能体运行时（SPEC §19 批次 11）

    /// 测试可注入时钟（健康判断：事件等待多久算调度器没在运行）。
    var runtimeNow: () -> Date = Date.init

    /// 读调度器写的运行记录 / 状态 / 死信 / 越权镜像；新出现的告警各写一次 DevLog（失败必须可见）。
    func refreshRuntime(io: AgentBridgeIO) {
        let snap = io.readRuntime()
        runtime = snap
        runtimeAlerts = AgentRuntimeHealth.alerts(snap, now: runtimeNow())
        for a in runtimeAlerts where !reportedRuntimeAlerts.contains(a.key) {
            reportedRuntimeAlerts.insert(a.key)
            if a.severity == .error { DevLog.shared.error("智能体运行", a.message) } else { DevLog.shared.warn("智能体运行", a.message) }
        }
    }

    /// 死信重新排队（只由用户点击触发）：移回 events/，调度器会再处理一次。
    func requeueDeadLetter(_ file: String) { withFolder("重新排队失败") { try $0.requeueDeadLetter(file) } }
    /// 收起死信（只由用户点击触发）：移入 events/failed/dismissed/，保留可查。
    func dismissDeadLetter(_ file: String) { withFolder("收起失败事件失败") { try $0.dismissDeadLetter(file) } }

    private func withFolder(_ what: String, _ body: (AgentBridgeIO) throws -> Void) {
        guard let url = resolveFolder() else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let io = AgentBridgeIO(root: url)
        do { try body(io) } catch { report(what, error) }
        refreshRuntime(io: io)
    }

    // MARK: 当前智能体状态标记（W24）

    /// 切换「当前智能体」时 / 启动时调用（AgentHub.apply）。**有意不受 isActive() 管**：切到内置智能体后桥接不是通道，
    /// 但心跳（独立于 App 的健康检查）需要知道「不写 context.json 是按设计」，否则会误报「App 没在运行」。
    /// 只写 runtime/active-agent.json 这一个文件：不同步、不导入、不写上下文 / 事件，不轮询（一次切换写一次）。
    /// 没连桥接目录 → 什么都不做（心跳那边会如实报「从没连上」）；通道标记不符 / 写失败 → 醒目报错（失败可见）。
    func markActiveAgent(_ kind: AgentKind) {
        guard let url = resolveFolder() else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try markActiveAgent(kind, io: AgentBridgeIO(root: url), at: .now) } catch { report("写当前智能体状态标记失败", error) }
    }

    /// 可直接用临时目录测试。通道不符（日用版 App 对着 Dev 工作区，或反之）→ 抛出，什么都不写。
    func markActiveAgent(_ kind: AgentKind, io: AgentBridgeIO, at now: Date) throws {
        if let mismatch = AppChannel.current.bridgeMismatch(io.root) { throw AgentBridgeError.invalid(mismatch) }
        try io.writeActiveAgentMarker(kind, at: now)
        DevLog.shared.info("智能体桥接", "已写当前智能体状态标记：\(kind.shortLabel)")
    }

    // MARK: 事件（SPEC §19 C1，默认关）

    /// 做完一件事等关键时刻：写事件唤醒智能体。未开启或未连接时什么都不做。
    /// 上下文收集要读 EventKit（async），所以写事件放进一个任务里跑；调用方保持同步签名。
    func emit(kind: String, summary: String, payload: [String: Any] = [:]) {
        guard isActive(), eventsEnabled(), connected else { return }
        nonisolated(unsafe) let payload = payload
        Task { await emitNow(kind: kind, summary: summary, payload: payload) }
    }

    /// emit 的异步本体：先刷新快照再写事件（调度器被事件唤醒时，智能体读到的就是此刻的上下文）。
    func emitNow(kind: String, summary: String, payload: [String: Any] = [:]) async {
        guard isActive(), eventsEnabled(), let url = resolveFolder() else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let io = AgentBridgeIO(root: url)
            try io.prepare()
            try io.writeContext(await contextProvider())   // 先刷新快照，智能体读到的就是此刻
            try io.writeEvent(kind: kind, summary: summary, payload: payload, at: .now)
            DevLog.shared.info("智能体桥接", "已写事件 \(kind)：\(summary)")
        } catch { report("写事件失败", error) }
    }

    /// 测试可注入；生产读 AgentEventSettings。
    var eventsEnabled: () -> Bool = { AgentEventSettings.enabled }

    /// SPEC §19 C1 W14 哨兵：在桥接目录里做一件事（写唤醒事件 / runtime/sentinel.json）。
    /// 不受「关键时刻唤醒」开关管——哨兵有自己的开关。refreshContext = 先刷新 context.json（唤醒前用）。
    /// 没连接或出错 → 抛出，由调用方写进自己的状态（失败可见）。
    func performInFolder(refreshContext: Bool, _ body: (AgentBridgeIO) throws -> Void) async throws {
        guard isActive() else { throw AgentBridgeError.invalid("当前智能体不是 Claude Code：桥接目录不是通道") }
        guard let url = resolveFolder() else { throw AgentBridgeError.invalid("桥接目录未连接") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let io = AgentBridgeIO(root: url)
        try io.prepare()
        if refreshContext { try io.writeContext(await contextProvider()) }
        try body(io)
    }

    /// 智能体提案有了结论（2 小时内）→ 一次性事件，让它知道结果、决定要不要跟进。
    private func emitResolvedProposals(io: AgentBridgeIO) throws {
        guard eventsEnabled() else { return }
        let key = "agentBridge.resolvedEmitted"
        var done = Set(defaults.stringArray(forKey: key) ?? [])
        let now = Date.now
        for p in center.proposals where p.origin == .agent && !done.contains(p.id.uuidString) {
            let state = p.effectiveState(at: now)
            // W10：你回了一句的提案不另发 proposal_resolved——那句话本身会作为 user_message（带 inReplyToProposal）唤醒智能体。
            if state == .replied { done.insert(p.id.uuidString); continue }
            guard state.isClosed, now.timeIntervalSince(p.appliedAt ?? p.decidedAt ?? p.expiresAt) < 7200 else { continue }
            try io.writeEvent(kind: "proposal_resolved", summary: "提案「\(p.title)」：\(state.label)",
                              payload: ["proposalId": p.id.uuidString, "state": state.rawValue], at: now)
            done.insert(p.id.uuidString)
        }
        defaults.set(Array(done.suffix(300)), forKey: key)
    }

    // MARK: 内部

    private func resolveFolder() -> URL? {
        #if os(macOS)
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            report("目录授权已失效，请重新选择", AgentBridgeError.invalid("书签无法解析")); return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
        #else
        return nil   // 智能体跑在 Mac 上；iOS 不连桥接目录
        #endif
    }

    private func report(_ what: String, _ error: Error) {
        lastError = "\(what)：\(error.localizedDescription)"
        DevLog.shared.error("智能体桥接", lastError!)
    }
}

// 写给智能体的上下文快照（AgentBridgeContext / AgentContextGatherer）见 AgentContext.swift（SPEC §19 A2）。
