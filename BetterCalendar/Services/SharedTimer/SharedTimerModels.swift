//
//  SharedTimerModels.swift
//  BetterCalendar
//
//  W5（SPEC §19.5 D1/D2）：共享计时的 iCloud 真相数据结构 + 设备端状态机。
//  iCloud 没有服务端代码可跑，所以把 StateBridge 服务端 taskCommand 的规则原样搬成纯函数，
//  再由 CloudKit「服务器版本未变才保存」保证多端只有一个写入成功。设计见 docs/bc-shared-timer-icloud.md。
//

import CryptoKit
import Foundation

/// 共享计时的真相放在哪里。启动时决定一次，运行中不切换。
nonisolated enum SharedTimerBackend: String, Codable, Sendable {
    case stateBridge   // 旧通道：StateBridge 云端（已冻结，开关关闭时的默认）
    case icloud        // 新通道：iCloud 私有库 zone BCSharedTimer

    var label: String { self == .icloud ? "iCloud" : "旧通道（StateBridge）" }
}

/// 一次状态变化的留底（存在会话记录内，按发生顺序）。
nonisolated struct SharedTimerEvent: Codable, Equatable, Sendable {
    var commandId: String
    var action: BridgeTaskCommand.Action
    var occurredAt: Date
    var recordedAt: Date
    var deviceId: String
    var revisionAfter: Int
    /// 命令内容指纹：同一 commandId 内容不同 → 拒绝复用。
    var fingerprint: String
}

/// iCloud 记录 BCTimerSession 的 payload（唯一真相）。elapsedMs 不含当前运行段。
nonisolated struct SharedTimerSession: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var id: String
    var title: String
    var status: BridgeTaskSession.Status
    var startedAt: Date
    var activeSince: Date?
    var elapsedMs: Double
    var updatedAt: Date
    var revision: Int
    var provenance = "user"
    var relatedRecordId: String?
    var origin: String
    var lastCommandId: String
    var mode: BridgeTaskSession.Mode
    var focusMinutes: Int?
    var experiment: Bool
    var events: [SharedTimerEvent]

    /// 投影成上层已在用的会话视图；运行中的时长折算到 readAt（与服务端 sessionView 同义）。
    func view(readAt: Date) -> BridgeTaskSession {
        let running = status == .running ? activeSince.map { max(0, readAt.timeIntervalSince($0)) * 1000 } ?? 0 : 0
        return BridgeTaskSession(id: id, title: title, status: status, startedAt: startedAt, activeSince: activeSince,
                                 elapsedMs: elapsedMs + running, updatedAt: updatedAt, revision: revision,
                                 provenance: provenance, relatedRecordId: relatedRecordId, origin: origin,
                                 lastCommandId: lastCommandId, mode: mode, focusMinutes: focusMinutes, experiment: experiment)
    }

    func validate() throws {
        guard schemaVersion == 1, !id.isEmpty, id.count <= 80, !title.isEmpty, title.count <= 300,
              revision > 0, revision == events.count, elapsedMs.isFinite, elapsedMs >= 0,
              provenance == "user", events.count <= SharedTimerReducer.maxEvents,
              Set(events.map(\.commandId)).count == events.count,
              events.last?.commandId == lastCommandId, events.first?.action == .start,
              (status == .running) == (activeSince != nil),
              mode == .light ? focusMinutes == nil : focusMinutes.map({ (1...240).contains($0) }) == true else {
            throw SharedTimerRejection(code: 422, message: "iCloud 计时记录不完整（\(id.prefix(12))）")
        }
    }
}

