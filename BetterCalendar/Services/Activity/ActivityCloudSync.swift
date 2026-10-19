//
//  ActivityCloudSync.swift
//  BetterCalendar
//
//  W13：iPhone 活动记录 → iCloud 私有库 → Mac 导入本机 ActivityLog（智能体住在 Mac 上）。
//  - 独立 zone「BCActivity」（不放进 BCApprovals：那个 zone 有推送订阅，每次打开 App 都会推一遍、唤醒两端刷新提案，
//    且提案/对话/消息的增量拉取都会被几百条活动记录拖慢）。本 zone 不建订阅：Mac 每 2 分钟拉一次增量即可。
//  - 记录类型 BCActivityEvent（一条事件一条记录，记录名 act-<uuid>，内容不可变，重传幂等）：
//      payload String（整条 ActivityEvent 的 JSON，唯一真相）+ 镜像字段 at Date、kind String、deviceId String、platform String、
//      appName String（可空）——镜像只便于在 CloudKit 控制台排查，不参与判断。
//    ⚠️ 新记录类型：须由协调者在 Development 建出（BC_DEV_SEED_ACTIVITY=1 启动 Debug 版）并 Deploy 到 Production。
//  - iPhone：先写本机日文件 + 待上传队列（ActivityOutbox），再尽力上传；传不上留在队列里，下次快捷指令 / 打开 App 再传。
//  - Mac：增量拉取（变更令牌存 UserDefaults，Data 是 plist 类型）→ 按 id 去重写入本机日志 → 记下 (记录名, 时刻) 索引，
//    超过 14 天的云端记录删掉（只是传输通道的清理，Mac 本机已有一份；14 天 = 稳定性边界，防 zone 无限变大）。
//

import CloudKit
import Foundation

nonisolated enum ActivityCloudCodec {
    static let recordType = "BCActivityEvent"
    static let zoneID = CKRecordZone.ID(zoneName: "BCActivity", ownerName: CKCurrentUserDefaultName)

    static func recordID(_ id: UUID) -> CKRecord.ID { CKRecord.ID(recordName: "act-" + id.uuidString, zoneID: zoneID) }

    static func record(_ e: ActivityEvent) throws -> CKRecord {
        let r = CKRecord(recordType: recordType, recordID: recordID(e.id))
        r["payload"] = String(decoding: try ActivityCodec.encoder().encode(e), as: UTF8.self) as CKRecordValue
        r["at"] = e.at as CKRecordValue
        r["kind"] = e.kind.rawValue as CKRecordValue
        r["deviceId"] = e.deviceId as CKRecordValue
        r["platform"] = e.platform as CKRecordValue
        if let a = e.appName { r["appName"] = a as CKRecordValue }
        return r
    }

    /// 解不出 / 记录名对不上 → nil（坏记录不进日志）。
    static func event(_ r: CKRecord) -> ActivityEvent? {
        guard r.recordType == recordType, let raw = r["payload"] as? String,
              let e = try? ActivityCodec.decoder().decode(ActivityEvent.self, from: Data(raw.utf8)),
              r.recordID.recordName == "act-" + e.id.uuidString else { return nil }
        return e
    }
}

/// iCloud 传输（生产 = CloudKitActivityStore；测试用内存版）。
nonisolated protocol ActivityCloudTransport: Sendable {
    func upload(_ events: [ActivityEvent]) async throws
    /// 增量拉取：token = 上次的变更令牌（归档成 Data）；返回新事件、坏记录数、新令牌。
    func fetchChanges(since token: Data?) async throws -> (events: [ActivityEvent], bad: Int, token: Data?)
    func delete(_ ids: [UUID]) async throws
}

actor CloudKitActivityStore: ActivityCloudTransport {
    private let db: CKDatabase
    private var zoneReady = false

    init(containerIdentifier: String = "iCloud.com.jason.BetterCalendar") {
        db = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: ActivityCloudCodec.zoneID)], deleting: [])
        zoneReady = true
    }

    func upload(_ events: [ActivityEvent]) async throws {
        guard !events.isEmpty else { return }
        try await ensureZone()
        for chunk in stride(from: 0, to: events.count, by: 200).map({ Array(events[$0..<min($0 + 200, events.count)]) }) {
            let records = try chunk.map(ActivityCloudCodec.record)
            let (results, _) = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
            for (_, r) in results { if case let .failure(error) = r { throw error } }
        }
    }

    func fetchChanges(since token: Data?) async throws -> (events: [ActivityEvent], bad: Int, token: Data?) {
        var current = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        var events: [ActivityEvent] = [], bad = 0, more = true, guardCount = 0
        while more, guardCount < 50 {   // 50 页 = 防失控上限
            guardCount += 1
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await db.recordZoneChanges(inZoneWith: ActivityCloudCodec.zoneID, since: current)
            } catch let error as CKError where error.code == .changeTokenExpired {
                current = nil; continue   // 令牌过期：从头拉，导入端按 id 去重
            } catch let error as CKError where error.code == .zoneNotFound {
                return ([], 0, token)     // iPhone 还没传过任何一条
            }
            for (_, result) in changes.modificationResultsByID {
                guard case let .success(m) = result else { bad += 1; continue }
                if let e = ActivityCloudCodec.event(m.record) { events.append(e) } else { bad += 1 }
            }
            current = changes.changeToken; more = changes.moreComing
        }
        let data = current.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return (events, bad, data)
    }

    func delete(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: 300).map({ Array(ids[$0..<min($0 + 300, ids.count)]) }) {
            _ = try await db.modifyRecords(saving: [], deleting: chunk.map(ActivityCloudCodec.recordID), savePolicy: .allKeys, atomically: false)
        }
    }
}

