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
    var results: [String: [String: BenchCaseResult]] = [:]   // caseID → 运行键(变体|模型) → 结果
    var selectedCaseID: String? = nil
    private var runTask: Task<Void, Never>?

    /// 云端模型清单（逗号分隔编辑；同服务商多模型对比——Jason 2026-07-08 提）。持久化本机。
    var cloudModelsText: String {
        didSet { UserDefaults.standard.set(cloudModelsText, forKey: "bench.cloudModels") }
    }
    var cloudModels: [String] {
        let list = cloudModelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return list.isEmpty ? [CloudSettings.activeModel] : list
    }

    init(runner: BenchRunner) {
        self.runner = runner
        self.cases = store.load()
        self.enabledVariants = Set(BenchVariants.all.map(\.id))
        self.cloudModelsText = UserDefaults.standard.string(forKey: "bench.cloudModels")
            ?? CloudSettings.activeModel
    }

    var filteredCases: [BenchCase] {
        guard let f = capabilityFilter else { return cases }
        return cases.filter { $0.capability == f }
    }

    func variants(for capability: BenchCapability) -> [BenchVariant] {
        BenchVariants.of(capability).filter { enabledVariants.contains($0.id) }
    }

    /// 一次「运行」= 变体 ×（云端变体则再乘模型清单）。
    struct BenchRun: Identifiable {
        let variant: BenchVariant
        let model: String?       // nil = 本地/端侧
        var id: String { model.map { "\(variant.id)|\($0)" } ?? variant.id }
        var label: String { model.map { "\(variant.name) · \(Self.shortModel($0))" } ?? variant.name }
        static func shortModel(_ m: String) -> String {
            m.split(separator: "/").last.map(String.init) ?? m
        }
    }

    func runs(for capability: BenchCapability) -> [BenchRun] {
        variants(for: capability).flatMap { v -> [BenchRun] in
            BenchRunner.cloudVariantIDs.contains(v.id)
                ? cloudModels.map { BenchRun(variant: v, model: $0) }
                : [BenchRun(variant: v, model: nil)]
        }
    }

    var selectedCase: BenchCase? { cases.first { $0.id == selectedCaseID } }

    // MARK: - 跑

    func runAll() {
        guard !running else { return }
        running = true
        let todo = filteredCases
        runTask = Task { [weak self] in
            guard let self else { return }
            let total = todo.reduce(0) { $0 + self.runs(for: $1.capability).count }
            var done = 0
            for c in todo {
                for run in self.runs(for: c.capability) {
                    if Task.isCancelled { break }
                    done += 1
                    self.progress = "\(c.id) × \(run.label)（\(done)/\(total)）…"
                    let r = await self.runner.run(c, variant: run.variant,
                                                  graceMinutes: self.graceMinutes, model: run.model)
                    self.results[c.id, default: [:]][run.id] = r
                }
                if Task.isCancelled { break }
            }
            self.progress = Task.isCancelled ? "已中止" : "完成（\(done) 次运行）"
            self.running = false
            if !Task.isCancelled { self.autoSaveReport() }
        }
    }

    /// 跑完自动把跑分 markdown 落盘到日志目录（Jason 要求：Claude 可直接读，无需手动贴）。
    private func autoSaveReport() {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        let dir = downloads.appendingPathComponent("BetterCalendar-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("algo-bench-最新跑分.md")
        try? exportMarkdown().data(using: .utf8)?.write(to: url, options: .atomic)
        DevLog.shared.info("试验台", "跑分已落盘 \(url.lastPathComponent)（BetterCalendar-logs）")
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
        var md = "# 算法试验台 · 跑分（宽限 \(graceMinutes)min · 模型清单 \(cloudModels.joined(separator: ", ")))\n\n"
        md += "## 分数矩阵（变体×模型 × 通过率）\n\n"
        md += "| 变体 | 模型 | 维度 | 通过 | 平均耗时 | 平均首包 | 解码失败 |\n|---|---|---|---|---|---|---|\n"
        for cap in BenchCapability.allCases {
            let capCases = cases.filter { $0.capability == cap }
            for run in runs(for: cap) {
                let dims = Set(capCases.map(\.dimension)).sorted()
                for d in dims {
                    let done = capCases.filter { $0.dimension == d }.compactMap { results[$0.id]?[run.id] }
                    guard !done.isEmpty else { continue }
                    let ran = done.filter { $0.skippedReason == nil }
                    let passed = ran.filter(\.passed).count
                    let avg = ran.isEmpty ? 0 : ran.map(\.output.latencyMS).reduce(0, +) / ran.count
                    let ttfts = ran.compactMap(\.output.firstOutputMS)
                    let ttft = ttfts.isEmpty ? "—" : "\(ttfts.reduce(0, +) / ttfts.count)ms"
                    let decodeFails = ran.filter { !$0.output.decodeOK }.count
                    md += "| \(run.variant.name) | \(run.model.map(BenchRun.shortModel) ?? "—") | \(d) | \(passed)/\(ran.count) | \(avg)ms | \(ttft) | \(decodeFails) |\n"
                }
            }
        }
        md += "\n## 逐用例\n\n"
        for c in cases {
            guard let row = results[c.id], !row.isEmpty else { continue }
            md += "### \(c.id) \(c.name)（\(c.dimension)）\n"
            for run in runs(for: c.capability) {
                guard let r = row[run.id] else { continue }
                if let skip = r.skippedReason { md += "- \(run.label)：⏭ \(skip)\n"; continue }
                let mark = r.passed ? "✅" : "❌"
                let fails = r.checks.filter { !$0.passed }
                    .map { "\($0.expectation.kind.rawValue)：\($0.detail)" }
                md += "- \(run.label)：\(mark) \(r.output.latencyMS)ms"
                if let f = r.output.firstOutputMS { md += "（首包 \(f)ms）" }
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
    @State private var showModelEditor = false

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
                ForEach(model.runs(for: c.capability)) { run in
                    Circle()
                        .fill(dotColor(model.results[c.id]?[run.id]))
                        .frame(width: 9, height: 9)
                        .help(run.label)
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
                    ForEach(model.runs(for: c.capability)) { run in
                        variantSection(c, run)
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
    private func variantSection(_ c: BenchCase, _ run: BenchViewModel.BenchRun) -> some View {
        let v = run.variant
        let r = model.results[c.id]?[run.id]
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(dotColor(r)).frame(width: 10, height: 10)
                    Text(run.label).font(.headline)
                    if v.frozen {
                        Text("冻结快照").font(.caption2).padding(.horizontal, 4)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    if let r, r.skippedReason == nil {
                        Text((r.output.firstOutputMS.map { "首包 \($0)ms · " } ?? "")
                             + "\(r.output.latencyMS)ms")
                            .font(.caption.monospacedDigit())
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

            Button {
                showModelEditor.toggle()
            } label: {
                Label("模型×\(model.cloudModels.count)", systemImage: "cpu")
            }
            .help("云端变体的模型清单（逗号分隔）：同服务商多模型对比，每个云端变体逐一跑")
            .popover(isPresented: $showModelEditor) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("云端模型清单（逗号分隔；服务商/key 取当前设置）").font(.caption)
                    TextField("如：claude-sonnet-5, claude-haiku-4-5-20251001",
                              text: Binding(get: { model.cloudModelsText },
                                            set: { model.cloudModelsText = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 420)
                    Text("当前生效：" + model.cloudModels.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(12)
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
