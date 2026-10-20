import Foundation
import Observation

/// Buttons and Dots share the server's durable sessions. This model only holds
/// a view cache and replayable user commands, never a second execution history.
@MainActor @Observable final class BridgeTaskViewModel {
    private let service: any BridgeTaskServing
    private let persistence: any BridgeTaskPersisting
    private let enabled: () -> Bool
    private let now: () -> Date
    /// W5：计时真相在哪（启动时决定）。默认旧通道，行为与改动前一致。
    let backend: SharedTimerBackend
    private let activePoll: TimeInterval
    private let idlePoll: TimeInterval
    private var file = BridgeTaskLocalFile()
    private var healthy = true
    private(set) var busy = false
    private(set) var message = "等待同步计时状态"
    private(set) var lastError: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var nextPoll = Date.distantPast
    @ObservationIgnored var onChange: (() -> Void)?

    init(service: any BridgeTaskServing, persistence: any BridgeTaskPersisting,
         enabled: @escaping () -> Bool, now: @escaping () -> Date = { Date() },
         backend: SharedTimerBackend = .stateBridge, activePoll: TimeInterval = 5, idlePoll: TimeInterval = 15) {
        self.service = service; self.persistence = persistence; self.enabled = enabled; self.now = now
        self.backend = backend; self.activePoll = activePoll; self.idlePoll = idlePoll
        do { file = try persistence.load(); try file.validate() }
        catch { healthy = false; report("计时队列读取失败，原文件已保留；修复后再操作") }
    }
    var isEnabled: Bool { enabled() }
    var sessions: [BridgeTaskSession] { file.state?.sessions ?? [] }
    var primary: BridgeTaskSession? { sessions.first(where: { !$0.isExperiment && $0.status == .running }) ?? sessions.first(where: { !$0.isExperiment }) ?? sessions.first }
    var pendingCount: Int { file.pending.filter { !$0.needsReview }.count }
    var reviewCount: Int { file.pending.filter(\.needsReview).count }
    var canSubmit: Bool { isEnabled && healthy && file.state != nil && !busy && pendingCount == 0 && file.pending.count < 100 }
    var isStale: Bool { file.receivedAt.map { let age = now().timeIntervalSince($0); return age >= 60 || age < -5 } ?? true }
    /// Local receipt time, not projection/update time. Failed refreshes must
    /// not keep an old lock-screen state looking current indefinitely.
    var presentationValidUntil: Date {
        guard healthy, !hasMore, let receivedAt = file.receivedAt,
              now().timeIntervalSince(receivedAt) >= -5 else { return now() }
        return receivedAt.addingTimeInterval(60)
    }
    var hasMore: Bool { file.state?.hasMore ?? false }
    /// W31b：本机是否读到过任何一次云端计时状态（没读到过时不能说「以上是最后一次同步的记录」）。
    var hasEverRead: Bool { file.state != nil }
    /// W31b：iCloud 通道每次云端调用最多等这么久（没登录 iCloud 时 CloudKit 可能永远不回，界面就永远「等待读取」）。
    var cloudTimeout: TimeInterval = 20
    private func bounded<T: Sendable>(_ op: @escaping @MainActor () async throws -> T) async throws -> T {
        guard backend == .icloud else { return try await op() }
        return try await CloudDeadline.race(seconds: cloudTimeout, op)
    }
    var lastReadReceivedAt: Date? { file.receivedAt }
    func estimatedServerDate(at localDate: Date? = nil) -> Date {
        guard let state = file.state, let midpoint = file.localMidpoint else { return localDate ?? now() }
        return state.readAt.addingTimeInterval(max(0, (localDate ?? now()).timeIntervalSince(midpoint)))
    }
    func elapsed(_ session: BridgeTaskSession, at date: Date? = nil) -> TimeInterval {
        guard let anchor = file.localMidpoint else { return session.elapsedMs / 1000 }
        return session.elapsed(at: date ?? now(), localMidpoint: anchor)
    }

