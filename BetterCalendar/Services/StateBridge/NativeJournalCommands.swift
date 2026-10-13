import Foundation
import SwiftData

/// Journal text is the user's subjective account, never inferred activity.
/// Reading and writing are separate permissions at the future transport boundary.
nonisolated struct NativeJournalQuery: Codable, Equatable {
    var start: Date? = nil
    var end: Date? = nil
    var text = ""
    var includeTrash = false
    var limit = 10
    var cursor: String? = nil
}
nonisolated struct NativeJournalCommand: Codable, Equatable {
    enum Action: String, Codable { case create, update }
    var commandId: UUID
    var recordId: UUID
    var action: Action
    var entryDate: Date? = nil
    var expectedRevision: String? = nil
    var patch: [String: BridgeJSON] = [:]
    var occurredAt: Date
    var provenance = "user"
    var userAuthorizationRef: String
}
@MainActor protocol NativeJournalAccessing {
    func read(_ query: NativeJournalQuery, readAllowed: Bool) throws -> BridgeJSON
    func execute(_ command: NativeJournalCommand, userConfirmed: Bool) throws -> BridgeJSON
}

/// Pure local entry point. No uploads, notifications, timer changes or inferred
/// entries. Attachments remain in their original store; a text read does not
/// claim to have retrieved image binaries or verified CloudKit convergence.
@MainActor final class SwiftDataNativeJournal: NativeJournalAccessing {
    private let context: ModelContext
    private let journal: any NativeActionJournaling
    private let now: () -> Date
    private let saveContext: () throws -> Void
    private let didSave: () -> Void
    init(context: ModelContext, journal: any NativeActionJournaling,
         now: @escaping () -> Date = Date.init, didSave: @escaping () -> Void = {},
         saveContext: (() throws -> Void)? = nil) {
        self.context = context; self.journal = journal; self.now = now; self.didSave = didSave
        self.saveContext = saveContext ?? { try context.save() }
    }
    private func all() throws -> [JournalEntry] {
        guard !context.hasChanges else { throw DataArchiveError.invalid("日记还有未保存内容，先保存后读取或操作") }
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        guard entries.allSatisfy({ [$0.date, $0.createdAt, $0.modifiedAt].allSatisfy { $0.timeIntervalSince1970.isFinite } }) else { throw DataArchiveError.invalid("日记时间无效，需核对原文") }
        guard Set(entries.map(\.id)).count == entries.count else { throw DataArchiveError.invalid("日记身份重复，需核对；未合并或覆盖") }
        return entries.sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
    }
    private func hash(_ value: BridgeJSON) throws -> String { BridgePoolCodec.hash(try BridgePoolCodec.encode(value)) }
    private func commandHash(_ command: NativeJournalCommand) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return BridgePoolCodec.hash(try encoder.encode(command))
    }
    private struct Cursor: Codable { var offset: Int; var queryHash: String; var snapshotHash: String }
    func read(_ query: NativeJournalQuery, readAllowed: Bool) throws -> BridgeJSON {
        guard readAllowed else { throw DataArchiveError.invalid("尚未允许读取日记；事项权限不包含日记") }
        guard (1...50).contains(query.limit), query.text.count <= 1000,
              query.start.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              query.end.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              query.start == nil || query.end == nil || query.start! < query.end! else {
            throw DataArchiveError.invalid("日记检索范围无效")
        }
        let readAt = now(), text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = try all().filter { entry in
            (query.includeTrash || !entry.isInTrash) &&
            (query.start == nil || entry.date >= query.start!) && (query.end == nil || entry.date < query.end!) &&
            (text.isEmpty || entry.body.localizedCaseInsensitiveContains(text) ||
             (entry.mood ?? "").localizedCaseInsensitiveContains(text) || entry.tags.contains { $0.localizedCaseInsensitiveContains(text) })
        }
        let values = try entries.map(Self.values)
        let snapshotHash = try hash(.array(values))
        let queryHash = try hash(.object(["start": Self.date(query.start), "end": Self.date(query.end),
            "text": .string(query.text), "includeTrash": .bool(query.includeTrash),
            "timeZone": .string(TimeZone.current.identifier), "dayBoundaryHour": .number(Double(DayContext.dayBoundaryHour))]))
        var offset = 0
        if let encoded = query.cursor {
            guard encoded.count <= 2000, let data = Data(base64Encoded: encoded),
                  let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
                  cursor.offset >= 0, cursor.offset <= values.count, cursor.queryHash == queryHash,
                  cursor.snapshotHash == snapshotHash else { throw DataArchiveError.invalid("检索条件或日记版本已变化，请从第一页重新读；旧页不能拼作完整结果") }
            offset = cursor.offset
        }
        var records: [BridgeJSON] = [], next = offset, size = 0
        for i in offset..<min(offset + query.limit, values.count) {
            let value = values[i]
            let record: BridgeJSON = .object(["id": .string(entries[i].id.uuidString), "logicalDay": .string(DayContext.dayKey(entries[i].date)), "revision": .string(try hash(value)), "values": value])
            let bytes = try BridgePoolCodec.encode(record).count
            guard bytes <= 32000 else { throw DataArchiveError.invalid("单条日记超过当前完整读取上限；未截断正文，需分段读取增量") }
            if size + bytes > 32000 { break }
            records.append(record); size += bytes; next += 1
        }
        let more = next < values.count
        let cursor = more ? try JSONEncoder().encode(Cursor(offset: next, queryHash: queryHash, snapshotHash: snapshotHash)).base64EncodedString() : nil
        return .object([
            "formatVersion": .number(1), "authority": .string("swiftdata"), "source": .string("bc.native.journal"),
            "dateUnit": .string("unix-milliseconds"), "readAt": Self.date(readAt), "snapshotHash": .string(snapshotHash),
            "records": .array(records), "matchingCount": .number(Double(values.count)),
            "hasMore": .bool(more), "complete": .bool(!more), "nextCursor": .text(cursor),
            "timeZone": .string(TimeZone.current.identifier), "dayBoundaryHour": .number(Double(DayContext.dayBoundaryHour)),
            "windowSemantics": .string("entry.date in [start,end); logicalDay is derived at retrieval"),
            "coverage": .object(["journalText": .string("complete_per_returned_record"),
                "photoReferences": .string("included"), "photoBinaries": .string("not_requested_or_retrieved"),
                "otherDevicesSync": .string("unknown"), "freshness": .string("local_persisted_store_at_readAt")])
        ])
    }
    func execute(_ command: NativeJournalCommand, userConfirmed: Bool) throws -> BridgeJSON {
        guard userConfirmed, command.provenance == "user", !command.userAuthorizationRef.isEmpty,
              command.userAuthorizationRef.count <= 300, command.occurredAt.timeIntervalSince1970.isFinite else {
            throw DataArchiveError.invalid("写日记需要用户明确请求；不能把代理推断写成你的感受")
        }
        let all = try all(), hash = try commandHash(command)
        var intents = try journal.load()
        let index = intents.firstIndex { $0.commandId == command.commandId }
        if let index {
            guard intents[index].kind == "journal", intents[index].requestHash == hash else { throw DataArchiveError.invalid("同一请求身份内容已改变，未写入日记") }
            if intents[index].phase == "applied", let receipt = intents[index].receipt { return receipt }
        }
        let entry = all.first { $0.id == command.recordId }, current = try entry.map(Self.values)
        let intent: NativeActionEntry
        if let index {
            intent = intents[index]
            let base: BridgeJSON
            if let before = intent.before {
                guard command.action == .update else { throw DataArchiveError.invalid("日记创建意图不一致，未重放") }; base = before
            } else {
                guard command.action == .create, let date = command.entryDate else { throw DataArchiveError.invalid("日记原文缺失，未重放") }
                base = try Self.values(JournalEntry(id: command.recordId, date: date, createdAt: command.occurredAt, modifiedAt: command.occurredAt))
            }
            guard try propose(base, command) == intent.proposed else { throw DataArchiveError.invalid("日记操作快照与请求不一致，保留原文件，未重放") }
            if current == intent.proposed { return try complete(intent, intents: &intents, index: index) }
            guard current == intent.before else { throw DataArchiveError.invalid("未决日记操作后内容已有变化；结果未知，不覆盖后来的文字") }
        } else {
            let base: BridgeJSON
            if command.action == .create {
                guard current == nil, command.expectedRevision == nil, let date = command.entryDate,
                      date.timeIntervalSince1970.isFinite,
                      !all.contains(where: { !$0.isInTrash && DayContext.isSameLogicalDay($0.date, date) }) else {
                    throw DataArchiveError.invalid("该逻辑日已有日记或创建身份无效，请读取现有日记再确认修改")
                }
                base = try Self.values(JournalEntry(id: command.recordId, date: date,
                    createdAt: command.occurredAt, modifiedAt: command.occurredAt))
            } else {
                guard command.entryDate == nil, let entry, !entry.isInTrash, let current,
                      try self.hash(current) == command.expectedRevision else { throw DataArchiveError.invalid("日记版本冲突或在回收站，请重新读取；未覆盖") }
                base = current
            }
            let proposed = try propose(base, command)
            intent = NativeActionEntry(commandId: command.commandId, kind: "journal", requestHash: hash, before: current, proposed: proposed)
            intents.append(intent); try journal.save(intents) // Complete original before any effect.
        }
        guard let proposed = intent.proposed else { throw DataArchiveError.invalid("日记操作原文缺失，未执行") }
        // A failed create retry must still respect a diary created on this day
        // by another operation after the original intent was stored.
        if command.action == .create, let date = command.entryDate,
           all.contains(where: { $0.id != command.recordId && !$0.isInTrash && DayContext.isSameLogicalDay($0.date, date) }) {
            throw DataArchiveError.invalid("该逻辑日后来已有日记，不重复创建")
        }
        let target = entry ?? JournalEntry(id: command.recordId, date: command.entryDate ?? command.occurredAt)
        do {
            try apply(proposed, to: target)
            if entry == nil { context.insert(target) }
            guard try Self.values(target) == proposed else { throw DataArchiveError.invalid("保存前日记内容与完整意图不一致，未写入") }
            try saveContext()
        } catch { context.rollback(); throw error }
        didSave()
        return try complete(intent, intents: &intents, index: index ?? intents.count - 1)
    }
    private func propose(_ base: BridgeJSON, _ command: NativeJournalCommand) throws -> BridgeJSON {
        var values = try NativeRemoteJSON.object(base)
        guard values["bodyFormat"] == .string("markdown"), !command.patch.isEmpty,
              Set(command.patch.keys).isSubset(of: ["body", "mood", "tags"]) else { throw DataArchiveError.invalid("当前只支持明确修改 Markdown 正文、心情和标签；照片、日期和格式保留") }
        if let body = command.patch["body"] {
            guard case let .string(text) = body, text.utf8.count <= 16000 else { throw DataArchiveError.invalid("日记正文需为文字，当前写入上限16000字节") }; values["body"] = body
        }
        if let mood = command.patch["mood"] {
            guard mood == .null || { if case let .string(text) = mood { return text.count <= 100 }; return false }() else { throw DataArchiveError.invalid("心情格式无效") }; values["mood"] = mood
        }
        if let tags = command.patch["tags"] {
            guard case let .array(array) = tags, array.count <= 30,
                  array.allSatisfy({ if case let .string(text) = $0 { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 100 }; return false }) else { throw DataArchiveError.invalid("日记标签无效") }; values["tags"] = tags
        }
        values["modifiedAt"] = Self.date(command.occurredAt)
        return .object(values)
    }
    private func apply(_ proposed: BridgeJSON, to entry: JournalEntry) throws {
        let values = try NativeRemoteJSON.object(proposed)
        let body = try NativeRemoteJSON.string(values["body"])
        let mood = values["mood"] == .null ? nil : try NativeRemoteJSON.string(values["mood"])
        guard values["id"] == .string(entry.id.uuidString), case let .array(tags) = values["tags"],
              case let .number(date) = values["date"], case let .number(created) = values["createdAt"],
              case let .number(modified) = values["modifiedAt"], [date, created, modified].allSatisfy({ $0.isFinite }) else { throw DataArchiveError.invalid("日记意图记录缺少完整字段") }
        let texts = try tags.map { try NativeRemoteJSON.string($0) }
        entry.body = body; entry.mood = mood; entry.tags = texts
        entry.date = Date(timeIntervalSince1970: date / 1000); entry.createdAt = Date(timeIntervalSince1970: created / 1000)
        entry.modifiedAt = Date(timeIntervalSince1970: modified / 1000)
        // photoRefs, bodyFormat and retention fields are never edited here.
    }
    private func complete(_ intent: NativeActionEntry, intents: inout [NativeActionEntry], index: Int) throws -> BridgeJSON {
        guard let proposed = intent.proposed else { throw DataArchiveError.invalid("缺少日记操作原文") }
        let receipt: BridgeJSON = .object(["commandId": .string(intent.commandId.uuidString), "saved": .bool(true),
            "persistedRevision": .string(try hash(proposed)), "authority": .string("swiftdata"),
            "deviceApplication": .string("local_store_saved"), "syncOtherDevices": .string("unknown"),
            "photoBinaries": .string("untouched_not_retrieved"), "originalSnapshot": .string("native-actions journal before/proposed"),
            "recoverable": .bool(true), "recovery": .string("confirm a new update from the saved original with current revision")])
        intents[index].phase = "applied"; intents[index].receipt = receipt; try journal.save(intents)
        return receipt
    }
    static func values(_ entry: JournalEntry) throws -> BridgeJSON {
        guard [entry.date, entry.createdAt, entry.modifiedAt].allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw DataArchiveError.invalid("日记时间无效，未发布不完整原文") }
        return .object(["id": .string(entry.id.uuidString), "date": date(entry.date), "body": .string(entry.body),
            "bodyFormat": .string(entry.bodyFormat), "mood": .text(entry.mood), "tags": .array(entry.tags.map(BridgeJSON.string)),
            "photoRefs": .array(entry.photoRefs.map(BridgeJSON.string)), "createdAt": date(entry.createdAt), "modifiedAt": date(entry.modifiedAt),
            "deletedAt": date(entry.deletedAt), "deletionId": .text(entry.deletionID?.uuidString),
            "restoredDeletionId": .text(entry.restoredDeletionID?.uuidString), "deletionContext": .text(entry.deletionContext?.base64EncodedString()),
            "isInTrash": .bool(entry.isInTrash)])
    }
    private static func date(_ value: Date?) -> BridgeJSON { value.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null }
}
