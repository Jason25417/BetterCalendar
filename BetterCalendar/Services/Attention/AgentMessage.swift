//
//  AgentMessage.swift
//  BetterCalendar
//
//  SPEC §19 C2/C4：智能体主动发给 Jason 的一句话（没有审批按钮）。
//  由 Mac 端导入时按打扰规则（C3）决定「弹出」还是「拦下」；各端同步同一份记录，只弹一次；
//  Jason 的反应（好 / 静音）被记下来，供智能体以后调低打扰。
//

import CloudKit
import Foundation
import Observation

nonisolated struct AgentMessage: Identifiable, Codable, Equatable, Sendable {
    enum Delivery: String, Codable, Sendable { case delivered, suppressed }
    /// W42：notUseful =「没用」（只由 Jason 点；哨兵据此校准：同一签名当天不再叫醒、那类信号门槛升高）。
    enum Reaction: String, Codable, Sendable { case acknowledged, muted, notUseful }

    var id: UUID
    var createdAt: Date
    var originLabel: String
    var parentRef: String?
    var title: String
    var body: String
    /// 智能体给的一句理由（为什么此刻值得说）。
    var reason: String
    var delivery: Delivery
    var suppressReason: String?
    var reaction: Reaction?
    var reactedAt: Date?
    var reactedByDeviceId: String?
    // —— W42（Optional：只在 JSON 载荷里，不改 CloudKit schema）——
    /// 这条是哨兵叫醒后发的：叫醒的信号（planned_start_passed…）与签名（同一块同一类 = 同一签名）。nil = 不是哨兵叫醒的。
    var wakeSignals: [String]? = nil
    var wakeSignature: String? = nil
}

nonisolated struct AgentMessageDraft: Sendable {
    var id: UUID? = nil
    var originLabel = "BetterCalendar 智能体"
    var parentRef: String? = nil
    var title: String
    var body: String
    var reason: String
    var wakeSignals: [String]? = nil
    var wakeSignature: String? = nil
}

nonisolated protocol AgentMessageTransport: Sendable {
    func post(_ message: AgentMessage) async throws
    func fetchRecent() async throws -> [AgentMessage]
    func save(_ message: AgentMessage) async throws
}

actor InMemoryAgentMessageTransport: AgentMessageTransport {
    private var store: [UUID: AgentMessage] = [:]
    func post(_ message: AgentMessage) async throws { store[message.id] = message }
    func fetchRecent() async throws -> [AgentMessage] { store.values.sorted { $0.createdAt > $1.createdAt } }
    func save(_ message: AgentMessage) async throws { store[message.id] = message }
}

/// 与提案同一个 iCloud 私有分区（BCApprovals），记录类型 BCAgentMessage。反应只增不改：最后一次反应覆盖（无冲突语义需要）。
actor CloudKitAgentMessageStore: AgentMessageTransport {
    static let recordType = "BCAgentMessage"
    private let db: CKDatabase
    private var known: [CKRecord.ID: CKRecord] = [:]
    private var changeToken: CKServerChangeToken?

    init(containerIdentifier: String = AppChannel.current.cloudKitContainerID) {
        db = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    private func recordID(_ id: UUID) -> CKRecord.ID { CKRecord.ID(recordName: "msg-" + id.uuidString, zoneID: CloudKitProposalStore.zoneID) }

    private func encode(_ m: AgentMessage, into r: CKRecord) throws {
        r["payload"] = String(decoding: try JSONEncoder().encode(m), as: UTF8.self) as CKRecordValue
        r["title"] = m.title as CKRecordValue
        r["body"] = m.body as CKRecordValue
        r["delivery"] = m.delivery.rawValue as CKRecordValue
    }

    private func decode(_ r: CKRecord) -> AgentMessage? {
        guard r.recordType == Self.recordType, let raw = r["payload"] as? String,
              let m = try? JSONDecoder().decode(AgentMessage.self, from: Data(raw.utf8)) else { return nil }
        return m
    }

    func post(_ message: AgentMessage) async throws {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID(message.id))
        try encode(message, into: r)
        known[r.recordID] = try await db.save(r)
    }

    func fetchRecent() async throws -> [AgentMessage] {
        var more = true
        while more {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await db.recordZoneChanges(inZoneWith: CloudKitProposalStore.zoneID, since: changeToken)
            } catch let error as CKError where error.code == .changeTokenExpired {
                changeToken = nil; known = [:]; continue
            } catch let error as CKError where error.code == .zoneNotFound {
                return []   // 提案侧还没建过分区：此时也不会有消息
            }
            for (id, result) in changes.modificationResultsByID {
                if case let .success(m) = result, m.record.recordType == Self.recordType { known[id] = m.record }
            }
            for d in changes.deletions { known[d.recordID] = nil }
            changeToken = changes.changeToken; more = changes.moreComing
        }
        return known.values.compactMap(decode).sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ message: AgentMessage) async throws {
        let id = recordID(message.id)
        let base: CKRecord
        if let cached = known[id]?.copy() as? CKRecord { base = cached } else { base = try await db.record(for: id) }
        try encode(message, into: base)
        let (results, _) = try await db.modifyRecords(saving: [base], deleting: [], savePolicy: .changedKeys, atomically: true)
        if case let .success(saved)? = results[id] { known[id] = saved }
    }
}

