//
//  JournalView.swift
//  BetterCalendar
//
//  反思层（日记）标签页：上面「写下今天」、下面历史时间轴、点开编辑（套 BetterTranscribe 的 实时+历史 模式）。
//  正文格式走接口（AppSettings.defaultEditorFormat）：开发期 Markdown（TextEditor 纯文本编辑）；
//  上线再加富文本分支，见 SPEC §9。
//

import SwiftUI
import UniformTypeIdentifiers
import LocalAuthentication
#if canImport(AppKit)
import AppKit
#endif

let journalMoods = ["😊", "😌", "😐", "😔", "😤", "🥳", "😴", "🤔"]

#if !os(macOS)
/// iOS 分享用：日记 markdown 导出文件（ShareLink）。
struct MarkdownDocument: Transferable {
    let text: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) {
            Data($0.text.utf8)
        }
        .suggestedFileName("BetterCalendar日记.md")
    }
}
#endif

/// 日记页所需依赖（组装点 AppContainer 构造；View 不见 AppContainer——反向依赖清零 2026-07-12）。
struct JournalDeps {
    let journalStore: JournalStore
    let milestones: MilestoneStore
    let photoStore: PhotoStore
    let reflectionContext: ReflectionContextProvider
    let router: AppRouter
    let makeReviewModel: () -> ReviewViewModel   // 复盘头 VM 工厂（每次进视图新建，同原 container.reviewModel）
}

struct JournalView: View {
    let deps: JournalDeps
    @State private var model: JournalViewModel
    @State private var today: JournalEntry?
    @State private var todayPrompt: String?   // 第一方情境引子（来自当天 PlanComparing）
    @State private var unlocked = false       // 隐私锁（R5）：本次前台会话是否已解锁
    @State private var authFailedHint: String?
    @Environment(\.scenePhase) private var scenePhase

    init(deps: JournalDeps) {
        self.deps = deps
        _model = State(initialValue: JournalViewModel(store: deps.journalStore))
    }

    private var locked: Bool { JournalSettings.privacyLock && !unlocked }

