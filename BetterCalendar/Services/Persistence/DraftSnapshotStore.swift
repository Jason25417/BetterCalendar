//
//  DraftSnapshotStore.swift
//  BetterCalendar
//
//  排日程页草稿快照（2026-07-04，Jason 提出）：输入框文本 + AI 排出的未确认草稿，
//  每次变更即写 JSON（App 容器内）——崩溃/强退/重启后打开 App 还原到之前的画面。
//  确认写入后草稿已进真相源，快照降级为只还原输入文本。本地文件、不进 CloudKit（草稿是设备态）。
//

import Foundation

nonisolated struct DraftSnapshot: Codable {
    nonisolated struct Block: Codable {
        var title: String
        var start: Date
        var end: Date
        var isFixed: Bool
        var timingStyleRaw: String
        var priorityRaw: String
        var deadline: Date?
        var fromPool: Bool

        init(from b: EditableBlock) {
            title = b.title; start = b.start; end = b.end; isFixed = b.isFixed
            timingStyleRaw = b.timingStyle.rawValue; priorityRaw = b.priority.rawValue
            deadline = b.deadline; fromPool = b.fromPool
        }

        var editable: EditableBlock {
            var eb = EditableBlock(title: title, start: start, end: end, isFixed: isFixed,
                                   timingStyle: TimingStyle(rawValue: timingStyleRaw) ?? .light,
                                   priority: BlockPriority(rawValue: priorityRaw) ?? .normal,
                                   deadline: deadline)
            eb.fromPool = fromPool
            return eb
        }
    }

    nonisolated struct PendingLongTask: Codable {
        var title: String
        var deadline: Date?
        var cadenceMinutesPerWeek: Int?
    }

    var inputText: String = ""
    var targetDay: Date = .now
    var draftSourceRaw: String = "empty"
    var blocks: [Block] = []
    var pendingLongTasks: [PendingLongTask] = []
    var savedAt: Date = .now
    var dirty: Bool? = nil   // 0.16：是否含未保存修改（optional 兼容旧快照）
}

@MainActor
final class DraftSnapshotStore {
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("BetterCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("draft-snapshot.json")
    }

    func save(_ snapshot: DraftSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func load() -> DraftSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(DraftSnapshot.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
