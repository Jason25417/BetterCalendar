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
final class JournalStore: ProposalJournalWriting {
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
            JournalAuthorship.plainText($0.body).localizedCaseInsensitiveContains(q)   // W32b：不搜作者标记本身
            || ($0.mood ?? "").localizedCaseInsensitiveContains(q)
            || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    /// 今天（逻辑日）是否已有记录（正文或心情）——收口卡用：记录过就不再邀请。**只读不创建**。
    func hasContentToday(_ now: Date = .now) -> Bool {
        guard let e = entry(forLogicalDay: now) else { return false }
        return !e.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || e.mood != nil
    }

    /// 某时刻之后的条目（按日期倒序，排除回收站）。只读；读失败抛错——给智能体上下文用（SPEC §19 A2，需 Jason 允许才调用）。
    func entries(since: Date) throws -> [JournalEntry] {
        try context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.date >= since },
                                                        sortBy: [SortDescriptor(\.date, order: .reverse)]))
            .filter { !$0.isInTrash }
    }

    func save() { try? context.save() }

    // MARK: W32b 审批写日记（时刻由调用方注入；失败抛错不吞）

    /// 按 id 取（含回收站里的，供版本核对）。身份重复视为数据异常，抛错不猜。
    func entry(id: UUID) throws -> JournalEntry? {
        let found = try context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == id }))
        guard found.count <= 1 else { throw DataArchiveError.invalid("日记身份重复，未执行") }
        return found.first
    }

    /// 某逻辑日（label = 该日零点）的那篇（不含回收站）；同一天不止一篇 → 抛错不猜。
    func entry(onLogicalDay label: Date) throws -> JournalEntry? {
        let window = DayContext.logicalWindow(forLabel: label)
        let lo = window.start.addingTimeInterval(-86_400), hi = window.end.addingTimeInterval(86_400)
        let found = try context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.date >= lo && $0.date < hi }))
            .filter { !$0.isInTrash && DayContext.logicalStartOfDay($0.date) == label }
        guard found.count <= 1 else { throw DataArchiveError.invalid("这一天有 \(found.count) 篇日记，没法确定写进哪篇") }
        return found.first
    }

    /// 新建某逻辑日（label = 该日零点）的一篇（id 指定，幂等由调用方查）。日期 = 此刻（就是那天）或那天中午（往日）。
    func create(id: UUID, day label: Date, body: String, at date: Date) throws {
        guard try entry(id: id) == nil else { throw DataArchiveError.invalid("这篇日记已存在，不重复新建") }
        let when = DayContext.logicalStartOfDay(date) == label ? date : label.addingTimeInterval(12 * 3600)
        let e = JournalEntry(id: id, date: when, body: body, createdAt: date, modifiedAt: date)
        context.insert(e)
        do { try context.save() } catch { context.delete(e); throw error }
    }

    func setBody(id: UUID, body: String, at date: Date) throws {
        guard let e = try entry(id: id), !e.isInTrash else { throw DataArchiveError.invalid("这篇日记不存在或在回收站") }
        let old = (e.body, e.modifiedAt)
        e.body = body; e.modifiedAt = date
        do { try context.save() } catch { e.body = old.0; e.modifiedAt = old.1; throw error }
    }

    /// 移入回收站（只用于撤销「新建」）。
    func discard(id: UUID, at date: Date) throws {
        guard let e = try entry(id: id), !e.isInTrash else { throw DataArchiveError.invalid("这篇日记不存在或已在回收站") }
        try RetainedDeletion.save([e], in: context, at: date)
    }

    func delete(_ entry: JournalEntry) {
        do { try RetainedDeletion.save([entry], in: context) }
        catch { DataSyncMonitor.shared.report("日记删除尚未保存：\(error.localizedDescription)") }
    }
}
