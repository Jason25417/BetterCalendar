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
        var isAnchor: Bool = false
        var timingStyleRaw: String
        var priorityRaw: String
        var deadline: Date?
        var fromPool: Bool
        var linkedTaskID: UUID? = nil   // 0.18.2；旧快照缺此键 → 解码为 nil，兼容
        var labels: [String]? = nil     // 0.22 并行组等扩展标签；旧快照缺此键 → nil，兼容

        init(from b: EditableBlock) {
            title = b.title; start = b.start; end = b.end; isFixed = b.isFixed
            timingStyleRaw = b.timingStyle.rawValue; priorityRaw = b.priority.rawValue
            deadline = b.deadline; fromPool = b.fromPool; linkedTaskID = b.linkedTaskID
            labels = b.labels.isEmpty ? nil : b.labels
        }

        var editable: EditableBlock {
            var eb = EditableBlock(title: title, start: start, end: end, isFixed: isFixed, isAnchor: isAnchor,
                                   timingStyle: TimingStyle(rawValue: timingStyleRaw) ?? .light,
                                   priority: BlockPriority(rawValue: priorityRaw) ?? .normal,
                                   deadline: deadline, linkedTaskID: linkedTaskID)
            eb.fromPool = fromPool
            eb.labels = labels ?? []
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

/// 按日草稿本文件（0.23 C，SPEC §11 ③）：每个目标日一页，键 = "yyyy-MM-dd"（该日 startOfDay）。
nonisolated struct DraftSnapshotFile: Codable {
    var days: [String: DraftSnapshot] = [:]
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

    // MARK: 按日 API（0.23 C：切目标日=切草稿本；旧的单页 API 已退役）

    func save(_ snapshot: DraftSnapshot, day: Date) {
        var file = loadFile()
        file.days[Self.dayKey(day)] = snapshot
        prune(&file)
        persist(file)
    }

    func load(day: Date) -> DraftSnapshot? {
        loadFile().days[Self.dayKey(day)]
    }

    func clear(day: Date) {
        var file = loadFile()
        file.days.removeValue(forKey: Self.dayKey(day))
        persist(file)
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: 内部

    /// 读整本；旧格式（单份 DraftSnapshot）自动迁移到它自己的 targetDay 页下——零迁移债。
    private func loadFile() -> DraftSnapshotFile {
        guard let data = try? Data(contentsOf: fileURL) else { return DraftSnapshotFile() }
        if let file = try? JSONDecoder().decode(DraftSnapshotFile.self, from: data),
           !file.days.isEmpty || (try? JSONDecoder().decode(DraftSnapshot.self, from: data)) == nil {
            return file
        }
        if let legacy = try? JSONDecoder().decode(DraftSnapshot.self, from: data) {
            return DraftSnapshotFile(days: [Self.dayKey(legacy.targetDay): legacy])
        }
        return DraftSnapshotFile()
    }

    private func persist(_ file: DraftSnapshotFile) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 过期清理：过去日子的草稿页没有意义（那天已经过完），只留 逻辑今天 及以后。
    private func prune(_ file: inout DraftSnapshotFile) {
        let today = Self.dayKey(DayContext.logicalDay(offset: 0))
        file.days = file.days.filter { $0.key >= today }   // yyyy-MM-dd 字典序 = 时间序
    }

    static func dayKey(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Calendar.current.startOfDay(for: day))
    }
}
