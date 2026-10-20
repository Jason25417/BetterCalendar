//
//  LongTermView.swift
//  BetterCalendar
//
//  长期 tab（#40 批1–3，2026-07-15；审计修正 2026-07-20）：第二时间尺度的家——跨日周期的任务管理页。
//  U1 主务=**说一句把长期的事收进来**（单一主务，2026-07-20 Jason 裁 D1-B）：本页是跨周期任务的
//  录入与整理现场；「排进今天」是次要动作（U2 论证：把任务排进今天的高频现场在排日程页，
//  那侧经「未来任务」行随时可达本页——本页的小音量 bordered small 与其频率相称）。
//  三分组：未来任务（展开）/先放下（折叠，捞回）/做成了（折叠，存档）。
//  红线（M10 管辖域修订后仍全周期生效）：无逾期红标/无百分比/无剩余量导向；投入只显 burnup；
//  主列表永不显差距（配额住详情页，不与投入并排——审计 #15，羞辱铁律）。
//

import SwiftUI

struct LongTermView: View {
    @Environment(\.appTheme) private var theme
    let store: LongTaskStore
    let router: AppRouter
    /// 解析器（#40 批3）：长期任务的**主入口=说一句**（同排日程 tab 的逻辑）；nil=只留手动兜底。
    var parser: ScheduleParsing?
    /// 说一句的「改现有」能力（2026-07-20 Jason 要求）：同一个框，模型判断是新增还是改现有；nil=只能新增。
    var refiner: LongTaskRefining?

    @State private var showShelved = false
    @State private var showDone = false
    // LLM 输入口状态：说 → 出草稿 → 用户逐条裁决 → 收下（工作台保留完整调整权，Jason 2026-07-15 定）
    @State private var sayText = ""
    @State private var parsing = false
    @State private var draft: [ParsedLongTask] = []
    @State private var draftUpdates: [LongTaskUpdate] = []   // 对现有任务的修改草稿
    @State private var parseError: String?

