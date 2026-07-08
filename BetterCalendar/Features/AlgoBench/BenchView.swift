//
//  BenchView.swift
//  BetterCalendar
//
//  算法试验台窗口（macOS，开发期）：用例 × 变体 跑分——左侧用例列表（各变体结果灯），
//  右侧明细（断言/候补/prompt/原始返回）。导出 markdown 到剪贴板。
//  上架前随「开发期可见报错」条款一起隐藏入口。
//

#if os(macOS)
import SwiftUI
import AppKit
import Observation

@MainActor
@Observable
final class BenchViewModel {
    private let runner: BenchRunner
    private let store = BenchSuiteStore()

    var cases: [BenchCase] = []
    var enabledVariants: Set<String>
    var capabilityFilter: BenchCapability? = nil
    var graceMinutes = 10                       // 收工线宽限：算法参数（不进设置页），10/20/30 实验
    var running = false
    var progress = ""
    var results: [String: [String: BenchCaseResult]] = [:]   // caseID → variantID → 结果
    var selectedCaseID: String? = nil
    private var runTask: Task<Void, Never>?

    init(runner: BenchRunner) {
        self.runner = runner
        self.cases = store.load()
        self.enabledVariants = Set(BenchVariants.all.map(\.id))
    }

    var filteredCases: [BenchCase] {
        guard let f = capabilityFilter else { return cases }
        return cases.filter { $0.capability == f }
    }

    func variants(for capability: BenchCapability) -> [BenchVariant] {
        BenchVariants.of(capability).filter { enabledVariants.contains($0.id) }
    }

    var selectedCase: BenchCase? { cases.first { $0.id == selectedCaseID } }

    // MARK: - 跑

    func runAll() {
        guard !running else { return }
        running = true
        let todo = filteredCases
        runTask = Task { [weak self] in
            guard let self else { return }
            let total = todo.reduce(0) { $0 + self.variants(for: $1.capability).count }
            var done = 0
            for c in todo {
                for v in self.variants(for: c.capability) {
                    if Task.isCancelled { break }
                    done += 1
                    self.progress = "\(c.id) × \(v.name)（\(done)/\(total)）…"
                    let r = await self.runner.run(c, variant: v, graceMinutes: self.graceMinutes)
                    self.results[c.id, default: [:]][v.id] = r
                }
                if Task.isCancelled { break }
            }
            self.progress = Task.isCancelled ? "已中止" : "完成（\(done) 次运行）"
            self.running = false
        }
    }

    func cancel() {
        runTask?.cancel()
        running = false
    }

    // MARK: - 用例集

    func reloadCases() { cases = store.load() }
    func resetDefaults() { cases = store.resetToDefaults(); results = [:] }
    func revealCaseFile() { NSWorkspace.shared.activateFileViewerSelecting([store.caseFileURL]) }

    func promptPreview(_ c: BenchCase, variant: BenchVariant) -> (system: String, user: String)? {
        runner.promptPreview(c, variant: variant, graceMinutes: graceMinutes)
    }

    // MARK: - 导出

    func exportMarkdown() -> String {
        var md = "# 算法试验台 · 跑分（宽限 \(graceMinutes)min）\n\n"
        md += "## 分数矩阵（变体 × 通过率）\n\n"
        md += "| 变体 | 维度 | 通过 | 平均耗时 | 解码失败 |\n|---|---|---|---|---|\n"
        for v in BenchVariants.all where enabledVariants.contains(v.id) {
            let vCases = cases.filter { $0.capability == v.capability }
            let dims = Set(vCases.map(\.dimension)).sorted()
            for d in dims {
                let dCases = vCases.filter { $0.dimension == d }
                let done = dCases.compactMap { results[$0.id]?[v.id] }
                guard !done.isEmpty else { continue }
                let ran = done.filter { $0.skippedReason == nil }
                let passed = ran.filter(\.passed).count
                let avg = ran.isEmpty ? 0 : ran.map(\.output.latencyMS).reduce(0, +) / ran.count
                let decodeFails = ran.filter { !$0.output.decodeOK }.count
                md += "| \(v.name) | \(d) | \(passed)/\(ran.count) | \(avg)ms | \(decodeFails) |\n"
            }
        }
        md += "\n## 逐用例\n\n"
        for c in cases {
            guard let row = results[c.id], !row.isEmpty else { continue }
            md += "### \(c.id) \(c.name)（\(c.dimension)）\n"
            for v in BenchVariants.of(c.capability) where enabledVariants.contains(v.id) {
                guard let r = row[v.id] else { continue }
                if let skip = r.skippedReason { md += "- \(v.name)：⏭ \(skip)\n"; continue }
                let mark = r.passed ? "✅" : "❌"
                let fails = r.checks.filter { !$0.passed }
                    .map { "\($0.expectation.kind.rawValue)：\($0.detail)" }
                md += "- \(v.name)：\(mark) \(r.output.latencyMS)ms"
                if let err = r.output.errorText { md += " · 错误：\(err)" }
                if !fails.isEmpty { md += " · " + fails.joined(separator: "；") }
                md += "\n"
            }
        }
        return md
    }

