import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

/// W19b：「导出完整数据档案」在 0.69.1 点了没反应——主上下文有未落盘改动时旧实现直接拒绝导出，错误又看不到。
/// 这里锁住：有未保存改动也能导出（先落盘、从独立上下文读）、自动快照走同一条路、失败一定可见（message + DevLog）。
@MainActor @Suite(.serialized) struct DataExportReliabilityTests {
    let container: ModelContainer
    let folder: URL

    init() throws {
        container = try ModelContainer(for: DataArchiveStore.schema,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bc-export-" + UUID().uuidString, isDirectory: true)
    }

    private func read(_ url: URL) throws -> DataArchive {
        try ArchiveCodec.decoder().decode(SealedDataArchive.self, from: Data(contentsOf: url)).verified()
    }

    private func titles(_ archive: DataArchive) -> Set<String> {
        Set(archive.records.filter { $0.entity == "PlanBlock" }.compactMap { r -> String? in
            if case .string(let s)? = r.values["title"] { return s }
            return nil
        })
    }

    @Test func exportSucceedsWithUnsavedEditsAndIncludesThem() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = PlanBlock(title: "已保存的块", start: t0, end: t0.addingTimeInterval(3600))
        container.mainContext.insert(saved)
        try container.mainContext.save()
        // 模拟日用中的常态：界面刚改了东西、自动保存还没跑
        container.mainContext.insert(PlanBlock(title: "还没落盘的块", start: t0, end: t0.addingTimeInterval(1800)))
        saved.title = "已保存的块（刚改名）"
        #expect(container.mainContext.hasChanges)

        let m = DataMaintenance()
        let url = try m.exportArchive(to: folder, container: container)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(url.lastPathComponent.hasPrefix("snapshot-"))
        #expect(m.latestArchive == url)
        #expect(m.message.hasPrefix("已导出"))
        #expect(!container.mainContext.hasChanges)   // 先替主上下文落盘
        let archive = try read(url)
        #expect(titles(archive) == ["已保存的块（刚改名）", "还没落盘的块"])
        #expect(archive.formatVersion == DataArchiveStore.currentVersion)
    }

    @Test func exportFailureIsVisibleInMessageAndDevLog() throws {
        // 目标「文件夹」其实是个文件 → 建目录失败
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("bc-export-blocker-" + UUID().uuidString)
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let m = DataMaintenance()
        #expect(throws: (any Error).self) { try m.exportArchive(to: blocker, container: container) }
        #expect(m.message.hasPrefix("导出没成功"))
        #expect(m.latestArchive == nil)
        // 同步调用、主 actor 上无交错 → 最后一条日志就是这次失败
        let last = try #require(DevLog.shared.entries.last)
        #expect(last.level == .error && last.source == "数据档案")
    }

    @Test func autoSnapshotUsesSamePathWithUnsavedEditsRespectsIntervalAndRotates() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        container.mainContext.insert(PlanBlock(title: "未保存", start: t0, end: t0.addingTimeInterval(600)))
        #expect(container.mainContext.hasChanges)
        let m = DataMaintenance()

        let first = try #require(m.autoSnapshot(now: .now, in: folder, container: container))
        #expect(first.lastPathComponent.hasPrefix("auto-"))
        #expect(m.autoSnapshotIssue == nil)
        #expect(titles(try read(first)) == ["未保存"])
        // 20 小时内不重复导
        #expect(m.autoSnapshot(now: .now.addingTimeInterval(3600), in: folder, container: container) == nil)
        #expect(DataMaintenance.autoSnapshots(in: folder).count == 1)

        // 轮换：塞满 14 份旧的，再到期导一份 → 最多留 14 份，最新的保留
        let fm = FileManager.default
        for i in 0..<DataMaintenance.autoSnapshotKeep {
            let u = folder.appendingPathComponent("auto-old\(i).json")
            try Data("{}".utf8).write(to: u)
            try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-Double(100_000 + i * 1000))], ofItemAtPath: u.path)
        }
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-90_000)], ofItemAtPath: first.path)
        let next = try #require(m.autoSnapshot(now: .now, in: folder, container: container))
        let left = DataMaintenance.autoSnapshots(in: folder)
        #expect(left.count == DataMaintenance.autoSnapshotKeep)
        #expect(left.first?.url.lastPathComponent == next.lastPathComponent)
    }

    @Test func autoSnapshotFailureIsVisible() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("bc-auto-blocker-" + UUID().uuidString)
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let m = DataMaintenance()
        #expect(m.autoSnapshot(now: .now, in: blocker, container: container) == nil)
        #expect(m.autoSnapshotIssue?.hasPrefix("自动快照没存成") == true)
        // 同步调用、主 actor 上无交错 → 最后一条日志就是这次失败
        let last = try #require(DevLog.shared.entries.last)
        #expect(last.level == .error && last.source == "数据档案")
    }
}