actor MemoryActivityCloud: ActivityCloudTransport {
    private(set) var stored: [UUID: ActivityEvent] = [:]
    private var order: [UUID] = []
    var failUpload = false
    func setFailUpload(_ v: Bool) { failUpload = v }
    func upload(_ events: [ActivityEvent]) async throws {
        if failUpload { throw URLError(.notConnectedToInternet) }
        for e in events { if stored[e.id] == nil { order.append(e.id) }; stored[e.id] = e }
    }
    func fetchChanges(since token: Data?) async throws -> (events: [ActivityEvent], bad: Int, token: Data?) {
        let start = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let ids = order.dropFirst(start)
        return (ids.compactMap { stored[$0] }, 0, Data(String(order.count).utf8))
    }
    func delete(_ ids: [UUID]) async throws { for id in ids { stored[id] = nil } }
}

/// iPhone 待上传队列（本机文件）。上限 5000 条 = 稳定性边界（长期离线时丢最旧的，并记 DevLog）。
actor ActivityOutbox {
    static let limit = 5000
    private let url: URL?
    private var pending: [ActivityEvent]
    private(set) var dropped = 0

    /// url = nil：只在内存（测试）。
    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) { pending = ActivityCodec.decodeLines(data).events } else { pending = [] }
    }

    static var defaultURL: URL {
        FileActivityLog.defaultRoot.deletingLastPathComponent().appendingPathComponent("ActivityOutbox.jsonl")
    }

    var count: Int { pending.count }

    func enqueue(_ events: [ActivityEvent]) throws {
        pending += events
        if pending.count > Self.limit { dropped += pending.count - Self.limit; pending.removeFirst(pending.count - Self.limit) }
        try save()
    }

    /// 尽力上传；成功的移出队列。返回（传上去的条数, 错误）。
    func flush(_ transport: any ActivityCloudTransport) async -> (sent: Int, error: Error?) {
        let batch = Array(pending.prefix(400))
        guard !batch.isEmpty else { return (0, nil) }
        do {
            try await transport.upload(batch)
            let sent = Set(batch.map(\.id))
            pending.removeAll { sent.contains($0.id) }
            try save()
            return (batch.count, nil)
        } catch { return (0, error) }
    }

    private func save() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for e in pending { data.append(try ActivityCodec.line(e)); data.append(UInt8(ascii: "\n")) }
        try data.write(to: url, options: .atomic)
    }
}

/// Mac：从 iCloud 导入 iPhone 记录（增量 + 去重 + 云端 14 天清理）。
@MainActor final class ActivityCloudImporter {
    static let tokenKey = "activity.cloud.changeToken"
    static let indexKey = "activity.cloud.index.v1"      // [recordUUID: at(秒)]，只为清理用
    static let lastPruneKey = "activity.cloud.lastPrune"
    /// 云端保留天数：传输通道的稳定性边界（Mac 本机已有一份）。
    static let cloudRetentionDays = 14

    private let transport: any ActivityCloudTransport
    private let log: FileActivityLog
    private let status: ActivityStatusBoard
    private let defaults: UserDefaults
    private var running = false
    private(set) var lastImported: Date?

    init(transport: any ActivityCloudTransport, log: FileActivityLog, status: ActivityStatusBoard, defaults: UserDefaults = .standard) {
        self.transport = transport; self.log = log; self.status = status; self.defaults = defaults
    }

    /// 一轮导入。返回新写入本机日志的条数。
    @discardableResult
    func importOnce(now: Date) async -> Int {
        guard !running else { return 0 }
        running = true; defer { running = false }
        do {
            let (events, bad, token) = try await transport.fetchChanges(since: defaults.data(forKey: Self.tokenKey))
            let incoming = events.filter { $0.platform != "macOS" }   // Mac 自己的不经云端；防御性过滤
            let written = try await log.appendNew(incoming).count
            if let token { defaults.set(token, forKey: Self.tokenKey) }
            var index = defaults.dictionary(forKey: Self.indexKey) as? [String: Double] ?? [:]
            for e in events { index[e.id.uuidString] = e.at.timeIntervalSince1970 }
            defaults.set(index, forKey: Self.indexKey)
            if bad > 0 { status.set(.cloudImport, .failed("\(bad) 条 iCloud 记录解不出，已跳过")) }
            else { status.working(.cloudImport, at: now) }
            if let last = incoming.map(\.at).max() {
                lastImported = last
                // 冒烟 2026-10-19：只有真正的快捷指令记录才算「快捷指令正常」（以前任何 iPhone 记录都会刷新这一行，网络探测也算）
                if let s = incoming.filter({ $0.source == .shortcut }).map(\.at).max() { status.working(.shortcut, at: s) }
            }
            await pruneIfDue(now: now, index: index)
            return written
        } catch {
            status.set(.cloudImport, .failed("拉取 iCloud 失败：\(error.localizedDescription)"))
            return 0
        }
    }

    private func pruneIfDue(now: Date, index: [String: Double]) async {
        let last = defaults.double(forKey: Self.lastPruneKey)
        guard now.timeIntervalSince1970 - last > 86_400 else { return }
        let cutoff = now.addingTimeInterval(-Double(Self.cloudRetentionDays) * 86_400).timeIntervalSince1970
        let old = index.filter { $0.value < cutoff }.compactMap { UUID(uuidString: $0.key) }
        do {
            try await transport.delete(old)
            var kept = index
            for id in old { kept[id.uuidString] = nil }
            defaults.set(kept, forKey: Self.indexKey)
            defaults.set(now.timeIntervalSince1970, forKey: Self.lastPruneKey)
        } catch {
            DevLog.shared.warn("设备活动", "清理 iCloud 上 \(Self.cloudRetentionDays) 天前的活动记录失败（下次再试）：\(error.localizedDescription)")
        }
    }
}
