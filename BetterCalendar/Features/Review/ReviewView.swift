//
//  ReviewView.swift
//  BetterCalendar
//
//  正反馈复盘视图（产品设计与行为逻辑.md §3.4）：默认只放大「做成了什么」（含计划外 bonus）+
//  有效投入时长；完成率/缺口默认隐藏，主动点才进二级。偏差一律中性措辞。
//

import SwiftUI

/// 可嵌入的复盘面板（0.28 提案A：并入日记页「回看今天」头部；独立复盘页已退役）。
/// 无自己的滚动容器/导航标题——宿主（日记页）提供；内容与原 ReviewView 一致。
struct ReviewPanel: View {
    @Environment(\.appTheme) private var theme   // 令牌表 v1（换装批次 B）
    @State private var model: ReviewViewModel

    init(model: ReviewViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
                if let c = model.comparison {
                    if model.isLooseToday {
                        // 松散日：复盘转"休息肯定"——不显对比/完成率/要紧事压力，措辞赋义（§5.12）
                        looseAffirmation(c)
                        if !c.accomplished.isEmpty { accomplishedSection(c) }
                    } else {
                        summaryCard(c)
                        mitSection()
                        mvpSection()
                        accomplishedSection(c)
                        if let lp = model.longTaskProgress {
                            Label(lp, systemImage: "tray.full")
                                .font(.caption).foregroundStyle(theme.looseTint)
                        }
                        calibrationSection(c)
                        spillSection   // E5c 两阶段溢出：收工语境下展示 + 逐件可改（盖章时硬执行）
                        shareSummaryButton(c)
                    }
                } else if model.isWorking {
                    ProgressView("正在读取今天…")
                } else {
                    // 体检 #12（U7）：执行入口名跨端各表——macOS=menu bar，iOS=「今天」页
                    Text("今天还没有可复盘的记录。先在\(Self.executionEntryName)流过一天，或在下面补一笔。")
                        .foregroundStyle(.secondary)
                }

            Divider()
            backfillSection
        }
        .task { await model.load() }
    }

    // MARK: 溢出处置（E5c 两阶段：软标展示→盖章硬执行；默认静默收待办区）
    // 措辞红线：说「留到以后/还想做的」，不说「没做完/没排下」；生活锚不上屏（溶解零叙事）。
    // 只在收工语境（过傍晚线）出现——白天「现在就回看」不把下午的计划说成「留到以后」。

    @ViewBuilder
    private var spillSection: some View {
        let pending = model.spillPending
        if !pending.isEmpty, let timeline = model.timeline,
           Date.now >= WorkHoursSettings.eveningStart(for: .now) {
            VStack(alignment: .leading, spacing: 6) {
                Label("还想做的 \(pending.count) 件，收工后进待办区（明早会露脸）",
                      systemImage: "tray.and.arrow.down")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(pending) { b in
                    HStack {
                        Text(b.title).font(.callout).lineLimit(1)
                        Spacer()
                        spillMenu(for: b, timeline: timeline)
                    }
                }
            }
        }
    }

    private func spillMenu(for b: ScheduledBlock, timeline: TimelineCoordinator) -> some View {
        let current = timeline.spillOverrides[b.id]
        let label = switch current {
        case .forward: "排到明天"
        case .dissolve: "就算了"
        default: "收进待办"
        }
        return Menu(label) {
            Button("收进待办（明早露脸）") { timeline.setSpillOverride(b.id, policy: nil) }
            Button("排到明天") { timeline.setSpillOverride(b.id, policy: .forward) }
            Button("就算了（丢了就丢了）") { timeline.setSpillOverride(b.id, policy: .dissolve) }
        }
        .font(.caption)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func shareSummaryButton(_ c: DayComparison) -> some View {
        let text = ReviewSummaryText.make(comparison: c,
                                          activeDayCount: model.activeDayCount,
                                          mvpTitle: model.mvpTitle,
                                          mvpNote: model.mvpNote)
        return ShareLink(item: text, preview: SharePreview("BetterCalendar 今日小结")) {
            Label("分享今日小结", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).tint(.primary)   // 体检 #10：次要动作收中性（条文2）
    }

    // MARK: 松散日「休息肯定」（退场+见证：不算账、赋义措辞；做了就平权庆祝、没做也不愧疚）

    private func looseAffirmation(_ c: DayComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("今天，你允许自己好好休息了", systemImage: "moon.stars.fill")
                .font(.title3.bold()).foregroundStyle(theme.looseTint)
            Text(c.accomplishedCount > 0
                 ? "顺手还做了 \(c.accomplishedCount) 件——都算数，但今天不必用它们证明什么。"
                 : "什么都没做也很好。休息本身，就是今天的意义。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(theme.looseTint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 正反馈主面

    private func summaryCard(_ c: DayComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 去对比化：默认只庆祝"做成 N 件"（计划内外一律平权、不提计划外/bonus，那几件已在清单里被数进 N）
            Text("今天做成 \(c.accomplishedCount) 件")
                .font(.title3.bold())
            Text("有效投入 \(Self.hm(c.effectiveMinutes))"
                 + (model.activeDayCount > 0 ? " · 已活跃使用 \(model.activeDayCount) 天" : ""))
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(theme.positiveTint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // 兑现红利：今日要紧事做成了 → 特写庆祝（🎯）；没做成的不出现（不罚、不留校）
    @ViewBuilder private func mitSection() -> some View {
        if !model.mitAccomplished.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.mitAccomplished, id: \.self) { title in
                    Label("想尽早的「\(title)」做成了", systemImage: "target")
                        .font(.headline).foregroundStyle(theme.positiveTint)   // 字阶收敛（C）：特写庆祝→headline 档
                }
            }
            .padding(10)
            .background(theme.positiveTint.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // 今日「最有价值的一件」轻自评（选了才显输入框；可写一句为什么）
    @ViewBuilder private func mvpSection() -> some View {
        @Bindable var model = model
        if let mvp = model.mvpTitle {
            VStack(alignment: .leading, spacing: 6) {
                // 换装 B/D：MVP=情感时刻 → 标题 accent+庆祝金底（celebrationTint，Jason 裁进色板）
                Label("今日最有价值：\(mvp)", systemImage: "trophy.fill")
                    .font(.headline).foregroundStyle(theme.accent)   // 字阶收敛（C）：卡标题→headline 档
                TextField("想写一句为什么？（可留空）", text: $model.mvpNote)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveMVPNote() }
            }
            .padding(10)
            .background(theme.celebrationTint.opacity(0.12))   // 庆祝金上户口（D，Jason 裁）
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
            // 去对比化：一律绿勾——计划外多做的不再用 sparkles/橙色单标（它和"计划"绑定，一标就把对比引回默认面）
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.positiveTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                Text(Self.calmPhrase(item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let m = item.actualMinutes { Text(Self.hm(m)).font(.caption).foregroundStyle(.secondary) }
            Button { model.toggleMVP(item.displayTitle) } label: {
                Image(systemName: isMVP ? "trophy.fill" : "trophy")
                    .foregroundStyle(isMVP ? theme.celebrationTint : .secondary)   // 庆祝金（D）
            }
            .buttonStyle(.plain)
            .help("设为今日最有价值的一件")
        }
        .padding(.vertical, 2)
        .background(isMVP ? theme.celebrationTint.opacity(0.14) : Color.clear)   // 庆祝金（D）
    }

    // MARK: 主动打开的「计划校准洞察」（去对比化：完整对比收这里，措辞朝前=帮下次排得更准，不打分）

    @ViewBuilder private func calibrationSection(_ c: DayComparison) -> some View {
        // 只在有可校准信息（计划外多做 或 计划里没排上）时出现；纯庆祝的日子不打扰
        if c.bonusCount > 0 || c.missedCount > 0 {
            let plannedDone = c.accomplishedCount - c.bonusCount
            let plannedTotal = plannedDone + c.missedCount
            DisclosureGroup(isExpanded: Binding(
                get: { model.showDetails }, set: { model.showDetails = $0 })
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    if plannedTotal > 0 {
                        Text("计划里的 \(plannedTotal) 件，完成了 \(plannedDone) 件。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // 计划外多做的（正向的一半）
                    ForEach(c.bonus) { item in
                        HStack {
                            Image(systemName: "plus.circle").foregroundStyle(theme.positiveTint)
                            Text(item.displayTitle)
                            Spacer()
                            Text("计划外多做的").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    // 计划里今天没排上的（朝前：帮你下次留时间/别排太满，不是评判）
                    ForEach(c.missed) { item in
                        HStack {
                            Image(systemName: "arrow.turn.up.right").foregroundStyle(.secondary)
                            Text(item.plannedTitle ?? "")
                            Spacer()
                            Text("今天没排上").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    Text("这页只帮你看清计划和现实的差，好让下次排得更准——不打分、不扣分。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Text("看看和计划的对照 · 帮下次排得更准").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 降级回填

    private var backfillSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            Text("补一笔今天做了什么").font(.headline)
            Text("\(Self.executionEntryName)没抓到的、或临时多做的，说一句补进蓝色「实际」。会合并、不覆盖已记录的。")   // 体检 #12
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                // 体检 #18：「对 AI 说话」的口统一穿 surface 纸面卡（同首页/长期页，条文5）
                TextField("例：下午临时读了篇论文一小时、晚上跑步半小时",
                          text: $model.backfillText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                Button { Task { await model.parseBackfill() } } label: {
                    Label("解析", systemImage: "wand.and.stars")
                }
                .tint(.primary)   // 体检 #10
                .disabled(model.isWorking)
            }

            if !model.backfillBlocks.isEmpty {
                List {
                    ForEach(model.backfillBlocks) { item in
                        // referenceDay=逻辑日标签（0.26.19）：凌晨块（0–4 点）显「次日」、跨午夜块显「至次日」
                        EditableRow(block: model.binding(for: item.id),
                                    referenceDay: DayContext.logicalStartOfDay(.now),
                                    onDelete: { model.deleteBackfill(id: item.id) })
                    }
                }
                .frame(minHeight: 140)

                HStack {
                    Button { model.addBackfillBlock() } label: { Label("加一项", systemImage: "plus") }
                        .font(.caption).tint(.primary)   // 体检 #10
                    Spacer()
                    Button { Task { await model.confirmBackfill() } } label: {
                        Label("写入实际日历", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
                }
            }

            if let n = model.backfillCommitted {
                Text("已补记 \(n) 项实际").font(.caption).foregroundStyle(theme.positiveTint)
            }
            if let err = model.errorText {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// 体检 #12：执行陪伴入口的跨端称呼（同一语义，两端载体不同）。
    static var executionEntryName: String {
        #if os(macOS)
        "menu bar "
        #else
        "「今天」页"
        #endif
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

    /// 默认复盘面用的中性措辞（去对比化：不提"计划外/比计划更多"这类把对比引回来的词，一律平权庆祝）。
    static func calmPhrase(_ item: ComparedItem) -> String {
        switch item.status {
        case .done:    return item.isContentChange ? "改做：\(item.plannedTitle ?? "")" : "完成"
        case .partial: return "做了一部分"
        case .over, .extra: return "完成"
        case .missed:  return "未做"   // 默认面不会出现 missed
        }
    }
}