    func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportMarkdown(), forType: .string)
    }
}

// MARK: - View

struct BenchView: View {
    @State private var model: BenchViewModel

    init(runner: BenchRunner) {
        _model = State(initialValue: BenchViewModel(runner: runner))
    }

    var body: some View {
        HSplitView {
            caseList
                .frame(minWidth: 330, idealWidth: 380)
            detail
                .frame(minWidth: 420)
        }
        .toolbar { toolbarContent }
        .navigationTitle("算法试验台（开发期）")
    }

    // MARK: 左：用例列表

    private var caseList: some View {
        List(selection: Binding(get: { model.selectedCaseID },
                                set: { model.selectedCaseID = $0 })) {
            ForEach(BenchCapability.allCases, id: \.self) { cap in
                let capCases = model.filteredCases.filter { $0.capability == cap }
                if !capCases.isEmpty {
                    Section("\(cap.label)（\(capCases.count)）") {
                        ForEach(capCases) { c in
                            row(c)
                                .tag(c.id)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ c: BenchCase) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(c.id) · \(c.name)").font(.callout)
                Text(c.dimension).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(model.variants(for: c.capability)) { v in
                    Circle()
                        .fill(dotColor(model.results[c.id]?[v.id]))
                        .frame(width: 9, height: 9)
                        .help(v.name)
                }
            }
        }
    }

    private func dotColor(_ r: BenchCaseResult?) -> Color {
        guard let r else { return .gray.opacity(0.25) }
        if r.skippedReason != nil { return .gray }
        return r.passed ? .green : .red
    }

    // MARK: 右：明细

    @ViewBuilder
    private var detail: some View {
        if let c = model.selectedCase {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    caseHeader(c)
                    ForEach(model.variants(for: c.capability)) { v in
                        variantSection(c, v)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("选一条用例", systemImage: "flask",
                                   description: Text("左侧选用例看明细；工具栏「跑全部」出分数矩阵。"))
        }
    }

    private func caseHeader(_ c: BenchCase) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(c.id) \(c.name)").font(.title3.bold())
            if let t = c.text { Text("输入：\(t)").font(.callout) }
            if let cmd = c.command { Text("指令：\(cmd)").font(.callout) }
            if let req = c.originalRequest { Text("最初需求：\(req)").font(.caption).foregroundStyle(.secondary) }
            if let blocks = c.blocks {
                Text("输入块：" + blocks.map { spec in
                    "\(spec.title) \(spec.startHM)+\(spec.durationMinutes)m"
                    + ((spec.isFixed ?? false) ? "[固定]" : "")
                    + ((spec.priority == "important") ? "[★]" : "")
                }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            }
            if c.capability == .reflow {
                Text("从 \(c.fromHM ?? "?") 起重排 · 收工线 \(c.windDownHM ?? "23:00") · 宽限 \(model.graceMinutes)min")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func variantSection(_ c: BenchCase, _ v: BenchVariant) -> some View {
        let r = model.results[c.id]?[v.id]
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(dotColor(r)).frame(width: 10, height: 10)
                    Text(v.name).font(.headline)
                    if v.frozen {
                        Text("冻结快照").font(.caption2).padding(.horizontal, 4)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    if let r, r.skippedReason == nil {
                        Text("\(r.output.latencyMS)ms").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(v.detail).font(.caption).foregroundStyle(.secondary)

                if let r {
                    if let skip = r.skippedReason {
                        Text("⏭ 未跑：\(skip)").font(.callout).foregroundStyle(.secondary)
                    } else {
                        if let err = r.output.errorText {
                            Text("错误：\(err)").font(.callout).foregroundStyle(.red)
                        }
                        ForEach(r.checks.indices, id: \.self) { i in
                            let ck = r.checks[i]
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: ck.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ck.passed ? .green : .red)
                                    .font(.caption)
                                Text("\(ck.expectation.kind.rawValue) — \(ck.detail)").font(.caption)
                            }
                        }
                        if !r.output.blocks.isEmpty {
                            blocksTable("排定", r.output.blocks)
                        }
                        if !r.output.deferred.isEmpty {
                            blocksTable("候补（不铺时间）", r.output.deferred)
                        }
                        if let note = r.output.note, !note.isEmpty {
                            Text("note：\(note)").font(.caption).italic()
                        }
                        if let raw = r.output.raw {
                            DisclosureGroup("原始返回") {
                                Text(raw).font(.caption.monospaced()).textSelection(.enabled)
                            }.font(.caption)
                        }
                    }
                } else {
                    Text("未运行").font(.callout).foregroundStyle(.secondary)
                }

                if let p = promptPair(c, v, r) {
                    DisclosureGroup("实际发送的 prompt") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("— system —").font(.caption2.bold())
                            Text(p.0).font(.caption.monospaced()).textSelection(.enabled)
                            Text("— user —").font(.caption2.bold())
                            Text(p.1).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }.font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// prompt 展示：跑过用实际发送的（存在 output 里），没跑过给预览。
    private func promptPair(_ c: BenchCase, _ v: BenchVariant, _ r: BenchCaseResult?) -> (String, String)? {
        if let sys = r?.output.promptSystem { return (sys, r?.output.promptUser ?? "") }
        if let p = model.promptPreview(c, variant: v) { return (p.system, p.user) }
        return nil
    }

    private func blocksTable(_ label: String, _ blocks: [ScheduledBlock]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.bold())
            ForEach(blocks) { b in
                Text("\(BenchRunner.hm(b.start))–\(BenchRunner.hm(b.end))  \(b.title)"
                     + (b.isFixed ? " [固定]" : "")
                     + (b.priority == .important ? " [★]" : "")
                     + (b.isAnchor ? " [锚]" : "")
                     + (b.timingStyle == .pomodoro ? " [番茄]" : ""))
                .font(.caption.monospaced())
            }
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("能力", selection: Binding(get: { model.capabilityFilter },
                                             set: { model.capabilityFilter = $0 })) {
                Text("全部").tag(BenchCapability?.none)
                ForEach(BenchCapability.allCases, id: \.self) { c in
                    Text(c.label).tag(BenchCapability?.some(c))
                }
            }
            .pickerStyle(.segmented)

            Picker("宽限", selection: Binding(get: { model.graceMinutes },
                                             set: { model.graceMinutes = $0 })) {
                Text("宽限10").tag(10)
                Text("宽限20").tag(20)
                Text("宽限30").tag(30)
            }
            .help("收工线宽限（算法参数，实验定值后写死，不进设置）")

            Menu {
                ForEach(BenchCapability.allCases, id: \.self) { cap in
                    Section(cap.label) {
                        ForEach(BenchVariants.of(cap)) { v in
                            Toggle(v.name, isOn: Binding(
                                get: { model.enabledVariants.contains(v.id) },
                                set: { on in
                                    if on { model.enabledVariants.insert(v.id) }
                                    else { model.enabledVariants.remove(v.id) }
                                }))
                        }
                    }
                }
            } label: {
                Label("变体", systemImage: "square.stack.3d.up")
            }

            if model.running {
                Button { model.cancel() } label: { Label("中止", systemImage: "stop.circle") }
                Text(model.progress).font(.caption).foregroundStyle(.secondary)
            } else {
                Button { model.runAll() } label: { Label("跑全部", systemImage: "play.fill") }
                if !model.progress.isEmpty {
                    Text(model.progress).font(.caption).foregroundStyle(.secondary)
                }
            }

            Menu {
                Button("复制跑分 markdown") { model.copyMarkdown() }
                Divider()
                Button("重载用例文件") { model.reloadCases() }
                Button("在访达显示用例文件") { model.revealCaseFile() }
                Button("恢复默认用例", role: .destructive) { model.resetDefaults() }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
        }
    }
}
#endif
