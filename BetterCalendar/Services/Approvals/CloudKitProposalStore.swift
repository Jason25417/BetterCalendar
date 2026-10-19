//
//  CloudKitProposalStore.swift
//  BetterCalendar
//
//  SPEC §19 B 组的生产中转：iCloud 私有库里的独立 zone「BCApprovals」。
//  - 读取：按 zone 增量拉变更（不依赖查询索引；开发环境不会自动建索引，查询会直接失败）。
//  - 写决定：带「服务器版本未变」条件保存（.ifServerRecordUnchanged），冲突返回服务器最新版本。
//  - 唤醒：zone 订阅静默推送（只订这一个 zone，不被 SwiftData 同步的推送淹没）。
//  与 FocusFollow 同容器；B5（App 没开也能收到）的可见推送另行核实后再加。
//

import CloudKit
import Foundation

nonisolated enum ProposalRecordCodec {
    static let recordType = "BCProposal"

    static func recordID(_ id: UUID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    /// 整份提案以 JSON 存 payload（唯一真相）；state/title/expiresAt 镜像成独立字段，便于将来做推送文案与排查。
    static func encode(_ p: Proposal, into record: CKRecord) throws {
        let data = try JSONEncoder().encode(p)
        record["payload"] = String(decoding: data, as: UTF8.self) as CKRecordValue
        record["state"] = p.state.rawValue as CKRecordValue
        // W10：B5 可见推送在「记录新建」时由 iCloud 代发，文案取这两个镜像字段。预授权规则代你决定的提案
        // 建出来就不是待确认——文案写明「已按规则处理」，免得像在等你批准（本机刷新后也会收起它）。
        let auto = p.preauth.map { "已按预授权规则\($0.effect.label) · " } ?? ""
        record["title"] = (auto + p.title) as CKRecordValue
        record["body"] = p.notificationBody as CKRecordValue
        record["expiresAt"] = p.expiresAt as CKRecordValue
        record["createdAtLocal"] = p.createdAt as CKRecordValue
    }

    static func decode(_ record: CKRecord) throws -> Proposal {
        guard record.recordType == recordType, let raw = record["payload"] as? String,
              let p = try? JSONDecoder().decode(Proposal.self, from: Data(raw.utf8)),
              p.id.uuidString == record.recordID.recordName else {
            throw ProposalTransportError.invalidTransition("云端提案记录损坏（\(record.recordID.recordName.prefix(8))）")
        }
        return p
    }
}

actor CloudKitProposalStore: ProposalRecordStore {
    static let zoneID = CKRecordZone.ID(zoneName: "BCApprovals", ownerName: CKCurrentUserDefaultName)
    static let subscriptionID = "bc-approvals-zone-sub"
    /// B5（实验，默认关）：新提案的可见推送——App 没运行也能弹出带批准/拒绝的通知。
    static let alertSubscriptionID = "bc-approvals-alert-sub"

    private let db: CKDatabase
    /// 最近一次从服务器拿到的记录（含版本信息），供条件保存。
    private var known: [CKRecord.ID: CKRecord] = [:]
    private var changeToken: CKServerChangeToken?
    private var zoneReady = false

    init(containerIdentifier: String = AppChannel.current.cloudKitContainerID) {
        db = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    /// 推送是否来自本 zone 的订阅。
    nonisolated static func isProposalPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        [subscriptionID, alertSubscriptionID].contains(CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID)
    }

    /// 可见推送对应的提案 id（云端代发的通知没有本机写入的 bcProposalId，只能从推送载荷里取记录名）。
    nonisolated static func proposalId(fromAlertPush userInfo: [AnyHashable: Any]) -> UUID? {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              note.subscriptionID == alertSubscriptionID, let name = note.recordID?.recordName else { return nil }
        return UUID(uuidString: name)
    }

    /// B5 可见推送订阅是否存在（订阅属于 iCloud 账户：一端打开，所有设备都会收到）。
    func isAlertPushEnabled() async throws -> Bool {
        do { _ = try await db.subscription(for: Self.alertSubscriptionID); return true }
        catch let error as CKError where error.code == .unknownItem { return false }
    }

    /// 打开/关闭 B5 可见推送订阅。只在新建提案时触发（新提案必为待确认）；文案由云端代入记录的 title/body。
    func setAlertPush(enabled: Bool) async throws {
        try await ensureZone()
        guard enabled else {
            do { _ = try await db.deleteSubscription(withID: Self.alertSubscriptionID) }
            catch let error as CKError where error.code == .unknownItem {}
            return
        }
        let sub = CKQuerySubscription(recordType: ProposalRecordCodec.recordType, predicate: NSPredicate(value: true),
                                      subscriptionID: Self.alertSubscriptionID, options: [.firesOnRecordCreation])
        sub.zoneID = Self.zoneID
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "BC_PROPOSAL_PUSH_TITLE"; info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "BC_PROPOSAL_PUSH_BODY"; info.alertLocalizationArgs = ["body"]
        info.category = "BC_PROPOSAL"
        info.soundName = "default"
        sub.notificationInfo = info
        _ = try await db.save(sub)
    }

    func ensureSubscription() async throws {
        try await ensureZone()
        let sub = CKRecordZoneSubscription(zoneID: Self.zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // 静默唤醒；可见通知由本机按提案内容生成
        sub.notificationInfo = info
        _ = try await db.save(sub)
    }

    func create(_ proposal: Proposal) async throws {
        try await ensureZone()
        let record = CKRecord(recordType: ProposalRecordCodec.recordType,
                              recordID: ProposalRecordCodec.recordID(proposal.id, zoneID: Self.zoneID))
        try ProposalRecordCodec.encode(proposal, into: record)
        let saved = try await db.save(record)
        known[saved.recordID] = saved
    }

    func all() async throws -> [Proposal] {
        try await ensureZone()
        var moreComing = true
        while moreComing {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await db.recordZoneChanges(inZoneWith: Self.zoneID, since: changeToken)
            } catch let error as CKError where error.code == .changeTokenExpired {
                changeToken = nil; known = [:]   // 令牌过期：全量重拉
                continue
            }
            for (id, result) in changes.modificationResultsByID {
                switch result {
                case let .success(modification):
                    // 同分区还有智能体消息（BCAgentMessage）：只收提案记录，其余静默跳过。
                    if modification.record.recordType == ProposalRecordCodec.recordType { known[id] = modification.record }
                case let .failure(error):
                    DevLog.shared.warn("多端审批", "拉取一条提案失败（\(id.recordName.prefix(8))）：\(error.localizedDescription)")
                }
            }
            for deletion in changes.deletions { known[deletion.recordID] = nil }
            changeToken = changes.changeToken
            moreComing = changes.moreComing
        }
        return known.values.compactMap { record in
            do { return try ProposalRecordCodec.decode(record) } catch {
                DevLog.shared.error("多端审批", error.localizedDescription); return nil
            }
        }
    }

    func latest(_ id: UUID) async throws -> Proposal? {
        try await ensureZone()
        let recordID = ProposalRecordCodec.recordID(id, zoneID: Self.zoneID)
        do {
            let record = try await db.record(for: recordID)
            known[recordID] = record
            return try ProposalRecordCodec.decode(record)
        } catch let error as CKError where error.code == .unknownItem {
            known[recordID] = nil
            return nil
        }
    }

    func update(_ proposal: Proposal) async throws -> ProposalUpdateResult {
        let recordID = ProposalRecordCodec.recordID(proposal.id, zoneID: Self.zoneID)
        if known[recordID] == nil { _ = try await latest(proposal.id) }
        guard let base = known[recordID]?.copy() as? CKRecord else { throw ProposalTransportError.notFound(proposal.id) }
        try ProposalRecordCodec.encode(proposal, into: base)
        do {
            let (results, _) = try await db.modifyRecords(saving: [base], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            switch results[recordID] {
            case let .success(saved)?:
                known[recordID] = saved
                return .saved(try ProposalRecordCodec.decode(saved))
            case let .failure(error)?:
                if let server = Self.serverRecord(in: error, for: recordID) { return try conflict(server) }
                throw error
            case nil:
                throw ProposalTransportError.invalidTransition("保存结果缺失；状态未知，请刷新核对")
            }
        } catch {
            if let server = Self.serverRecord(in: error, for: recordID) { return try conflict(server) }
            throw error
        }
    }

    // MARK: 内部

    private func conflict(_ server: CKRecord) throws -> ProposalUpdateResult {
        known[server.recordID] = server
        return .conflict(try ProposalRecordCodec.decode(server))
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        zoneReady = true
    }

    /// 从「服务器版本已变」错误（含批量部分失败）里取出服务器上的最新记录。
    private static func serverRecord(in error: Error, for id: CKRecord.ID) -> CKRecord? {
        guard let ck = error as? CKError else { return nil }
        if ck.code == .serverRecordChanged { return ck.serverRecord }
        if ck.code == .partialFailure, let inner = ck.partialErrorsByItemID?[id] as? CKError,
           inner.code == .serverRecordChanged { return inner.serverRecord }
        return nil
    }
}