    func startPolling() {
        // W16：旧通道（StateBridge）未配置时 isEnabled=false → 不建每秒空转的定时器；iCloud 后端恒 true，照常
        guard timer == nil, !TestHost.isActive, isEnabled else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isEnabled, self.now() >= self.nextPoll else { return }
                await self.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common); timer = t
        Task { await refresh() }
    }

    /// startedAt（SPEC §19 W8）：审批通过的回溯起点（本机时钟）；换算成服务器时间后作开始命令的 occurredAt。nil = 此刻。
    func start(title: String, relatedRecordId: String? = nil, mode: BridgeTaskSession.Mode = .light, focusMinutes: Int? = nil, experiment: Bool = false,
               startedAt: Date? = nil) async {
        guard queueStart(title: title, relatedRecordId: relatedRecordId, mode: mode, focusMinutes: focusMinutes, experiment: experiment, startedAt: startedAt) else { return }
        await refresh()
    }
    @discardableResult func queueStart(title: String, relatedRecordId: String? = nil, mode: BridgeTaskSession.Mode = .light, focusMinutes: Int? = nil, experiment: Bool = false,
                                       startedAt: Date? = nil) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let occurredAt = startedAt.map { estimatedServerDate().addingTimeInterval(min(0, $0.timeIntervalSince(now()))) } ?? estimatedServerDate()
        return enqueue(BridgeTaskCommand(commandId: UUID().uuidString, action: .start, title: title,
                                         occurredAt: occurredAt, relatedRecordId: relatedRecordId, mode: mode, focusMinutes: focusMinutes, experiment: experiment))
    }
    func act(_ action: BridgeTaskCommand.Action, on session: BridgeTaskSession) async {
        guard action != .start else { return }
        guard enqueue(BridgeTaskCommand(commandId: UUID().uuidString, action: action, sessionId: session.id,
                                         expectedRevision: session.revision, occurredAt: estimatedServerDate())) else { return }
        await refresh()
    }
    @discardableResult private func enqueue(_ command: BridgeTaskCommand) -> Bool {
        guard canSubmit, command.validMode else { return false }
        var next = file; next.pending.append(.init(command: command))
        do { try persistence.save(next); file = next }
        catch { report("操作未能保存到本机，没有开始或改变计时"); return false }
        message = "操作已存到本机，等待云端确认"
        nextPoll = .distantPast
        return true
    }

    func refresh(allowCommands: Bool = true) async {
        guard isEnabled, !busy else { return }
        busy = true; defer {
            busy = false
            nextPoll = now().addingTimeInterval(sessions.isEmpty && pendingCount == 0 ? idlePoll : activePoll)
            onChange?()
        }
        var hadConflict = false
        do {
            while healthy && allowCommands, let queued = file.pending.first(where: { !$0.needsReview }) {
                do {
                    let command = queued.command, service = self.service
                    let receipt = try await bounded { try await service.submitTask(command) }
                    guard receipt.saved, receipt.commandId == queued.command.commandId else { throw URLError(.cannotParseResponse) }
                    var next = file; next.pending.removeAll { $0.command.commandId == receipt.commandId }
                    try persistence.save(next); file = next
                    message = "操作已保存；正在更新显示"
                } catch {
                    let e = error as NSError
                    guard Self.isPermanentRejection(e) else { throw error }
                    var next = file
                    if let i = next.pending.firstIndex(where: { $0.command.commandId == queued.command.commandId }) { next.pending[i].needsReview = true }
                    try persistence.save(next); file = next; hadConflict = true
                    report(e.code == 409 ? "另一端已改变状态，未覆盖它的操作；请根据当前状态重新选择" : "操作未被接受；已保留请求，请检查连接或记录状态")
                }
            }
            let service = self.service
            let sentAt = now(), state = try await bounded { try await service.readTasks() }, receivedAt = now()
            try state.validate()
            if let previous = file.state {
                guard state.readAt >= previous.readAt else { throw URLError(.cannotParseResponse) }
                for incoming in state.sessions {
                    if let old = previous.sessions.first(where: { $0.id == incoming.id }) {
                        guard incoming.revision >= old.revision,
                              incoming.resolvedMode == old.resolvedMode, incoming.focusMinutes == old.focusMinutes,
                              incoming.isExperiment == old.isExperiment,
                              incoming.revision != old.revision || (incoming.status == old.status && incoming.lastCommandId == old.lastCommandId) else { throw URLError(.cannotParseResponse) }
                    }
                    guard previous.applicationSnapshot?.finishedVersions.contains(where: { $0.sessionId == incoming.id }) != true else { throw URLError(.cannotParseResponse) }
                }
            }
            var next = file; next.state = state; next.receivedAt = receivedAt
            next.localMidpoint = sentAt.addingTimeInterval(max(0, receivedAt.timeIntervalSince(sentAt)) / 2)
            if healthy, !state.hasMore, let snapshot = state.applicationSnapshot {
                var ids = next.pendingApplicationSnapshots ?? []
                if ids.count < 100 { ids.append(snapshot.id); next.pendingApplicationSnapshots = ids }
                else { report("设备读取已更新；应用回执队列已满，未将本次读取确认为已应用") }
            }
            if healthy { try persistence.save(next) }
            file = next
            if !hadConflict {
                if reviewCount == 0 && healthy { lastError = nil }
                message = !healthy ? "已读取云端状态；本地操作队列需修复" : pendingCount > 0 ? "状态已更新；还有 \(pendingCount) 条操作待同步" : syncedMessage
            }
            if healthy {
                // The state and pending receipt are saved atomically before
                // reporting. A lost reply/restart retries the same snapshot ID.
                while let ids = file.pendingApplicationSnapshots, !ids.isEmpty {
                    let sent = Array(ids.prefix(10))
                    do {
                        let accepted = try await bounded { try await service.reportSavedTaskSnapshots(sent) }
                        guard accepted == Set(sent) else { throw URLError(.cannotParseResponse) }
                        var applied = file; applied.pendingApplicationSnapshots = ids.filter { !accepted.contains($0) }
                        try persistence.save(applied); file = applied
                    } catch {
                        report("计时显示已读取；设备应用回执尚未确认，保留原身份重试")
                        break
                    }
                }
            }
        } catch {
            // W31b：写出真实原因（原来只说「暂未完成」，没登录 iCloud 时 iPhone 甚至一直停在「等待」）
            report("计时同步暂未完成（\(error.localizedDescription)）；保留最后状态与 \(pendingCount) 条待同步操作，连接恢复后重试")
        }
    }
    /// A confirmed remote command uses the same cloud session, then requires
    /// the device's persisted complete snapshot to cover that returned version.
    /// A newer version is reported as superseding it, never as the exact state.
    func confirmSavedVersion(_ result: BridgeJSON) async throws -> BridgeJSON {
        let fields = try NativeRemoteJSON.object(result)
        let id = try NativeRemoteJSON.string(fields["id"]), revision = try NativeRemoteJSON.integer(fields["revision"])
        let expectedStatus = try NativeRemoteJSON.string(fields["status"]), expectedCommand = try NativeRemoteJSON.string(fields["commandId"])
        guard revision > 0, fields["saved"] == .bool(true) else { throw URLError(.cannotParseResponse) }
        await refresh(allowCommands: false)
        guard healthy, !hasMore, !isStale, let state = file.state, let snapshot = state.applicationSnapshot else {
            throw DataArchiveError.invalid("服务已保存计时，但本机完整状态保存尚未核验")
        }
        let cached = state.sessions.first { $0.id == id }
        let finished = snapshot.finishedVersions.first { $0.sessionId == id }
        guard let savedRevision = cached?.revision ?? finished?.revision, savedRevision >= revision else {
            throw DataArchiveError.invalid("服务已保存计时，本机尚未读取到该版本，不称设备完成")
        }
        if savedRevision == revision {
            if let expectedMode = fields["mode"] {
                let mode = cached?.resolvedMode ?? finished?.mode ?? .light
                let minutes = cached?.focusMinutes ?? finished?.focusMinutes
                let experiment = cached?.isExperiment ?? finished?.experiment ?? false
                guard expectedMode == .string(mode.rawValue),
                      (fields["focusMinutes"] ?? .null) == (minutes.map { .number(Double($0)) } ?? .null),
                      (fields["experiment"] ?? .bool(false)) == .bool(experiment) else {
                    throw DataArchiveError.invalid("本机计时模式、时长或实验标记未匹配服务结果，未确认应用")
                }
            }
            guard (cached?.status.rawValue ?? finished?.status.rawValue) == expectedStatus,
                  (cached?.lastCommandId ?? finished?.commandId) == expectedCommand else {
                throw DataArchiveError.invalid("本机版本号相同但状态或操作身份不同，未确认应用")
            }
        }
        return .object(["serviceResult": result, "deviceEffect": .string("local_cache_persisted"),
                        "snapshotId": .string(snapshot.id), "sessionId": .string(id),
                        "requestedRevision": .number(Double(revision)), "savedRevision": .number(Double(savedRevision)),
                        "superseded": .bool(savedRevision > revision), "readAt": NativeRemoteJSON.timestamp(state.readAt),
                        "screenPresentation": .string("unknown"), "userSeen": .string("unknown")])
    }
    /// 永久拒绝（标需复核、不重放、不覆盖）：旧通道的 HTTP 4xx，或 iCloud 状态机的拒绝。其余都按暂时错误保留重试。
    nonisolated static func isPermanentRejection(_ e: NSError) -> Bool {
        [stateBridgeRejectionDomain, SharedTimerRejection.domain].contains(e.domain) && [400,401,403,404,409,422].contains(e.code)
    }
    private nonisolated static let stateBridgeRejectionDomain = "StateBridge.HTTP"
    var syncedMessage: String { backend == .icloud ? "已同步；各台设备共用 iCloud 计时" : "已同步；与 Dots 共用 BC 计时" }
    private func report(_ text: String) {
        if lastError != text, !TestHost.isActive { DevLog.shared.warn("BC计时", text) }
        lastError = text; message = text
    }
}
