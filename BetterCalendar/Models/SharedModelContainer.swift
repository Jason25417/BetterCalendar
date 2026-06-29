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
        do {
            return try ModelContainer(
                for: PlanDay.self, PlanBlock.self, CompletionLink.self,
                ExecutionSession.self, AppSettings.self, JournalEntry.self)
        } catch {
            fatalError("无法创建 ModelContainer：\(error)")
        }
    }()
}
