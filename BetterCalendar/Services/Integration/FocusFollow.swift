//
//  FocusFollow.swift
//  BetterCalendar
//
//  多端跟随专注（#30，2026-07-11 哲学审核过审，V1「跟随开始」）：
//  一端 start/complete → CloudKit 单记录 runstate + 静默推送 → 另一端进入/退出「跟随陪伴」显示态
//  （menu bar / 今天页显示同任务计时；iPhone 可联动番茄屏蔽）。
//  审核红线：默认关；**跟随端绝不落任何本地记录**（session/行为/实际/日历全无——记录归发起端，
//  iCloud 自然同步）；一键退出；失同步静默自愈（推送错过靠前台 catch-up 兜底，同聪音对账哲学）。
//  诚实预期：准实时（秒~十几秒，受系统推送调度影响）。
//  ⚠️ 新记录类型 FocusRunState：TestFlight（生产环境）生效前需 CloudKit Console 手动
//  Deploy Schema to Production（同 M7 流程）——开发环境（Xcode 直装）自动建 schema。
//

import Foundation
import CloudKit

enum FocusFollowSettings {
    /// 总开关（默认关；红线①）。
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "integration.focusFollow") }
        set { UserDefaults.standard.set(newValue, forKey: "integration.focusFollow") }
    }
}

/// 跟随态（另一台设备正在做的事）：只读展示 + （iOS）联动屏蔽，绝不产生本地记录。
@Observable
final class FollowRunState {
    static let shared = FollowRunState()

    struct Run {
        var title: String
        var sourceDevice: String = ""
        var style: String        // light / pomodoro / none
        var startedAt: Date      // 已按 elapsed 折算，直接 now-startedAt 即「已多久」
        var pausedAt: Date? = nil
        var isRest: Bool = false
        var updatedAt: Date = .now
        func elapsed(at now: Date = .now) -> TimeInterval { max(0, (pausedAt ?? now).timeIntervalSince(startedAt)) }
        var seq: Int64           // 来源记录 seq（退出跟随后按它静音，防 catch-up 复活）

        var liveActivitySnapshot: LiveActivitySnapshot {
            .init(title: title, timerStart: startedAt, pausedAt: pausedAt,
                  // 协议尚未同步番茄段终点，先展示准确的已用时间。
                  mode: .light, phaseEndsAt: nil, phaseIsRest: isRest, isRemote: true)
        }
    }

    private(set) var run: Run?
    private var mutedSeq: Int64 = -1
    private var mutedDevice = ""
    /// 跟随态变化钩子（组装点接 VM 的屏蔽收敛，跟随也走「工作段=屏蔽」同一纯函数）。
    var onChange: (() -> Void)?

    /// 跟随中且是番茄 → 参与屏蔽谓词（VM updateScreenTimeShield 里 OR 进去）。
    var shouldShield: Bool { run?.style == "pomodoro" && run?.pausedAt == nil && run?.isRest == false }

    func set(_ r: Run?) {
        if let r, r.seq == mutedSeq, r.sourceDevice == mutedDevice { return }   // 用户退出过这一轮跟随 → 静音
        let changed = (run?.title != r?.title) || (run == nil) != (r == nil)
            || run?.sourceDevice != r?.sourceDevice || run?.seq != r?.seq
            || run?.startedAt != r?.startedAt || run?.style != r?.style
            || run?.pausedAt != r?.pausedAt || run?.isRest != r?.isRest
        run = r
        if changed { onChange?() }
    }

    /// 一键退出（红线③）：本轮 seq 静音，直到对面下一个新事件才可能再跟随。
    func exitFollow() {
        mutedSeq = run?.seq ?? -1
        mutedDevice = run?.sourceDevice ?? ""
        run = nil
        onChange?()
        DevLog.shared.info("跟随", "已退出本轮跟随（对面下个新动作前不再跟）")
    }
}

/// CloudKit 通道：单记录 runstate（覆盖写）+ CKQuerySubscription 静默推送 + 前台 catch-up 兜底。
enum FocusFollow {
    static let recordType = "FocusRunState"
    private static let recordID = CKRecord.ID(recordName: "focus-run-state")
    private static let subscriptionID = "focus-follow-sub"
    private static var db: CKDatabase {
        CKContainer(identifier: "iCloud.com.jason.BetterCalendar").privateCloudDatabase
    }

