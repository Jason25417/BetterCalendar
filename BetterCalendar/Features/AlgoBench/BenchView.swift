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
    /// 宽限多选（只作用于 reflow V2 变体）：勾几个就把矩阵乘几份。
    var selectedGraces: Set<Int> = [10]
    var running = false
    var progress = ""
    var progressDone = 0
    var progressTotal = 0
    /// caseID → 运行键(变体|模型|宽限) → **多次尝试**（重复 N 轮看稳定性——模型有方差，单轮说了不算）。
    var results: [String: [String: [BenchCaseResult]]] = [:]
    /// 每格重复次数（1–10）：Sonnet 三轮 0→6→2/7 的教训——通过率要用分布说话。
    var repeatCount = 1
    var selectedCaseID: String? = nil
    private var runTask: Task<Void, Never>?

    /// 云端模型池（逗号分隔编辑）+ 池内多选（勾上的才进矩阵）。池持久化本机。
    var cloudModelsText: String {
        didSet {
            UserDefaults.standard.set(cloudModelsText, forKey: "bench.cloudModels")
            enabledModels.formIntersection(cloudModelPool)          // 池里删掉的取消勾选
            if enabledModels.isEmpty, let first = cloudModelPool.first { enabledModels = [first] }
        }
    }
    var cloudModelPool: [String] {
        let list = cloudModelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return list.isEmpty ? [CloudSettings.activeModel] : list
    }
    var enabledModels: Set<String>
    /// 进矩阵的模型（保持池内顺序）。
    var activeModels: [String] { cloudModelPool.filter { enabledModels.contains($0) } }

    init(runner: BenchRunner) {
        self.runner = runner
        self.cases = store.load()
        self.enabledVariants = Set(BenchVariants.all.map(\.id))
        let pool = UserDefaults.standard.string(forKey: "bench.cloudModels") ?? CloudSettings.activeModel
        self.cloudModelsText = pool
        self.enabledModels = Set(pool.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        if enabledModels.isEmpty { enabledModels = [CloudSettings.activeModel] }
    }

    var filteredCases: [BenchCase] {
        guard let f = capabilityFilter else { return cases }
        return cases.filter { $0.capability == f }
    }

    func variants(for capability: BenchCapability) -> [BenchVariant] {
        BenchVariants.of(capability).filter { enabledVariants.contains($0.id) }
    }

    /// 一次「运行」= 变体 ×（云端变体 × 已勾选模型）×（reflow V2 变体 × 已勾选宽限）——测试矩阵。
    struct BenchRun: Identifiable {
        let variant: BenchVariant
        let model: String?       // nil = 本地/端侧
        let grace: Int?          // nil = 宽限无关变体
        var id: String { "\(variant.id)|\(model ?? "-")|g\(grace ?? 0)" }
        var label: String {
            var l = variant.name
            if let m = model { l += " · \(Self.shortModel(m))" }
            if let g = grace { l += " · 宽限\(g)" }
            return l
        }
        static func shortModel(_ m: String) -> String {
            m.split(separator: "/").last.map(String.init) ?? m
        }
    }

    /// 宽限只对 V2 有意义（V1 本来就不执法收工线）。
    private static let graceSensitive: Set<String> = [BenchVariantID.reflowNaiveV2, BenchVariantID.reflowLLMV2]

    func runs(for capability: BenchCapability) -> [BenchRun] {
        variants(for: capability).flatMap { v -> [BenchRun] in
            let models: [String?] = BenchRunner.cloudVariantIDs.contains(v.id)
                ? activeModels.map { $0 } : [nil]
            let graces: [Int?] = Self.graceSensitive.contains(v.id)
                ? selectedGraces.sorted().map { $0 } : [nil]
            return models.flatMap { m in graces.map { g in BenchRun(variant: v, model: m, grace: g) } }
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
            let n = max(1, min(10, self.repeatCount))
            let total = todo.reduce(0) { $0 + self.runs(for: $1.capability).count } * n
            self.progressTotal = total
            self.progressDone = 0
            let fmIDs: Set<String> = [BenchVariantID.parseFM, BenchVariantID.refineFM,
                                      BenchVariantID.refineFMGuard]
            var fmTimeouts = 0   // 端侧熔断：连续超时 2 次 → 本轮剩余端侧全跳过（别拖死矩阵）
            for c in todo {
                for run in self.runs(for: c.capability) {
                    var attempts: [BenchCaseResult] = []
                    for i in 1...n {
                        if Task.isCancelled { break }
                        self.progress = "\(c.id) × \(run.label)" + (n > 1 ? "（第 \(i)/\(n) 轮）" : "") + "…"
                        let r: BenchCaseResult
                        if fmTimeouts >= 2, fmIDs.contains(run.variant.id) {
                            r = BenchCaseResult(output: BenchOutput(), checks: [],
                                                skippedReason: "端侧连续超时已熔断（重启 App / 查 Apple Intelligence 后再试）")
                        } else {
                            let runner = self.runner
                            let grace = run.grace ?? WorkHoursSettings.graceMinutes
                            do {
                                r = try await BenchRunner.withWatchdog(seconds: 120) {
                                    await runner.run(c, variant: run.variant,
                                                     graceMinutes: grace, model: run.model)
                                }
                            } catch {
                                r = BenchCaseResult(
                                    output: BenchOutput(latencyMS: 120_000, decodeOK: false,
                                                        errorText: "看门狗超时（120s）——模型疑似循环生成，本次判失败"),
                                    checks: [])
                                if fmIDs.contains(run.variant.id) { fmTimeouts += 1 }
                            }
                        }
                        attempts.append(r)
                        self.progressDone += 1
                        // 跳过的格子（没 key/开关没开/已熔断）重复毫无意义，跑一次即止
                        if r.skippedReason != nil { self.progressDone += n - i; break }
                    }
                    self.results[c.id, default: [:]][run.id] = attempts
                    if Task.isCancelled { break }
                }
                if Task.isCancelled { break }
            }
            self.progress = Task.isCancelled ? "已中止（部分报告已落盘）" : "完成（\(self.progressDone) 次运行）"
            self.running = false
            self.autoSaveReport(partial: Task.isCancelled)   // 中止也落盘：几十分钟的部分数据不该蒸发
        }
    }

    /// 跑完自动把跑分 markdown 落盘到日志目录（Jason 要求：Claude 可直接读，无需手动贴）。
    /// partial=true（中止）：文件头标注"部分"，数据照存。
    private func autoSaveReport(partial: Bool = false) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        let dir = downloads.appendingPathComponent("BetterCalendar-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("algo-bench-最新跑分.md")
        var md = exportMarkdown()
        if partial { md = "> ⚠️ 部分报告：中止于 \(progressDone)/\(progressTotal) 次运行。\n\n" + md }
        try? md.data(using: .utf8)?.write(to: url, options: .atomic)
        DevLog.shared.info("试验台", "跑分已落盘 \(url.lastPathComponent)（BetterCalendar-logs）")
    }

    func cancel() {
        runTask?.cancel()
        running = false
    }

    /// 一格的聚合读数（多轮）：nil = 没跑过。
    struct CellSummary {
        var attempts: [BenchCaseResult]
        var skipped: String? { attempts.first?.skippedReason }
        var ran: [BenchCaseResult] { attempts.filter { $0.skippedReason == nil } }
        var passCount: Int { ran.filter(\.passed).count }
        var passText: String { "\(passCount)/\(ran.count)" }
        var avgLatency: Int { ran.isEmpty ? 0 : ran.map(\.output.latencyMS).reduce(0, +) / ran.count }
        var avgTTFT: Int? {
            let t = ran.compactMap(\.output.firstOutputMS)
            return t.isEmpty ? nil : t.reduce(0, +) / t.count
        }
        /// 展示哪一次的明细：第一个失败的（信息量最大），全过则最后一次。
        var showcase: BenchCaseResult? { ran.first { !$0.passed } ?? ran.last ?? attempts.first }
    }

    func cell(_ caseID: String, _ runID: String) -> CellSummary? {
        guard let a = results[caseID]?[runID], !a.isEmpty else { return nil }
        return CellSummary(attempts: a)
    }

    // MARK: - 用例集

    func reloadCases() { cases = store.load() }
    func resetDefaults() { cases = store.resetToDefaults(); results = [:] }
    func revealCaseFile() { NSWorkspace.shared.activateFileViewerSelecting([store.caseFileURL]) }

    func promptPreview(_ c: BenchCase, variant: BenchVariant) -> (system: String, user: String)? {
        runner.promptPreview(c, variant: variant, graceMinutes: selectedGraces.min() ?? WorkHoursSettings.graceMinutes)
    }

    // MARK: - 导出

    func exportMarkdown() -> String {
        var md = "# 算法试验台 · 跑分（宽限 \(selectedGraces.sorted().map(String.init).joined(separator: "/"))min · 模型 \(activeModels.joined(separator: ", "))）\n\n"
        md += "## 分数矩阵（变体×模型×宽限 × 通过率）\n\n"
        md += "| 变体 | 模型 | 宽限 | 维度 | 通过 | 平均耗时 | 平均首包 | 解码失败 |\n|---|---|---|---|---|---|---|---|\n"
        for cap in BenchCapability.allCases {
            let capCases = cases.filter { $0.capability == cap }
            for run in runs(for: cap) {
                let dims = Set(capCases.map(\.dimension)).sorted()
                for d in dims {
                    // 多轮：把该维度所有用例的所有尝试摊平统计（通过率=通过次数/总次数）
                    let allAttempts = capCases.filter { $0.dimension == d }
                        .compactMap { results[$0.id]?[run.id] }.flatMap { $0 }
                    guard !allAttempts.isEmpty else { continue }
                    let ran = allAttempts.filter { $0.skippedReason == nil }
                    let passed = ran.filter(\.passed).count
                    let avg = ran.isEmpty ? 0 : ran.map(\.output.latencyMS).reduce(0, +) / ran.count
                    let ttfts = ran.compactMap(\.output.firstOutputMS)
                    let ttft = ttfts.isEmpty ? "—" : "\(ttfts.reduce(0, +) / ttfts.count)ms"
                    let decodeFails = ran.filter { !$0.output.decodeOK }.count
                    md += "| \(run.variant.name) | \(run.model.map(BenchRun.shortModel) ?? "—") | \(run.grace.map { "\($0)min" } ?? "—") | \(d) | \(passed)/\(ran.count) | \(avg)ms | \(ttft) | \(decodeFails) |\n"
                }
            }
        }
        md += "\n## 逐用例\n\n"
        for c in cases {
            guard let row = results[c.id], !row.isEmpty else { continue }
            md += "### \(c.id) \(c.name)（\(c.dimension)）\n"
            for run in runs(for: c.capability) {
                guard let summary = cell(c.id, run.id) else { continue }
                if let skip = summary.skipped { md += "- \(run.label)：⏭ \(skip)\n"; continue }
                let mark = summary.passCount == summary.ran.count ? "✅"
                         : (summary.passCount == 0 ? "❌" : "⚠️")
                md += "- \(run.label)：\(mark) \(summary.passText) · 均 \(summary.avgLatency)ms"
                if let f = summary.avgTTFT { md += "（首包均 \(f)ms）" }
                if let bad = summary.showcase, !bad.passed {
                    let fails = bad.checks.filter { !$0.passed }
                        .map { "\($0.expectation.kind.rawValue)：\($0.detail)" }
                    if let err = bad.output.errorText { md += " · 错误：\(err)" }
                    if !fails.isEmpty { md += " · 样例失败：" + fails.joined(separator: "；") }
                }
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
                        .fill(cellColor(model.cell(c.id, run.id)))
                        .frame(width: 9, height: 9)
                        .help(run.label)
                }
            }
        }
    }

    /// 多轮聚合灯色：绿=全过，橙=部分过（不稳定！），红=全挂，灰=没跑/跳过。
    private func cellColor(_ c: BenchViewModel.CellSummary?) -> Color {
        guard let c else { return .gray.opacity(0.25) }
        if c.skipped != nil || c.ran.isEmpty { return .gray }
        if c.passCount == c.ran.count { return .green }
        return c.passCount == 0 ? .red : .orange
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
                Text("从 \(c.fromHM ?? "?") 起重排 · 收工线 \(c.windDownHM ?? "23:00") · 宽限 \(model.selectedGraces.sorted().map(String.init).joined(separator: "/"))min")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func variantSection(_ c: BenchCase, _ run: BenchViewModel.BenchRun) -> some View {
        let v = run.variant
        let summary = model.cell(c.id, run.id)
        let r = summary?.showcase
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(cellColor(summary)).frame(width: 10, height: 10)
                    Text(run.label).font(.headline)
                    if v.frozen {
                        Text("冻结快照").font(.caption2).padding(.horizontal, 4)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    if let summary, summary.skipped == nil, !summary.ran.isEmpty {
                        Text("通过 \(summary.passText)"
                             + (summary.avgTTFT.map { " · 首包均 \($0)ms" } ?? "")
                             + " · 均 \(summary.avgLatency)ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(v.detail).font(.caption).foregroundStyle(.secondary)
                // 多轮时：每轮一个小灯（一眼看方差）；明细展示信息量最大的那轮（首个失败，全过则最后一轮）
                if let summary, summary.ran.count > 1 {
                    HStack(spacing: 3) {
                        ForEach(summary.ran.indices, id: \.self) { i in
                            Circle().fill(summary.ran[i].passed ? Color.green : .red)
                                .frame(width: 6, height: 6)
                                .help("第 \(i + 1) 轮：\(summary.ran[i].passed ? "过" : "挂") · \(summary.ran[i].output.latencyMS)ms")
                        }
                        if let show = r, !show.passed {
                            Text("（下方明细=失败样例）").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

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

            Menu {
                ForEach([10, 20, 30], id: \.self) { g in
                    Toggle("宽限 \(g) 分钟", isOn: Binding(
                        get: { model.selectedGraces.contains(g) },
                        set: { on in
                            if on { model.selectedGraces.insert(g) }
                            else if model.selectedGraces.count > 1 { model.selectedGraces.remove(g) }
                        }))
                }
            } label: {
                Label("宽限×\(model.selectedGraces.count)", systemImage: "clock.badge.questionmark")
            }
            .help("收工线宽限多选（只作用于 reflow V2）：勾几个矩阵乘几份；实验定值后写死进软件")

            Picker("轮数", selection: Binding(get: { model.repeatCount },
                                             set: { model.repeatCount = $0 })) {
                ForEach([1, 2, 3, 5, 10], id: \.self) { n in Text("×\(n) 轮").tag(n) }
            }
            .help("每格重复跑 N 轮看稳定性（模型有方差，单轮说了不算）；跳过的格子只跑一次")

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
                Label("模型×\(model.activeModels.count)", systemImage: "cpu")
            }
            .help("云端变体的模型清单（逗号分隔）：同服务商多模型对比，每个云端变体逐一跑")
            .popover(isPresented: $showModelEditor) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("云端模型池（逗号分隔；服务商/key 取当前设置）").font(.caption)
                    TextField("如：claude-sonnet-5, claude-haiku-4-5-20251001",
                              text: Binding(get: { model.cloudModelsText },
                                            set: { model.cloudModelsText = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 420)
                    Divider()
                    Text("勾选进入测试矩阵的模型：").font(.caption)
                    ForEach(model.cloudModelPool, id: \.self) { m in
                        Toggle(m, isOn: Binding(
                            get: { model.enabledModels.contains(m) },
                            set: { on in
                                if on { model.enabledModels.insert(m) }
                                else if model.enabledModels.count > 1 { model.enabledModels.remove(m) }
                            }))
                        .font(.caption)
                    }
                }
                .padding(12)
            }

            if model.running {
                Button { model.cancel() } label: { Label("中止", systemImage: "stop.circle") }
                ProgressView(value: Double(model.progressDone),
                             total: Double(max(model.progressTotal, 1)))
                    .frame(width: 120)
                Text("\(model.progressDone)/\(model.progressTotal) · \(model.progress)")
                    .font(.caption).foregroundStyle(.secondary)
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
