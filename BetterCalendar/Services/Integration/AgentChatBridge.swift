//
//  AgentChatBridge.swift
//  BetterCalendar
//
//  SPEC §19 A1 / F1 的桥接一步（Mac 端，AgentBridge 每轮同步时调用；协议见智能体工作区 bridge/README.md）：
//    - 导入智能体回复 chat/*.json（reply_jason 写）→ 存 iCloud 同步各端，导入后移入 chat/imported/，坏文件移入 chat/rejected/；
//    - 把还没转交的你的消息写成 user_message 事件（调度器据此唤醒智能体），并写「已转交」回执；
//    - 到了晚间复盘时刻（默认关）写 evening_review 事件，一天一次；
//    - 写 chat/history.json（最近 40 条对话 + 卡片上提案的最新状态），供智能体 read_chat。
//  user_message 是你主动对智能体说话：只要桥接已连接就转交，不受「关键时刻唤醒智能体」开关限制（那个开关管的是 App 自己发起的事件）。
//

import Foundation

extension AgentBridgeIO {
    func prepareChat() throws {
        for sub in ["chat/imported", "chat/rejected"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    func pendingChatFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("chat"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "history.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 智能体回复文件 → 草稿。严格校验；不认识的 kind、坏的 id 一律拒绝，绝不猜测。
    static func chatReplyDraft(from data: Data) throws -> AgentChatReplyDraft {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], o["schemaVersion"] as? Int == 1 else {
            throw AgentBridgeError.invalid("不是 v1 对话回复文件")
        }
        guard let raw = o["id"] as? String, let id = UUID(uuidString: raw) else { throw AgentBridgeError.invalid("回复 id 缺失或不是 UUID") }
        guard let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 1000 else {
            throw AgentBridgeError.invalid("回复正文缺失或过长（≤1000 字）")
        }
        let kindRaw = (o["kind"] as? String) ?? AgentChatMessage.Kind.chat.rawValue
        guard let kind = AgentChatMessage.Kind(rawValue: kindRaw) else { throw AgentBridgeError.invalid("不认识的回复种类 \(kindRaw)") }
        var replyTo: UUID?
        if let r = o["replyTo"], !(r is NSNull) {
            guard let s = r as? String, let u = UUID(uuidString: s) else { throw AgentBridgeError.invalid("replyTo 不是消息 UUID") }
            replyTo = u
        }
        let rawIds = (o["proposalIds"] as? [Any]) ?? []
        guard rawIds.count <= 5 else { throw AgentBridgeError.invalid("一条回复最多带 5 张提案卡片") }
        let ids = try rawIds.map { v -> UUID in
            guard let s = v as? String, let u = UUID(uuidString: s) else { throw AgentBridgeError.invalid("proposalIds 里有不是 UUID 的项") }
            return u
        }
        return AgentChatReplyDraft(id: id, text: text, kind: kind, replyTo: replyTo, proposalIds: ids,
                                   parentRef: o["parentEventId"] as? String)
    }

    /// 最近 40 条对话（只在内容变化时重写）。卡片附提案最新状态，智能体不必再翻 results/。
    func writeChatHistory(_ messages: [AgentChatMessage], proposals: [Proposal], status: (AgentChatMessage) -> AgentChatUserStatus, at now: Date) throws {
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = messages.suffix(40).map { m in
            var row: [String: Any] = ["id": m.id.uuidString, "at": iso.string(from: m.createdAt), "author": m.author.rawValue,
                                      "kind": m.kind.rawValue, "text": m.text, "device": m.deviceLabel,
                                      "replyTo": m.replyTo?.uuidString ?? NSNull()]
            if m.author == .user { row["status"] = status(m).label }
            if !m.proposalIds.isEmpty {
                row["proposals"] = m.proposalIds.map { id -> [String: Any] in
                    guard let p = proposals.first(where: { $0.id == id }) else { return ["id": id.uuidString, "state": "unknown"] }
                    return ["id": id.uuidString, "title": p.title, "state": p.effectiveState(at: now).rawValue]
                }
            }
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "messages": rows], options: [.prettyPrinted, .sortedKeys])
        if (try? Data(contentsOf: root.appendingPathComponent("chat/history.json"))) != data { try writeAtomic(data, to: "chat/history.json") }
    }
}

@MainActor enum AgentChatBridgeStep {
    /// 一轮对话桥接（可直接用临时目录测试）。单个文件出错只影响它自己；目录级错误抛给 AgentBridge 显示。
    static func run(io: AgentBridgeIO, chat: AgentChatCenter, proposals: [Proposal], defaults: UserDefaults,
                    eveningFacts: () -> [String: Any], now: Date, report: (String, Error) -> Void) async throws {
        try io.prepareChat()
        await chat.refresh()
        // ① 智能体回复 → iCloud（提案文件已在本轮更早导入，卡片引用的提案通常已经在）
        for file in try io.pendingChatFiles() {
            do {
                let draft = try AgentBridgeIO.chatReplyDraft(from: Data(contentsOf: file))
                guard await chat.receiveAgent(draft) != nil else { continue }   // 存 iCloud 失败：留原处下轮重试（错误已可见）
                try io.move(file, to: "imported", kind: "chat")
            } catch {
                try? io.move(file, to: "rejected", note: error.localizedDescription, kind: "chat")
                report("拒绝导入智能体回复 \(file.lastPathComponent)", error)
            }
        }
        // ② 你的消息 → user_message 事件
        let iso = ISO8601DateFormatter()
        for m in chat.pendingForwards() {
            var payload: [String: Any] = ["messageId": m.id.uuidString, "text": m.text, "device": m.deviceLabel,
                                          "saidAt": iso.string(from: m.createdAt)]
            if let rid = m.replyTo, let prior = chat.messages.first(where: { $0.id == rid }) {
                payload["inReplyTo"] = ["id": rid.uuidString, "kind": prior.kind.rawValue, "text": String(prior.text.prefix(200))]
            }
            try io.writeEvent(kind: "user_message", summary: "Jason 在对话里说：\(m.text.prefix(80))", payload: payload, at: now)
            await chat.markForwarded(m.id)
            DevLog.shared.info("智能体对话", "已转交智能体：\(m.text.prefix(40))")
        }
        // ③ 晚间复盘（F1，默认关）
        if let day = EveningReviewSettings.dueDayKey(enabled: EveningReviewSettings.enabled(defaults), minute: EveningReviewSettings.minute(defaults),
                                                     lastDayKey: defaults.string(forKey: EveningReviewSettings.lastDayKey), now: now) {
            let minute = EveningReviewSettings.minute(defaults)
            var payload = eveningFacts()
            payload["logicalDay"] = day
            payload["configuredTime"] = String(format: "%02d:%02d", minute / 60, minute % 60)
            try io.writeEvent(kind: "evening_review", summary: "晚间复盘时间到：在对话里写「今天做成了什么」", payload: payload, at: now)
            defaults.set(day, forKey: EveningReviewSettings.lastDayKey)
            DevLog.shared.info("智能体对话", "已发晚间复盘事件（\(day)）")
        }
        // ④ 对话历史给 read_chat
        try io.writeChatHistory(chat.messages, proposals: proposals, status: { chat.status(of: $0) }, at: now)
    }

    /// 晚间复盘的事实素材（做成了什么）：执行陪伴今天记下的「实际」。只给事实，措辞交给智能体按正反馈原则写。
    static func eveningFacts(done: [(title: String, start: Date, end: Date)]) -> [String: Any] {
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        let items: [[String: Any]] = done.sorted { $0.start < $1.start }.map {
            ["title": $0.title, "start": hm.string(from: $0.start), "end": hm.string(from: $0.end),
             "minutes": max(1, Int($0.end.timeIntervalSince($0.start) / 60))]
        }
        return ["doneToday": items, "doneSource": "BetterCalendar 执行陪伴记下的实际（蓝色日历同源）"]
    }
}