    /// 本机身份（区分发起端/跟随端）。
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "integration.focusFollowDeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "integration.focusFollowDeviceID")
        return id
    }

    private struct Publication: Codable {
        var kind: String
        var title: String
        var sourceDevice: String = ""
        var style: String
        var startedAt: Date
        var hasActive: Bool
        var seq: Int64
        var updatedAt: Date
    }
    static var localHeartbeat: (() -> Void)?
    private static var lastTickPublish: Date = .distantPast
    private static let outboxKey = "integration.focusFollow.outbox.v1"
    private static var pending: Publication? = {
        guard !TestHost.isActive, let data = UserDefaults.standard.data(forKey: outboxKey) else { return nil }
        return try? JSONDecoder().decode(Publication.self, from: data)
    }()
    private static var worker: Task<Void, Never>?
    private static var timer: Timer?
    private static var readTask: Task<Void, Never>?
    private static var refreshAgain = false
    private static var readGeneration = 0
    private static var readRetryAt = Date.distantPast
    private static var nextPoll = Date.distantPast
    private static var revisionGate = FocusRevisionGate()
    private static var hasLocalRun = false
    private static var foreground = true
    private static var subscribed = false
    private static var retryAt = Date.distantPast
    private static var lastSubscriptionAttempt = Date.distantPast
    private static var lastSequence: Int64 = pending?.seq ?? 0
    private static var lastAction = "tick"

    /// Durable, serialized outbox. Network failure never means “record does not exist”.
    static func publish(kind: String, active: FocusStateExporter.State.Active?, isPaused: Bool = false,
                        elapsed: TimeInterval? = nil, sampledAt: Date = .now) {
        guard !TestHost.isActive, FocusFollowSettings.enabled else { return }
        // An idle receiver's periodic catch-up must never manufacture a completion and compete
        // with the device that is actually running. Only an explicit complete may clear a run.
        guard FocusSyncPolicy.shouldPublish(kind: kind, hasActive: active != nil) else { return }
        let now = sampledAt
        hasLocalRun = active != nil
        let action = isPaused ? "paused" : (active?.inRest == true ? "rest" : "running")
        let changed = kind != "tick" || action != lastAction
        if !changed {
            guard active != nil, now.timeIntervalSince(lastTickPublish) >= FocusSyncPolicy.heartbeat else { return }
        }
        // Keep a failed start/pause/complete until delivered; a heartbeat must not erase it.
        if !changed, pending != nil { drain(); return }
        if changed { lastSequence = max(lastSequence + 1, Int64(now.timeIntervalSince1970 * 1000)) }
        lastTickPublish = now; lastAction = action
        pending = Publication(kind: active == nil ? "complete" : (changed ? action : "tick-" + action),
                              title: active?.title ?? "", style: active?.timingStyle ?? "",
                              startedAt: active.map { FocusSyncPolicy.anchor(sampledAt: now, elapsed: elapsed ?? Double($0.elapsedSec)) } ?? .distantPast,
                              hasActive: active != nil, seq: lastSequence, updatedAt: now)
        persistPending()
        if kind != "tick" {
            DevLog.shared.info("跟随", "待发送 \(pending?.kind ?? kind) · seq \(lastSequence)")
        }
        drain()
    }

    private static func persistPending() {
        if let pending, let data = try? JSONEncoder().encode(pending) { UserDefaults.standard.set(data, forKey: outboxKey) }
        else { UserDefaults.standard.removeObject(forKey: outboxKey) }
    }

    private static func drain() {
        guard worker == nil, pending != nil, FocusFollowSettings.enabled, !TestHost.isActive, Date.now >= retryAt else { return }
        worker = Task {
            defer { worker = nil }
            while let next = pending, FocusFollowSettings.enabled {
                do {
                    let requestStart = ProcessInfo.processInfo.systemUptime
                    let record: CKRecord
                    do { record = try await db.record(for: recordID) }
                    catch let error as CKError where error.code == .unknownItem {
                        record = CKRecord(recordType: recordType, recordID: recordID)
                    }
                    guard FocusFollowSettings.enabled else { return }
                    let owner = record["deviceID"] as? String
                    // An old owner's heartbeat/completion cannot stop or steal a newer owner's run.
                    let mayWrite = canPublish(owner: owner, localDevice: deviceID,
                        remoteDate: (record["updatedAt"] as? Date) ?? .distantPast,
                        localDate: next.updatedAt, kind: next.kind, hasActive: next.hasActive)
                    if mayWrite {
                        record["deviceID"] = deviceID; record["action"] = next.kind
                        record["hasActive"] = next.hasActive ? 1 : 0
                        record["title"] = next.title; record["style"] = next.style
                        record["startedAt"] = next.startedAt; record["seq"] = next.seq
                        record["updatedAt"] = next.updatedAt
                        _ = try await db.save(record)
                        FocusSyncDiagnostics.shared.sent(action: next.kind, seq: next.seq, device: deviceID,
                            sourceAt: next.updatedAt, now: .now,
                            seconds: ProcessInfo.processInfo.systemUptime - requestStart)
                        if !next.kind.hasPrefix("tick") {
                            DevLog.shared.info("跟随", "服务器已接收 \(next.kind) · seq \(next.seq)")
                        }
                    } else {
                        FocusSyncDiagnostics.shared.failed("较新状态已由另一动作保存，本机旧动作未覆盖它。")
                    }
                    if pending?.updatedAt == next.updatedAt { pending = nil; persistPending() }
                } catch {
                    let delay = (error as NSError).userInfo[CKErrorRetryAfterKey] as? Double ?? 15
                    retryAt = Date.now.addingTimeInterval(max(15, delay))
                    FocusSyncDiagnostics.shared.failed("执行状态尚未同步：\(error.localizedDescription)")
                    DataSyncMonitor.shared.report("执行状态尚未同步：\(error.localizedDescription)")
                    return // preserved on disk; foreground polling retries, no busy loop.
                }
            }
        }
    }

    static func canPublish(owner: String?, localDevice: String, remoteDate: Date,
                           localDate: Date, kind: String, hasActive: Bool) -> Bool {
        guard localDate >= remoteDate else { return false }
        return owner == nil || owner == localDevice || (hasActive && !kind.hasPrefix("tick"))
    }

    static func setForeground(_ active: Bool) {
        foreground = active
        if active { resume() }
    }

    /// Sample the current local state immediately; subscription setup must not block a read.
    static func resume() {
        guard !TestHost.isActive, FocusFollowSettings.enabled else { return }
        nextPoll = .distantPast
        localHeartbeat?()
        drain()
        Task { await ensureSubscription() }
        Task { await refreshAndApply(reason: "回前台或开启") }
    }

    static func settingsChanged() {
        readGeneration += 1
        if FocusFollowSettings.enabled { resume() }
        else {
            pending = nil; persistPending()
            hasLocalRun = false; lastAction = ""; lastTickPublish = .distantPast
            FollowRunState.shared.set(nil)
        }
    }

    static func startPolling() {
        guard !TestHost.isActive, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                #if os(iOS)
                guard foreground else { return }
                #endif
                guard FocusFollowSettings.enabled else { FollowRunState.shared.set(nil); return }
                // Expiration runs even while CloudKit is throttling or a request is still pending.
                if let run = FollowRunState.shared.run,
                   Date.now.timeIntervalSince(run.updatedAt) >= FocusSyncPolicy.staleAfter {
                    FollowRunState.shared.set(nil)
                }
                guard Date.now >= nextPoll else { return }
                nextPoll = Date.now.addingTimeInterval(FocusSyncPolicy.pollInterval(
                    hasLocalRun: hasLocalRun, hasFollowedRun: FollowRunState.shared.run != nil,
                    hasPending: pending != nil))
                localHeartbeat?()
                drain()
                if !subscribed { Task { await ensureSubscription() } }
                await refreshAndApply(reason: "前台补查")
            }
        }
    }

    #if DEBUG
    /// Explicit developer action: creates an INACTIVE schema probe, never the live run record.
    static func seedDevelopmentSchema() async throws {
        guard !TestHost.isActive else { return }
        let probe = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: "focus-schema-probe"))
        probe["deviceID"] = "schema-probe"; probe["action"] = "complete"
        probe["hasActive"] = 0; probe["title"] = ""; probe["style"] = "light"
        probe["startedAt"] = Date(timeIntervalSince1970: 0)
        probe["seq"] = Int64(0); probe["updatedAt"] = Date(timeIntervalSince1970: 0)
        let record: CKRecord
        do { record = try await db.record(for: probe.recordID) }
        catch let e as CKError where e.code == .unknownItem { record = probe }
        for key in probe.allKeys() { record[key] = probe[key] }
        _ = try await db.save(record)
    }
    #endif

    /// 订阅另一端的 runstate 变化（静默推送）。幂等：重复保存同 ID 订阅无害。
    static func ensureSubscription() async {
        guard !TestHost.isActive, FocusFollowSettings.enabled else { return }
        guard Date.now.timeIntervalSince(lastSubscriptionAttempt) >= 60 else { return }
        lastSubscriptionAttempt = .now
        let sub = CKQuerySubscription(recordType: recordType, predicate: NSPredicate(value: true),
                                      subscriptionID: subscriptionID,
                                      options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // 静默推送：不打扰（通知铁则不受影响）
        sub.notificationInfo = info
        do {
            _ = try await db.save(sub)
            subscribed = true
            FocusSyncDiagnostics.shared.subscriptionSucceeded()
            DevLog.shared.info("跟随", "CloudKit 订阅就绪（focus-follow-sub）")
        } catch {
            FocusSyncDiagnostics.shared.failed("执行状态订阅失败：\(error.localizedDescription)")
            if let retry = (error as? CKError)?.retryAfterSeconds {
                lastSubscriptionAttempt = Date.now.addingTimeInterval(max(0, retry - 60))
            }
            DataSyncMonitor.shared.report("执行状态订阅失败：\(error.localizedDescription)")
        }
    }

    /// 远程静默推送入口（双端 AppDelegate 转发进来）。
    static func handlePush(_ userInfo: [AnyHashable: Any]) async {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo),
              note.subscriptionID == subscriptionID else { return }
        await refreshAndApply(reason: "推送")
    }

    /// 拉取最新 runstate 并收敛本机跟随态（推送触发 + 前台 catch-up 兜底，level-triggered）。
    static func refreshAndApply(reason: String) async {
        guard !TestHost.isActive, FocusFollowSettings.enabled, Date.now >= readRetryAt else { return }
        // Push/foreground/manual requests share one flight. A push during a read gets one catch-up.
        if let readTask {
            if reason != "前台补查" { refreshAgain = true }
            await readTask.value
            return
        }
        let task = Task {
            repeat {
                refreshAgain = false
                await fetchAndApply(reason: reason, generation: readGeneration)
            } while refreshAgain && FocusFollowSettings.enabled && Date.now >= readRetryAt
        }
        readTask = task
        await task.value
        readTask = nil
    }

    private static func fetchAndApply(reason: String, generation: Int) async {
        let requestStart = ProcessInfo.processInfo.systemUptime
        do {
            let record = try await db.record(for: recordID)
            guard FocusFollowSettings.enabled, generation == readGeneration else { return }
            let now = Date.now
            let seconds = ProcessInfo.processInfo.systemUptime - requestStart
            FocusSyncDiagnostics.shared.read(at: now, seconds: seconds)
            apply(record, reason: reason, now: now, requestSeconds: seconds)
        } catch let e as CKError where e.code == .unknownItem {
            guard FocusFollowSettings.enabled, generation == readGeneration else { return }
            FocusSyncDiagnostics.shared.read(at: .now, seconds: ProcessInfo.processInfo.systemUptime - requestStart)
            revisionGate = FocusRevisionGate()
            FollowRunState.shared.set(nil)
        } catch {
            guard FocusFollowSettings.enabled, generation == readGeneration else { return }
            readRetryAt = Date.now.addingTimeInterval(max(15, (error as? CKError)?.retryAfterSeconds ?? 15))
            if let run = FollowRunState.shared.run, Date.now.timeIntervalSince(run.updatedAt) >= FocusSyncPolicy.staleAfter {
                FollowRunState.shared.set(nil)
            }
            FocusSyncDiagnostics.shared.failed("执行状态拉取失败（\(reason)）：\(error.localizedDescription)")
            DataSyncMonitor.shared.report("执行状态拉取失败（\(reason)）：\(error.localizedDescription)")
        }
    }

    private static func apply(_ record: CKRecord, reason: String, now: Date, requestSeconds: Double) {
        let updatedAt = (record["updatedAt"] as? Date) ?? .distantPast
        guard revisionGate.accept(serverDate: record.modificationDate, sourceDate: updatedAt) else { return }
        let sourceDevice = (record["deviceID"] as? String) ?? ""
        guard sourceDevice != deviceID else { FollowRunState.shared.set(nil); return }   // 自己发的不跟
        let hasActive = (record["hasActive"] as? NSNumber)?.boolValue ?? false
        let seq = (record["seq"] as? NSNumber)?.int64Value ?? 0
        let action = (record["action"] as? String) ?? ""
        let newlyObserved = FocusSyncDiagnostics.shared.received(action: action, seq: seq, device: sourceDevice,
            sourceAt: updatedAt, now: now, seconds: requestSeconds, reason: reason,
            revision: record.recordChangeTag ?? "\(sourceDevice):\(seq):\(updatedAt.timeIntervalSince1970)")
        if newlyObserved, !action.hasPrefix("tick") {
            DevLog.shared.info("跟随", "收到另一台设备 \(action) · seq \(seq) · \(reason)")
        }
        // 60 秒心跳；12 分钟无新状态停止展示。时钟超前明显时不伪装成零延迟。
        if updatedAt.timeIntervalSince(now) > 5 {
            FocusSyncDiagnostics.shared.failed("来源设备时间超前，请核对两端自动日期与时间；延迟测量含时钟偏差。")
        }
        guard hasActive, now.timeIntervalSince(updatedAt) < FocusSyncPolicy.staleAfter else {
            FollowRunState.shared.set(nil)
            return
        }
        let title = (record["title"] as? String) ?? ""
        let style = (record["style"] as? String) ?? "light"
        let startedAt = (record["startedAt"] as? Date) ?? .now
        guard !title.isEmpty else { FollowRunState.shared.set(nil); return }
        let paused = action.hasSuffix("paused")
        let rest = action.hasSuffix("rest")
        FollowRunState.shared.set(.init(title: title, sourceDevice: sourceDevice, style: style, startedAt: startedAt,
                                       pausedAt: paused ? updatedAt : nil, isRest: rest,
                                       updatedAt: updatedAt, seq: seq))

    }
}
