//
//  AlarmMirror.swift
//  BetterCalendar
//
//  W30（原则 11 · 闹钟）：闹钟默认归随身设备（iPhone）——它必须提前排在一台设备上、到点无法改派，而它的意义是「一定叫醒你」；
//  其他设备到点只弹一份**安静的镜像**（passive、无声，只进通知中心），让你回头在 Mac / iPad 上也看得到「8:00 的闹钟在 iPhone 上响了」。
//  做法：每台设备在对齐审批通知后看一眼已执行的闹钟提案——设在别的设备上、还没到点、没撤销 → 本机排一条镜像；撤销了 → 收起。
//  只在「一处响」开关打开时做；关着时不新建镜像（已排的照旧收起，不留尾巴）。
//

import Foundation
import UserNotifications

@MainActor
final class AlarmMirrorSync {
    static let idPrefix = "bc.alarm.mirror."

    private let deviceID: String
    private let center: any ReachNotificationCentering
    private let reach: ReachOutlet
    private let devices: @MainActor () -> [KnownDevice]
    private let isEnabled: @MainActor () -> Bool
    private let now: () -> Date

    init(deviceID: String, center: any ReachNotificationCentering, reach: ReachOutlet,
         devices: @escaping @MainActor () -> [KnownDevice],
         isEnabled: @escaping @MainActor () -> Bool = { ReachSettings.onePlaceEnabled },
         now: @escaping () -> Date = { .now }) {
        self.deviceID = deviceID; self.center = center; self.reach = reach
        self.devices = devices; self.isEnabled = isEnabled; self.now = now
    }

    nonisolated struct Mirror: Equatable, Sendable {
        var id: UUID; var title: String; var fireAt: Date; var deviceId: String
    }

    /// 应当在本机挂镜像的闹钟（纯函数）：已执行、没撤销、设在别的设备上、还没到点。
    nonisolated static func wanted(_ proposals: [Proposal], me: String, now: Date) -> [Mirror] {
        proposals.compactMap { p in
            guard p.state == .applied, p.undoneAt == nil,
                  case let .alarm(id, title, fireAt, deviceId) = p.chosen.action,
                  deviceId != me, fireAt > now else { return nil }
            return Mirror(id: id, title: title, fireAt: fireAt, deviceId: deviceId)
        }
    }

    func sync(_ proposals: [Proposal]) async {
        let want = isEnabled() ? Self.wanted(proposals, me: deviceID, now: now()) : []
        let wantIDs = Set(want.map { Self.idPrefix + $0.id.uuidString })
        let pending = Set(await center.pendingRequests().map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) })
        let stale = pending.subtracting(wantIDs)
        if !stale.isEmpty {
            center.removePending(Array(stale))
            DevLog.shared.info("触达", "闹钟镜像收起 \(stale.count) 条（闹钟已撤销 / 开关关了）")
        }
        for m in want where !pending.contains(Self.idPrefix + m.id.uuidString) {
            let label = devices().first(where: { $0.id == m.deviceId })?.label ?? "iPhone"
            let content = UNMutableNotificationContent()
            content.title = "闹钟：\(m.title)"
            content.body = "闹钟在「\(label)」上响；这里只安静放一份"
            content.threadIdentifier = "bc.alarm.mirror"
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: m.fireAt)
            let request = UNNotificationRequest(identifier: Self.idPrefix + m.id.uuidString, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            do {
                try await center.add(reach.route(request, kind: .alarmMirror, reachID: "alarm:\(m.id.uuidString)", fireAt: m.fireAt))
            } catch {
                DevLog.shared.warn("触达", "闹钟镜像没排上（闹钟本身在「\(label)」上不受影响）：\(error.localizedDescription)")
            }
        }
    }
}
