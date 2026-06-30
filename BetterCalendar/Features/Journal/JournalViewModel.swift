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

    func save() { store.save(); reload() }
    func delete(_ e: JournalEntry) { store.delete(e); reload() }
}
