import Foundation
import SwiftData
import CryptoKit

@MainActor protocol StateBridgePoolReading {
    func snapshot() throws -> BridgePoolSnapshot
}
nonisolated struct BridgePoolSnapshot: Sendable {
    let data: Data
    let recordCount: Int
    var executionSessionCount: Int = 0
}
nonisolated enum BridgePoolCodec {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encode(_ value: BridgeJSON) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// Read the authoritative store without changing it; do not export only cached
/// active items, which would omit done, shelved, or retained-deletion records.
@MainActor final class SwiftDataBridgePoolReader: StateBridgePoolReading {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }
    func snapshot() throws -> BridgePoolSnapshot {
        guard !context.hasChanges else { throw DataArchiveError.invalid("事项尚有未保存改动，保留上一份目录") }
        let tasks = try context.fetch(FetchDescriptor<LongTask>()).sorted { $0.id.uuidString < $1.id.uuidString }
        guard Set(tasks.map(\.id)).count == tasks.count else { throw DataArchiveError.invalid("事项身份重复，需核对后再发布目录") }
        var records: [BridgeJSON] = []
        for task in tasks {
            let values = try Self.values(task)
            records.append(.object(["id": .string(task.id.uuidString), "revision": .string(BridgePoolCodec.hash(try BridgePoolCodec.encode(values))), "values": values]))
        }
        let executions = try context.fetch(FetchDescriptor<ExecutionSession>()).map { row -> BridgeJSON in
            // A local stable read identity, not a new shared timer/session ID.
            // Different devices remain separate views; identical values are not
            // collapsed because two genuine sessions may have the same content.
            let id = "legacy:" + BridgePoolCodec.hash(Data(String(describing: row.persistentModelID).utf8))
            let values: BridgeJSON = .object(["id": .string(id), "origin": .string("swiftdata_execution_session"),
                "title": .string(row.title), "blockID": Self.uuid(row.blockID), "start": Self.date(row.start), "end": Self.date(row.end),
                "timingStyle": .string(row.timingStyle.rawValue), "completedCount": Self.integer(row.completedCount),
                "interruptions": .number(Double(row.interruptions)), "commandId": .null,
                "durationBasis": .string("stored_start_end_not_reconstructed_activity")])
            return .object(["id": .string(id), "revision": .string(BridgePoolCodec.hash(try BridgePoolCodec.encode(values))), "values": values])
        }.sorted { lhs, rhs in
            guard case let .object(a) = lhs, case let .object(b) = rhs,
                  case let .string(x) = a["id"], case let .string(y) = b["id"] else { return false }
            return x < y
        }
        let payload = try BridgePoolCodec.encode(.object(["formatVersion": .number(1), "authority": .string("swiftdata"), "dateUnit": .string("unix-milliseconds"), "records": .array(records), "executionSessions": .array(executions)]))
        guard payload.count <= 8 * 1024 * 1024 else { throw DataArchiveError.invalid("事项目录超过传输上限，原库保留，未发布不完整目录") }
        return BridgePoolSnapshot(data: payload, recordCount: records.count, executionSessionCount: executions.count)
    }
    static func values(_ task: LongTask) throws -> BridgeJSON {
            let stages = (task.checkpoints ?? []).sorted { ($0.order, $0.id.uuidString) < ($1.order, $1.id.uuidString) }
            guard Set(stages.map(\.id)).count == stages.count else { throw DataArchiveError.invalid("阶段身份重复，需核对后再发布目录") }
            return BridgeJSON.object([
                "id": .string(task.id.uuidString), "title": .string(task.title), "note": .string(task.note),
                "zone": .string(task.zoneRaw), "status": .string(task.status.rawValue),
                "createdAt": date(task.createdAt), "modifiedAt": date(task.modifiedAt),
                "deadline": date(task.deadline), "doneAt": date(task.doneAt),
                "cadenceMinutesPerWeek": integer(task.cadenceMinutesPerWeek), "totalMinutes": integer(task.totalMinutes),
                "unitMinutes": integer(task.unitMinutes), "family": .text(task.family), "spilledFromDay": date(task.spilledFromDay),
                "deletedAt": date(task.deletedAt), "deletionId": uuid(task.deletionID), "restoredDeletionId": uuid(task.restoredDeletionID),
                "deletionContext": .text(task.deletionContext?.base64EncodedString()), "isInTrash": .bool(task.isInTrash),
                "checkpoints": .array(stages.map { cp in .object([
                    "id": .string(cp.id.uuidString), "title": .string(cp.title), "order": .number(Double(cp.order)),
                    "estimatedMinutes": integer(cp.estimatedMinutes), "doneAt": date(cp.doneAt), "createdAt": date(cp.createdAt),
                    "deletedAt": date(cp.deletedAt), "deletionId": uuid(cp.deletionID), "restoredDeletionId": uuid(cp.restoredDeletionID),
                    "deletionContext": .text(cp.deletionContext?.base64EncodedString()), "isInTrash": .bool(cp.isInTrash)
                ]) })
            ])
    }
    private static func date(_ date: Date?) -> BridgeJSON { date.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null }
    private static func integer(_ value: Int?) -> BridgeJSON { value.map { .number(Double($0)) } ?? .null }
    private static func uuid(_ value: UUID?) -> BridgeJSON { .text(value?.uuidString) }
}

