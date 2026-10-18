//
//  ICloudSharedTimerService.swift
//  BetterCalendar
//
//  W5：BridgeTaskServing 的 iCloud 实现。上层 BridgeTaskViewModel / ExecutionViewModel / 菜单栏 / Live Activity
//  完全不变，只是命令不再发给 StateBridge，而是在本机跑状态机后条件保存到 iCloud。
//  并发：读最新 → 状态机判断 → 条件保存 → 冲突则拿服务器最新版本重判（同 ConflictCheckedProposalTransport）。
//

import Foundation

/// iCloud 计时 zone 推送 → 刷新本机显示（组装点在 iCloud 后端时挂上；双端 AppDelegate 转发）。
@MainActor enum SharedTimerWake {
    static var onPush: (() async -> Void)?
}

@MainActor final class ICloudSharedTimerService: BridgeTaskServing {
    private let store: any SharedTimerRecordStore
    private let deviceId: String
    private let now: () -> Date
    private let maxAttempts: Int
    /// 上一次 readAt：保证单调不减（ViewModel 拒绝「比上次旧」的读取）。
    private var lastReadAt: Date

    init(store: any SharedTimerRecordStore, deviceId: String, readFloor: Date? = nil,
         maxAttempts: Int = 4, now: @escaping () -> Date = { Date() }) {
        self.store = store; self.deviceId = deviceId; self.now = now; self.maxAttempts = maxAttempts
        self.lastReadAt = readFloor ?? .distantPast
    }

    func readTasks() async throws -> BridgeTaskState {
        let all = try await store.allSessions()
        let readAt = max(now(), lastReadAt)
        lastReadAt = readAt
        let active = all.filter { $0.status != .finished }
            .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        return BridgeTaskState(schemaVersion: 1, authority: "bettercalendar", readAt: readAt,
                               sessions: active.prefix(100).map { $0.view(readAt: readAt) },
                               hasMore: active.count > 100)
    }

    func submitTask(_ command: BridgeTaskCommand) async throws -> BridgeTaskReceipt {
        let targetId: String
        if command.action == .start { targetId = SharedTimerReducer.sessionId(forStart: command.commandId) }
        else {
            guard let id = command.sessionId, !id.isEmpty else { throw SharedTimerRejection(code: 400, message: "缺少 sessionId").nsError }
            targetId = id
        }
        do {
            for _ in 0..<maxAttempts {
                let existing = try await store.latest(targetId)
                switch try SharedTimerReducer.apply(command, to: existing, deviceId: deviceId, now: now()) {
                case .replay:
                    return BridgeTaskReceipt(commandId: command.commandId, saved: true)
                case let .write(next):
                    switch try await store.save(next, isNew: existing == nil) {
                    case .saved: return BridgeTaskReceipt(commandId: command.commandId, saved: true)
                    case .conflict: continue   // 服务器版本变了：回到顶部用最新版本重判（可能变成幂等回执或 409）
                    }
                }
            }
            throw SharedTimerRejection(code: 409, message: "计时连续冲突，请重新读取后再操作")
        } catch let rejection as SharedTimerRejection {
            throw rejection.nsError   // 永久错误：ViewModel 标需复核，不重放、不覆盖
        }
    }
}
