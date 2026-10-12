import Foundation
import SwiftData

/// Restore acknowledges one deletion ID. An older restore cannot acknowledge
/// a subsequent deletion received from another device, even with clock skew.
@MainActor protocol RetainedRecord: AnyObject {
    var deletedAt: Date? { get set }
    var deletionID: UUID? { get set }
    var restoredDeletionID: UUID? { get set }
    var deletionContext: Data? { get set }
}

extension RetainedRecord {
    var isInTrash: Bool { deletionID != nil && deletionID != restoredDeletionID }
    var retentionUntil: Date? { deletedAt?.addingTimeInterval(30 * 86_400) }
    func markDeleted(at date: Date = .now) {
        guard !isInTrash else { return }
        deletedAt = date; deletionID = UUID()
    }
    func acknowledgeRestoration(expected: UUID) throws {
        guard isInTrash, deletionID == expected else {
            throw DataArchiveError.invalid("删除状态已改变，请刷新回收站后重试")
        }
        restoredDeletionID = expected
    }
}

/// Roll back only touched metadata after failed save, preserving unrelated
/// pending edits. Original rows/content are never physically removed.
@MainActor enum RetainedDeletion {
    static func save(_ rows: [any RetainedRecord], in context: ModelContext, at date: Date = .now) throws {
        let before = rows.map { ($0.deletedAt, $0.deletionID, $0.restoredDeletionID, $0.deletionContext) }
        for row in rows { row.markDeleted(at: date) }
        do { try context.save() }
        catch {
            for (row, value) in zip(rows, before) {
                row.deletedAt = value.0; row.deletionID = value.1
                row.restoredDeletionID = value.2; row.deletionContext = value.3
            }
            throw error
        }
    }
}

nonisolated struct DeletedPhotoOwner: Codable, Equatable {
    var entryID: UUID
    var createdAt: Date
    var position: Int
}
