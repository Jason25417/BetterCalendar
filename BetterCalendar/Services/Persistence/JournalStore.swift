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
        ((try? context.fetch(
            FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []).filter { !$0.isInTrash }
    }

    /// 某逻辑日的条目（一天最多一条）。
    func entry(forLogicalDay day: Date) -> JournalEntry? {
        allEntries().first { DayContext.isSameLogicalDay($0.date, day) }
    }

    /// W28b：当天条目；没有就给一个**未落库**的草稿（只打开日记页不再插入空条目——以前会让「写下 1 篇」虚报）。
    /// 草稿在第一次有输入时由 commit(_:) 落库。
    func todayEntryOrDraft(_ now: Date = .now) -> JournalEntry {
        entry(forLogicalDay: now) ?? JournalEntry(date: now)
    }

    /// 是否已落库（false = todayEntryOrDraft 给的草稿，还没写任何东西）。
    func isPersisted(_ entry: JournalEntry) -> Bool { entry.modelContext != nil }

    /// 保存一条（草稿有输入才插入；已落库的照常保存）。保存失败记 DevLog（失败可见）。
    func commit(_ entry: JournalEntry) {
        if entry.modelContext == nil {
            guard entry.hasAnyInput else { return }
            // 另一台设备同一天刚写的一条可能稍后经 iCloud 到达：那时会有两条（可见、不丢字），不在这里猜着合并
            context.insert(entry)
        }
        do { try context.save() }
        catch { DevLog.shared.warn("日记", "保存失败：\(error.localizedDescription)") }
    }

    /// 取当天条目，没有就建一个并插入（导入 / 测试用；界面走 todayEntryOrDraft + commit，避免空条目落库）。
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
        return e.hasRealContent
    }

    /// 某时刻之后的条目（按日期倒序，排除回收站）。只读；读失败抛错——给智能体上下文用（SPEC §19 A2，需 Jason 允许才调用）。
    func entries(since: Date) throws -> [JournalEntry] {
        try context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.date >= since },
                                                        sortBy: [SortDescriptor(\.date, order: .reverse)]))
            .filter { !$0.isInTrash }
    }

    func save() { try? context.save() }

    func delete(_ entry: JournalEntry) {
        do { try RetainedDeletion.save([entry], in: context) }
        catch { DataSyncMonitor.shared.report("日记删除尚未保存：\(error.localizedDescription)") }
    }
}
