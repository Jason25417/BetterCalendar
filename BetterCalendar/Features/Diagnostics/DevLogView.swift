//
//  DevLogView.swift
//  BetterCalendar
//
//  开发日志查看页（首页工具栏 🐞）。开发期用，便于看清云端/系统调用的成败。
//

import SwiftUI

struct DevLogView: View {
    var body: some View {
        List {
            if DevLog.shared.entries.isEmpty {
                Text("暂无日志").foregroundStyle(.secondary)
            }
            ForEach(DevLog.shared.entries.reversed()) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Circle().fill(Self.color(e.level)).frame(width: 8, height: 8)
                        Text(e.source).font(.caption.bold())
                        Spacer()
                        Text(e.time.formatted(date: .omitted, time: .standard))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(e.message).font(.caption)
                }
            }
        }
        .navigationTitle("开发日志")
        .toolbar {
            Button("清空") { DevLog.shared.clear() }
        }
    }

    static func color(_ level: DevLog.Level) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
