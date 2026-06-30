//
//  CalendarPreviewView.swift
//  BetterCalendar
//
//  假日历预览：把 FakeCalendarStore 捕获的「本要写进系统日历」的事件以文本/列表展示。
//  开发期靠它看清「写进日历会长啥样」，零污染。逻辑稳了换 EventKitCalendarStore 即写真日历。
//

import SwiftUI

struct CalendarPreviewView: View {
    let store: FakeCalendarStore
    let reminderStore: FakeReminderStore

    var body: some View {
        List {
            Section("假日历（开发期预览 · 不写系统）") {
                if store.captured.isEmpty {
                    Text("还没有写入任何事件").foregroundStyle(.secondary)
                } else {
                    ForEach(store.captured) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Circle()
                                    .fill(color(event.kind))
                                    .frame(width: 8, height: 8)
                                Text(event.title)
                            }
                            Text(label(event))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("假提醒事项（开发期预览 · 不写系统）") {
                if reminderStore.captured.isEmpty {
                    Text("还没有写入任何提醒").foregroundStyle(.secondary)
                } else {
                    ForEach(reminderStore.captured) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: r.priority == 1 ? "star.fill" : "circle")
                                    .font(.caption2)
                                    .foregroundStyle(r.priority == 1 ? .orange : .secondary)
                                Text(r.title)
                            }
                            Text(label(r))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("日历 / 提醒预览")
    }

    private func color(_ kind: PlanCalendarKind) -> Color {
        switch kind {
        case .planned: return .green
        case .actual:  return .blue
        case .preview: return .orange
        }
    }

    private func label(_ e: CalendarEventDraft) -> String {
        let kindName: String
        switch e.kind {
        case .planned: kindName = "预先设计·绿"
        case .actual:  kindName = "实际·蓝"
        case .preview: kindName = "预览·橙"
        }
        let s = e.start.formatted(date: .abbreviated, time: .shortened)
        let end = e.end.formatted(date: .omitted, time: .shortened)
        return "[\(kindName)] \(s) – \(end)"
    }

    private func label(_ r: ReminderDraft) -> String {
        var parts: [String] = []
        if r.priority == 1 { parts.append("要紧事") }
        if let due = r.due {
            parts.append("截止 " + due.formatted(date: .abbreviated, time: .shortened))
        }
        if let lead = r.leadMinutes, lead > 0 { parts.append("提前 \(lead) 分钟提醒") }
        return parts.isEmpty ? "无截止" : parts.joined(separator: " · ")
    }
}
