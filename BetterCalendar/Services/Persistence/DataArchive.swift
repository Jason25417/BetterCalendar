import Foundation
import SwiftData
import CryptoKit

/// JSON interchange values deliberately do not expose Core Data / SwiftData storage details.
nonisolated enum ArchiveValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([ArchiveValue]), object([String: ArchiveValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ArchiveValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ArchiveValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    static func wrap<T: Encodable>(_ value: T) throws -> ArchiveValue {
        try ArchiveCodec.decoder().decode(ArchiveValue.self, from: ArchiveCodec.encoder().encode(value))
    }
}

nonisolated enum ArchiveCodec {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]; return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
nonisolated struct DataArchiveRecord: Codable, Equatable, Sendable {
    var entity: String
    var key: String
    var values: [String: ArchiveValue]
    func get<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        guard let value = values[name] else { throw DataArchiveError.invalid("缺少字段 \(entity).\(name)") }
        return try ArchiveCodec.decoder().decode(T.self, from: ArchiveCodec.encoder().encode(value))
    }
}
nonisolated struct DataArchive: Codable, Sendable {
    var formatVersion = 1
    var createdAt: Date
    var sourceVersion: String
    var records: [DataArchiveRecord]
    // Auxiliary app state is a separate, opt-in restoration domain. Never restore device identity or credentials.
    var localFiles: [String: Data] = [:]
    var preferences: [String: ArchiveValue] = [:]
}
nonisolated struct SealedDataArchive: Codable, Sendable {
    var archive: DataArchive
    var sha256: String
    init(_ archive: DataArchive) throws {
        self.archive = archive
        sha256 = ArchiveCodec.digest(try ArchiveCodec.encoder().encode(archive))
    }
    func verified() throws -> DataArchive {
        guard archive.formatVersion == 1 else { throw DataArchiveError.invalid("不支持的档案版本，原文件保持不变") }
        guard ArchiveCodec.digest(try ArchiveCodec.encoder().encode(archive)) == sha256 else {
            throw DataArchiveError.invalid("档案校验失败：内容已改变或文件不完整")
        }
        return archive
    }
}
nonisolated enum DataArchiveError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// Export all rows including duplicate logical IDs and unreferenced photos. Never silently “clean” a backup.
@MainActor enum DataArchiveStore {
    static let schema = Schema([PlanBlock.self, ExecutionSession.self, LongTask.self, LongTaskCheckpoint.self,
                               DayRecord.self, DayPlanSnapshot.self, ResidualSample.self,
                               JournalEntry.self, JournalPhoto.self, DeviceLog.self])

