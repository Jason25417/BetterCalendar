//
//  Hotfix0722Tests.swift
//  BetterCalendarTests
//
//  0.72.2 热修（2026-10-20 晚 191 实测）：
//  ① 0.72.1 拆小了日志，Mac 导出仍被拒（同一条 CloudKit 记录 933564C0，text 已 199,950 字节）——记录本身坏了，
//     本设备日志记录换新身份重建一次（内容不变）。
//  ② 智能体写进共享记忆的跟进被 iCloud 送来的旧副本盖掉：带更新时间的键，远程更旧就不覆盖本机。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

@MainActor
@Suite(.serialized) struct DeviceLogRebuildTests {
    @Test func ownRecordsAreRebuiltOnceWithNewIdentityAndSameContent() throws {
        let container = try ModelContainer(for: DeviceLog.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let ctx = container.mainContext
        let defaults = try #require(UserDefaults(suiteName: "bc-0722-\(UUID().uuidString)"))
        let me = LogSyncService.deviceID
        let poisoned = DeviceLog(deviceID: me, deviceName: "Mac", dayKey: "2026-10-19", text: "十九号\n")
        let part = DeviceLog(deviceID: me, deviceName: "Mac", dayKey: "2026-10-19-part2", text: "续段\n")
        let phone = DeviceLog(deviceID: "iphone", deviceName: "iPhone", dayKey: "2026-10-19", text: "手机\n")
        [poisoned, part, phone].forEach(ctx.insert)
        try ctx.save()
        let oldIDs = Set([poisoned, part].map(\.persistentModelID))
        let phoneID = phone.persistentModelID

        let sync = LogSyncService(context: ctx, defaults: defaults)
        sync.dumpEnabled = false
        sync.flush(now: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23))!)

        let rows = try ctx.fetch(FetchDescriptor<DeviceLog>())
        let mine = rows.filter { $0.deviceID == me }
        #expect(Set(mine.map(\.dayKey)) == ["2026-10-19", "2026-10-19-part2"])
        #expect(mine.first { $0.dayKey == "2026-10-19" }?.text == "十九号\n")
        #expect(oldIDs.isDisjoint(with: Set(mine.map(\.persistentModelID))),
                "换新对象 = 新 CloudKit 记录名，不再背旧记录的坏缓存")
        #expect(rows.contains { $0.persistentModelID == phoneID }, "另一台设备的记录不碰")
        #expect(defaults.bool(forKey: LogSyncService.rebuiltKey))

        let afterFirst = Set(mine.map(\.persistentModelID))
        sync.flush(now: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 1))!)
        let again = Set(try ctx.fetch(FetchDescriptor<DeviceLog>()).filter { $0.deviceID == me }.map(\.persistentModelID))
        #expect(again == afterFirst, "只重建一次")
    }
}

@Suite struct SharedMemorySyncVersionTests {
    private func memory(_ text: String, _ at: String) -> String {
        "{\"text\":\"\(text)\",\"updatedAt\":\"\(at)\",\"updatedBy\":\"x\"}"
    }

    @Test func olderRemoteSharedMemoryDoesNotOverwriteNewerLocal() {
        let key = AgentSharedMemoryStore.key
        let local = memory("含买菜补充的新版", "2026-10-21T01:44:59Z")
        let stale = memory("旧版", "2026-10-21T00:44:18Z")
        #expect(SettingsSync.remoteIsOlder(key: key, local: local, remote: stale), "旧副本不能盖掉本机新写的")
        #expect(!SettingsSync.remoteIsOlder(key: key, local: stale, remote: local), "另一台设备更新的照常落地")
        #expect(!SettingsSync.remoteIsOlder(key: key, local: nil, remote: stale))
        #expect(!SettingsSync.remoteIsOlder(key: key, local: "坏数据", remote: stale), "读不出版本就照旧以远程为准")
        #expect(!SettingsSync.remoteIsOlder(key: "push.muted", local: true, remote: false), "没登记版本的键不变")
    }
}
