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
        let schema = Schema([PlanDay.self, PlanBlock.self, CompletionLink.self,
                             ExecutionSession.self, AppSettings.self, JournalEntry.self,
                             DayRecord.self])
        // M7：优先 iCloud 同步（需 iCloud + CloudKit capability + container）。
        // 配好 entitlement → 自动用 CloudKit 跨端同步；没配好 → 回退本地库，绝不崩。
        if let cloud = try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)) {
            return cloud
        }
        print("[数据] CloudKit 不可用（未配 iCloud capability？）→ 回退本地库")
        do {
            return try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        } catch {
            fatalError("无法创建 ModelContainer：\(error)")
        }
    }()
}