    static func capture(_ context: ModelContext, now: Date = .now) throws -> DataArchive {
        var records: [DataArchiveRecord] = []
        for row in try context.fetch(FetchDescriptor<PlanBlock>()) {
            records.append(DataArchiveRecord(entity: "PlanBlock", key: "PlanBlock:" + String(describing: row.persistentModelID), values: [
                "id": try ArchiveValue.wrap(row.id),
                "title": try ArchiveValue.wrap(row.title),
                "start": try ArchiveValue.wrap(row.start),
                "end": try ArchiveValue.wrap(row.end),
                "isFixed": try ArchiveValue.wrap(row.isFixed),
                "isAnchor": try ArchiveValue.wrap(row.isAnchor),
                "kind": try ArchiveValue.wrap(row.kind),
                "timingStyle": try ArchiveValue.wrap(row.timingStyle),
                "priority": try ArchiveValue.wrap(row.priority),
                "deadline": try ArchiveValue.wrap(row.deadline),
                "labels": try ArchiveValue.wrap(row.labels),
                "linkedTaskID": try ArchiveValue.wrap(row.linkedTaskID),
                "completion": try ArchiveValue.wrap(row.completion)
            ]))
        }
        for row in try context.fetch(FetchDescriptor<ExecutionSession>()) {
            records.append(DataArchiveRecord(entity: "ExecutionSession", key: "ExecutionSession:" + String(describing: row.persistentModelID), values: [
                "blockID": try ArchiveValue.wrap(row.blockID),
                "title": try ArchiveValue.wrap(row.title),
                "start": try ArchiveValue.wrap(row.start),
                "end": try ArchiveValue.wrap(row.end),
                "timingStyle": try ArchiveValue.wrap(row.timingStyle),
                "completedCount": try ArchiveValue.wrap(row.completedCount),
                "interruptions": try ArchiveValue.wrap(row.interruptions)
            ]))
        }
        for row in try context.fetch(FetchDescriptor<LongTask>()) {
            records.append(DataArchiveRecord(entity: "LongTask", key: "LongTask:" + String(describing: row.persistentModelID), values: [
                "id": try ArchiveValue.wrap(row.id),
                "title": try ArchiveValue.wrap(row.title),
                "note": try ArchiveValue.wrap(row.note),
                "deadline": try ArchiveValue.wrap(row.deadline),
                "cadenceMinutesPerWeek": try ArchiveValue.wrap(row.cadenceMinutesPerWeek),
                "totalMinutes": try ArchiveValue.wrap(row.totalMinutes),
                "unitMinutes": try ArchiveValue.wrap(row.unitMinutes),
                "status": try ArchiveValue.wrap(row.status),
                "createdAt": try ArchiveValue.wrap(row.createdAt),
                "doneAt": try ArchiveValue.wrap(row.doneAt),
                "modifiedAt": try ArchiveValue.wrap(row.modifiedAt),
                "zoneRaw": try ArchiveValue.wrap(row.zoneRaw),
                "family": try ArchiveValue.wrap(row.family),
                "spilledFromDay": try ArchiveValue.wrap(row.spilledFromDay)
            ]))
        }
        for row in try context.fetch(FetchDescriptor<LongTaskCheckpoint>()) {
            records.append(DataArchiveRecord(entity: "LongTaskCheckpoint", key: "LongTaskCheckpoint:" + String(describing: row.persistentModelID), values: [
                "id": try ArchiveValue.wrap(row.id),
                "title": try ArchiveValue.wrap(row.title),
                "estimatedMinutes": try ArchiveValue.wrap(row.estimatedMinutes),
                "doneAt": try ArchiveValue.wrap(row.doneAt),
                "order": try ArchiveValue.wrap(row.order),
                "createdAt": try ArchiveValue.wrap(row.createdAt),
                "taskKey": try ArchiveValue.wrap(row.task.map { "LongTask:" + String(describing: $0.persistentModelID) })
            ]))
        }
        for row in try context.fetch(FetchDescriptor<DayRecord>()) {
            records.append(DataArchiveRecord(entity: "DayRecord", key: "DayRecord:" + String(describing: row.persistentModelID), values: [
                "dayKey": try ArchiveValue.wrap(row.dayKey),
                "isActive": try ArchiveValue.wrap(row.isActive),
                "mvpTitle": try ArchiveValue.wrap(row.mvpTitle),
                "mvpNote": try ArchiveValue.wrap(row.mvpNote),
                "modifiedAt": try ArchiveValue.wrap(row.modifiedAt)
            ]))
        }
        for row in try context.fetch(FetchDescriptor<DayPlanSnapshot>()) {
            records.append(DataArchiveRecord(entity: "DayPlanSnapshot", key: "DayPlanSnapshot:" + String(describing: row.persistentModelID), values: [
                "dayLabel": try ArchiveValue.wrap(row.dayLabel),
                "createdAt": try ArchiveValue.wrap(row.createdAt),
                "itemsJSON": try ArchiveValue.wrap(row.itemsJSON)
            ]))
        }
        for row in try context.fetch(FetchDescriptor<ResidualSample>()) {
            records.append(DataArchiveRecord(entity: "ResidualSample", key: "ResidualSample:" + String(describing: row.persistentModelID), values: [
                "dayLabel": try ArchiveValue.wrap(row.dayLabel),
                "blockID": try ArchiveValue.wrap(row.blockID),
                "title": try ArchiveValue.wrap(row.title),
                "labels": try ArchiveValue.wrap(row.labels),
                "linkedTaskID": try ArchiveValue.wrap(row.linkedTaskID),
                "isFixed": try ArchiveValue.wrap(row.isFixed),
                "isAnchor": try ArchiveValue.wrap(row.isAnchor),
                "plannedStart": try ArchiveValue.wrap(row.plannedStart),
                "plannedMinutes": try ArchiveValue.wrap(row.plannedMinutes),
                "actualStart": try ArchiveValue.wrap(row.actualStart),
                "actualMinutes": try ArchiveValue.wrap(row.actualMinutes),
                "sourceRaw": try ArchiveValue.wrap(row.sourceRaw),
                "createdAt": try ArchiveValue.wrap(row.createdAt)
            ]))
        }
        for row in try context.fetch(FetchDescriptor<JournalEntry>()) {
            records.append(DataArchiveRecord(entity: "JournalEntry", key: "JournalEntry:" + String(describing: row.persistentModelID), values: [
                "id": try ArchiveValue.wrap(row.id),
                "date": try ArchiveValue.wrap(row.date),
                "body": try ArchiveValue.wrap(row.body),
                "bodyFormat": try ArchiveValue.wrap(row.bodyFormat),
                "mood": try ArchiveValue.wrap(row.mood),
                "tags": try ArchiveValue.wrap(row.tags),
                "photoRefs": try ArchiveValue.wrap(row.photoRefs),
                "createdAt": try ArchiveValue.wrap(row.createdAt),
                "modifiedAt": try ArchiveValue.wrap(row.modifiedAt)
            ]))
        }
        for row in try context.fetch(FetchDescriptor<JournalPhoto>()) {
            records.append(DataArchiveRecord(entity: "JournalPhoto", key: "JournalPhoto:" + String(describing: row.persistentModelID), values: [
                "ref": try ArchiveValue.wrap(row.ref),
                "data": try ArchiveValue.wrap(row.data),
                "createdAt": try ArchiveValue.wrap(row.createdAt)
            ]))
        }
        for row in try context.fetch(FetchDescriptor<DeviceLog>()) {
            records.append(DataArchiveRecord(entity: "DeviceLog", key: "DeviceLog:" + String(describing: row.persistentModelID), values: [
                "deviceID": try ArchiveValue.wrap(row.deviceID),
                "deviceName": try ArchiveValue.wrap(row.deviceName),
                "dayKey": try ArchiveValue.wrap(row.dayKey),
                "text": try ArchiveValue.wrap(row.text),
                "modifiedAt": try ArchiveValue.wrap(row.modifiedAt)
            ]))
        }
        return DataArchive(createdAt: now, sourceVersion: AppInfo.version,
                           records: records.sorted { $0.key < $1.key })
    }

