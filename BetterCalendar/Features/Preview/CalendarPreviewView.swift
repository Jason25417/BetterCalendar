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
                                    .fill(event.kind == .planned ? Color.green : Color.blue)
                                    .frame(width: 8, height: 8)
                                Text(event.title)
                            }
                            Text(label(event))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("日历预览")
    }

    private func label(_ e: CalendarEventDraft) -> String {
        let kind = e.kind == .planned ? "预先设计·绿" : "实际·蓝"
        let s = e.start.formatted(date: .abbreviated, time: .shortened)
        let end = e.end.formatted(date: .omitted, time: .shortened)
        return "[\(kind)] \(s) – \(end)"
    }
}
