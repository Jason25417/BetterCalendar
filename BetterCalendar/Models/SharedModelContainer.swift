//
//  SharedModelContainer.swift
//  BetterCalendar
//
//  共享 SwiftData 容器：App 与（日后的）App Intents 用同一个磁盘库。
//

import Foundation
import SwiftData

enum SharedModelContainer {
    static let shared: ModelContainer = {
        // PlanDay/CompletionLink 已删（2026-07-22 死代码审计：零实例化的 M0 骨架 model，云端 record type 留着无害）
        // E4（2026-08-14）：+DayPlanSnapshot/ResidualSample（学习层采集端）⚠️ 发 TestFlight 前 CloudKit Deploy
        let schema = Schema([PlanBlock.self, DayPlanSnapshot.self, ResidualSample.self,
                             ExecutionSession.self, JournalEntry.self,   // AppSettings 已删（2026-07-22：M0 骨架遗产，从未实例化——设置全走 UserDefaults；云端 record type 留着无害）
                             DayRecord.self, JournalPhoto.self, LongTask.self,
                             LongTaskCheckpoint.self, DeviceLog.self])
        if TestHost.isActive {
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        }
        // M7：优先 iCloud 同步（需 iCloud + CloudKit capability + container）。
        // 配好 entitlement → 自动用 CloudKit 跨端同步；没配好 → 回退本地库，绝不崩。
        do {
            let cloud = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .private(AppChannel.current.cloudKitContainerID)))
            DataSyncMonitor.shared.storageOpened(cloud: true)
            return cloud
        } catch {
            DataSyncMonitor.shared.storageOpened(cloud: false, error: error)
        }
        do {
            return try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        } catch {
            fatalError("无法创建 ModelContainer：\(error)")
        }
    }()
}
