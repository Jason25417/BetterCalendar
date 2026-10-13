import Foundation
#if os(iOS)
import AlarmKit
import SwiftUI
#endif

nonisolated struct NativeAlarmRequest: Codable, Equatable {
    var commandId: UUID
    var fireAt: Date
    var title: String
    var userAuthorizationRef: String
}
nonisolated struct NativeAlarmCapability {
    var supported: Bool
    var authorization: String
}
@MainActor protocol NativeAlarmScheduling {
    func inspect() -> NativeAlarmCapability
    func requestAuthorization() async throws -> NativeAlarmCapability
    func schedule(_ request: NativeAlarmRequest, userConfirmed: Bool) async throws -> BridgeJSON
    func cancel(commandId: UUID, alarmId: UUID, userConfirmed: Bool) throws -> BridgeJSON
    func recordedAlarms() throws -> [NativeAlarmRequest]
}
@MainActor final class UnsupportedNativeAlarms: NativeAlarmScheduling {
    func inspect() -> NativeAlarmCapability { .init(supported: false, authorization: "unsupported") }
    func requestAuthorization() async throws -> NativeAlarmCapability { inspect() }
    func schedule(_ request: NativeAlarmRequest, userConfirmed: Bool) async throws -> BridgeJSON { throw DataArchiveError.invalid("此平台不支持原生闹钟，未替换成普通通知") }
    func cancel(commandId: UUID, alarmId: UUID, userConfirmed: Bool) throws -> BridgeJSON { throw DataArchiveError.invalid("此平台不支持原生闹钟") }
    func recordedAlarms() throws -> [NativeAlarmRequest] { [] }
}

