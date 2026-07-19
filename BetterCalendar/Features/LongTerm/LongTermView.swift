//
//  LongTermView.swift
//  BetterCalendar
//
//  长期 tab（#40 批1，2026-07-15）：第二时间尺度的家——跨日周期的排程态。
//  U1 主务=看长期任务的健康 + 把下一步排进今天。三分组：在途（展开）/先放下（折叠，捞回）/做成了（折叠，存档）。
//  红线（M10 管辖域修订后仍全周期生效）：无逾期红标/无百分比/无剩余量导向；投入只显 burnup。
//  批 2 待接：检查点清单 UI/联动推算/收尾轻问；批 3：LLM 解析入口（主入口=说一句，工作台=本页）。
//

import SwiftUI

struct LongTermView: View {
    @Environment(\.appTheme) private var theme
    let store: LongTaskStore
    let router: AppRouter

    @State private var newTitle = ""
    @State private var showShelved = false
    @State private var showDone = false

    var body: some View {
        NavigationStack {
            List {
                // ===== 在途 =====
                Section {
                    if store.items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("长期的事放这里").font(.headline)
                            Text("考试、论文、想练的技能——不占今天的格子，但一直有人记得。在排日程页说一句「我要准备 GRE，10 月考」就会自动进来；也可以在下面直接添加。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(store.items) { task in
                        NavigationLink(value: task.id) {
                            taskCard(task)
                        }
                    }
                    HStack {
                        TextField("加一件长期的事…", text: $newTitle)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addNew() }
                        Button("加入") { addNew() }
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("在途 \(store.items.isEmpty ? "" : "\(store.items.count) 件")")
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
                                    Button("捞回来") { store.unshelve(task) }
                                        .font(.caption).buttonStyle(.bordered).controlSize(.small)
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
                                }
                            }
                        } label: {
                            Label("做成了 \(done.count) 件", systemImage: "checkmark.seal")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("长期")
            .navigationDestination(for: UUID.self) { id in
                if let task = store.items.first(where: { $0.id == id }) {
                    LongTaskDetailView(store: store, router: router, task: task)
                } else {
                    Text("这件事已不在途").foregroundStyle(.secondary)
                }
            }
            .onAppear { store.reload() }
        }
    }

    private func addNew() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.add(title: t)
        newTitle = ""
    }

    // 任务卡：标题 + 进度（三模式各自口径）+ 增长条 + DDL/配额（中性陈述）
    @ViewBuilder private func taskCard(_ task: LongTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(task.title).font(.headline)
                Spacer()
                Button("排进今天") { insertToToday(task) }
                    .font(.caption).buttonStyle(.bordered).controlSize(.small)
            }
            let progress = store.progressText(for: task)
            if !progress.isEmpty {
                Text(progress).font(.caption).foregroundStyle(theme.positiveTint)
            }
            if let f = store.progressFraction(for: task) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 3)
                        Capsule().fill(theme.positiveTint).frame(width: geo.size.width * f, height: 3)
                    }
                }
                .frame(height: 3)
            }
            HStack(spacing: 8) {
                if let d = task.deadline {
                    Text("DDL \(d.formatted(.dateTime.month(.defaultDigits).day()))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let c = task.cadenceMinutesPerWeek {
                    let week = store.investedThisWeek(for: task)
                    Text("每周约 \(ReviewSummaryText.hm(c))"
                         + (week > 0 ? " · 近 7 天已投入 \(ReviewSummaryText.hm(week))" : ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func insertToToday(_ task: LongTask) {
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
    @State private var newCheckpoint = ""
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
                    Text("估个初值就够——我们是闭环系统，边做边准。")
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
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(height: 4)
                            Capsule().fill(theme.positiveTint).frame(width: geo.size.width * f, height: 4)
                        }
                    }
                    .frame(height: 4)
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
                            if !wasDone { celebrate(cp) }   // 勾上=轻庆祝（庆祝白名单）；取消勾不庆祝也不惩罚
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
                            Text("下一个").font(.caption2).foregroundStyle(theme.accent)
                        }
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
                HStack {
                    TextField("加一个阶段（如「第 3 章 测度论」）", text: $newCheckpoint)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addCheckpoint() }
                    Button("加入") { addCheckpoint() }
                        .disabled(newCheckpoint.trimmingCharacters(in: .whitespaces).isEmpty)
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
                    router.scheduleRequest = .insertLongTask(task.id)
                    router.selectedTab = .schedule
                    dismiss()
                } label: {
                    Label("排进今天（智能插空档）", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("做成了 🎉") { store.complete(task); dismiss() }
                Button("先放下（随时捞回）") { store.shelve(task); dismiss() }
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

    private func addCheckpoint() {
        store.addCheckpoint(to: task, title: newCheckpoint)
        newCheckpoint = ""
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
