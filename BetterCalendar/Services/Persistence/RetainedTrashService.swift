import Foundation
import SwiftData

nonisolated struct TrashItem: Identifiable {
    var id: String
    var title: String
    var category: String
    var deletionID: UUID
    var deletedAt: Date
    var retentionUntil: Date { deletedAt.addingTimeInterval(30 * 86_400) }
}

@MainActor protocol TrashManaging: AnyObject {
    func entries() throws -> [TrashItem]
    func restore(_ item: TrashItem) async throws
}

/// Original content and relationships stay in the same row. The UI holds an
/// opaque row identity and deletion receipt, never a mutable database object.
@MainActor final class RetainedTrashService: TrashManaging {
    private let context: ModelContext
    private let calendar: CalendarStore
    private let projection: ProjectionService
    private var busy = false

    init(context: ModelContext, calendar: CalendarStore, projection: ProjectionService) {
        self.context = context; self.calendar = calendar; self.projection = projection
    }

    private func key(_ row: any PersistentModel) -> String {
        String(describing: row.persistentModelID)
    }

    private func records() throws -> [(any PersistentModel, any RetainedRecord, String, String)] {
        var result: [(any PersistentModel, any RetainedRecord, String, String)] = []
        for r in try context.fetch(FetchDescriptor<PlanBlock>()) {
            result.append((r, r, r.title, r.kind == .actual ? "实际记录" : "计划"))
        }
        for r in try context.fetch(FetchDescriptor<LongTask>()) { result.append((r, r, r.title, "待办／长期事项")) }
        for r in try context.fetch(FetchDescriptor<LongTaskCheckpoint>()) { result.append((r, r, r.title, "阶段")) }
        for r in try context.fetch(FetchDescriptor<JournalEntry>()) {
            result.append((r, r, String(r.body.prefix(50)), "日记"))
        }
        for r in try context.fetch(FetchDescriptor<JournalPhoto>()) { result.append((r, r, r.ref, "照片")) }
        return result
    }

    func entries() throws -> [TrashItem] {
        try records().compactMap { model, row, title, category in
            guard row.isInTrash, let operation = row.deletionID, let date = row.deletedAt else { return nil }
            return TrashItem(id: key(model), title: title.isEmpty ? "未命名" : title,
                             category: category, deletionID: operation, deletedAt: date)
        }.sorted { $0.deletedAt > $1.deletedAt }
    }