    var body: some View {
        NavigationStack {
            List {
                // ===== 在途 =====
                Section {
                    if store.items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("长期的事放这里").font(.headline)
                            // 审计 #16：空状态指向本页主入口（下方「说一句」），不再把人引去别的页
                            Text("考试、论文、想练的技能——不占今天的格子，但一直有人记得。在下面说一句「我要准备 GRE，10 月 8 号考」就会进来。")   // W31 自测：排日程页已不在（今天 / 智能体 / 长期 / 日记），删掉指向它的半句（P4 不让你找不存在的入口）
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(store.items) { task in
                        NavigationLink(value: task.id) {
                            taskCard(task)
                        }
                    }
                } header: {
                    // 审计 #17：术语统一「未来任务」（v0.16.2 已裁气质词「在途」不进 UI）
                    Text("未来任务 \(store.items.isEmpty ? "" : "\(store.items.count) 件")")
                }

                // ===== 说一句（#40 批3）：主入口=LLM 解析，工作台保留完整裁决权 =====
                Section {
                    if draft.isEmpty && draftUpdates.isEmpty {
                        // 审计 #3：与排日程页同语义的「对 AI 说话」口 → 同款 surface 纸面卡（12 圆角+描边），
                        // 提交钮内嵌右下；#14：进行中指示收进按钮自身，操作行不摆状态文字（U3）
                        VStack(alignment: .trailing, spacing: 8) {
                            TextField(store.items.isEmpty
                                      ? "说说这件长期的事…例：准备 GRE，10 月 8 号考，每周约 5 小时，分三个阶段：词汇、填空、写作"
                                      : "说一句——加新的，或改现有的。例：GRE 改到 11 月考 · 给论文加一个阶段：改格式",
                                      text: $sayText, axis: .vertical)
                                .lineLimit(2...5)
                                .textFieldStyle(.plain)
                                .persistedDraft($sayText, key: TextDraftKey.longtermSay)   // W29：重启后还在；收下草稿才清
                            Button { Task { await parseSaid() } } label: {
                                if parsing {
                                    Label { Text("理解中…") } icon: { ProgressView().controlSize(.small) }
                                        .font(.caption)
                                } else {
                                    Label("理解一下", systemImage: "wand.and.stars").font(.caption)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(parsing || sayText.trimmingCharacters(in: .whitespaces).isEmpty || parser == nil)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                        if let parseError {
                            Text(parseError).font(.caption).foregroundStyle(.orange)
                        }
                        // 审计 #11：手打兜底走全 App 统一的「＋ 加一项」尾行（InlineAddRow，登记件）
                        InlineAddRow(prompt: "手动加一件", placeholder: "这件长期的事叫…", draftKey: TextDraftKey.longtermAddManual) {
                            FeatureUsage.used(.longtermAddManual); store.add(title: $0)
                        }
                    } else {
                        // 草稿：每条可删；确认前不落库（代理而不代权——写入永远是用户的动作）
                        Text("理解成这样，对吗？").font(.headline)
                        // 审计 #19：兜底/提示在草稿分支也要可见——否则「替你兜底成纯标题」这个自动决定用户永远看不到
                        if let parseError {
                            Text(parseError).font(.caption).foregroundStyle(.secondary)
                        }
                        // 对现有任务的修改（与新增分开列，一眼看清「这是要改哪件」）
                        ForEach(draftUpdates) { u in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    // 审计 #4/#5：行标题=headline 档（不自造字重）；diff 标记非情感时刻，不吃 accent
                                    Label("改「\(u.targetTitle)」", systemImage: "pencil")
                                        .font(.headline).foregroundStyle(.primary)
                                    Spacer()
                                    Button {
                                        draftUpdates.removeAll { $0.id == u.id }
                                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("不要改「\(u.targetTitle)」这条")
                                }
                                Text(u.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        ForEach(draft) { d in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(d.title).font(.headline)   // 审计 #4：行标题=headline 档
                                    Spacer()
                                    Button {
                                        draft.removeAll { $0.id == d.id }
                                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("不要「\(d.title)」这条")
                                }
                                Text(draftSummary(d)).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        HStack {
                            Button("重说") {
                                FeatureUsage.abandonIfOpen(.longtermSay)   // W21：理解出草稿却没收下 = 没做完
                                draft = []; draftUpdates = []; parseError = nil
                            }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                commitDraft()
                            } label: {
                                Label("收下（\(draft.count + draftUpdates.count) 项）",
                                      systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.isEmpty && draftUpdates.isEmpty)
                        }
                        Text("收下之后还能改：进详情页调时间、加减阶段。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("说一句")   // 审计 #20：标题覆盖真实能力（加新的＋改现有的），与排日程页一框双模同族
                }

                // ===== 待办（E5a 一池两区）：小愿望 + 溢出顺延物 =====
                // 池铁律全继承：无维护义务、不显时间衰减/计数徽标、丢弃=溶解零愧疚。
                // 溢出物排前（晨间露脸序，E5d 接晨间摘要）；捕获口常驻（捕获零摩擦）。
                Section {
                    ForEach(store.todos) { entry in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title).font(.callout)
                                if entry.spilledFromDay != nil {
                                    // 中性来源事实，不写「没做完」（呈现红线：世界归因、无缺口措辞）
                                    Text("之前留下的").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("排今天") {
                                FeatureUsage.used(.longtermTodoToToday)
                                router.scheduleRequest = .insertLongTask(entry.id)
                                router.selectedTab = .schedule
                            }
                            .font(.caption).buttonStyle(.bordered).controlSize(.small)
                            .tint(.primary)
                            Button {
                                FeatureUsage.used(.longtermTodoDiscard)
                                store.discard(entry)
                            } label: { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .help("丢弃——想做的事可以不做，丢了就丢了")
                            .accessibilityLabel("丢弃「\(entry.title)」")
                        }
                        .padding(.vertical, 2)
                    }
                    InlineAddRow(prompt: "记一件想做的小事", placeholder: "想做的小事叫…", draftKey: TextDraftKey.longtermAddTodo) {
                        FeatureUsage.used(.longtermTodoAdd)
                        store.addTodo(title: $0)
                    }
                } header: {
                    Text("待办")
                }

                // ===== 先放下（捞回入口） =====
                let shelved = store.shelved()
                if !shelved.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showShelved) {
                            ForEach(shelved) { task in
                                HStack {
                                    Text(task.title).font(.callout)
                                    Spacer()
                                    Button("捞回来") { FeatureUsage.used(.longtermUnshelve); store.unshelve(task) }
                                        .font(.caption).buttonStyle(.bordered).controlSize(.small)
                                        .tint(.primary)   // 审计 #2：次要动作收中性
                                }
                            }
                        } label: {
                            Label("先放下的 \(shelved.count) 件", systemImage: "tray")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                // ===== 做成了（正反馈存档） =====
                let done = store.doneItems()
                if !done.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showDone) {
                            ForEach(done) { task in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(theme.positiveTint)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(task.title).font(.callout)
                                        Text((task.doneAt?.formatted(date: .abbreviated, time: .omitted) ?? "")
                                             + " · 共投入 \(ReviewSummaryText.hm(store.investedMinutes(for: task)))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    // D2-C（2026-07-20 Jason 裁）：做成了可逆——与「先放下」的捞回对齐，
                                    // 详情面的「做成了」按钮因此不再是破坏性动作（U10 距离不需要了）
                                    Button("拿回来") { FeatureUsage.used(.longtermReopen); store.reopen(task) }
                                        .font(.caption).buttonStyle(.bordered).controlSize(.small)
                                        .tint(.primary)
                                        .help("误标了、或还想继续做——拿回在途，投入记录都还在")
                                }
                            }
                        } label: {
                            Label("做成了 \(done.count) 件", systemImage: "checkmark.seal")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg.ignoresSafeArea())   // 审计 #1（条文1）：微暖页底——此前是四 tab 里唯一漏掉的
            .navigationTitle("长期")
            .navigationDestination(for: UUID.self) { id in
                if let task = store.items.first(where: { $0.id == id }) {
                    LongTaskDetailView(store: store, router: router, task: task)
                        .onAppear { FeatureUsage.used(.longtermDetail) }
                } else {
                    Text("这件事已不在列表里").foregroundStyle(.secondary)   // 审计 #17：术语
                }
            }
            .onAppear {
                store.reload()
                FeatureUsage.seen(.longtermPage)
                // 埋点（调研）：长期页访问频率——按天去重，用于观察第二尺度的真实使用强度
                BehaviorLog.recordOncePerDay(key: "长期页", "长期页", "打开（在途 \(store.items.count) 件）")
            }
        }
    }

    /// 说一句 → 解析成长期任务草稿（#40 批3）。复用排日程同一条解析链：
    /// 长期语义天然落 `longTasks`（prompt 既有规则），这里只取 longTasks、丢弃当日块。
    /// 说一句 → 草稿（2026-07-20 起**双模**：有 refiner 且池非空 → 走「加新的/改现有的」链；
    /// 否则退回纯解析链（只新增）。与排日程页「一框双模」对称。
    private func parseSaid() async {
        let text = sayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        parsing = true; parseError = nil
        defer { parsing = false }

        if let refiner, !store.items.isEmpty {
            let existing = store.items.map {
                LongTaskContext(title: $0.title, deadline: $0.deadline,
                                cadenceMinutesPerWeek: $0.cadenceMinutesPerWeek,
                                totalMinutes: $0.totalMinutes,
                                checkpoints: $0.sortedCheckpoints.map(\.title))
            }
            do {
                let edit = try await refiner.refine(text: text, existing: existing, now: .now)
                if edit.isEmpty {
                    parseError = "没太听懂想加什么或改什么——换句话再说一遍？"
                } else {
                    draft = edit.creates
                    draftUpdates = edit.updates
                    FeatureUsage.begin(.longtermSay)
                }
                return
            } catch {
                DevLog.shared.warn("长期", "AI 调整失败，回退纯解析：\(error.localizedDescription)")
                // 不 return：落到下面的纯解析链兜底（至少还能新增）
            }
        }

        guard let parser else {
            // 审计 #23：禁「只」+ 给下一步（前向措辞）
            parseError = "云端还没配置——先用下面的手动入口加进来；配好之后说一句就能自动理解了。"
            return
        }
        do {
            let plan = try await parser.parse(text, referenceDate: .now, context: ParseContext())
            if plan.longTasks.isEmpty {
                // 一件长期事项都没识别出来 → 兜底成一条纯标题（不让用户白说一遍）
                parseError = "没太听出时间设定——先按一件事收着，你可以在详情页补。"
                draft = [ParsedLongTask(title: text)]
            } else {
                draft = plan.longTasks
            }
            FeatureUsage.begin(.longtermSay)
        } catch {
            FeatureUsage.record(.longtermSay, .failed)
            parseError = "没能理解（\(error.localizedDescription)）——可以再说一遍，或用下面的手打入口。"
            DevLog.shared.warn("长期", "解析失败：\(error.localizedDescription)")
        }
    }

    /// 草稿收下：新增逐条入池（幂等）+ 修改逐条应用 + 阶段落库；写入是用户的动作（代理而不代权）。
    private func commitDraft() {
        for d in draft {
            let task = store.add(title: d.title, deadline: d.deadline,
                                 cadenceMinutesPerWeek: d.cadenceMinutesPerWeek,
                                 totalMinutes: d.totalMinutes, unitMinutes: d.unitMinutes)
            let existing = Set(task.sortedCheckpoints.map(\.title))
            for name in d.checkpoints where !existing.contains(name) {
                store.addCheckpoint(to: task, title: name)
            }
        }
        // 修改现有任务（按标题相似匹配；匹配不到就跳过——绝不误改别的任务）
        var appliedUpdates = 0
        for u in draftUpdates {
            guard let task = store.items.first(where: { TitleMatch.similarity($0.title, u.targetTitle) >= 0.6 })
            else { continue }
            store.update(task, title: u.newTitle, note: nil,
                         deadline: u.deadline,
                         cadenceMinutesPerWeek: u.cadenceMinutesPerWeek,
                         totalMinutes: u.totalMinutes,
                         unitMinutes: nil)
            let have = Set(task.sortedCheckpoints.map(\.title))
            for name in u.addCheckpoints where !have.contains(name) {
                store.addCheckpoint(to: task, title: name)
            }
            appliedUpdates += 1
        }
        DevLog.shared.info("长期", "说一句：新增 \(draft.count) 件 · 修改 \(appliedUpdates) 件")
        BehaviorLog.record("长期页", "说一句收下 新增\(draft.count)/改\(appliedUpdates)"
                           + (draft.contains { !$0.checkpoints.isEmpty } ? "（含阶段）" : ""))
        FeatureUsage.complete(.longtermSay)
        draft = []; draftUpdates = []; sayText = ""; parseError = nil
        TextDraftStore.shared.clear(TextDraftKey.longtermSay)   // W29：收下了才清（输入框此刻不在屏上，直接清存储）
    }

    /// 草稿摘要行：把解析到的三量与阶段摊开给用户核对。
    private func draftSummary(_ d: ParsedLongTask) -> String {
        var parts: [String] = []
        if let dl = d.deadline { parts.append("DDL \(dl.formatted(.dateTime.month().day()))") }
        if let c = d.cadenceMinutesPerWeek { parts.append("每周约 \(ReviewSummaryText.hm(c))") }
        if let t = d.totalMinutes { parts.append("共约 \(ReviewSummaryText.hm(t))") }
        if !d.checkpoints.isEmpty { parts.append("阶段：" + d.checkpoints.joined(separator: " → ")) }
        return parts.isEmpty ? "没有时间设定（之后可在详情页补）" : parts.joined(separator: " · ")
    }

    // 任务卡：标题 + 进度（三模式各自口径）+ 增长条 + DDL（中性陈述）
    // 审计 #15（羞辱铁律）：配额不进主列表——「每周约 Y · 已投入 X」并排=让用户自己算缺口；
    // 卡上只留 burnup 事实，配额住详情页「时间设定」区。
    @ViewBuilder private func taskCard(_ task: LongTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(task.title).font(.headline)
                Spacer()
                // 审计 #2/#13：次要动作收中性（条文2 橙音量）；文案图标与详情面/L3 条同族（U7）
                Button { insertToToday(task) } label: {
                    Label("排进今天", systemImage: "calendar.badge.plus").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .tint(.primary)
            }
            let progress = store.progressText(for: task)
            if !progress.isEmpty {
                Text(progress).font(.caption).foregroundStyle(theme.positiveTint)
            }
            if let f = store.progressFraction(for: task) {
                InvestedBar(fraction: f)   // 审计 #6/#12：burnup 条统一为登记件
            }
            HStack(spacing: 8) {
                if let d = task.deadline {
                    Text("DDL \(d.formatted(.dateTime.month(.defaultDigits).day()))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                let week = store.investedThisWeek(for: task)
                if week > 0 {
                    Text("近 7 天已投入 \(ReviewSummaryText.hm(week))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func insertToToday(_ task: LongTask) {
        FeatureUsage.used(.longtermTaskToToday)
        router.scheduleRequest = .insertLongTask(task.id)
        router.selectedTab = .schedule
    }
}

// MARK: - 详情面（批1：基本+三量编辑+操作；批2 加检查点清单与联动推算）

struct LongTaskDetailView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let store: LongTaskStore
    let router: AppRouter
    let task: LongTask

    // 三量的编辑态（开关+值；关=清空该量——显式表单语义）
    @State private var title: String = ""
    @State private var note: String = ""
    @State private var hasDeadline = false
    @State private var deadline: Date = .now
    @State private var hasCadence = false
    @State private var cadenceMinutes = 300
    @State private var hasTotal = false
    @State private var totalMinutes = 600
    @State private var celebratingCheckpoint: String?

    var body: some View {
        Form {
            Section("这件事") {
                TextField("标题", text: $title)
                    .onSubmit { save() }
                TextField("备注（可留空）", text: $note, axis: .vertical)
                    .lineLimit(1...3)
            }

            Section("时间设定（都可不设——不设就只记投入）") {
                Toggle("截止（DDL）", isOn: $hasDeadline)
                if hasDeadline {
                    DatePicker("哪天前", selection: $deadline, displayedComponents: .date)
                }
                Toggle("每周投入节奏", isOn: $hasCadence)
                if hasCadence {
                    Stepper("每周约 \(ReviewSummaryText.hm(cadenceMinutes))",
                            value: $cadenceMinutes, in: 30...2400, step: 30)
                }
                Toggle("总量估算", isOn: $hasTotal)
                if hasTotal {
                    Stepper("大约共 \(ReviewSummaryText.hm(totalMinutes))",
                            value: $totalMinutes, in: 60...30000, step: 60)
                    Text("估个初值就够——做起来自然会准。")   // 审计 #18：实现术语不进用户文案
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("已投入") {
                let invested = store.investedMinutes(for: task)
                let week = store.investedThisWeek(for: task)
                Text("累计 \(ReviewSummaryText.hm(invested))"
                     + (week > 0 ? " · 近 7 天 \(ReviewSummaryText.hm(week))" : ""))
                    .font(.callout).foregroundStyle(theme.positiveTint)
                if let f = store.progressFraction(for: task) {
                    InvestedBar(fraction: f)   // 审计 #6/#12：burnup 条统一为登记件
                }
            }

            // ===== 检查点（批 2）：命名阶段——只此一层、只有顺序、无各自 DDL（红线）=====
            Section {
                let cps = task.sortedCheckpoints
                ForEach(cps) { cp in
                    HStack(spacing: 10) {
                        Button {
                            let wasDone = cp.doneAt != nil
                            store.toggleCheckpoint(cp)
                            if !wasDone {
                                celebrate(cp)   // 勾上=轻庆祝（庆祝白名单）；取消勾不庆祝也不惩罚
                                BehaviorLog.record("长期页", "勾选阶段")
                                FeatureUsage.used(.longtermCheckpoint, "详情页")
                            }
                        } label: {
                            Image(systemName: cp.doneAt != nil ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(cp.doneAt != nil ? theme.positiveTint : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(cp.doneAt != nil ? "取消「\(cp.title)」的推进标记" : "标记推进到「\(cp.title)」")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cp.title)
                                .foregroundStyle(cp.doneAt != nil ? .secondary : .primary)
                            if let m = cp.estimatedMinutes {
                                Text("约 \(ReviewSummaryText.hm(m))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if cp.id == task.nextCheckpoint?.id {
                            // 审计 #5：accent=尽早 tag 专用（微决策区），「下一个」是计划语义 → plannedTint
                            Text("下一个").font(.caption2).foregroundStyle(theme.plannedTint)
                        }
                    }
                    // 审计 #24（U9）：删除必须有可达控件——contextMenu 双端可用、带完整标签；
                    // .onDelete 保留作 iOS 侧滑快捷方式（macOS 上手势不可达，曾是全项目唯一无控件删除）
                    .contextMenu {
                        Button(role: .destructive) {
                            store.deleteCheckpoint(cp)
                        } label: { Label("删除阶段「\(cp.title)」", systemImage: "trash") }
                    }
                }
                .onDelete { idx in
                    idx.map { cps[$0] }.forEach { store.deleteCheckpoint($0) }
                }
                .onMove { from, to in
                    var arr = cps
                    arr.move(fromOffsets: from, toOffset: to)
                    store.reorderCheckpoints(task, ordered: arr)
                }
                // 审计 #11：就地新增走统一「＋ 加一项」尾行（InlineAddRow 登记件）
                InlineAddRow(prompt: "加一个阶段", placeholder: "如「第 3 章 测度论」", draftKey: TextDraftKey.checkpointAdd(task.id)) {
                    store.addCheckpoint(to: task, title: $0)
                }
                if celebratingCheckpoint != nil {
                    HStack(spacing: 8) {
                        CelebrationBurst()
                        Text("推进到「\(celebratingCheckpoint ?? "")」了").font(.callout)
                    }
                }
            } header: {
                Text("分阶段（可不分）")
            } footer: {
                Text("阶段只有顺序、不设各自的截止——排进今天时会自动带上「下一个」，做完点一下就好。")
            }

            // ===== 联动推算（批 2）：只填空缺的格子——用户设了的量以用户为准（Jason 2026-07-15 定）=====
            if let line = projectionLine {
                Section {
                    Text(line).font(.callout).foregroundStyle(.secondary)
                } header: {
                    Text("按现在的设定")
                }
            }

            Section {
                Button {
                    FeatureUsage.used(.longtermTaskToToday, "详情页")
                    router.scheduleRequest = .insertLongTask(task.id)
                    router.selectedTab = .schedule
                    dismiss()
                } label: {
                    Label("排进今天", systemImage: "calendar.badge.plus")   // 审计 #21：同一动作同一文案；实现口径不进标签
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                // 视觉轮 V1（2026-07-20 dark 截图实锤）：审计 #2 漏网点位——这两颗曾被全局 tint 染橙，
                // 同屏三橙违条文2。做成了=绿族语义（不占彩色预算），先放下=中性。
                Button { FeatureUsage.used(.longtermComplete); store.complete(task); dismiss() } label: {
                    Label("做成了", systemImage: "checkmark.seal.fill")   // 审计 #22：Form 系统场域不用 emoji（条文9）
                }
                .tint(theme.positiveTint)
                Button("先放下（随时捞回）") { FeatureUsage.used(.longtermShelve); store.shelve(task); dismiss() }
                    .tint(.primary)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(task.title)
        .onAppear { load() }
        .onChange(of: hasDeadline) { _, _ in save() }
        .onChange(of: deadline) { _, _ in save() }
        .onChange(of: hasCadence) { _, _ in save() }
        .onChange(of: cadenceMinutes) { _, _ in save() }
        .onChange(of: hasTotal) { _, _ in save() }
        .onChange(of: totalMinutes) { _, _ in save() }
        .onChange(of: note) { _, _ in save() }
    }

    /// 勾上检查点 → 轻庆祝（2.5s 自动收；庆祝白名单内，无音无通知）。
    private func celebrate(_ cp: LongTaskCheckpoint) {
        celebratingCheckpoint = cp.title
        let name = cp.title
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if celebratingCheckpoint == name { celebratingCheckpoint = nil }
        }
    }

    /// 联动推算（**只填空缺的格子**，Jason 2026-07-15 裁）：三量知二推一；
    /// 用户显式设了的量以用户为准、不替他推。措辞红线：只说可行路径，绝不说差距（禁「落后/还差」）。
    private var projectionLine: String? {
        let invested = store.investedMinutes(for: task)
        let remaining = max(0, (task.totalMinutes ?? 0) - invested)
        // ① 有 DDL + 总量、缺配额 → 推「每周约需」
        if let ddl = task.deadline, task.totalMinutes != nil, task.cadenceMinutesPerWeek == nil {
            let weeks = max(0.2, ddl.timeIntervalSince(.now) / (7 * 24 * 3600))
            guard remaining > 0 else { return "总量已经投够了——想收尾就点「做成了」。" }
            let perWeek = Int(Double(remaining) / weeks)
            return "想在 \(ddl.formatted(.dateTime.month().day())) 前完成，每周约需 \(ReviewSummaryText.hm(perWeek))。"
        }
        // ② 有配额 + 总量、缺 DDL → 推「大约何时完成」
        if let cadence = task.cadenceMinutesPerWeek, cadence > 0, task.totalMinutes != nil, task.deadline == nil {
            guard remaining > 0 else { return "总量已经投够了——想收尾就点「做成了」。" }
            let weeks = Double(remaining) / Double(cadence)
            let eta = Calendar.current.date(byAdding: .day, value: Int(weeks * 7), to: .now) ?? .now
            return "按每周 \(ReviewSummaryText.hm(cadence)) 的节奏，大约到 \(eta.formatted(.dateTime.month().day())) 做完。"
        }
        // ③ 三量都设了 → 不推算（用户说了算），只在「按这个节奏会晚于 DDL」时给一条可行路径
        if let ddl = task.deadline, let cadence = task.cadenceMinutesPerWeek, cadence > 0,
           task.totalMinutes != nil, remaining > 0 {
            let weeksNeeded = Double(remaining) / Double(cadence)
            let eta = Calendar.current.date(byAdding: .day, value: Int(weeksNeeded * 7), to: .now) ?? .now
            if eta > ddl {
                let weeksLeft = max(0.2, ddl.timeIntervalSince(.now) / (7 * 24 * 3600))
                let need = Int(Double(remaining) / weeksLeft)
                return "按现在的节奏大约到 \(eta.formatted(.dateTime.month().day()))——想赶上 \(ddl.formatted(.dateTime.month().day())) 的话，每周约需 \(ReviewSummaryText.hm(need))；也可以改期或先放下。"
            }
        }
        return nil
    }

    private func load() {
        title = task.title
        note = task.note
        hasDeadline = task.deadline != nil
        deadline = task.deadline ?? Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
        hasCadence = task.cadenceMinutesPerWeek != nil
        cadenceMinutes = task.cadenceMinutesPerWeek ?? 300
        hasTotal = task.totalMinutes != nil
        totalMinutes = task.totalMinutes ?? 600
    }

    private func save() {
        store.update(task,
                     title: title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title,
                     note: note,
                     deadline: hasDeadline ? deadline : .some(nil),
                     cadenceMinutesPerWeek: hasCadence ? cadenceMinutes : .some(nil),
                     totalMinutes: hasTotal ? totalMinutes : .some(nil),
                     unitMinutes: task.unitMinutes)   // 单元时长批1不动（详情编辑批2 随检查点一起理）
    }
}
