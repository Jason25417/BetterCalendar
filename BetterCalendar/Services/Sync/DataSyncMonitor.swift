import Foundation
import CoreData
import CloudKit
import SwiftData
import Observation

/// Observes transport completion separately from local saves. A successful local save is not a sync receipt.
@MainActor @Observable
final class DataSyncMonitor {
    static let shared = DataSyncMonitor()
    static let dataChanged = Notification.Name("BetterCalendar.dataChanged")
    private(set) var lastImport: Date?
    private(set) var lastExport: Date?
    private(set) var lastRefresh: Date?
    private(set) var issue: String?
    private(set) var account = "尚未检查"
    private(set) var storage = "正在打开"
    private var transportEvidence = DataSyncTransportEvidence()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refresh: (() -> Void)?

    func storageOpened(cloud: Bool, error: Error? = nil) {
        transportEvidence.opened(cloud: cloud)
        storage = cloud ? "CloudKit 同步库（传输状态见下方）" : "仅本地保存 · 云同步未启用"
        if let error { report("数据库未能启用 CloudKit：\(error.localizedDescription)") }
    }

    func start(refresh: @escaping () -> Void) {
        guard !TestHost.isActive, observers.isEmpty else { return }
        self.refresh = refresh
        observers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor [weak self] in
                guard let self, let endedAt = event.endDate else { return }
                let phase: DataSyncTransportEvidence.Phase
                switch event.type {
                case .import: phase = .import
                case .export: phase = .export
                default: phase = .setup
                }
                self.transportEvidence.finished(phase, at: endedAt, succeeded: event.succeeded, error: event.error)
                if let error = event.error { self.report("CloudKit \(event.type)：\(error.localizedDescription)") }
                if event.succeeded {
                    switch event.type {
                    case .import: self.lastImport = event.endDate; self.scheduleRefresh()
                    case .export: self.lastExport = event.endDate
                    default: break
                    }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.scheduleRefresh() } })
        Task { await checkAccount() }
    }

    /// Safe bounded metadata for the existing device.status source; no error
    /// descriptions, userInfo, record contents, account IDs or credentials.
    func diagnostics() -> BridgeJSON { transportEvidence.diagnostics() }

    func report(_ message: String) {
        guard issue != message else { return }
        issue = message
        // warn avoids recursive error -> LogSync.flush -> context.save -> error logging.
        DevLog.shared.warn("数据同步", message)
    }

    func checkAccount() async {
        guard !TestHost.isActive else { return }
        do {
            let status = try await CKContainer(identifier: "iCloud.com.jason.BetterCalendar").accountStatus()
            account = status == .available ? "iCloud 账号可用" : "iCloud 不可用（状态 \(status.rawValue)）"
        } catch { account = "账号检查失败"; report(error.localizedDescription) }
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    /// Re-read already imported local data. Does not promise to force Apple's transport scheduler.
    func refreshNow() {
        refresh?()
        lastRefresh = .now
        NotificationCenter.default.post(name: Self.dataChanged, object: nil)
        NotificationCenter.default.post(name: ReconcileService.planChangedExternally, object: nil)
    }
}
