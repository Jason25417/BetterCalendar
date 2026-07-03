//
//  ReviewView.swift
//  BetterCalendar
//
//  正反馈复盘视图（产品设计与行为逻辑.md §3.4）：默认只放大「做成了什么」（含计划外 bonus）+
//  有效投入时长；完成率/缺口默认隐藏，主动点才进二级。偏差一律中性措辞。
//

import SwiftUI

struct ReviewView: View {
    let container: AppContainer
    @State private var model: ReviewViewModel

    init(container: AppContainer) {
        self.container = container
        _model = State(initialValue: container.reviewModel)
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let c = model.comparison {
                    summaryCard(c)
                    mvpSection()
                    accomplishedSection(c)
                    if c.bonusCount > 0 { Text("计划外也算赢——这些是今天的 bonus。").font(.caption).foregroundStyle(.secondary) }
                    detailsSection(c)
                    shareSummaryButton(c)
                    writeTodayButton
                } else if model.isWorking {
                    ProgressView("正在读取今天…")
                } else {
                    Text("今天还没有可复盘的记录。先在 menu bar 流过一天，或在下面补一笔。")
                        .foregroundStyle(.secondary)
                }

                Divider()
                backfillSection
            }
            .padding()
        }
        .navigationTitle("今日复盘")
        .task { await model.load() }
    }

    // 写下今天 → 切到日记页、打开当天条目（带入今天的情境）
    private var writeTodayButton: some View {
        Button {
            container.router.journalRequest = .now
            container.router.selectedTab = .journal
        } label: {
            Label("写下今天的感受", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .padding(.top, 4)
    }

    private func shareSummaryButton(_ c: DayComparison) -> some View {
        let text = ReviewSummaryText.make(comparison: c,
                                          activeDayCount: model.activeDayCount,
                                          mvpTitle: model.mvpTitle,
                                          mvpNote: model.mvpNote)
        return ShareLink(item: text, preview: SharePreview("BetterCalendar 今日小结")) {
            Label("分享今日小结", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    // MARK: 正反馈主面

    private func summaryCard(_ c: DayComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("今天做成 \(c.accomplishedCount) 件"
                 + (c.bonusCount > 0 ? "（含 \(c.bonusCount) 件计划外）" : ""))
                .font(.title3.bold())
            Text("有效投入 \(Self.hm(c.effectiveMinutes))"
                 + (model.activeDayCount > 0 ? " · 已活跃使用 \(model.activeDayCount) 天" : ""))
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.green.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // 今日「最有价值的一件」轻自评（选了才显输入框；可写一句为什么）
    @ViewBuilder private func mvpSection() -> some View {
        @Bindable var model = model
        if let mvp = model.mvpTitle {
            VStack(alignment: .leading, spacing: 6) {
                Label("今日最有价值：\(mvp)", systemImage: "trophy.fill")
                    .font(.subheadline).foregroundStyle(.orange)
                TextField("想写一句为什么？（可留空）", text: $model.mvpNote)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveMVPNote() }
            }
            .padding(10)
            .background(Color.yellow.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func accomplishedSection(_ c: DayComparison) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("做成了什么").font(.headline)
            if c.accomplished.isEmpty {
                Text("还没有记录——别急，开始一件就有了。").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(c.accomplished) { item in
                    accomplishedRow(item)
                }
            }
        }
    }

    private func accomplishedRow(_ item: ComparedItem) -> some View {
        let isMVP = (model.mvpTitle == item.displayTitle)
        return HStack(spacing: 10) {
            Image(systemName: item.status == .extra ? "sparkles" : "checkmark.circle.fill")
                .foregroundStyle(item.status == .extra ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                Text(Self.phrase(item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let m = item.actualMinutes { Text(Self.hm(m)).font(.caption).foregroundStyle(.secondary) }
            Button { model.toggleMVP(item.displayTitle) } label: {
                Image(systemName: isMVP ? "trophy.fill" : "trophy")
                    .foregroundStyle(isMVP ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help("设为今日最有价值的一件")
        }
        .padding(.vertical, 2)
        .background(isMVP ? Color.yellow.opacity(0.12) : Color.clear)
    }

    // MARK: 二级（默认隐藏）：缺口

    @ViewBuilder private func detailsSection(_ c: DayComparison) -> some View {
        if c.missedCount > 0 {
            DisclosureGroup(isExpanded: Binding(
                get: { model.showDetails }, set: { model.showDetails = $0 })
            ) {
                ForEach(c.missed) { item in
                    HStack {
                        Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                        Text(item.plannedTitle ?? "")
                        Spacer()
                        Text("未做").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                Text("没做到的事不扣分——明天从「现在起可行」的部分继续就好。")
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                Text("看看缺口（\(c.missedCount)）").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 降级回填

    private var backfillSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            Text("补一笔今天做了什么").font(.headline)
            Text("menu bar 没抓到的、或临时多做的，说一句补进蓝色「实际」。会合并、不覆盖已记录的。")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                TextField("例：下午临时读了篇论文一小时、晚上跑步半小时",
                          text: $model.backfillText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Button { Task { await model.parseBackfill() } } label: {
                    Label("解析", systemImage: "wand.and.stars")
                }
                .disabled(model.isWorking)
            }

            if !model.backfillBlocks.isEmpty {
                List {
                    ForEach(model.backfillBlocks) { item in
                        EditableRow(block: model.binding(for: item.id),
                                    onDelete: { model.deleteBackfill(id: item.id) })
                    }
                }
                .frame(minHeight: 140)

                HStack {
                    Button { model.addBackfillBlock() } label: { Label("加一项", systemImage: "plus") }
                        .font(.caption)
                    Spacer()
                    Button { Task { await model.confirmBackfill() } } label: {
                        Label("写入实际日历", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
                }
            }

            if let n = model.backfillCommitted {
                Text("已补记 \(n) 项实际").font(.caption).foregroundStyle(.green)
            }
            if let err = model.errorText {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // 分钟 → 「H 小时 M 分」/「M 分钟」
    static func hm(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时"
        }
        return "\(minutes) 分钟"
    }

    // 中性/正向措辞（绝不出现「失败/未完成」）
    static func phrase(_ item: ComparedItem) -> String {
        switch item.status {
        case .done:    return item.isContentChange ? "改做：\(item.plannedTitle ?? "")" : "完成"
        case .partial: return "做了一部分"
        case .over:    return "做得比计划更多"
        case .extra:   return "计划外 · bonus"
        case .missed:  return "未做"
        }
    }
}
