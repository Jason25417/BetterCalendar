//
//  CloudKitSharedTimerStore.swift
//  BetterCalendar
//
//  W5：共享计时的生产存储——iCloud 私有库独立 zone「BCSharedTimer」，一次计时一条 BCTimerSession 记录。
//  - 读取：zone 增量变更（不依赖查询索引）。
//  - 写入：.ifServerRecordUnchanged 条件保存；冲突返回服务器最新版本（同 CloudKitProposalStore）。
//  - 唤醒：zone 订阅静默推送。
//  ⚠️ 新记录类型 BCTimerSession：须先在 Development 建出并 Deploy 到 Production（由协调者安排）。
//

import CloudKit
import Foundation

nonisolated enum SharedTimerRecordCodec {
    static let recordType = "BCTimerSession"

    static func recordID(_ id: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }

    /// payload = 整份会话 JSON（唯一真相）；其余字段只是镜像，便于排查，不参与判断。
    static func encode(_ s: SharedTimerSession, into record: CKRecord) throws {
        try s.validate()
        let data = try JSONEncoder().encode(s)
        record["payload"] = String(decoding: data, as: UTF8.self) as CKRecordValue
        record["status"] = s.status.rawValue as CKRecordValue
        record["revision"] = Int64(s.revision) as CKRecordValue
        record["title"] = s.title as CKRecordValue
        record["updatedAt"] = s.updatedAt as CKRecordValue
        record["startedAt"] = s.startedAt as CKRecordValue
        record["mode"] = s.mode.rawValue as CKRecordValue
        record["experiment"] = Int64(s.experiment ? 1 : 0) as CKRecordValue
    }

    static func decode(payload raw: String?, recordName: String) throws -> SharedTimerSession {
        guard let raw, let s = try? JSONDecoder().decode(SharedTimerSession.self, from: Data(raw.utf8)),
              s.id == recordName else {
            throw SharedTimerRejection(code: 422, message: "iCloud 计时记录损坏（\(recordName.prefix(12))）")
        }
        try s.validate()
        return s
    }

    static func decode(_ record: CKRecord) throws -> SharedTimerSession {
        guard record.recordType == recordType else {
            throw SharedTimerRejection(code: 422, message: "不是计时记录（\(record.recordType)）")
        }
        return try decode(payload: record["payload"] as? String, recordName: record.recordID.recordName)
    }
}

