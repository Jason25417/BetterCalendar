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
    /// B10：防抖窗口内收到的信号（本机保存回声 vs CloudKit 导入），决定刷新时 planChangedExternally 标什么来源。
    @ObservationIgnored private var routing = PlanChangeRouting()

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
                let wasWedged = self.transportEvidence.isWedged
                self.transportEvidence.finished(phase, at: endedAt, succeeded: event.succeeded, error: event.error)
                if let error = event.error { self.report(Self.describe(type: event.type, error: error)) }
                // 0.72.1：只有导入 / 导出真的成功才算「之前的失败消除了」。旧版连 setup 成功也算——
                // 10-19 起 Mac 导出每次都被拒，每次重试先 setup 成功就把横幅清掉，失败整整一天不可见。
                if event.succeeded, phase != .setup {
                    DevLog.shared.resolve(source: "数据同步")   // W16：同步成功 = 之前的短暂失败自动消除
                    self.issue = nil                          // 下次再失败要重新报（旧版同文案去重 → 清掉后再也不报）
                    switch event.type {
                    case .import: self.lastImport = event.endDate; self.scheduleRefresh(.cloudImportSucceeded)
                    case .export: self.lastExport = event.endDate
                    default: break
                    }
                }
                if wasWedged, !self.transportEvidence.isWedged {
                    NotificationCenter.default.post(name: Self.transportRecovered, object: nil)
                }
            }
        })
        // ⚠️ 本机保存也会发 NSPersistentStoreRemoteChange：这里只重读界面数据，**不当外部变更**（B10 自激循环）
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.scheduleRefresh(.storeRemoteChange) } })
        Task { await checkAccount() }
    }

    /// Safe bounded metadata for the existing device.status source; no error
    /// descriptions, userInfo, record contents, account IDs or credentials.
    func diagnostics() -> BridgeJSON { transportEvidence.diagnostics() }

    /// 0.72.1：同步通道卡死（导出被服务器拒收、之后没成功过）——见 DataSyncTransportEvidence.isWedged。
    /// 对账 / 投影据此不把日历上的变化当成你的手改、不拿本机（可能落后的）真相去盖另一台设备的画面。
    var isTransportWedged: Bool { transportEvidence.isWedged }
    /// 卡死 → 恢复的那一刻（对账借此把卡死期间挂起的差异重新核一遍）。
    static let transportRecovered = Notification.Name("BetterCalendar.dataSyncTransportRecovered")

    /// 失败文案：CloudKit「部分失败」只说 "Failed to modify some records"，真正原因藏在逐条错误里
    /// （例：服务器说 schema 缺字段）——把第一条非「整批连带失败」的原因带出来，失败才真的可见。
    nonisolated static func describe(type: NSPersistentCloudKitContainer.EventType, error: Error) -> String {
        "CloudKit \(type)：\(error.localizedDescription)" + (firstPartialReason(error).map { "（\($0)）" } ?? "")
    }

    nonisolated static func firstPartialReason(_ error: Error) -> String? {
        var e = error as NSError
        if e.domain != CKErrorDomain, let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { e = u }
        guard e.domain == CKErrorDomain, e.code == CKError.Code.partialFailure.rawValue,
              let items = e.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] else { return nil }
        let reasons = items.values.map { $0 as NSError }
            .filter { !($0.domain == CKErrorDomain && $0.code == CKError.Code.batchRequestFailed.rawValue) }
        guard let first = reasons.first else { return nil }
        return (first.userInfo[NSLocalizedDescriptionKey] as? String) ?? first.localizedDescription
    }

    func report(_ message: String) {
        guard issue != message else { return }
        issue = message
        // warn avoids recursive error -> LogSync.flush -> context.save -> error logging.
        DevLog.shared.warn("数据同步", message)
    }

    @ObservationIgnored private let launchedAt = Date()
    /// 启动后多久内还没收到第一次导入，算「本机数据可能还不全」。
    static let firstImportGrace: TimeInterval = 15 * 60

    /// 0.76（10-25 01:38 iPhone iCloud 账号短暂掉线 → 系统清空同步库再重新导入，智能体在空窗里读到「今天 0 块」去重排）：
    /// 给智能体的一句提醒——本机数据此刻可能不全。nil = 正常。
    func agentCaution(now: Date) async -> String? {
        guard !TestHost.isActive else { return nil }
        await checkAccount()
        if !account.hasPrefix("iCloud 账号可用") && account != "尚未检查" {
            return "iCloud 账号此刻不可用（\(account)）：系统可能清空了本机同步库、正在重新导入"
        }
        if isTransportWedged { return "iCloud 同步卡住了：本机看到的可能是旧数据" }
        if lastImport.map({ $0 < launchedAt }) ?? true, now.timeIntervalSince(launchedAt) < Self.firstImportGrace {
            return "App 刚启动 \(Int(now.timeIntervalSince(launchedAt) / 60)) 分钟，还没收到第一次 iCloud 同步：本机计划可能还不全"
        }
        return nil
    }

    func checkAccount() async {
        guard !TestHost.isActive else { return }
        do {
            let status = try await CKContainer(identifier: AppChannel.current.cloudKitContainerID).accountStatus()
            account = status == .available ? "iCloud 账号可用" : "iCloud 不可用（状态 \(status.rawValue)）"
        } catch { account = "账号检查失败"; report(error.localizedDescription) }
    }

    func scheduleRefresh(_ signal: PlanChangeRouting.Signal) {
        routing.note(signal)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flushRefresh()
        }
    }

    /// Re-read already imported local data. Does not promise to force Apple's transport scheduler.
    /// 显式调用（回到前台、开发数据修改、回收站恢复）= 一次性外部变更。
    func refreshNow() {
        routing.note(.manualRefresh)
        flushRefresh()
    }

    private func flushRefresh() {
        let source = routing.drain()
        refresh?()
        lastRefresh = .now
        NotificationCenter.default.post(name: Self.dataChanged, object: nil)
        // 界面照常刷新；时间线协调器按 source 分流——本机保存回声（localStoreSave）不触发重算（B10）
        NotificationCenter.default.post(name: ReconcileService.planChangedExternally, object: nil,
                                        userInfo: [PlanChangeSource.key: source])
    }
}