    /// Restoration is only into an EMPTY isolated container. Never wipe or replace a live synced store.
    @discardableResult static func restore(_ archive: DataArchive, into context: ModelContext) throws -> [String: String] {
        guard archive.formatVersion == 1 else { throw DataArchiveError.invalid("不支持的档案版本") }
        guard try capture(context).records.isEmpty, !context.hasChanges else {
            throw DataArchiveError.invalid("恢复目标必须是空库；不覆盖正在使用的数据")
        }
        guard Set(archive.records.map(\.key)).count == archive.records.count else {
            throw DataArchiveError.invalid("重复的档案行标识")
        }
        var tasks: [String: LongTask] = [:]
        var checkpoints: [(LongTaskCheckpoint, String?)] = []
        var restoredKeys: [(DataArchiveRecord, any PersistentModel)] = []
        do {
            for record in archive.records {
                switch record.entity {
                case "PlanBlock":
                    try requireFields(record, ["id", "title", "start", "end", "isFixed", "isAnchor", "kind", "timingStyle", "priority", "deadline", "labels", "linkedTaskID", "completion"])
                    let row = PlanBlock(title: "", start: .distantPast, end: .distantPast)
                    row.id = try record.get("id")
                    row.title = try record.get("title")
                    row.start = try record.get("start")
                    row.end = try record.get("end")
                    row.isFixed = try record.get("isFixed")
                    row.isAnchor = try record.get("isAnchor")
                    row.kind = try record.get("kind")
                    row.timingStyle = try record.get("timingStyle")
                    row.priority = try record.get("priority")
                    row.deadline = try record.get("deadline")
                    row.labels = try record.get("labels")
                    row.linkedTaskID = try record.get("linkedTaskID")
                    row.completion = try record.get("completion")
                    context.insert(row)
                    restoredKeys.append((record, row))
                case "ExecutionSession":
                    try requireFields(record, ["blockID", "title", "start", "end", "timingStyle", "completedCount", "interruptions"])
                    let row = ExecutionSession()
                    row.blockID = try record.get("blockID")
                    row.title = try record.get("title")
                    row.start = try record.get("start")
                    row.end = try record.get("end")
                    row.timingStyle = try record.get("timingStyle")
                    row.completedCount = try record.get("completedCount")
                    row.interruptions = try record.get("interruptions")
                    context.insert(row)
                    restoredKeys.append((record, row))
                case "LongTask":
                    try requireFields(record, ["id", "title", "note", "deadline", "cadenceMinutesPerWeek", "totalMinutes", "unitMinutes", "status", "createdAt", "doneAt", "modifiedAt", "zoneRaw", "family", "spilledFromDay"])
                    let row = LongTask(title: "")
                    row.id = try record.get("id")
                    row.title = try record.get("title")
                    row.note = try record.get("note")
                    row.deadline = try record.get("deadline")
                    row.cadenceMinutesPerWeek = try record.get("cadenceMinutesPerWeek")
                    row.totalMinutes = try record.get("totalMinutes")
                    row.unitMinutes = try record.get("unitMinutes")
                    row.status = try record.get("status")
                    row.createdAt = try record.get("createdAt")
                    row.doneAt = try record.get("doneAt")
                    row.modifiedAt = try record.get("modifiedAt")
                    row.zoneRaw = try record.get("zoneRaw")
                    row.family = try record.get("family")
                    row.spilledFromDay = try record.get("spilledFromDay")
                    context.insert(row)
                    restoredKeys.append((record, row))
                    tasks[record.key] = row
                case "LongTaskCheckpoint":
                    try requireFields(record, ["id", "title", "estimatedMinutes", "doneAt", "order", "createdAt", "taskKey"])
                    let row = LongTaskCheckpoint(title: "")
                    row.id = try record.get("id")
                    row.title = try record.get("title")
                    row.estimatedMinutes = try record.get("estimatedMinutes")
                    row.doneAt = try record.get("doneAt")
                    row.order = try record.get("order")
                    row.createdAt = try record.get("createdAt")
                    context.insert(row)
                    restoredKeys.append((record, row))
                    checkpoints.append((row, try record.get("taskKey", as: String?.self)))
                case "DayRecord":
                    try requireFields(record, ["dayKey", "isActive", "mvpTitle", "mvpNote", "modifiedAt"])
                    let row = DayRecord(dayKey: "")
                    row.dayKey = try record.get("dayKey")
                    row.isActive = try record.get("isActive")
                    row.mvpTitle = try record.get("mvpTitle")
                    row.mvpNote = try record.get("mvpNote")
                    row.modifiedAt = try record.get("modifiedAt")
                    context.insert(row)
                    restoredKeys.append((record, row))
                case "DayPlanSnapshot":
                    try requireFields(record, ["dayLabel", "createdAt", "itemsJSON"])
                    let row = DayPlanSnapshot(dayLabel: .distantPast, items: [])
                    row.dayLabel = try record.get("dayLabel")
                    row.createdAt = try record.get("createdAt")
                    row.itemsJSON = try record.get("itemsJSON")
                    context.insert(row)
                    restoredKeys.append((record, row))
                case "ResidualSample":
                    try requireFields(record, ["dayLabel", "blockID", "title", "labels", "linkedTaskID", "isFixed", "isAnchor", "plannedStart", "plannedMinutes", "actualStart", "actualMinutes", "sourceRaw", "createdAt"])
                    let row = ResidualSample(dayLabel: .distantPast, blockID: UUID(), title: "", plannedStart: .distantPast, plannedMinutes: 0, actualStart: .distantPast, actualMinutes: 0, source: .recall)
                    row.dayLabel = try record.get("dayLabel")
                    row.blockID = try record.get("blockID")
                    row.title = try record.get("title")
                    row.labels = try record.get("labels")
                    row.linkedTaskID = try record.get("linkedTaskID")
                    row.isFixed = try record.get("isFixed")
                    row.isAnchor = try record.get("isAnchor")
                    row.plannedStart = try record.get("plannedStart")
                    row.plannedMinutes = try record.get("plannedMinutes")
                    row.actualStart = try record.get("actualStart")
                    row.actualMinutes = try record.get("actualMinutes")
                    row.sourceRaw = try record.get("sourceRaw")
                    row.createdAt = try record.get("createdAt")
                    context.insert(row)
                    restoredKeys.append((record, row))
                case "JournalEntry":
                    try requireFields(record, ["id", "date", "body", "bodyFormat", "mood", "tags", "photoRefs", "createdAt", "modifiedAt"])
                    let row = JournalEntry(date: .distantPast)
                    row.id = try record.get("id")
                    row.date = try record.get("date")
                    row.body = try record.get("body")
                    row.bodyFormat = try record.get("bodyFormat")
                    row.mood = try record.get("mood")
                    row.tags = try record.get("tags")
                    row.photoRefs = try record.get("photoRefs")
                    row.createdAt = try record.get("createdAt")
                    row.modifiedAt = try record.get("modifiedAt")
                    context.insert(row)
                    restoredKeys.append((record, row))
                case "JournalPhoto":
                    try requireFields(record, ["ref", "data", "createdAt"])
                    let row = JournalPhoto(ref: "", data: Data())
                    row.ref = try record.get("ref")
                    row.data = try record.get("data")
                    row.createdAt = try record.get("createdAt")
                    context.insert(row)
                    restoredKeys.append((record, row))
                case "DeviceLog":
                    try requireFields(record, ["deviceID", "deviceName", "dayKey", "text", "modifiedAt"])
                    let row = DeviceLog(deviceID: "", deviceName: "", dayKey: "")
                    row.deviceID = try record.get("deviceID")
                    row.deviceName = try record.get("deviceName")
                    row.dayKey = try record.get("dayKey")
                    row.text = try record.get("text")
                    row.modifiedAt = try record.get("modifiedAt")
                    context.insert(row)
                    restoredKeys.append((record, row))
                default: throw DataArchiveError.invalid("未知数据类型：\(record.entity)")
                }
            }
            for (cp, taskID) in checkpoints {
                if let taskID {
                    guard let task = tasks[taskID] else { throw DataArchiveError.invalid("检查点缺少所属长期任务") }
                    cp.task = task
                }
            }
            try context.save()
            return Dictionary(uniqueKeysWithValues: restoredKeys.map { original, row in
                (original.entity + ":" + String(describing: row.persistentModelID), original.key)
            })
        } catch { context.rollback(); throw error }
    }

