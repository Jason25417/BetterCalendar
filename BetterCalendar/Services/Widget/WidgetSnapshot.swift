//
//  WidgetSnapshot.swift
//  BetterCalendar
//
//  主 App → 主屏小组件 的数据桥（2026-07-04，v0.11）：执行状态快照写进 App Group 容器的 JSON，
//  小组件 TimelineProvider 读它渲染。⚠️ 同时编进主 App 与 Widget 扩展两个 target（membership exception）。
//  正反馈口径：只给「做成了 N 件 / 正在做 / 接下来」，不给完成率。
//

import Foundation

nonisolated struct WidgetSnapshot: Codable {
    nonisolated struct Item: Codable {
        var title: String
        var start: Date
        var end: Date

        init(title: String, start: Date, end: Date) {
            self.title = title
            self.start = start
            self.end = end
        }
    }

    var updatedAt: Date = .now
    var doneCount: Int = 0
    var activeTitle: String?      // 正在做（前台块）
    var remaining: [Item] = []    // 接下来（已排除做完/进行中）

    init(updatedAt: Date = .now, doneCount: Int = 0,
         activeTitle: String? = nil, remaining: [Item] = []) {
        self.updatedAt = updatedAt
        self.doneCount = doneCount
        self.activeTitle = activeTitle
        self.remaining = remaining
    }
}

nonisolated enum WidgetSnapshotStore {
    static let appGroup = "group.com.jason.BetterCalendar"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget-snapshot.json")
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
