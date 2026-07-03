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

struct JournalView: View {
    let container: AppContainer
    @State private var model: JournalViewModel
    @State private var today: JournalEntry?
    @State private var todayPrompt: String?   // 第一方情境引子（来自当天 PlanComparing）
    @State private var unlocked = false       // 隐私锁（R5）：本次前台会话是否已解锁
    @State private var authFailedHint: String?
    @Environment(\.scenePhase) private var scenePhase

    init(container: AppContainer) {
        self.container = container
        _model = State(initialValue: JournalViewModel(store: container.journalStore))
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
                }
            }
            .navigationDestination(for: JournalEntry.self) { e in
                JournalDetailView(entry: e, model: model, photoStore: container.photoStore)
            }
        }
        .onAppear {
            if locked { unlock() }
            openTodayIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            // 退后台自动重新上锁（下次回前台需再解锁）
            if phase == .background, JournalSettings.privacyLock { unlocked = false }
        }
        .onChange(of: container.router.journalRequest) { _, req in
            guard req != nil else { return }
            if locked { unlock() }
            today = model.todayEntry()
            loadPrompt()
            container.router.journalRequest = nil   // 消费掉
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
        Task { todayPrompt = await container.reflectionContext.todayPrompt() }
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
                JournalEditor(entry: e, model: model, photoStore: container.photoStore)
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