@MainActor protocol AgentMessageNotifying {
    func show(_ message: AgentMessage) async
    func withdraw(_ id: UUID) async
}

@MainActor @Observable final class AgentMessageCenter {
    private(set) var messages: [AgentMessage] = []
    private(set) var lastError: String?
    var settings: AttentionSettings { didSet { settings.save(defaults) } }

    let deviceId: String
    private let transport: any AgentMessageTransport
    private let notifier: any AgentMessageNotifying
    let ledger: any OperationLedger
    private let defaults: UserDefaults
    private let now: () -> Date
    /// 本机已弹过的消息（用户手动划掉后也不再重弹）。
    private var shownHere: Set<UUID>

    init(transport: any AgentMessageTransport, notifier: any AgentMessageNotifying, ledger: any OperationLedger,
         deviceId: String, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.transport = transport; self.notifier = notifier; self.ledger = ledger
        self.deviceId = deviceId; self.defaults = defaults; self.now = now
        settings = AttentionSettings.load(defaults)
        shownHere = Set((defaults.stringArray(forKey: "attention.shownHere") ?? []).compactMap(UUID.init))
    }

    /// 设置从另一台设备同步过来后重读（W8：打扰设置随 iCloud 设置同步，一端静音两端生效）。
    func reloadSettings() {
        let latest = AttentionSettings.load(defaults)
        if latest != settings { settings = latest }
    }

    /// 智能体发来一句话（由 Mac 端桥接导入）：先过打扰规则，再保存并同步到各端。
    @discardableResult
    func receive(_ draft: AgentMessageDraft) async -> AgentMessage? {
        let at = now()
        await refresh()
        if let id = draft.id, let existing = messages.first(where: { $0.id == id }) { return existing }   // 幂等
        let delivered = messages.filter { $0.delivery == .delivered }.map(\.createdAt)
        let verdict = AttentionPolicy.evaluate(settings, at: at, recentDeliveries: delivered)
        var m = AgentMessage(id: draft.id ?? UUID(), createdAt: at, originLabel: draft.originLabel, parentRef: draft.parentRef,
                             title: draft.title, body: draft.body, reason: draft.reason, delivery: .delivered)
        if case let .suppress(why) = verdict { m.delivery = .suppressed; m.suppressReason = why }
        m.wakeSignals = draft.wakeSignals; m.wakeSignature = draft.wakeSignature
        do {
            try await transport.post(m)
            record(.agent, draft.originLabel, m.delivery == .delivered ? "message.delivered" : "message.suppressed", m,
                   m.delivery == .delivered ? "主动通知：\(m.title)" : "已拦下：\(m.suppressReason ?? "")")
            await refresh()
            return m
        } catch {
            fail("保存智能体消息失败", error); return nil
        }
    }

    /// 推送唤醒 / 回前台时调用：本机弹出新的、未被回应的消息（6 小时内），已回应的收起。
    func refresh() async {
        do { messages = try await transport.fetchRecent() } catch { fail("读取智能体消息失败", error); return }
        DevLog.shared.resolve(source: "智能体消息")   // W16：拉取成功 = 短暂失败自动消除
        let cutoff = now().addingTimeInterval(-6 * 3600)
        for m in messages where m.delivery == .delivered && m.reaction == nil && m.createdAt > cutoff && !shownHere.contains(m.id) {
            await notifier.show(m)
            shownHere.insert(m.id)
            record(.system, "BetterCalendar", "message.notified", m, "已在本机弹出")
        }
        for m in messages where m.reaction != nil { await notifier.withdraw(m.id) }
        defaults.set(Array(shownHere.map(\.uuidString).suffix(200)), forKey: "attention.shownHere")
    }

    /// Jason 的反应（C4）。静音 = 两小时内不再弹任何智能体通知。
    func react(_ id: UUID, _ reaction: AgentMessage.Reaction) async {
        guard var m = messages.first(where: { $0.id == id }) else { await refresh(); return }
        m.reaction = reaction; m.reactedAt = now(); m.reactedByDeviceId = deviceId
        if reaction == .muted { settings.mutedUntil = now().addingTimeInterval(2 * 3600) }
        do {
            try await transport.save(m)
            record(.user, "你", "message.\(reaction.rawValue)", m, reaction == .muted ? "静音 2 小时" : reaction == .notUseful ? "没用" : "知道了")
            await refresh()
        } catch { fail("保存回应失败", error) }
    }

    func clearError() { lastError = nil }

    private func record(_ actor: ProposalOrigin, _ label: String, _ event: String, _ m: AgentMessage, _ detail: String) {
        ledger.append(OperationRecord(at: now(), actor: actor, actorLabel: label, deviceId: deviceId, event: event,
                                      proposalId: m.id, parentId: nil, parentRef: m.parentRef, detail: detail))
    }

    private func fail(_ what: String, _ error: Error) {
        lastError = "\(what)：\(error.localizedDescription)"
        DevLog.shared.error("智能体消息", lastError!)
    }
}