    private static func requireFields(_ record: DataArchiveRecord, _ names: Set<String>) throws {
        guard Set(record.values.keys) == names else {
            throw DataArchiveError.invalid("\(record.entity) 字段与版本 1 不符；保留原文件，禁止丢字段恢复")
        }
    }

    /// Exercise the real mapper in an isolated local store, including all relationships and binary assets.
    static func validateRestoration(_ archive: DataArchive) throws {
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let keyMap = try restore(archive, into: container.mainContext)
        var restored = try capture(container.mainContext)
        for i in restored.records.indices where restored.records[i].entity == "LongTaskCheckpoint" {
            if case .string(let key) = restored.records[i].values["taskKey"], let old = keyMap[key] {
                restored.records[i].values["taskKey"] = .string(old)
            }
        }
        // SQLite object IDs necessarily change; compare the multiset of portable values, not storage IDs.
        func content(_ records: [DataArchiveRecord]) throws -> [String] {
            try records.map { r in
                r.entity + ":" + ArchiveCodec.digest(try ArchiveCodec.encoder().encode(r.values))
            }.sorted()
        }
        guard try content(archive.records) == content(restored.records) else {
            throw DataArchiveError.invalid("恢复后字段或关系不一致；原始档案保持不变")
        }
    }
}

nonisolated struct DataEditRequest: Codable, Sendable {
    var formatVersion = 1
    var requestID: UUID
    var edits: [Edit]
    struct Edit: Codable, Sendable {
        var key: String
        var expected: [String: ArchiveValue]
        var replacement: [String: ArchiveValue]
    }
}