    var body: some View {
        NavigationStack {
            Group {
                if locked {
                    lockedView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            reviewHeader
                            // 成就静默解锁（#27）：零通知——只在日记页安静出一条，点 ✕ 收起；全景在工具栏 🏅
                            ForEach(deps.milestones.freshlyUnlocked) { m in
                                MessageStrip(icon: "seal.fill", tint: .orange,
                                             text: "\(m.title)——\(m.line)") {
                                    Button { deps.milestones.acknowledgeFresh() } label: {
                                        Image(systemName: "xmark").font(.caption2)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                            }
                            todayCard
                            onThisDayCard
                            Divider()
                            historySection
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("日记")
            .toolbar {
                if !locked {
                    ToolbarItem(placement: .primaryAction) { exportButton }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink { AchievementsView(store: deps.milestones) } label: {
                            Label("成就", systemImage: "seal")
                        }
                        .help("累计里程碑——只做加法，没有断签")
                    }
                }
            }
            .navigationDestination(for: JournalEntry.self) { e in
                JournalDetailView(entry: e, model: model, photoStore: deps.photoStore)
            }
        }
        .onAppear {
            if locked { unlock() }
            openTodayIfNeeded()
            deps.milestones.refresh()   // 成就检查（天级节奏：进日记页时看看有没有新点亮）
        }
        .onChange(of: scenePhase) { _, phase in
            // 退后台自动重新上锁（下次回前台需再解锁）
            if phase == .background, JournalSettings.privacyLock { unlocked = false }
        }
        .onChange(of: deps.router.journalRequest) { _, req in
            guard req != nil else { return }
            if locked { unlock() }
            today = model.todayEntry()
            loadPrompt()
            deps.router.journalRequest = nil   // 消费掉
        }
    }

    // MARK: 隐私锁（R5）

    private var lockedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("日记已上锁").font(.headline)
            Button { unlock() } label: {
                Label("解锁日记", systemImage: "faceid")
            }
            .buttonStyle(.borderedProminent)
            if let hint = authFailedHint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func unlock() {
        let ctx = LAContext()
        var err: NSError?
        // 设备没设任何锁 → 直接放行（别把用户永久锁在外面）
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            unlocked = true
            return
        }
        Task {
            do {
                let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: "解锁日记")
                unlocked = ok
                authFailedHint = ok ? nil : "没认出来，再试一次"
            } catch {
                authFailedHint = "已取消 · 点「解锁日记」重试"
            }
        }
    }

    private func openTodayIfNeeded() {
        if today == nil { today = model.todayEntry() }
        loadPrompt()
    }
    private func loadPrompt() {
        Task { todayPrompt = await deps.reflectionContext.todayPrompt() }
    }

    // MARK: 复盘头（0.28 提案A：复盘并入日记页，时刻驱动出现——过收工线才展开，白天不打扰）

    @State private var showReviewNow = false

    private var isEveningTime: Bool { Date.now >= WorkHoursSettings.effectiveWindDown(from: .now) }

    @ViewBuilder private var reviewHeader: some View {
        if isEveningTime || showReviewNow {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("回看今天", systemImage: "sunset").font(.headline)
                    Spacer()
                    // 自动日记（0.28，Jason 设想）：15–30 秒最低闭环——本地模板生成简短鼓励型正文
                    //（不出云、瞬时）；与手写明显区分（首行 🤖 标记 + 「自动日记」标签）。
                    Button { Task { await applyAutoJournal() } } label: {
                        Label("自动日记", systemImage: "wand.and.stars")
                    }
                    .help("用今天的做成记录自动生成一篇简短日记（可再编辑；与手写内容明显区分）")
                }
                ReviewPanel(model: deps.makeReviewModel())
            }
            .padding()
            .background(Color.orange.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onAppear {   // 埋点（调研 B 组）：复盘头展开方式（自动=过收工线 / 手动提前），按天去重
                BehaviorLog.recordOncePerDay(key: "复盘头", "复盘头",
                                             "展开·\(isEveningTime ? "自动（过收工线）" : "手动提前")")
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "sun.max").foregroundStyle(.secondary)
                Text("今天还在进行——晚上回来回看这一天").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("现在就回看") { showReviewNow = true }
                    .font(.caption).buttonStyle(.plain).underline().foregroundStyle(.secondary)
            }
        }
    }

    /// 自动日记落笔：正文空 → 填入；已有手写 → 追加在后（空行分隔）；打「自动日记」标签。
    private func applyAutoJournal() async {
        guard let text = await deps.reflectionContext.autoJournalText() else {
            authFailedHint = nil
            todayPrompt = "今天还没有做成记录——开始一件事，自动日记就有素材了。"
            return
        }
        let e = today ?? model.todayEntry()
        if e.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { e.body = text }
        else { e.body += "\n\n" + text }
        if !e.tags.contains("自动日记") { e.tags.append("自动日记") }
        e.modifiedAt = .now
        model.save()
        today = e
        BehaviorLog.record("自动日记", "生成 \(text.count) 字")
    }

    @ViewBuilder private var todayCard: some View {
        if let e = today {
            VStack(alignment: .leading, spacing: 8) {
                Text("写下今天").font(.headline)
                if let prompt = todayPrompt {
                    Label(prompt, systemImage: "sparkles")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                JournalEditor(entry: e, model: model, photoStore: deps.photoStore)
                // 功能说明（非提示催写，Jason 2026-07-10 定）：只告知能力存在，绝不出现「你还没写给明天」。
                // 0.34.1（Jason 定）：开写就收起——正文有任何内容时这行说明消失，不占注意力。
                if e.body.isEmpty {
                    Text("小知识：写一行「给明天：……」，明早会替你带给明天的自己。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding()
            .background(Color.purple.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// 「往年今天」（R5）：有往年同月同日的日记就轻轻放一张卡，点开重温。内测头一年自然不出现。
    @ViewBuilder private var onThisDayCard: some View {
        if let e = model.onThisDay() {
            NavigationLink(value: e) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("往年今天 · \(e.date.formatted(date: .abbreviated, time: .omitted)) \(e.mood ?? "")")
                            .font(.subheadline.bold())
                        Text(e.body.isEmpty ? "（只记了心情）" : e.body)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(Color.purple.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    /// 导出全部日记为 markdown（R5）：macOS 存盘 / iOS 分享。
    @ViewBuilder private var exportButton: some View {
        #if os(macOS)
        Button { exportMarkdown() } label: { Label("导出日记", systemImage: "square.and.arrow.up") }
            .help("把全部日记导出为 Markdown 文件")
        #else
        ShareLink(item: MarkdownDocument(text: model.exportMarkdown()),
                  preview: SharePreview("BetterCalendar 日记.md")) {
            Label("导出日记", systemImage: "square.and.arrow.up")
        }
        #endif
    }

    #if os(macOS)
    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "BetterCalendar日记.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? model.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }
    #endif

    private var historySection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("历史").font(.headline)
                Spacer()
                TextField("搜索", text: $model.searchText)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    .onChange(of: model.searchText) { _, _ in model.reload() }
            }
            if model.history.isEmpty {
                Text(model.entries.isEmpty
                     ? "还没有日记。在上面「写下今天」就好。"
                     : "今天的日记在上面 ✏️ · 改动自动保存；往后每天的会按时间出现在这里。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(model.history) { e in
                    NavigationLink(value: e) { JournalRow(entry: e) }
                        .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

/// 心情选择（emoji 轻量表，再点同一个=取消）。
struct MoodPicker: View {
    @Binding var mood: String?
    var body: some View {
        HStack(spacing: 6) {
            ForEach(journalMoods, id: \.self) { m in
                Text(m)
                    .font(.title3)
                    .opacity(mood == m ? 1 : 0.4)
                    .scaleEffect(mood == m ? 1.15 : 1)
                    .onTapGesture { mood = (mood == m) ? nil : m }
            }
        }
    }
}

/// 历史一行：日期 + 心情 + 正文摘要。
struct JournalRow: View {
    let entry: JournalEntry
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.mood ?? "·").font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.bold())
                Text(entry.body.isEmpty ? "（只记了心情）" : entry.body)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// 历史条目详情/编辑。
struct JournalDetailView: View {
    @Bindable var entry: JournalEntry
    let model: JournalViewModel
    let photoStore: PhotoStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            JournalEditor(entry: entry, model: model, photoStore: photoStore)
                .padding()
        }
        .navigationTitle(entry.date.formatted(date: .abbreviated, time: .omitted))
        .toolbar {
            Button(role: .destructive) { model.delete(entry); dismiss() } label: {
                Image(systemName: "trash")
            }
        }
    }
}
