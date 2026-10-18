//
//  KnownDevices.swift
//  BetterCalendar
//
//  SPEC §19 W8（D3 提醒与闹钟）：智能体要把「8 点叫我」设到 iPhone 上，得先知道 iPhone 的设备 id。
//  每台设备启动 / 回到前台时把自己的身份（id、名字、平台）登记进 iCloud KV（NSUbiquitousKeyValueStore，
//  与设置同步同一个存储）；Mac 写 context.json 时附上 actionTargets.devices，智能体据此填 targetDevice。
//  只是一份「最近见过的设备」名册（只读参考，不是权限）：两端并发登记可能丢一条，下次启动会再补上，最终一致。
//

import Foundation

nonisolated struct KnownDevice: Codable, Equatable, Sendable {
    var id: String
    var label: String
    /// "iOS" / "macOS"
    var platform: String
    var seenAt: Date

    var isPhone: Bool { platform == "iOS" }
}

nonisolated enum KnownDevicesCodec {
    /// 最多记几台、多久没见过就不再列（换机后旧设备自然淡出）。
    static let maxDevices = 12
    static let staleAfter: TimeInterval = 60 * 86_400

    static func decode(_ data: Data?) -> [KnownDevice] {
        guard let data, let list = try? JSONDecoder().decode([KnownDevice].self, from: data) else { return [] }
        return list
    }

    /// 把一台设备并进名册（同 id 覆盖），去掉过久没见的，按最近见过排序。
    static func merge(_ existing: [KnownDevice], adding device: KnownDevice, now: Date) -> [KnownDevice] {
        var list = existing.filter { $0.id != device.id && now.timeIntervalSince($0.seenAt) < staleAfter }
        list.append(device)
        return Array(list.sorted { $0.seenAt > $1.seenAt }.prefix(maxDevices))
    }
}

@MainActor enum KnownDevices {
    static let kvKey = "devices.known.v1"

    static var thisDevice: KnownDevice {
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        return KnownDevice(id: ProposalDevice.id, label: ProposalDevice.label, platform: platform, seenAt: .now)
    }

    /// 登记本机（启动 / 回到前台时调用）。测试环境不碰 iCloud。
    static func announce(now: Date = .now) {
        guard !TestHost.isActive else { return }
        let kv = NSUbiquitousKeyValueStore.default
        var me = thisDevice; me.seenAt = now
        let merged = KnownDevicesCodec.merge(KnownDevicesCodec.decode(kv.data(forKey: kvKey)), adding: me, now: now)
        guard let data = try? JSONEncoder().encode(merged) else { return }
        kv.set(data, forKey: kvKey)
    }

    /// 名册（含本机）。测试环境只有本机。
    static func all(now: Date = .now) -> [KnownDevice] {
        let stored = TestHost.isActive ? [] : KnownDevicesCodec.decode(NSUbiquitousKeyValueStore.default.data(forKey: kvKey))
        return KnownDevicesCodec.merge(stored, adding: thisDevice, now: now)
    }
}
