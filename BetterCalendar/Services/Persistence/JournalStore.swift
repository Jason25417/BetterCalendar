//
//  JournalStore.swift
//  BetterCalendar
//
//  反思层（日记）数据访问（M9/R1）：JournalEntry 的增删改查 + 全文搜索。
//  本地 SwiftData 是唯一真相源；随同一 CloudKit 容器同步。注入 ModelContext 可测。
//

import Foundation
import SwiftData

@MainActor
final class JournalStore {
    private let context: ModelContext

    init(context: ModelContext? = nil) {
        self.context = context ?? SharedModelContainer.shared.mainContext
    }

    /// 全部条目，按日期倒序。
    func allEntries() -> [JournalEntry] {
        (try? context.fetch(
            FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
    }

    /// 某逻辑日的条目（一天最多一条）。
    func entry(forLogicalDay day: Date) -> JournalEntry? {
        allEntries().first { DayContext.isSameLogicalDay($0.date, day) }
    }

    /// 取当天条目，没有就建一个并插入（「写下今天」用）。
    @discardableResult
    func entryForToday(_ now: Date = .now) -> JournalEntry {
        if let e = entry(forLogicalDay: now) { return e }
        let e = JournalEntry(date: now)   // 存创建时刻；同逻辑日判断走 isSameLogicalDay
        context.insert(e)
        try? context.save()
        return e
    }

    /// 全文搜索（正文 + 标签 + 心情，本地可控，Apple 手记搜不好正是我们的优势）。
    func search(_ query: String) -> [JournalEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allEntries() }
        return allEntries().filter {
            $0.body.localizedCaseInsensitiveContains(q)
            || ($0.mood ?? "").localizedCaseInsensitiveContains(q)
            || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    /// 今天（逻辑日）是否已有记录（正文或心情）——收口卡用：记录过就不再邀请。**只读不创建**。
    func hasContentToday(_ now: Date = .now) -> Bool {
        guard let e = entry(forLogicalDay: now) else { return false }
        return !e.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || e.mood != nil
    }

    func save() { try? context.save() }

    func delete(_ entry: JournalEntry) {
        context.delete(entry)
        try? context.save()
    }
}
