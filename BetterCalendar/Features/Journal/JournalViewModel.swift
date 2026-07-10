//
//  JournalViewModel.swift
//  BetterCalendar
//
//  反思层（日记）标签页 VM：管列表/搜索/当天条目。编辑直接改 @Model 属性 + store.save()。
//

import Foundation
import Observation

@Observable
final class JournalViewModel {
    private let store: JournalStore
    var searchText = ""
    private(set) var entries: [JournalEntry] = []

    init(store: JournalStore) {
        self.store = store
        reload()
    }

    func reload() { entries = store.search(searchText) }

    /// 当天条目（没有就建）。
    func todayEntry() -> JournalEntry {
        let e = store.entryForToday()
        reload()
        return e
    }

    /// 历史 = 非今天的条目（今天在顶部「写下今天」卡片里编辑）。
    var history: [JournalEntry] {
        entries.filter { !DayContext.isSameLogicalDay($0.date, .now) }
    }

    /// 「往年今天」（R5）：往年同月同日的条目，最近一年优先；没有则 nil（内测头一年自然不出现）。
    func onThisDay(_ now: Date = .now) -> JournalEntry? {
        let cal = Calendar.current
        let today = cal.dateComponents([.month, .day], from: now)
        let thisYear = cal.component(.year, from: now)
        return entries.first {
            let c = cal.dateComponents([.year, .month, .day], from: $0.date)
            return c.month == today.month && c.day == today.day && (c.year ?? thisYear) < thisYear
        }
    }

    /// 全部日记 → markdown（导出/备份；R5）。
    func exportMarkdown() -> String { JournalExport.markdown(entries) }

    func save() {
        store.save(); reload()
        // 「给明天的一句话」（#23）：保存即本地提取（规则匹配，零模型）→ 存给明天；若明早通知已排则并入
        let note = TomorrowNote.extract(from: store.entryForToday().body)
        TomorrowNote.store(note)
        if let note { Task { await UNNotificationService.appendTomorrowNoteToMorning(note) } }
    }
    func delete(_ e: JournalEntry) { store.delete(e); reload() }
}