actor CloudKitSharedTimerStore: SharedTimerRecordStore {
    static let zoneID = CKRecordZone.ID(zoneName: "BCSharedTimer", ownerName: CKCurrentUserDefaultName)
    static let subscriptionID = "bc-shared-timer-zone-sub"

    private let db: CKDatabase
    private var known: [CKRecord.ID: CKRecord] = [:]
    private var changeToken: CKServerChangeToken?
    private var zoneReady = false

    init(containerIdentifier: String = AppChannel.current.cloudKitContainerID) {
        db = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    nonisolated static func isTimerPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == subscriptionID
    }

    func ensureSubscription() async throws {
        try await ensureZone()
        let sub = CKRecordZoneSubscription(zoneID: Self.zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // 静默唤醒，不打扰
        sub.notificationInfo = info
        _ = try await db.save(sub)
    }

    func allSessions() async throws -> [SharedTimerSession] {
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
                    if modification.record.recordType == SharedTimerRecordCodec.recordType { known[id] = modification.record }
                case let .failure(error):
                    let text = "拉取一条计时失败（\(id.recordName.prefix(12))）：\(error.localizedDescription)"
                    await MainActor.run { DevLog.shared.warn("共享计时", text) }
                }
            }
            for deletion in changes.deletions { known[deletion.recordID] = nil }
            changeToken = changes.changeToken
            moreComing = changes.moreComing
        }
        var sessions: [SharedTimerSession] = []
        for record in known.values {
            do { sessions.append(try SharedTimerRecordCodec.decode(record)) } catch {
                let text = error.localizedDescription   // 坏记录跳过但可见，不拖垮整个计时显示
                await MainActor.run { DevLog.shared.error("共享计时", text) }
            }
        }
        return sessions
    }

    func latest(_ id: String) async throws -> SharedTimerSession? {
        try await ensureZone()
        let recordID = SharedTimerRecordCodec.recordID(id, zoneID: Self.zoneID)
        do {
            let record = try await db.record(for: recordID)
            known[recordID] = record
            return try SharedTimerRecordCodec.decode(record)
        } catch let error as CKError where error.code == .unknownItem {
            known[recordID] = nil
            return nil
        }
    }

    func save(_ session: SharedTimerSession, isNew: Bool) async throws -> SharedTimerSaveResult {
        try await ensureZone()
        let recordID = SharedTimerRecordCodec.recordID(session.id, zoneID: Self.zoneID)
        let base: CKRecord
        if isNew {
            base = CKRecord(recordType: SharedTimerRecordCodec.recordType, recordID: recordID)
        } else {
            guard let known = known[recordID]?.copy() as? CKRecord else {
                throw SharedTimerRejection(code: 404, message: "本机尚未读到这条计时的最新版本")
            }
            base = known
        }
        try SharedTimerRecordCodec.encode(session, into: base)
        do {
            let (results, _) = try await db.modifyRecords(saving: [base], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            switch results[recordID] {
            case let .success(saved)?:
                known[recordID] = saved
                return .saved(try SharedTimerRecordCodec.decode(saved))
            case let .failure(error)?:
                if let server = Self.serverRecord(in: error, for: recordID) { return try conflict(server) }
                throw error
            case nil:
                throw URLError(.cannotParseResponse)   // 结果缺失：状态未知，按暂时错误保留命令重试
            }
        } catch {
            if let server = Self.serverRecord(in: error, for: recordID) { return try conflict(server) }
            throw error
        }
    }

    #if DEBUG
    /// 开发者显式操作：在 Development 写一条「已结束」的探针记录，让 CloudKit 建出 BCTimerSession schema。
    /// 探针是 finished 状态，不会出现在当前计时里。
    func seedDevelopmentSchema(now: Date) async throws {
        try await ensureZone()
        let probe = SharedTimerSession(id: "timer_schema_probe", title: "schema probe", status: .finished, startedAt: now,
                                       activeSince: nil, elapsedMs: 0, updatedAt: now, revision: 2, origin: "schema-probe",
                                       lastCommandId: "schema-probe-finish", mode: .light, focusMinutes: nil, experiment: true,
                                       events: [.init(commandId: "schema-probe-start", action: .start, occurredAt: now, recordedAt: now,
                                                      deviceId: "schema-probe", revisionAfter: 1, fingerprint: ""),
                                                .init(commandId: "schema-probe-finish", action: .finish, occurredAt: now, recordedAt: now,
                                                      deviceId: "schema-probe", revisionAfter: 2, fingerprint: "")])
        let recordID = SharedTimerRecordCodec.recordID(probe.id, zoneID: Self.zoneID)
        let record: CKRecord
        do { record = try await db.record(for: recordID) }
        catch let e as CKError where e.code == .unknownItem { record = CKRecord(recordType: SharedTimerRecordCodec.recordType, recordID: recordID) }
        try SharedTimerRecordCodec.encode(probe, into: record)
        _ = try await db.save(record)
        try await ensureSubscription()
    }
    #endif

    // MARK: 内部

    private func conflict(_ server: CKRecord) throws -> SharedTimerSaveResult {
        known[server.recordID] = server
        return .conflict(try SharedTimerRecordCodec.decode(server))
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        zoneReady = true
    }

    private static func serverRecord(in error: Error, for id: CKRecord.ID) -> CKRecord? {
        guard let ck = error as? CKError else { return nil }
        if ck.code == .serverRecordChanged { return ck.serverRecord }
        if ck.code == .partialFailure, let inner = ck.partialErrorsByItemID?[id] as? CKError,
           inner.code == .serverRecordChanged { return inner.serverRecord }
        return nil
    }
}
