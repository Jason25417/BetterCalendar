import Foundation
import SwiftData
import Observation

/// Developer file bridge. JSON files are interchange; never edit a live SQLite/WAL store.
@MainActor @Observable
final class DataMaintenance {
    static let shared = DataMaintenance()
    private(set) var message = "尚未导出或校验"
    private(set) var latestArchive: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var snapshotTimer: Timer?
    var bridgeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "development.dataBridge") }
        set { UserDefaults.standard.set(newValue, forKey: "development.dataBridge") }
    }
    var directory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent(AppChannel.current.dataFolderName, isDirectory: true)   // W17：Dev 版单独目录（开发修改入口也不串）
    }

    func start() {
        guard !TestHost.isActive, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.processInbox() }
        }
        #if os(macOS)
        // W17 发版前快照：启动 2 分钟后查一次（先让 iCloud 导入跑一会儿），之后每小时查；到期才导出。
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.autoSnapshotIfDue() }
        }
        Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.autoSnapshotIfDue() }
        }
        #endif
    }

    // MARK: W17 自动快照（发版前的数据保险）

    /// 自动快照目录：<数据档案目录>/auto/。发版脚本 scripts/release-dual.py 在日用版发版前检查这里（或手动导出的
    /// snapshot-*.json）有没有足够新的档案，没有就拒绝发版。只写本机，不上传任何地方。
    var autoSnapshotDirectory: URL { directory.appendingPathComponent("auto", isDirectory: true) }
    /// 多久导一次 / 留几份（只轮换本功能自己写的 auto-*.json；手动导出的档案从不动）。
    static let autoSnapshotInterval: TimeInterval = 20 * 3600
    static let autoSnapshotKeep = 14

    /// Mac：最新一份自动快照超过 20 小时 → 导出一份完整档案（与「导出完整数据档案」同一份内容），再删掉第 15 份及更早的自动快照。
    /// 失败（如有未保存编辑）→ DevLog 可见，下个小时再试。
    func autoSnapshotIfDue(now: Date = .now) {
        guard !TestHost.isActive else { return }
        let folder = autoSnapshotDirectory
        let existing = Self.autoSnapshots(in: folder)
        if let newest = existing.first, now.timeIntervalSince(newest.date) < Self.autoSnapshotInterval { return }
        do {
            let url = try writeArchive(prefix: "auto", to: folder).url
            DevLog.shared.info("数据档案", "已自动保存快照 \(url.lastPathComponent)（发版前保险，只存本机）")
            for old in Self.autoSnapshots(in: folder).dropFirst(Self.autoSnapshotKeep) {
                try? FileManager.default.removeItem(at: old.url)
            }
        } catch {
            DevLog.shared.warn("数据档案", "自动快照没存成（下个小时再试）：\(error.localizedDescription)")
        }
    }

    /// 目录里的自动快照，新的在前。
    nonisolated static func autoSnapshots(in folder: URL) -> [(url: URL, date: Date)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("auto-") && $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
    }

    /// Explicit snapshots; existing archives are never rotated or overwritten automatically.
    @discardableResult func exportArchive(prefix: String = "snapshot") throws -> URL {
        let (url, count) = try writeArchive(prefix: prefix, to: directory)
        latestArchive = url
        message = "已导出 \(count) 条数据库记录（含照片本体）；尚未做恢复校验"
        return url
    }

    /// 写一份完整档案到 folder（不改界面状态；手动导出与自动快照共用）。
    private func writeArchive(prefix: String, to folder: URL) throws -> (url: URL, count: Int) {
        let context = SharedModelContainer.shared.mainContext
        guard !context.hasChanges else { throw DataArchiveError.invalid("请先保存当前编辑，再导出") }
        var archive = try DataArchiveStore.capture(context)
        // Keep caches/markers in a separate namespace, not mixed into historical facts.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterCalendar")
        for name in ["behavior-log.jsonl", "draft-snapshot.json", "change-traces.json", "learning-buckets.json"] {
            let url = support.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { archive.localFiles[name] = try Data(contentsOf: url) }
        }
        // Pending bridge intents are evidence only. They are never replayed by
        // isolated restoration, and credentials/device identity are excluded.
        let bridgeSupport = support.deletingLastPathComponent().appendingPathComponent("DotStateBridge")
        for name in ["outbox-v1.json", "task-commands-v1.json"] {
            let url = bridgeSupport.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { archive.localFiles["bridge/" + name] = try Data(contentsOf: url) }
        }
        // Keep legacy/cache files separately; missing cloud rows are not permission to resurrect them.
        let photoDirectory = support.appendingPathComponent("journal-photos")
        if FileManager.default.fileExists(atPath: photoDirectory.path) {
            for file in try FileManager.default.contentsOfDirectory(at: photoDirectory, includingPropertiesForKeys: [.isRegularFileKey]) {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    archive.localFiles["photo-cache/" + file.lastPathComponent] = try Data(contentsOf: file)
                }
            }
        }
        for key in SettingsSync.syncedKeys.union(["looseDays"]) {
            if let value = UserDefaults.standard.object(forKey: key) {
                archive.preferences["local:" + key] = try ArchiveCodec.decoder().decode(ArchiveValue.self,
                    from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]))
            }
        }
        // Capture all KVS property-list state as opaque plist, including routines/achievements/started days.
        let kv = NSUbiquitousKeyValueStore.default.dictionaryRepresentation
        archive.localFiles["icloud-kv.plist"] = try PropertyListSerialization.data(fromPropertyList: kv, format: .xml, options: 0)
        let data = try ArchiveCodec.encoder().encode(SealedDataArchive(archive))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (url, archive.records.count)
    }

    func validate(_ url: URL) throws {
        let seal = try ArchiveCodec.decoder().decode(SealedDataArchive.self, from: Data(contentsOf: url))
        let archive = try seal.verified()
        try DataArchiveStore.validateRestoration(archive)
        message = "校验通过：\(archive.records.count) 条记录已在隔离空库恢复，字段、关系、照片一致；未写入日用库"
    }

    func processInbox() {
        guard bridgeEnabled, !TestHost.isActive else { return }
        let input = directory.appendingPathComponent("request.json")
        guard FileManager.default.fileExists(atPath: input.path) else { return }
        let receipt = directory.appendingPathComponent("receipt.json")
        // Atomically claim one request; external writers submit by rename from request.tmp.
        let processing = directory.appendingPathComponent("processing-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: input, to: processing)
            let request = try ArchiveCodec.decoder().decode(DataEditRequest.self, from: Data(contentsOf: processing))
            let context = SharedModelContainer.shared.mainContext
            guard !context.hasChanges else { throw DataArchiveError.invalid("有未保存编辑，请保存后重试") }
            let current = try DataArchiveStore.capture(context)
            let prepared = try DataArchiveStore.prepare(request, current: current)
            let backup = try exportArchive(prefix: "before-edit")
            try DataArchiveStore.applyPrepared(prepared, request: request, to: context)
            DataSyncMonitor.shared.refreshNow()
            message = "已应用 \(request.edits.count) 条开发修改；旧内容保存在 \(backup.lastPathComponent)。云端到达另看同步状态。"
            let body = ["requestID": request.requestID.uuidString, "status": "applied-locally", "backup": backup.lastPathComponent]
            try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted]).write(to: receipt, options: .atomic)
        } catch {
            message = "开发修改未完成：\(error.localizedDescription)"
            DataSyncMonitor.shared.report(message)
            let body = ["status": "needs-review", "message": message, "requestFile": processing.lastPathComponent]
            try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted]).write(to: receipt, options: .atomic)
        }
    }
}
