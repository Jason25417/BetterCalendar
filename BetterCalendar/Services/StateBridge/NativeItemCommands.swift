import Foundation
import SwiftData

nonisolated struct NativeItemCommand: Codable, Equatable {
    enum Action: String, Codable { case create, update, delete, restore }
    var commandId: UUID
    var recordId: UUID
    var action: Action
    var expectedRevision: String?
    var patch: [String: BridgeJSON] = [:]
    var occurredAt: Date
    var provenance = "user"
    var userAuthorizationRef: String
}
nonisolated struct NativePoolRecord: Identifiable {
    var id: UUID
    var revision: String
    var values: BridgeJSON
}
@MainActor protocol NativeItemWriting {
    func records() throws -> [NativePoolRecord]
    func execute(_ command: NativeItemCommand, userConfirmed: Bool) throws -> BridgeJSON
}

/// One native write boundary for UI and the future MCP executor. No second
/// authority and no per-device duplicate fan-out. Remote transport is separate.
@MainActor final class SwiftDataNativeItemWriter: NativeItemWriting {
    private let context: ModelContext
    private let journal: any NativeActionJournaling
    private let didSave: () -> Void
    private let saveContext: () throws -> Void
    init(context: ModelContext, journal: any NativeActionJournaling, didSave: @escaping () -> Void = {},
         saveContext: (() throws -> Void)? = nil) {
        self.context = context; self.journal = journal; self.didSave = didSave
        self.saveContext = saveContext ?? { try context.save() }
    }
    func records() throws -> [NativePoolRecord] {
        guard !context.hasChanges else { throw DataArchiveError.invalid("还有未保存改动，先保存后刷新事项") }
        let tasks = try context.fetch(FetchDescriptor<LongTask>())
        guard Set(tasks.map(\.id)).count == tasks.count else { throw DataArchiveError.invalid("事项身份重复，未执行") }
        return try tasks.map {
            let values = try SwiftDataBridgePoolReader.values($0)
            return NativePoolRecord(id: $0.id, revision: try revision(values), values: values)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func revision(_ values: BridgeJSON) throws -> String { BridgePoolCodec.hash(try BridgePoolCodec.encode(values)) }
    func execute(_ command: NativeItemCommand, userConfirmed: Bool) throws -> BridgeJSON {
        guard userConfirmed, command.provenance == "user", !command.userAuthorizationRef.isEmpty,
              command.userAuthorizationRef.count <= 300, command.occurredAt.timeIntervalSince1970.isFinite else {
            throw DataArchiveError.invalid("事项写入需要用户明确请求，推断不会改动事项")
        }
        guard !context.hasChanges else { throw DataArchiveError.invalid("还有未保存改动，未执行事项操作") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let hash = BridgePoolCodec.hash(try encoder.encode(command))
        var entries = try journal.load()
        let existing = entries.firstIndex { $0.commandId == command.commandId }
        if let i = existing {
            guard entries[i].kind == "item", entries[i].requestHash == hash else { throw DataArchiveError.invalid("同一请求身份的内容改变，未执行") }
            if entries[i].phase == "applied", let receipt = entries[i].receipt { return receipt }
        }
        let id = command.recordId
        let found = try context.fetch(FetchDescriptor<LongTask>(predicate: #Predicate { $0.id == id }))
        guard found.count <= 1 else { throw DataArchiveError.invalid("事项身份重复，未执行") }
        var task = found.first
        let current = try task.map { try SwiftDataBridgePoolReader.values($0) }
        var entry: NativeActionEntry
        if let i = existing {
            entry = entries[i]
            // Save succeeded but receipt response/save was lost. Exact reread
            // can finalize the old intent; a later unrelated edit is unknown.
            if current == entry.proposed { return try complete(entry, entries: &entries, index: i) }
            guard current == entry.before else { throw DataArchiveError.invalid("未决操作后版本已改变；结果未知，请核对，不重复执行") }
        } else {
            if command.action == .create {
                guard task == nil, command.expectedRevision == nil else { throw DataArchiveError.invalid("新事项身份已存在，未重复创建") }
                task = LongTask(id: id, title: "", createdAt: command.occurredAt, modifiedAt: command.occurredAt, zone: .todo)
            } else {
                guard let current, try revision(current) == command.expectedRevision else { throw DataArchiveError.invalid("事项版本冲突，请刷新后重新确认") }
            }
            guard let task else { throw DataArchiveError.invalid("事项不存在") }
            let original = try SwiftDataBridgePoolReader.values(task)
            do { try mutate(task, command) }
            catch { context.rollback(); throw error }
            let proposed = try SwiftDataBridgePoolReader.values(task)
            // Restore temporary preview immediately, before persisting intent.
            apply(original, to: task)
            context.rollback()
            entry = NativeActionEntry(commandId: command.commandId, kind: "item", requestHash: hash,
                                      before: current, proposed: proposed)
            entries.append(entry)
            try journal.save(entries)
        }
        guard let proposed = entry.proposed else { throw DataArchiveError.invalid("操作原文缺失，未执行") }
        if task == nil { task = LongTask(id: id, title: "", createdAt: command.occurredAt, modifiedAt: command.occurredAt, zone: .todo) }
        guard let task else { throw DataArchiveError.invalid("事项不存在") }
        if command.action == .create && found.isEmpty { context.insert(task) }
        apply(proposed, to: task)
        do { try saveContext() }
        catch {
            // No suspension and no pre-existing changes: rollback belongs
            // entirely to this command, never to an unrelated editor.
            context.rollback(); throw error
        }
        didSave()
        return try complete(entry, entries: &entries, index: existing ?? entries.count - 1)
    }
    private func complete(_ entry: NativeActionEntry, entries: inout [NativeActionEntry], index: Int) throws -> BridgeJSON {
        guard let proposed = entry.proposed else { throw DataArchiveError.invalid("缺少操作回执原文") }
        let receipt: BridgeJSON = .object([
            "commandId": .string(entry.commandId.uuidString), "saved": .bool(true),
            "persistedRevision": .string(try revision(proposed)), "authority": .string("swiftdata"),
            "deviceApplication": .string("local_store_saved"), "syncOtherDevices": .string("unknown"),
            "screenVisible": .string("unknown"), "recoverable": .bool(true)
        ])
        entries[index].phase = "applied"; entries[index].receipt = receipt
        try journal.save(entries) // Failure remains prepared; never report done.
        return receipt
    }
    private func mutate(_ task: LongTask, _ command: NativeItemCommand) throws {
        guard Set(command.patch.keys).isSubset(of: ["title", "note", "status"]), command.action == .update || command.action == .create || command.patch.isEmpty else {
            throw DataArchiveError.invalid("不支持的事项字段，未执行")
        }
        if command.action == .delete {
            guard task.poolZone == .todo, !task.isInTrash else { throw DataArchiveError.invalid("长期事项请先放下；待办已在回收站时不重复删除") }
            task.deletedAt = command.occurredAt; task.deletionID = command.commandId
        } else if command.action == .restore {
            guard let deletion = task.deletionID, task.isInTrash else { throw DataArchiveError.invalid("事项不在回收站") }
            try task.acknowledgeRestoration(expected: deletion)
        } else {
            guard !task.isInTrash else { throw DataArchiveError.invalid("请先恢复事项再修改") }
            if let value = command.patch["title"] {
                guard case let .string(title) = value, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 500 else { throw DataArchiveError.invalid("标题无效") }
                task.title = title
            }
            if let value = command.patch["note"] {
                guard case let .string(note) = value, note.count <= 20000 else { throw DataArchiveError.invalid("备注无效") }
                task.note = note
            }
            if let value = command.patch["status"] {
                guard case let .string(status) = value, let decoded = LongTaskStatus(rawValue: status) else { throw DataArchiveError.invalid("状态无效") }
                if task.status != decoded { task.doneAt = decoded == .done ? command.occurredAt : nil }
                task.status = decoded
            }
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DataArchiveError.invalid("新事项需要标题") }
        }
        task.modifiedAt = command.occurredAt
    }
    private func apply(_ values: BridgeJSON, to task: LongTask) {
        guard case let .object(v) = values else { return }
        if case let .string(title) = v["title"] { task.title = title }
        if case let .string(note) = v["note"] { task.note = note }
        if case let .string(status) = v["status"], let decoded = LongTaskStatus(rawValue: status) { task.status = decoded }
        if case let .number(date) = v["createdAt"] { task.createdAt = Date(timeIntervalSince1970: date / 1000) }
        if case let .number(date) = v["modifiedAt"] { task.modifiedAt = Date(timeIntervalSince1970: date / 1000) }
        task.doneAt = timestamp(v["doneAt"]); task.deletedAt = timestamp(v["deletedAt"])
        task.deletionID = uuid(v["deletionId"]); task.restoredDeletionID = uuid(v["restoredDeletionId"])
    }
    private func timestamp(_ value: BridgeJSON?) -> Date? { if case let .number(ms) = value { return Date(timeIntervalSince1970: ms / 1000) }; return nil }
    private func uuid(_ value: BridgeJSON?) -> UUID? { if case let .string(id) = value { return UUID(uuidString: id) }; return nil }
}