struct BridgePoolCache: Codable {
    var deviceId: String
    var contentHash: String
    var manifest: BridgeJSON
    func validate() throws {
        guard !deviceId.isEmpty, deviceId.count <= 80,
              contentHash.count == 64, contentHash.allSatisfy({ "0123456789abcdef".contains($0) }),
              case let .object(value) = manifest,
              value["formatVersion"] == .number(1), value["authority"] == .string("swiftdata"),
              value["availability"] == .string("available"), value["contentHash"] == .string(contentHash),
              case let .number(count) = value["recordCount"], count.isFinite, count >= 0, count.rounded() == count,
              case let .array(ids) = value["chunkEventIds"], !ids.isEmpty, ids.count <= 274 else {
            throw DataArchiveError.invalid("目录队列清单无效，保留原文件")
        }
        let strings = ids.compactMap { item -> String? in if case let .string(id) = item { return id }; return nil }
        guard strings.count == ids.count, Set(strings).count == strings.count,
              strings.allSatisfy({ !$0.isEmpty && $0.count <= 150 }) else {
            throw DataArchiveError.invalid("目录队列分片身份无效，保留原文件")
        }
    }
}

extension BridgeOutbox {
    /// Chunks and their final manifest enter the durable queue together. A failed
    /// save never advances this cache; retries keep original IDs and timestamps.
    mutating func enqueuePool(_ snapshot: BridgePoolSnapshot, deviceId: String, at date: Date) throws {
        guard snapshot.data.count <= 8 * 1024 * 1024, snapshot.recordCount >= 0 else { throw DataArchiveError.invalid("事项目录无效") }
        let hash = BridgePoolCodec.hash(snapshot.data)
        let formatter = ISO8601DateFormatter(), timestamp = formatter.string(from: date)
        func append(_ source: String, _ value: BridgeJSON, validFor: TimeInterval) -> String {
            let id = UUID().uuidString
            observations.append(BridgeObservation(eventId: id, source: source, sequence: nextSequence,
                observedAt: timestamp, expiresAt: formatter.string(from: date.addingTimeInterval(validFor)), value: value))
            nextSequence += 1; return id
        }
        let manifest: BridgeJSON
        if let cached = poolCache, cached.deviceId == deviceId, cached.contentHash == hash { manifest = cached.manifest }
        else {
            var ids: [BridgeJSON] = []
            for offset in stride(from: 0, to: snapshot.data.count, by: 30 * 1024) {
                let bytes = snapshot.data.subdata(in: offset..<min(offset + 30 * 1024, snapshot.data.count))
                ids.append(.string(append("bc.pool.chunk", .object(["formatVersion": .number(1), "contentHash": .string(hash),
                    "index": .number(Double(ids.count)), "bytes": .string(bytes.base64EncodedString())]), validFor: 365 * 86400)))
            }
            manifest = .object(["formatVersion": .number(1), "authority": .string("swiftdata"), "availability": .string("available"),
                "contentHash": .string(hash), "recordCount": .number(Double(snapshot.recordCount)), "executionSessionCount": .number(Double(snapshot.executionSessionCount)), "chunkEventIds": .array(ids)])
            poolCache = BridgePoolCache(deviceId: deviceId, contentHash: hash, manifest: manifest)
        }
        _ = append("bc.pool", manifest, validFor: 180)
        try validate()
    }
}
