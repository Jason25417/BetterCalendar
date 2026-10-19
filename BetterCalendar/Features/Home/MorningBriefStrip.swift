//
//  MorningBriefStrip.swift
//  BetterCalendar
//
//  晨间摘要（E5d，§14.6 提名清单的宿主；TomorrowNote 寄语条同族）：
//  ① 昨日收池条目露脸（露脸义务=每件一次：只认 spilledFromDay=昨天，前天以前的自动安静——无维护义务铁律）
//  ② 带 DDL 的置顶（位置事实措辞，不催促）
//  ③ 「计划有 N 处自动调整」→ 痕迹 sheet（预授权直写绿的配套义务，R12 世界归因）
//  DDL 拉力的长期任务提名照旧归 L3 建议条（本条不重复）。按逻辑日 keyed、点 ✕ 只收当天。
//

import SwiftUI

/// 晨间摘要的数据与当天收起标记（UserDefaults 按逻辑日 keyed——TomorrowNote 同款）。
@MainActor
enum MorningBrief {
    private static func dismissKey(_ day: Date) -> String {
        "bc.morningbrief.dismissed.\(DayContext.dayKey(day))"
    }
    static var isDismissedToday: Bool {
        UserDefaults.standard.bool(forKey: dismissKey(DayContext.logicalDay(offset: 0)))
    }
    static func dismissToday() {
        UserDefaults.standard.set(true, forKey: dismissKey(DayContext.logicalDay(offset: 0)))
    }

    /// 昨日收池的待办条目（露脸清单）：DDL 在前（位置事实），其余按收池新旧。
    static func yesterdaySpills(from store: LongTaskStore) -> [LongTask] {
        let yesterday = DayContext.logicalDay(offset: -1)
        return store.todoItems()
            .filter { $0.spilledFromDay.map { Calendar.current.isDate($0, inSameDayAs: yesterday) } ?? false }
            .sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
    }
}

/// 晨间摘要条（HomeView 顶部 MessageStrip 区）。
struct MorningBriefStrip: View {
    @Environment(\.appTheme) private var theme
    let longTasks: LongTaskStore
    let router: AppRouter
    /// 收起后让宿主重算可见性（UserDefaults 非 @Observable——TomorrowNote 同款 tick 模式）。
    var onDismiss: () -> Void

    var body: some View {
        let spills = MorningBrief.yesterdaySpills(from: longTasks)
        if !spills.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("昨天留下的 \(spills.count) 件在待办区——今天要排吗？", systemImage: "tray.and.arrow.up")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { MorningBrief.dismissToday(); onDismiss() } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("今天先不排（条目都还在待办区）")
                }
                ForEach(spills.prefix(3)) { entry in
                    HStack(spacing: 8) {
                        Text(entry.title).font(.callout).lineLimit(1)
                        if let ddl = entry.deadline {
                            // 位置事实措辞：说「截止在几号」，不说「还剩 N 天」（R 线：无倒数）
                            Text("截止 \(ddl.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(theme.accent)
                        }
                        Spacer()
                        Button("排今天") {
                            router.scheduleRequest = .insertLongTask(entry.id)
                        }
                        .font(.caption).buttonStyle(.bordered).controlSize(.small)
                        .tint(.primary)
                    }
                }
                if spills.count > 3 {
                    Text("还有 \(spills.count - 3) 件在长期页待办区")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
    }
}

/// 变更痕迹 sheet（E5d 二层）：今天的自动调整清单 + 一键撤。
struct ChangeTraceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let timeline: TimelineCoordinator
    @State private var undoneCount: Int?

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                if let n = undoneCount {
                    Text("已恢复 \(n) 块到调整前的位置").font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(timeline.todayTraces()) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.title).font(.callout).lineLimit(1)
                                Spacer()
                                Text(Self.fmt.string(from: e.time))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if e.kind != "撤销" {
                                Text("\(Self.fmt.string(from: e.beforeStart)) → \(Self.fmt.string(from: e.afterStart)) · \(e.reason)")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(e.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("今天的自动调整")
                } footer: {
                    Text("这些是计划为跟上现实做的让位与顺延——世界在变，不是你在错。")
                        .font(.caption2)
                }
            }
            .navigationTitle("变更痕迹")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("撤销今天的自动调整") {
                        let n = timeline.undoToday()
                        undoneCount = n
                        if n > 0 { FeatureUsage.record(.autoAdjust, .undone, "\(n) 块") }   // W21：自动调整的结果被你撤销
                    }
                        .disabled(timeline.todayTraceCount() == 0)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 320)
        .onAppear { FeatureUsage.used(.todayTraceReview) }
    }
}
