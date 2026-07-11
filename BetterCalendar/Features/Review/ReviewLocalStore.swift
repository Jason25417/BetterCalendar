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
            migrateFromUserDefaultsIfNeeded()
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

    private static let migratedFlag = "review.migratedToSwiftData"

    private func migrateFromUserDefaultsIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.migratedFlag) else { return }
        var imported = 0
        // ① 活跃日数组
        for key in d.stringArray(forKey: "review.activeDays") ?? [] where record(forDayKey: key) == nil {
            context.insert(DayRecord(dayKey: key, isActive: true))
            imported += 1
        }
        // ② 历史 MVP（键形如 review.mvp.yyyy-MM-dd / review.mvpNote.yyyy-MM-dd）
        for (key, value) in d.dictionaryRepresentation() {
            if key.hasPrefix("review.mvp."), let title = value as? String, !title.isEmpty {
                let dayKey = String(key.dropFirst("review.mvp.".count))
                let r = record(forDayKey: dayKey) ?? {
                    let n = DayRecord(dayKey: dayKey); context.insert(n); return n
                }()
                if r.mvpTitle == nil { r.mvpTitle = title; imported += 1 }
            }
            if key.hasPrefix("review.mvpNote."), let note = value as? String, !note.isEmpty {
                let dayKey = String(key.dropFirst("review.mvpNote.".count))
                let r = record(forDayKey: dayKey) ?? {
                    let n = DayRecord(dayKey: dayKey); context.insert(n); return n
                }()
                if r.mvpNote.isEmpty { r.mvpNote = note; imported += 1 }
            }
        }
        try? context.save()
        d.set(true, forKey: Self.migratedFlag)
        if imported > 0 {
            DevLog.shared.info("复盘", "旧活跃天/MVP 数据已迁入 SwiftData（\(imported) 项，随 iCloud 同步）")
        }
    }
}
