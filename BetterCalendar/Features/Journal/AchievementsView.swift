//
//  AchievementsView.swift
//  BetterCalendar
//
//  成就带（#27 V1）：累计里程碑的时间线——只做加法、没有断签、与完成率无关。
//  低调入口（日记页工具栏 🏅）：低频查看、高情感密度；解锁本身在日记页静默出条，这里是回看全景。
//

import SwiftUI

struct AchievementsView: View {
    let store: MilestoneStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 在路上：每类指标的当前值与下一站（只向前看，不催）
                VStack(alignment: .leading, spacing: 8) {
                    Text("在路上").font(.headline)
                    ForEach(MilestoneMetric.allCases, id: \.self) { metric in
                        if let next = store.next(for: metric) {
                            HStack {
                                Text(metric.label).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(metric.format(store.currentValues[metric] ?? 0)) · 下一站 \(metric.format(next.threshold))")
                                    .font(.callout.monospacedDigit())
                            }
                        }
                    }
                }

                Divider()

                Text("已点亮").font(.headline)
                if store.timeline.isEmpty {
                    Text("还没有点亮的里程碑——它们会随着日子自己出现，不用刻意。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.timeline, id: \.milestone.id) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: "seal.fill").foregroundStyle(.orange)
                            Text(item.milestone.title).font(.callout.bold())
                            Spacer()
                            Text(item.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.milestone.line).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }

                Text("这里只做加法：每一格都是攒下的，不会清零、没有断签。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding()
        }
        .navigationTitle("成就")
        .onAppear { store.refresh() }
    }
}
