//
//  DevLogView.swift
//  BetterCalendar
//
//  开发日志查看页（首页工具栏 🐞）。开发期用，便于看清云端/系统调用的成败。
//

import SwiftUI

struct DevLogView: View {
    /// 通道筛选（0.28）：全部 / 仅问题（警告+错误）/ 行为（BehaviorLog 镜像，source=「行为」）。
    enum Channel: String, CaseIterable { case all = "全部", issues = "仅问题", behavior = "行为", smoke = "冒烟" }
    @State private var channel: Channel = .all

    private var filtered: [DevLog.Entry] {
        switch channel {
        case .all: return DevLog.shared.entries
        case .issues: return DevLog.shared.entries.filter { $0.level != .info }
        case .behavior: return DevLog.shared.entries.filter { $0.source == "行为" }
        case .smoke: return DevLog.shared.entries.filter { $0.source == SmokeLog.source }
        }
    }

    var body: some View {
        List {
            Picker("通道", selection: $channel) {
                ForEach(Channel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if filtered.isEmpty {
                Text(channel == .behavior ? "还没有行为记录（确认写入/开始/完成…会记在这里，只存本地）"
                     : channel == .smoke ? "还没有冒烟记录（点右上「打标记」开一轮，再去操作被测功能）" : "暂无日志")
                    .foregroundStyle(.secondary)
            }
            ForEach(filtered.reversed()) { e in
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
        .navigationTitle("错误日志（开发期）")
        .toolbar {
            // 冒烟一轮起点（仿 BT 冒烟指南）：点它 → 去操作被测功能 → Claude 从这根标记之后读日志核销
            Button("打标记") { SmokeLog.mark(); channel = .smoke }
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
