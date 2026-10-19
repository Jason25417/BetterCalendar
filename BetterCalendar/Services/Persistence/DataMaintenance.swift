import Foundation
import SwiftData
import Observation

/// Developer file bridge. JSON files are interchange; never edit a live SQLite/WAL store.
@MainActor @Observable
final class DataMaintenance {
    static let shared = DataMaintenance()
    private(set) var message = "尚未导出或校验"
    private(set) var latestArchive: URL?
    /// 最近一次自动快照失败的原因（成功后清空）；面板显示，DevLog 同时记错误。
    private(set) var autoSnapshotIssue: String?
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
    /// 失败 → DevLog 错误（🐞 + 横幅可见）+ 面板「自动快照」行显示原因，下个小时再试。
    func autoSnapshotIfDue(now: Date = .now) {
        guard !TestHost.isActive else { return }
        autoSnapshot(now: now, in: autoSnapshotDirectory)
    }

    /// 自动快照本体（测试直接调：可指定目录 / 容器）。返回新写的档案；没到期或失败返回 nil。
    @discardableResult
    func autoSnapshot(now: Date, in folder: URL, container: ModelContainer = SharedModelContainer.shared) -> URL? {
        let existing = Self.autoSnapshots(in: folder)
        if let newest = existing.first, now.timeIntervalSince(newest.date) < Self.autoSnapshotInterval { return nil }
        do {
            let written = try writeArchive(prefix: "auto", to: folder, container: container)
            autoSnapshotIssue = nil
            let note = written.unsavedNote.map { "；" + $0 } ?? ""
            DevLog.shared.info("数据档案", "已自动保存快照 \(written.url.lastPathComponent)（发版前保险，只存本机）\(note)")
            for old in Self.autoSnapshots(in: folder).dropFirst(Self.autoSnapshotKeep) {
                try? FileManager.default.removeItem(at: old.url)
            }
            return written.url
        } catch {
            autoSnapshotIssue = "自动快照没存成（下个小时再试）：\(error.localizedDescription)"
            DevLog.shared.error("数据档案", autoSnapshotIssue!)
            return nil
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
    /// 失败时：message 换成失败原因（面板按钮旁那一行）+ DevLog 错误，再抛给调用方——绝不静默。
    @discardableResult
    func exportArchive(prefix: String = "snapshot", to folder: URL? = nil,
                       container: ModelContainer = SharedModelContainer.shared) throws -> URL {
        do {
            let written = try writeArchive(prefix: prefix, to: folder ?? directory, container: container)
            latestArchive = written.url
            let note = written.unsavedNote.map { "\n" + $0 } ?? ""
            message = "已导出 \(written.count) 条数据库记录（含照片本体）到 \(written.url.lastPathComponent)；尚未做恢复校验\(note)"
            DevLog.shared.info("数据档案", "已导出完整档案 \(written.url.lastPathComponent)（\(written.count) 条）")
            return written.url
        } catch {
            message = "导出没成功：\(error.localizedDescription)"
            DevLog.shared.error("数据档案", message)
            throw error
        }
    }

    /// 写一份完整档案到 folder（不改界面状态；手动导出与自动快照共用）。
    ///
    /// W19b 修复（0.69.1「点导出没反应」）：旧实现直接用 mainContext，且 `mainContext.hasChanges` 时直接拒绝
    /// （「请先保存当前编辑，再导出」）。日用中 mainContext 几乎总有未落盘的改动（自动保存有间隔、计时/日志/
    /// 编辑随时在改），于是导出几乎必然被拒——错误写进面板的一行附加文字，又没有 DevLog，等于静默失败。
    /// 现在：① 先替主上下文落盘一次（和系统自动保存做的是同一件事）；落盘失败不再挡导出，原因写进 DevLog 与结果；
    /// ② 从**新建的独立 ModelContext** 读磁盘上的已保存数据，跟界面正在编辑的对象互不干扰。
    private func writeArchive(prefix: String, to folder: URL,
                              container: ModelContainer = SharedModelContainer.shared) throws -> (url: URL, count: Int, unsavedNote: String?) {
        var unsavedNote: String?
        let main = container.mainContext
        if main.hasChanges {
            do { try main.save() }
            catch {
                unsavedNote = "有未保存的改动没进这份档案（替你保存时失败：\(error.localizedDescription)）"
                DevLog.shared.error("数据档案", "导出前保存主上下文失败——这些改动可能一直没落盘：\(error.localizedDescription)")
            }
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
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
        try Self.captureLocalPreferences(from: .standard, keys: SettingsSync.syncedKeys.union(["looseDays"]), into: &archive)
        // Capture all KVS property-list state as opaque plist, including routines/achievements/started days.
        let kv = NSUbiquitousKeyValueStore.default.dictionaryRepresentation
        archive.localFiles["icloud-kv.plist"] = try PropertyListSerialization.data(fromPropertyList: kv, format: .xml, options: 0)
        let data = try ArchiveCodec.encoder().encode(SealedDataArchive(archive))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (url, archive.records.count, unsavedNote)
    }

    /// 本机偏好（UserDefaults）进档案。JSON 能表达的进 `preferences["local:<key>"]`；Data / Date 等 JSON 表达不了的
    /// plist 值整份原样存 `localFiles["local-defaults/<key>.plist"]`（同 icloud-kv.plist 的做法）。
    ///
    /// 修复（2026-10-19）：旧实现对每个值直接 `JSONSerialization.data(withJSONObject:)`——遇到 Data（如
    /// approvals.preauthRules.v1，PreauthRules 存的是编码后的 Data）它抛的是 **ObjC 异常**（NSInvalidArgumentException），
    /// Swift 的 try/catch 接不住：异常越过 Swift 帧被 AppKit runloop 吞掉 → 导出/自动快照的主 actor 任务半路消失，
    /// 既不成功也不报错（又一次「点导出没反应」），单测 host 则无限挂起；之后主线程还可能因被撕裂的执行器状态 SIGSEGV。
    /// 所以先用 `isValidJSONObject` 判定（它不抛异常），再走 JSON；否则走 plist；连 plist 都不是的值才 throw（可见失败）。
    nonisolated static func captureLocalPreferences(from defaults: UserDefaults, keys: Set<String>,
                                                    into archive: inout DataArchive) throws {
        for key in keys.sorted() {
            guard let value = defaults.object(forKey: key) else { continue }
            if JSONSerialization.isValidJSONObject([value]) {
                let json = try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
                if case .array(let wrapped) = try ArchiveCodec.decoder().decode(ArchiveValue.self, from: json), let v = wrapped.first {
                    archive.preferences["local:" + key] = v
                    continue
                }
            }
            guard PropertyListSerialization.propertyList(value, isValidFor: .xml) else {
                throw DataArchiveError.invalid("本机偏好 \(key) 不是属性列表类型（\(type(of: value))），无法存进档案")
            }
            archive.localFiles["local-defaults/\(key).plist"] = try PropertyListSerialization.data(
                fromPropertyList: [key: value], format: .xml, options: 0)
        }
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
