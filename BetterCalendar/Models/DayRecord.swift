//
//  DayRecord.swift
//  BetterCalendar
//
//  一天的复盘小数据（活跃标记 + 今日 MVP），SwiftData + CloudKit 跨端同步。
//  取代早期 UserDefaults 版 ReviewLocalStore 存储（那份是设备本地的，Mac/iPhone 各记各的，
//  活跃天数对不上）。dayKey = 逻辑日 yyyy-MM-dd（凌晨 4 点日界线，见 DayContext.dayKey）。
//  CloudKit 约束：非 optional 属性带声明默认值、无 @Attribute(.unique)——同一 dayKey
//  可能因两端同时写出现多条，读取端按 dayKey 去重、modifiedAt 新者优先。
//

import Foundation
import SwiftData

@Model
final class DayRecord {
    var dayKey: String = ""            // 逻辑日 yyyy-MM-dd
    var isActive: Bool = false         // 当天做成 ≥1 件（活跃天数用）
    var mvpTitle: String?              // 今日「最有价值的一件」
    var mvpNote: String = ""
    var modifiedAt: Date = Date.now    // 跨端冲突时新者优先

    init(dayKey: String, isActive: Bool = false,
         mvpTitle: String? = nil, mvpNote: String = "", modifiedAt: Date = .now) {
        self.dayKey = dayKey
        self.isActive = isActive
        self.mvpTitle = mvpTitle
        self.mvpNote = mvpNote
        self.modifiedAt = modifiedAt
    }
}
