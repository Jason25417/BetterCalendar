//
//  JournalView.swift
//  BetterCalendar
//
//  反思层（日记）标签页：上面「写下今天」、下面历史时间轴、点开编辑（套 BetterTranscribe 的 实时+历史 模式）。
//  正文格式走接口（AppSettings.defaultEditorFormat）：开发期 Markdown（TextEditor 纯文本编辑）；
//  上线再加富文本分支，见 SPEC §9。
//

import SwiftUI

let journalMoods = ["😊", "😌", "😐", "😔", "😤", "🥳", "😴", "🤔"]

struct JournalView: View {
    let container: AppContainer
    @State private var model: JournalViewModel
    @State private var today: JournalEntry?
    @State private var todayPrompt: String?   // 第一方情境引子（来自当天 PlanComparing）

    init(container: AppContainer) {
        self.container = container
        _model = State(initialValue: JournalViewModel(store: container.journalStore))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    todayCard
                    Divider()
                    historySection
                }
                .padding()
            }
            .navigationTitle("日记")
            .navigationDestination(for: JournalEntry.self) { e in
                JournalDetailView(entry: e, model: model, photoStore: container.photoStore)
            }
        }
        .onAppear { openTodayIfNeeded() }
        .onChange(of: container.router.journalRequest) { _, req in
            guard req != nil else { return }
            today = model.todayEntry()
            loadPrompt()
            container.router.journalRequest = nil   // 消费掉
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
                Text("还没有历史日记").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
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
