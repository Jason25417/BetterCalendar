//
//  ChangeTraceStore.swift
//  BetterCalendar
//
//  变更痕迹（E5b 数据层，D6；UI=E5d）：预授权直写绿的配套义务——每次自动改动留一条可查、可撤的痕迹。
//  存本地 JSON（DraftSnapshotStore 先例）：痕迹是解释层，真相已在 PlanStore 随 CloudKit 同步，不重复上云。
//  措辞纪律（R12 世界归因）：reason 只描述世界（「为『组会』让位」「顺延维护」），永不指向用户能力。
//

import Foundation

/// 一条自动变更痕迹（Codable，按逻辑日分页落盘）。
nonisolated struct ChangeTraceEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var time: Date
    var blockID: UUID
    var title: String
    /// 类别：顺延 / 活动预报 / 软标 / 收池 / 晨间投放 / 撤销
    var kind: String
    var beforeStart: Date
    var beforeEnd: Date
    var afterStart: Date
    var afterEnd: Date
    var reason: String
}

nonisolated private struct ChangeTraceFile: Codable {
    var days: [String: [ChangeTraceEntry]] = [:]
}

@MainActor
final class ChangeTraceStore {
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("BetterCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("change-traces.json")
    }

    func append(_ entry: ChangeTraceEntry, day: Date) {
        var file = loadFile()
        file.days[DraftSnapshotStore.dayKey(day), default: []].append(entry)
        prune(&file)
        persist(file)
    }

    func entries(day: Date) -> [ChangeTraceEntry] {
        loadFile().days[DraftSnapshotStore.dayKey(day)] ?? []
    }

    func clear(day: Date) {
        var file = loadFile()
        file.days.removeValue(forKey: DraftSnapshotStore.dayKey(day))
        persist(file)
    }

    // MARK: 内部

    private func loadFile() -> ChangeTraceFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(ChangeTraceFile.self, from: data) else {
            return ChangeTraceFile()
        }
        return file
    }

    private func persist(_ file: ChangeTraceFile) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 只留最近 7 个逻辑日（痕迹是当期解释层，不是档案；学习层数据另有 E4 管道）。
    private func prune(_ file: inout ChangeTraceFile) {
        let cutoff = DraftSnapshotStore.dayKey(DayContext.logicalDay(offset: -7))
        file.days = file.days.filter { $0.key >= cutoff }   // yyyy-MM-dd 字典序 = 时间序
    }
}