    func restore(_ item: TrashItem) async throws {
        guard !busy else { throw DataArchiveError.invalid("另一项恢复正在保存，请稍后重试") }
        busy = true; defer { busy = false }
        guard let (model, row, _, _) = try records().first(where: { key($0.0) == item.id }),
              row.isInTrash, row.deletionID == item.deletionID else {
            throw DataArchiveError.invalid("删除状态已改变，请刷新回收站后重试")
        }
        // Check identity conflicts before touching the calendar or the row.
        if let block = model as? PlanBlock {
            let duplicates = try context.fetch(FetchDescriptor<PlanBlock>()).filter {
                $0.persistentModelID != block.persistentModelID && $0.id == block.id &&
                $0.kind == block.kind && !$0.isInTrash
            }
            guard duplicates.isEmpty else { throw DataArchiveError.invalid("已有同身份日程，已保留两份原始记录，需先核对") }
            let start = block.start, end = block.end, title = block.title
            let label = DayContext.logicalStartOfDay(start)
            // Calendar restore must succeed before acknowledging deletion. On
            // failure the row stays recoverable rather than vanishing at reconciliation.
            if block.kind == .planned {
                try await projection.project(label: label, restoring: ScheduledBlock(
                    id: block.id, title: title, start: start, end: end,
                    isFixed: block.isFixed, isAnchor: block.isAnchor, timingStyle: block.timingStyle,
                    priority: block.priority, deadline: block.deadline, linkedTaskID: block.linkedTaskID,
                    labels: block.labels))
            } else {
                let window = DayContext.logicalWindow(forLabel: label)
                var existing = try await calendar.read(kind: .actual).filter {
                    $0.start >= window.start && $0.start < window.end && $0.blockID != block.id
                }
                existing.append(CalendarEventDraft(title: title, start: start, end: end, kind: .actual, blockID: block.id))
                try await calendar.apply(existing, kind: .actual, window: window)
            }
            guard block.start == start, block.end == end, block.title == title else {
                throw DataArchiveError.invalid("恢复时日程内容发生变化，请刷新后重试；原记录仍保留")
            }
        } else if let task = model as? LongTask {
            guard try !context.fetch(FetchDescriptor<LongTask>()).contains(where: {
                $0.persistentModelID != task.persistentModelID && $0.id == task.id && !$0.isInTrash
            }) else { throw DataArchiveError.invalid("已有同身份事项，需先核对") }
        } else if let checkpoint = model as? LongTaskCheckpoint {
            guard !(checkpoint.task?.isInTrash ?? false) else {
                throw DataArchiveError.invalid("请先恢复所属事项，再恢复这个阶段")
            }
            guard try !context.fetch(FetchDescriptor<LongTaskCheckpoint>()).contains(where: {
                $0.persistentModelID != checkpoint.persistentModelID && $0.id == checkpoint.id && !$0.isInTrash
            }) else { throw DataArchiveError.invalid("已有同身份阶段，需先核对") }
        } else if let entry = model as? JournalEntry {
            guard try !context.fetch(FetchDescriptor<JournalEntry>()).contains(where: {
                $0.persistentModelID != entry.persistentModelID && $0.id == entry.id && !$0.isInTrash
            }) else { throw DataArchiveError.invalid("已有同身份日记，需先核对") }
        } else if let photo = model as? JournalPhoto {
            guard try !context.fetch(FetchDescriptor<JournalPhoto>()).contains(where: {
                $0.persistentModelID != photo.persistentModelID && $0.ref == photo.ref && !$0.isInTrash
            }) else { throw DataArchiveError.invalid("已有同引用照片，需先核对") }
        }
        // Revalidate after asynchronous system calls: an old restore must never
        // acknowledge a new deletion arriving from another device.
        guard row.isInTrash, row.deletionID == item.deletionID else {
            throw DataArchiveError.invalid("恢复期间删除状态改变，请刷新后重试")
        }
        let previous = row.restoredDeletionID
        var ownersBefore: [(JournalEntry, [String])] = []
        do {
            if let photo = model as? JournalPhoto, let bytes = photo.deletionContext {
                let owners = try ArchiveCodec.decoder().decode([DeletedPhotoOwner].self, from: bytes)
                let entries = try context.fetch(FetchDescriptor<JournalEntry>())
                for owner in owners {
                    // Ambiguous duplicates are not silently attached to another entry.
                    // Millisecond Double JSON round trips may differ by one floating-point ULP.
                    let matches = entries.filter { $0.id == owner.entryID && abs($0.createdAt.timeIntervalSince(owner.createdAt)) < 0.000_001 }
                    guard matches.count <= 1 else { throw DataArchiveError.invalid("照片所属日记有重复身份，需先核对") }
                    if let entry = matches.first, !entry.photoRefs.contains(photo.ref) {
                        ownersBefore.append((entry, entry.photoRefs))
                        entry.photoRefs.insert(photo.ref, at: min(max(0, owner.position), entry.photoRefs.count))
                    }
                }
            }
            try row.acknowledgeRestoration(expected: item.deletionID)
            try context.save()
        } catch {
            row.restoredDeletionID = previous
            for (entry, references) in ownersBefore { entry.photoRefs = references }
            throw error
        }
        DataSyncMonitor.shared.refreshNow()
        DevLog.shared.info("回收站", "已恢复\(item.category)，原始记录与关系保持")
    }
}
