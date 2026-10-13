import Foundation
import Observation

/// Buttons and Dots share the server's durable sessions. This model only holds
/// a view cache and replayable user commands, never a second execution history.
@MainActor @Observable final class BridgeTaskViewModel {
    private let service: any BridgeTaskServing
    private let persistence: any BridgeTaskPersisting
    private let enabled: () -> Bool
    private let now: () -> Date
    private var file = BridgeTaskLocalFile()
    private var healthy = true
    private(set) var busy = false
    private(set) var message = "等待同步计时状态"
    private(set) var lastError: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var nextPoll = Date.distantPast
    @ObservationIgnored var onChange: (() -> Void)?

    init(service: any BridgeTaskServing, persistence: any BridgeTaskPersisting,
         enabled: @escaping () -> Bool, now: @escaping () -> Date = { Date() }) {
        self.service = service; self.persistence = persistence; self.enabled = enabled; self.now = now
        do { file = try persistence.load(); try file.validate() }
        catch { healthy = false; report("计时队列读取失败，原文件已保留；修复后再操作") }
    }
    var isEnabled: Bool { enabled() }
    var sessions: [BridgeTaskSession] { file.state?.sessions ?? [] }
    var primary: BridgeTaskSession? { sessions.first(where: { $0.status == .running }) ?? sessions.first }
    var pendingCount: Int { file.pending.filter { !$0.needsReview }.count }
    var reviewCount: Int { file.pending.filter(\.needsReview).count }
    var canSubmit: Bool { isEnabled && healthy && file.state != nil && !busy && pendingCount == 0 && file.pending.count < 100 }
    var isStale: Bool { file.receivedAt.map { let age = now().timeIntervalSince($0); return age > 60 || age < -5 } ?? true }
    var hasMore: Bool { file.state?.hasMore ?? false }
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
        guard timer == nil, !TestHost.isActive else { return }
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

    func start(title: String, relatedRecordId: String? = nil) async {
        guard queueStart(title: title, relatedRecordId: relatedRecordId) else { return }
        await refresh()
    }
    @discardableResult func queueStart(title: String, relatedRecordId: String? = nil) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return enqueue(BridgeTaskCommand(commandId: UUID().uuidString, action: .start, title: title,
                                         occurredAt: estimatedServerDate(), relatedRecordId: relatedRecordId))
    }
    func act(_ action: BridgeTaskCommand.Action, on session: BridgeTaskSession) async {
        guard action != .start else { return }
        guard enqueue(BridgeTaskCommand(commandId: UUID().uuidString, action: action, sessionId: session.id,
                                         expectedRevision: session.revision, occurredAt: estimatedServerDate())) else { return }
        await refresh()
    }
    @discardableResult private func enqueue(_ command: BridgeTaskCommand) -> Bool {
        guard canSubmit else { return false }
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
            nextPoll = now().addingTimeInterval(sessions.isEmpty && pendingCount == 0 ? 15 : 5)
            onChange?()
        }
        var hadConflict = false
        do {
            while healthy && allowCommands, let queued = file.pending.first(where: { !$0.needsReview }) {
                do {
                    let receipt = try await service.submitTask(queued.command)
                    guard receipt.saved, receipt.commandId == queued.command.commandId else { throw URLError(.cannotParseResponse) }
                    var next = file; next.pending.removeAll { $0.command.commandId == receipt.commandId }
                    try persistence.save(next); file = next
                    message = "操作已保存；正在更新显示"
                } catch {
                    let e = error as NSError
                    guard e.domain == "StateBridge.HTTP", [400,401,403,404,409,422].contains(e.code) else { throw error }
                    var next = file
                    if let i = next.pending.firstIndex(where: { $0.command.commandId == queued.command.commandId }) { next.pending[i].needsReview = true }
                    try persistence.save(next); file = next; hadConflict = true
                    report(e.code == 409 ? "另一端已改变状态，未覆盖它的操作；请根据当前状态重新选择" : "操作未被接受；已保留请求，请检查连接或记录状态")
                }
            }
            let sentAt = now(), state = try await service.readTasks(), receivedAt = now()
            try state.validate()
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
                message = !healthy ? "已读取云端状态；本地操作队列需修复" : pendingCount > 0 ? "状态已更新；还有 \(pendingCount) 条操作待同步" : "已同步；与 Dots 共用 BC 计时"
            }
            if healthy {
                // The state and pending receipt are saved atomically before
                // reporting. A lost reply/restart retries the same snapshot ID.
                while let ids = file.pendingApplicationSnapshots, !ids.isEmpty {
                    let sent = Array(ids.prefix(10))
                    do {
                        let accepted = try await service.reportSavedTaskSnapshots(sent)
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
            report("计时同步暂未完成；保留最后状态与 \(pendingCount) 条待同步操作，连接恢复后重试")
        }
    }
    private func report(_ text: String) {
        if lastError != text, !TestHost.isActive { DevLog.shared.warn("BC计时", text) }
        lastError = text; message = text
    }
}
