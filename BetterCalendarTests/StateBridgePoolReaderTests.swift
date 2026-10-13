import Foundation
import Testing
import SwiftData
@testable import BetterCalendar

@MainActor @Suite struct StateBridgePoolReaderTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: DataArchiveStore.schema, configurations: ModelConfiguration(schema: DataArchiveStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
    @Test func completeDirectoryKeepsDoneShelvedWishesTrashAndStageContent() throws {
        let c = try container(), context = c.mainContext
        let tasks = [LongTask(title: "在途"), LongTask(title: "已完成", status: .done), LongTask(title: "放下", status: .shelved), LongTask(title: "愿望", zone: .todo)]
        tasks.forEach { context.insert($0) }
        tasks[3].deletionID = UUID(); tasks[3].deletedAt = Date(timeIntervalSince1970: 50)
        let stage = LongTaskCheckpoint(title: "原阶段", doneAt: Date(timeIntervalSince1970: 100)); stage.task = tasks[0]; context.insert(stage)
        try context.save()
        let reader = SwiftDataBridgePoolReader(context: context), snapshot = try reader.snapshot()
        let object = try #require(JSONSerialization.jsonObject(with: snapshot.data) as? [String: Any])
        let records = try #require(object["records"] as? [[String: Any]])
        #expect(snapshot.recordCount == 4 && records.count == 4)
        let values = records.compactMap { $0["values"] as? [String: Any] }
        #expect(Set(values.compactMap { $0["status"] as? String }) == ["active", "done", "shelved"])
        #expect(values.contains { $0["isInTrash"] as? Bool == true && $0["zone"] as? String == "todo" })
        let before = snapshot.data
        stage.title = "开发期直接修改"; try context.save()
        #expect(try reader.snapshot().data != before) // Detects edits even without a parent timestamp update.
        #expect(context.hasChanges == false)
    }
    @Test func uncommittedOrAmbiguousRowsAreNeverPublishedAsComplete() throws {
        let c = try container(), context = c.mainContext, task = LongTask(title: "未保存")
        context.insert(task)
        #expect(throws: (any Error).self) { try SwiftDataBridgePoolReader(context: context).snapshot() }
        try context.save(); context.insert(LongTask(id: task.id, title: "同身份")); try context.save()
        #expect(throws: (any Error).self) { try SwiftDataBridgePoolReader(context: context).snapshot() }
    }
    @Test func oldOutboxAndMultipartDirectorySurviveRestartWithoutIdentityChanges() throws {
        let old = Data("{\"nextSequence\":1,\"observations\":[]}".utf8)
        var queue = try JSONDecoder().decode(BridgeOutbox.self, from: old)
        let data = Data(String(repeating: "学习🌲", count: 18000).utf8)
        let snapshot = BridgePoolSnapshot(data: data, recordCount: 1), date = Date(timeIntervalSince1970: 100)
        try queue.enqueuePool(snapshot, deviceId: "mac", at: date)
        #expect(queue.observations.allSatisfy { (try? JSONEncoder().encode($0).count) ?? Int.max < 48 * 1024 })
        let restored = try JSONDecoder().decode(BridgeOutbox.self, from: JSONEncoder().encode(queue))
        #expect(restored.observations.map(\.eventId) == queue.observations.map(\.eventId))
        var bytes = Data()
        for observation in restored.observations where observation.source == "bc.pool.chunk" {
            guard case let .object(value) = observation.value, case let .string(encoded) = value["bytes"], let part = Data(base64Encoded: encoded) else { Issue.record("missing chunk"); return }
            bytes.append(part)
        }
        #expect(bytes == data)
        let firstCount = queue.observations.count
        try queue.enqueuePool(snapshot, deviceId: "mac", at: date.addingTimeInterval(60))
        #expect(queue.observations.count == firstCount + 1) // Fresh read, unchanged immutable content reused.
        try queue.enqueuePool(snapshot, deviceId: "another-mac", at: date.addingTimeInterval(120))
        #expect(queue.observations.count > firstCount + 2) // A device switch cannot reuse another device's chunks.
        queue.poolCache?.manifest = .object([:])
        #expect(throws: (any Error).self) { try queue.validate() }
    }
}

@MainActor @Suite struct StateBridgeLegacyExecutionTests {
    @Test func originalSessionsRemainSeparateReadOnlyAndDetectExternalEditsWithoutMigration() throws {
        let schema = DataArchiveStore.schema
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)), context = c.mainContext
        let first = ExecutionSession(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let identical = ExecutionSession(start: first.start, end: first.end)
        first.title = "同内容原会话"; identical.title = first.title
        context.insert(first); context.insert(identical); try context.save()
        let reader = SwiftDataBridgePoolReader(context: context), snapshot = try reader.snapshot()
        let payload = try #require(JSONSerialization.jsonObject(with: snapshot.data) as? [String: Any])
        let rows = try #require(payload["executionSessions"] as? [[String: Any]])
        #expect(rows.count == 2 && snapshot.executionSessionCount == 2)
        #expect(Set(rows.compactMap { $0["id"] as? String }).count == 2)
        #expect(try reader.snapshot().data == snapshot.data)
        let beforeIDs = Set(rows.compactMap { $0["id"] as? String })
        first.title = "外部修正后"; try context.save()
        let updated = try reader.snapshot()
        let object = try #require(JSONSerialization.jsonObject(with: updated.data) as? [String: Any])
        let after = try #require(object["executionSessions"] as? [[String: Any]])
        #expect(Set(after.compactMap { $0["id"] as? String }) == beforeIDs)
        #expect(updated.data != snapshot.data && context.hasChanges == false)
        #expect(try context.fetch(FetchDescriptor<ExecutionSession>()).count == 2)
        #expect(first.start == Date(timeIntervalSince1970: 100) && first.end == Date(timeIntervalSince1970: 200))
    }
}