extension DataArchiveStore {
    static func prepare(_ request: DataEditRequest, current: DataArchive) throws -> DataArchive {
        guard request.formatVersion == 1, !request.edits.isEmpty,
              Set(request.edits.map(\.key)).count == request.edits.count else {
            throw DataArchiveError.invalid("修改请求版本、条数或行标识无效")
        }
        var result = current
        for edit in request.edits {
            guard let index = result.records.firstIndex(where: { $0.key == edit.key }) else {
                throw DataArchiveError.invalid("目标已删除或来自另一份数据库，请重新导出")
            }
            let old = result.records[index]
            if old.values == edit.replacement { continue } // idempotent retry after receipt write failure
            guard old.values == edit.expected else { throw DataArchiveError.invalid("内容已被其他操作更新，拒绝覆盖；请重新导出") }
            let immutable = ["id", "kind", "blockID", "ref", "deviceID", "dayKey", "dayLabel", "createdAt"]
            for key in immutable where old.values[key] != edit.replacement[key] {
                throw DataArchiveError.invalid("不能修改身份字段 \(key)；本接口只改既有记录")
            }
            result.records[index].values = edit.replacement
            try validateEditedRecord(result.records[index])
        }
        try validateRestoration(result)
        return result
    }

    private static func validateEditedRecord(_ r: DataArchiveRecord) throws {
        if r.entity == "PlanBlock" || r.entity == "ExecutionSession" {
            let start: Date = try r.get("start")
            let end: Date? = try r.get("end")
            if let end, end < start { throw DataArchiveError.invalid("结束时间不能早于开始时间") }
        }
        if ["PlanBlock", "LongTask", "LongTaskCheckpoint"].contains(r.entity) {
            let title: String = try r.get("title")
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw DataArchiveError.invalid("标题不能为空") }
        }
        for key in ["estimatedMinutes", "cadenceMinutesPerWeek", "totalMinutes", "unitMinutes", "interruptions", "completedCount", "plannedMinutes", "actualMinutes"] where r.values[key] != nil {
            let n: Int? = try r.get(key)
            if let n, n < 0 { throw DataArchiveError.invalid("时长和计数不能为负数") }
        }
        if r.entity == "LongTask" {
            let zone: String = try r.get("zoneRaw")
            guard PoolZone(rawValue: zone) != nil else { throw DataArchiveError.invalid("未知的任务分区") }
        }
        if r.entity == "JournalEntry" {
            let refs: [String] = try r.get("photoRefs")
            guard refs.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && $0 != ".." }) else {
                throw DataArchiveError.invalid("照片引用必须是文件名")
            }
        }
    }

    /// Caller must first durably write a pre-change archive. No event/calendar projection is invoked here.
    static func applyPrepared(_ prepared: DataArchive, request: DataEditRequest, to context: ModelContext) throws {
        guard !context.hasChanges else { throw DataArchiveError.invalid("App 有尚未保存的编辑，稍后重试") }
        let current = try capture(context)
        _ = try prepare(request, current: current) // last-moment optimistic concurrency check
        let keys = Set(request.edits.map(\.key))
        let replacements = Dictionary(uniqueKeysWithValues: prepared.records.filter { keys.contains($0.key) }.map { ($0.key, $0) })
        do {
            for row in try context.fetch(FetchDescriptor<PlanBlock>()) {
                guard let record = replacements["PlanBlock:" + String(describing: row.persistentModelID)] else { continue }
                row.id = try record.get("id")
                row.title = try record.get("title")
                row.start = try record.get("start")
                row.end = try record.get("end")
                row.isFixed = try record.get("isFixed")
                row.isAnchor = try record.get("isAnchor")
                row.kind = try record.get("kind")
                row.timingStyle = try record.get("timingStyle")
                row.priority = try record.get("priority")
                row.deadline = try record.get("deadline")
                row.labels = try record.get("labels")
                row.linkedTaskID = try record.get("linkedTaskID")
                row.completion = try record.get("completion")
            }
            for row in try context.fetch(FetchDescriptor<ExecutionSession>()) {
                guard let record = replacements["ExecutionSession:" + String(describing: row.persistentModelID)] else { continue }
                row.blockID = try record.get("blockID")
                row.title = try record.get("title")
                row.start = try record.get("start")
                row.end = try record.get("end")
                row.timingStyle = try record.get("timingStyle")
                row.completedCount = try record.get("completedCount")
                row.interruptions = try record.get("interruptions")
            }
            for row in try context.fetch(FetchDescriptor<LongTask>()) {
                guard let record = replacements["LongTask:" + String(describing: row.persistentModelID)] else { continue }
                row.id = try record.get("id")
                row.title = try record.get("title")
                row.note = try record.get("note")
                row.deadline = try record.get("deadline")
                row.cadenceMinutesPerWeek = try record.get("cadenceMinutesPerWeek")
                row.totalMinutes = try record.get("totalMinutes")
                row.unitMinutes = try record.get("unitMinutes")
                row.status = try record.get("status")
                row.createdAt = try record.get("createdAt")
                row.doneAt = try record.get("doneAt")
                row.modifiedAt = try record.get("modifiedAt")
                row.zoneRaw = try record.get("zoneRaw")
                row.family = try record.get("family")
                row.spilledFromDay = try record.get("spilledFromDay")
            }
            for row in try context.fetch(FetchDescriptor<LongTaskCheckpoint>()) {
                guard let record = replacements["LongTaskCheckpoint:" + String(describing: row.persistentModelID)] else { continue }
                row.id = try record.get("id")
                row.title = try record.get("title")
                row.estimatedMinutes = try record.get("estimatedMinutes")
                row.doneAt = try record.get("doneAt")
                row.order = try record.get("order")
                row.createdAt = try record.get("createdAt")
                let taskKey: String? = try record.get("taskKey")
                row.task = try context.fetch(FetchDescriptor<LongTask>()).first {
                    "LongTask:" + String(describing: $0.persistentModelID) == taskKey
                }
            }
            for row in try context.fetch(FetchDescriptor<DayRecord>()) {
                guard let record = replacements["DayRecord:" + String(describing: row.persistentModelID)] else { continue }
                row.dayKey = try record.get("dayKey")
                row.isActive = try record.get("isActive")
                row.mvpTitle = try record.get("mvpTitle")
                row.mvpNote = try record.get("mvpNote")
                row.modifiedAt = try record.get("modifiedAt")
            }
            for row in try context.fetch(FetchDescriptor<DayPlanSnapshot>()) {
                guard let record = replacements["DayPlanSnapshot:" + String(describing: row.persistentModelID)] else { continue }
                row.dayLabel = try record.get("dayLabel")
                row.createdAt = try record.get("createdAt")
                row.itemsJSON = try record.get("itemsJSON")
            }
            for row in try context.fetch(FetchDescriptor<ResidualSample>()) {
                guard let record = replacements["ResidualSample:" + String(describing: row.persistentModelID)] else { continue }
                row.dayLabel = try record.get("dayLabel")
                row.blockID = try record.get("blockID")
                row.title = try record.get("title")
                row.labels = try record.get("labels")
                row.linkedTaskID = try record.get("linkedTaskID")
                row.isFixed = try record.get("isFixed")
                row.isAnchor = try record.get("isAnchor")
                row.plannedStart = try record.get("plannedStart")
                row.plannedMinutes = try record.get("plannedMinutes")
                row.actualStart = try record.get("actualStart")
                row.actualMinutes = try record.get("actualMinutes")
                row.sourceRaw = try record.get("sourceRaw")
                row.createdAt = try record.get("createdAt")
            }
            for row in try context.fetch(FetchDescriptor<JournalEntry>()) {
                guard let record = replacements["JournalEntry:" + String(describing: row.persistentModelID)] else { continue }
                row.id = try record.get("id")
                row.date = try record.get("date")
                row.body = try record.get("body")
                row.bodyFormat = try record.get("bodyFormat")
                row.mood = try record.get("mood")
                row.tags = try record.get("tags")
                row.photoRefs = try record.get("photoRefs")
                row.createdAt = try record.get("createdAt")
                row.modifiedAt = try record.get("modifiedAt")
            }
            for row in try context.fetch(FetchDescriptor<JournalPhoto>()) {
                guard let record = replacements["JournalPhoto:" + String(describing: row.persistentModelID)] else { continue }
                row.ref = try record.get("ref")
                row.data = try record.get("data")
                row.createdAt = try record.get("createdAt")
            }
            for row in try context.fetch(FetchDescriptor<DeviceLog>()) {
                guard let record = replacements["DeviceLog:" + String(describing: row.persistentModelID)] else { continue }
                row.deviceID = try record.get("deviceID")
                row.deviceName = try record.get("deviceName")
                row.dayKey = try record.get("dayKey")
                row.text = try record.get("text")
                row.modifiedAt = try record.get("modifiedAt")
            }
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
