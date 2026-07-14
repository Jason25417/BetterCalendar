//
//  TodayWidget.swift
//  BetterCalendarWidgets
//
//  主屏小组件「今天」（2026-07-04，v0.11）：正在做 / 接下来 / 今日做成 N 件。
//  正反馈口径（产品原则 2）：只放大做成了什么，不显示完成率/缺口。
//  数据 = 主 App 写在 App Group 的 WidgetSnapshot（每次执行动作后刷新）。
//

import WidgetKit
import SwiftUI

struct TodayEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, snap: WidgetSnapshot(
            doneCount: 2, activeTitle: "写代码",
            remaining: [WidgetSnapshot.Item(title: "健身", start: .now, end: .now.addingTimeInterval(3600))]))
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(TodayEntry(date: .now, snap: WidgetSnapshotStore.load() ?? WidgetSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = TodayEntry(date: .now, snap: WidgetSnapshotStore.load() ?? WidgetSnapshot())
        // 主要靠主 App 动作后 reloadTimelines 推动；这里兜底半小时自刷一次
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.appTheme) private var theme   // 令牌表 v1（换装批次 B；AppTheme.swift 经 membership exception 共享进本 target）
    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let active = entry.snap.activeTitle {
                Label(active, systemImage: "play.circle.fill")
                    .font(.subheadline.bold()).foregroundStyle(theme.actualTint).lineLimit(1)
            } else if let next = entry.snap.remaining.first {
                Label(next.title, systemImage: "arrow.right.circle")
                    .font(.subheadline.bold()).lineLimit(1)
            } else {
                Text(entry.snap.doneCount > 0 ? "今天的计划都做完了 🎉" : "还没排今天")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if family == .systemMedium {
                mediumList
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var header: some View {
        HStack {
            Text(entry.snap.activeTitle != nil ? "正在做" : "接下来")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if entry.snap.doneCount > 0 {
                Text("今日做成 \(entry.snap.doneCount) 件")
                    .font(.caption2.bold()).foregroundStyle(theme.positiveTint)
            }
        }
    }

    /// systemMedium：多列几件「接下来」（跳过第一件——小尺寸已显）。
    @ViewBuilder private var mediumList: some View {
        let rest = entry.snap.activeTitle != nil
            ? Array(entry.snap.remaining.prefix(3))
            : Array(entry.snap.remaining.dropFirst().prefix(3))
        ForEach(Array(rest.enumerated()), id: \.offset) { _, item in
            HStack(spacing: 6) {
                Text(item.start.formatted(.dateTime.hour().minute()))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(item.title).font(.caption).lineLimit(1)
                Spacer()
            }
        }
    }
}

struct BetterCalendarTodayWidget: Widget {
    let kind = "BetterCalendarTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("今天")
        .description("正在做的事、接下来、今日做成——一眼掌控。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