#if os(iOS)
nonisolated struct BCAlarmMetadata: AlarmMetadata {}
@MainActor final class AlarmKitNativeAlarms: NativeAlarmScheduling {
    private let journal: any NativeActionJournaling
    private var scheduling = false
    init(journal: any NativeActionJournaling) { self.journal = journal }
    func inspect() -> NativeAlarmCapability {
        let state: String
        switch AlarmManager.shared.authorizationState {
        case .authorized: state = "authorized"
        case .denied: state = "denied"
        case .notDetermined: state = "not_determined"
        @unknown default: state = "unknown"
        }
        return .init(supported: true, authorization: state)
    }
    func requestAuthorization() async throws -> NativeAlarmCapability {
        _ = try await AlarmManager.shared.requestAuthorization()
        return inspect()
    }
    private func requestData(_ request: NativeAlarmRequest) throws -> BridgeJSON {
        .object(["id": .string(request.commandId.uuidString),
                 "fireAt": .number(request.fireAt.timeIntervalSince1970 * 1000),
                 "title": .string(request.title), "userAuthorizationRef": .string(request.userAuthorizationRef)])
    }
    func schedule(_ request: NativeAlarmRequest, userConfirmed: Bool) async throws -> BridgeJSON {
        guard !scheduling else { throw DataArchiveError.invalid("已有闹钟操作正在核验，稍后重试") }
        guard userConfirmed, !request.userAuthorizationRef.isEmpty, request.userAuthorizationRef.count <= 300,
              !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.title.count <= 150,
              request.fireAt.timeIntervalSince1970.isFinite else { throw DataArchiveError.invalid("闹钟需要用户明确指定标题和时间") }
        guard inspect().authorization == "authorized" else { throw DataArchiveError.invalid("尚未获得系统闹钟授权，请主动授权后再设置") }
        let payload = try requestData(request), hash = BridgePoolCodec.hash(try BridgePoolCodec.encode(payload))
        var entries = try journal.load()
        let existing = entries.first { $0.commandId == request.commandId }
        if let existing {
            guard existing.kind == "alarm", existing.requestHash == hash else { throw DataArchiveError.invalid("同一闹钟请求内容改变，未重复排程") }
            if existing.phase == "applied", let receipt = existing.receipt {
                // Historical schedule receipt is not proof it is still pending.
                return .object(["originalReceipt": receipt, "currentlyPending": .bool(try AlarmManager.shared.alarms.contains { $0.id == request.commandId }),
                                "guaranteedWake": .bool(false)])
            }
            let matching = try AlarmManager.shared.alarms.first { $0.id == request.commandId }
            if let matching {
                guard matching.schedule == .fixed(request.fireAt) else { throw DataArchiveError.invalid("系统闹钟身份相同但时间不同，结果未知") }
                return try finalize(request.commandId, receipt: receipt(request.commandId, stage: "system_schedule_verified"))
            }
            // The process could have died after schedule succeeded; a missing
            // alarm may already have fired/dismissed. Never recreate blindly.
            throw DataArchiveError.invalid("上次闹钟排程结果未知；系统中未找到，不自动重排，请核对后新建")
        }
        guard request.fireAt > .now else { throw DataArchiveError.invalid("时间已过去，未补响闹钟") }
        entries.append(NativeActionEntry(commandId: request.commandId, kind: "alarm", requestHash: hash, before: nil, proposed: payload))
        try journal.save(entries)
        scheduling = true; defer { scheduling = false }
        let title = LocalizedStringResource(stringLiteral: request.title)
        let stop = AlarmButton(text: "关闭", textColor: .white, systemImageName: "stop.fill")
        let presentation = AlarmPresentation(alert: AlarmPresentation.Alert(title: title, stopButton: stop))
        let attributes = AlarmAttributes(presentation: presentation, metadata: BCAlarmMetadata(), tintColor: .blue)
        let configuration = AlarmManager.AlarmConfiguration<BCAlarmMetadata>.alarm(schedule: .fixed(request.fireAt), attributes: attributes)
        _ = try await AlarmManager.shared.schedule(id: request.commandId, configuration: configuration)
        guard let alarm = try AlarmManager.shared.alarms.first(where: { $0.id == request.commandId }),
              alarm.schedule == .fixed(request.fireAt) else { throw DataArchiveError.invalid("系统已响应，但未能核对排程，结果未知") }
        return try finalize(request.commandId, receipt: receipt(request.commandId, stage: "system_schedule_verified"))
    }
    func cancel(commandId: UUID, alarmId: UUID, userConfirmed: Bool) throws -> BridgeJSON {
        guard !scheduling, userConfirmed, inspect().authorization == "authorized" else { throw DataArchiveError.invalid("取消闹钟需要用户请求及系统授权") }
        var entries = try journal.load()
        guard entries.contains(where: { $0.commandId == alarmId && $0.kind == "alarm" }) else { throw DataArchiveError.invalid("不属于本机BC已记录的闹钟，未取消") }
        let hash = BridgePoolCodec.hash(try BridgePoolCodec.encode(.string(alarmId.uuidString)))
        if let entry = entries.first(where: { $0.commandId == commandId }) {
            guard entry.kind == "cancel_alarm", entry.requestHash == hash else { throw DataArchiveError.invalid("取消请求身份冲突") }
            if entry.phase == "applied", let receipt = entry.receipt { return receipt }
        } else {
            entries.append(NativeActionEntry(commandId: commandId, kind: "cancel_alarm", requestHash: hash, before: nil, proposed: .string(alarmId.uuidString)))
            try journal.save(entries)
        }
        if try AlarmManager.shared.alarms.contains(where: { $0.id == alarmId }) { try AlarmManager.shared.cancel(id: alarmId) }
        guard try !AlarmManager.shared.alarms.contains(where: { $0.id == alarmId }) else { throw DataArchiveError.invalid("取消尚未核验，结果未知") }
        return try finalize(commandId, receipt: receipt(alarmId, stage: "system_absence_verified"))
    }
    private func receipt(_ id: UUID, stage: String) -> BridgeJSON {
        .object(["alarmId": .string(id.uuidString), "channel": .string("native_alarm"), "stage": .string(stage),
                 "checkedAt": .number(Date.now.timeIntervalSince1970 * 1000), "guaranteedWake": .bool(false),
                 "userHeard": .string("unknown"), "source": .string("AlarmKit")])
    }
    private func finalize(_ id: UUID, receipt: BridgeJSON) throws -> BridgeJSON {
        // Reload after await to preserve intervening item/cancellation receipts.
        var entries = try journal.load()
        guard let i = entries.firstIndex(where: { $0.commandId == id }) else { throw DataArchiveError.invalid("排程原请求丢失，结果未知") }
        entries[i].phase = "applied"; entries[i].receipt = receipt
        try journal.save(entries); return receipt
    }
    func recordedAlarms() throws -> [NativeAlarmRequest] {
        let pending = Set(try AlarmManager.shared.alarms.map(\.id))
        return try journal.load().compactMap { entry in
            guard entry.kind == "alarm", pending.contains(entry.commandId),
                  case let .object(p) = entry.proposed, case let .number(ms) = p["fireAt"],
                  case let .string(title) = p["title"], case let .string(ref) = p["userAuthorizationRef"] else { return nil }
            return .init(commandId: entry.commandId, fireAt: Date(timeIntervalSince1970: ms / 1000), title: title, userAuthorizationRef: ref)
        }
    }
}
#endif
