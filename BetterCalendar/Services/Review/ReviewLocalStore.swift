//
//  ReviewLocalStore.swift
//  BetterCalendar
//
//  复盘的小数据（① 活跃天累计：当天做成 ≥1 件即活跃 ② 今日「最有价值的一件」轻自评）。
//  底层 SwiftData `DayRecord`（随 CloudKit 跨端同步）；首次启动把旧 UserDefaults 数据一次性迁入。
//  同一 dayKey 两端并发写可能出现多条记录（CloudKit 禁 unique）→ 读按 dayKey 去重、modifiedAt 新者优先。
//

import Foundation
import SwiftData

@MainActor
final class ReviewLocalStore {
    private let context: ModelContext

    init(context: ModelContext? = nil) {
        if let context {
            // 注入库（测试）：不迁移——迁移旗标在真 UserDefaults，测试不能碰（会让真迁移被跳过）
            self.context = context
        } else {
            self.context = SharedModelContainer.shared.mainContext
            purgeLegacyUserDefaultsKeysOnce()
        }
    }

    // MARK: - 读

    private func allRecords() -> [DayRecord] {
        (try? context.fetch(FetchDescriptor<DayRecord>())) ?? []
    }

    /// 某逻辑日的记录（多条时 modifiedAt 新者优先）。
    private func record(forDayKey key: String) -> DayRecord? {
        allRecords().filter { $0.dayKey == key }.max { $0.modifiedAt < $1.modifiedAt }
    }

    private func recordForToday() -> DayRecord {
        let key = DayContext.dayKey(.now)
        if let r = record(forDayKey: key) { return r }
        let r = DayRecord(dayKey: key)
        context.insert(r)
        return r
    }

    // MARK: 活跃天累计（不是连续；就是「已经活跃使用了多少天」）

    var activeDayCount: Int {
        Set(allRecords().filter(\.isActive).map(\.dayKey)).count
    }

    /// 首个活跃日（成就 D1「相识 N 年」）：dayKey 为 yyyy-MM-dd，字典序最小即最早。nil = 还没活跃过。
    var firstActiveDayKey: String? {
        allRecords().filter(\.isActive).map(\.dayKey).min()
    }

    /// 活跃过的月份集合 1–12（成就 D2「四季都来过」）。
    var activeMonths: Set<Int> {
        Set(allRecords().filter(\.isActive).compactMap { r -> Int? in
            let parts = r.dayKey.split(separator: "-")
            return parts.count >= 2 ? Int(parts[1]) : nil
        })
    }

    /// 当天做成 ≥1 件时调用：把该逻辑日计入活跃日（幂等）。date 可注入便于测试。
    func markActive(on date: Date = .now) {
        let key = DayContext.dayKey(date)
        if let r = record(forDayKey: key) {
            guard !r.isActive else { return }
            r.isActive = true
            r.modifiedAt = .now
        } else {
            context.insert(DayRecord(dayKey: key, isActive: true))
        }
        try? context.save()
    }

    // MARK: 今日「最有价值的一件」

    var todayMVP: String? {
        get { record(forDayKey: DayContext.dayKey(.now))?.mvpTitle }
        set {
            let r = recordForToday()
            r.mvpTitle = newValue
            r.modifiedAt = .now
            try? context.save()
        }
    }

    var todayMVPNote: String {
        get { record(forDayKey: DayContext.dayKey(.now))?.mvpNote ?? "" }
        set {
            let r = recordForToday()
            r.mvpNote = newValue
            r.modifiedAt = .now
            try? context.save()
        }
    }

    // MARK: - 旧 UserDefaults 数据一次性迁移

    /// 死代码审计（2026-07-22）：UserDefaults→SwiftData 的一次性迁移已完成历史使命（写方 v0.6 已删、
    /// 所有设备均已跑过 ≥v0.6）→ 迁移函数退役，换成一次性清掉躺在 defaults plist 里的三族源键
    /// （"review.activeDays" / "review.mvp.<日期>"×N / "review.mvpNote.<日期>"×N）与旧迁移旗标。
    private func purgeLegacyUserDefaultsKeysOnce() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: "review.legacyPurged") else { return }
        ud.removeObject(forKey: "review.activeDays")
        ud.removeObject(forKey: "review.migratedToSwiftData")
        for key in ud.dictionaryRepresentation().keys
        where key.hasPrefix("review.mvp.") || key.hasPrefix("review.mvpNote.") {
            ud.removeObject(forKey: key)
        }
        ud.set(true, forKey: "review.legacyPurged")
        DevLog.shared.info("复盘", "旧 UserDefaults 复盘键已一次性清理")
    }
}