/// 状态机拒绝（永久错误）：本机命令标「需要复核」，绝不自动重放或覆盖。code 沿用 HTTP 语义便于对照旧通道。
nonisolated struct SharedTimerRejection: Error, Equatable, LocalizedError, Sendable {
    static let domain = "SharedTimer.Rejected"
    let code: Int
    let message: String
    var errorDescription: String? { message }
    var nsError: NSError { NSError(domain: Self.domain, code: code, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// 设备端状态机：与 StateBridge 服务端 taskCommand 逐条对齐（差异只有「早于上一状态 5 分钟内夹紧」，见设计稿 3.4）。
nonisolated enum SharedTimerReducer {
    enum Outcome: Equatable, Sendable {
        /// 这条命令已执行过（重试/回包丢失）：直接回原回执，不再写。
        case replay
        /// 需要写入的新版本。
        case write(SharedTimerSession)
    }

    static let maxEvents = 500
    static let futureTolerance: TimeInterval = 120
    static let backwardClamp: TimeInterval = 300

    /// 开始命令 → 会话 ID（确定性：同一条开始命令在任何设备重试都落到同一条记录）。
    static func sessionId(forStart commandId: String) -> String {
        "timer_" + SHA256.hash(data: Data(commandId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
    }

    static func fingerprint(_ c: BridgeTaskCommand) -> String {
        let parts: [String] = [c.action.rawValue, c.sessionId ?? "", c.expectedRevision.map(String.init) ?? "",
                               c.title ?? "", String(Int64((c.occurredAt.timeIntervalSince1970 * 1000).rounded())),
                               c.provenance, c.relatedRecordId ?? "", c.mode?.rawValue ?? "",
                               c.focusMinutes.map(String.init) ?? "", c.experiment.map { $0 ? "1" : "0" } ?? ""]
        return SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// existing：开始命令时为「同 ID 记录」（通常为 nil），其它命令为目标会话的最新版本。
    static func apply(_ command: BridgeTaskCommand, to existing: SharedTimerSession?,
                      deviceId: String, now: Date) throws -> Outcome {
        guard !command.commandId.isEmpty, command.commandId.count <= 150 else { throw reject(400, "commandId 无效") }
        let print = fingerprint(command)
        if let existing, let event = existing.events.first(where: { $0.commandId == command.commandId }) {
            guard event.fingerprint == print else { throw reject(409, "commandId 不能复用于不同命令") }
            return .replay
        }
        guard command.provenance == "user" else { throw reject(400, "计时仅接受用户明确表达") }
        guard command.validMode else { throw reject(400, "模式、番茄时长和实验标记仅在开始时指定，番茄需 1–240 分钟") }
        guard command.occurredAt.timeIntervalSince(now) <= futureTolerance else { throw reject(400, "计时动作不能在未来") }

        if command.action == .start {
            let title = (command.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 300 else { throw reject(400, "任务名需要 1–300 字") }
            if let related = command.relatedRecordId { guard !related.isEmpty, related.count <= 150 else { throw reject(400, "关联记录 ID 无效") } }
            let id = sessionId(forStart: command.commandId)
            guard existing == nil else { throw reject(409, "计时记录已存在，但不是这条开始命令") }
            let at = command.occurredAt, mode = command.mode ?? .light
            return .write(SharedTimerSession(id: id, title: title, status: .running, startedAt: at, activeSince: at,
                                             elapsedMs: 0, updatedAt: at, revision: 1, relatedRecordId: command.relatedRecordId,
                                             origin: "bc-icloud", lastCommandId: command.commandId, mode: mode,
                                             focusMinutes: mode == .pomodoro ? command.focusMinutes : nil,
                                             experiment: command.experiment ?? false,
                                             events: [.init(commandId: command.commandId, action: .start, occurredAt: at,
                                                            recordedAt: now, deviceId: deviceId, revisionAfter: 1, fingerprint: print)]))
        }

        guard let old = existing else { throw reject(404, "找不到计时记录") }
        guard command.sessionId == old.id else { throw reject(400, "sessionId 与记录不符") }
        guard command.expectedRevision == old.revision else { throw reject(409, "状态已变，请先重新读取") }
        var at = command.occurredAt
        if at < old.updatedAt {
            // iCloud 没有服务端时钟：两端时钟差一两秒很常见。短时倒退按上一状态时间记，不让时长倒流。
            guard old.updatedAt.timeIntervalSince(at) <= backwardClamp else { throw reject(400, "动作早于上一状态；请明确修正历史") }
            at = old.updatedAt
        }
        switch (command.action, old.status) {
        case (_, .finished), (.pause, .paused), (.resume, .running): throw reject(409, "当前状态不能执行此动作")
        default: break
        }
        guard old.events.count < maxEvents else { throw reject(422, "这次计时的操作次数已达上限；结束后重新开始即可") }
        var next = old
        next.elapsedMs = old.elapsedMs + (old.activeSince.map { max(0, at.timeIntervalSince($0)) * 1000 } ?? 0)
        next.status = command.action == .resume ? .running : command.action == .pause ? .paused : .finished
        next.activeSince = command.action == .resume ? at : nil
        next.updatedAt = at
        next.revision = old.revision + 1
        next.lastCommandId = command.commandId
        next.events.append(.init(commandId: command.commandId, action: command.action, occurredAt: at, recordedAt: now,
                                 deviceId: deviceId, revisionAfter: next.revision, fingerprint: print))
        return .write(next)
    }

    private static func reject(_ code: Int, _ message: String) -> SharedTimerRejection { .init(code: code, message: message) }
}
