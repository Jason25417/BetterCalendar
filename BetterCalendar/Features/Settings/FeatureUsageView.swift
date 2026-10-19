//
//  FeatureUsageView.swift
//  BetterCalendar
//
//  W21：开发者选项里的「功能使用」只读页——给 Jason 自己看本机的功能使用探针（U13 开发期界面：能用不乱即可）。
//  上：解读出的假设（每条带证据）；下：按区域列每个功能的计数（今天 / 近 7 天 / 近 30 天、没做完 / 撤销 / 出错、最后用）。
//  数据只在本机；这一页不改任何东西。
//

import SwiftUI

struct FeatureUsageView: View {
    @State private var report: FeatureUsageReport?
    @State private var onlyActive = true

    var body: some View {
        Form {
            if let report {
                Section {
                    Text("开始统计：\(report.trackingSince?.formatted(date: .abbreviated, time: .shortened) ?? "还没有记录") · 共 \(report.trackingDays) 天")
                    Text("只在本机记「哪个功能、什么事件」，不记标题、内容、App 或网站名，从不上传。假设只是线索，不是结论。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("给智能体：\(FeatureUsageSettings.shareWithAgent ? "已打开（设置 → 智能体）" : "关着（设置 → 智能体 →「让智能体参考功能使用」）")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let hyps = FeatureUsageInterpreter.hypotheses(report)
                Section("可能的原因（\(hyps.count)）") {
                    if hyps.isEmpty { Text("暂时没有可说的模式").foregroundStyle(.secondary) }
                    ForEach(hyps, id: \.feature) { h in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(h.feature.label) → \(h.text)").font(.callout)
                            Text(h.evidence).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("只看有记录的功能", isOn: $onlyActive)
                ForEach(areas(report), id: \.self) { area in
                    Section(area) {
                        ForEach(rows(report, area: area), id: \.id) { s in row(s) }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("功能使用")
        .toolbar { Button("刷新") { reload() } }
        .onAppear { reload() }
    }

    private func reload() { report = FeatureUsageReporter.shared.report(now: .now) }

    private func areas(_ r: FeatureUsageReport) -> [String] {
        var seen: [String] = []
        for f in FeatureID.allCases where !seen.contains(f.area) && !rows(r, area: f.area).isEmpty { seen.append(f.area) }
        return seen
    }

    private func rows(_ r: FeatureUsageReport, area: String) -> [FeatureStats] {
        FeatureID.allCases.filter { $0.area == area }.compactMap { r.stats[$0] }
            .filter { !onlyActive || !$0.total.isEmpty || $0.usedLifetime > 0 }
    }

    private func row(_ s: FeatureStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(s.id.label).font(.callout)
                Spacer()
                Text(s.id.rawValue).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Text(line(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func line(_ s: FeatureStats) -> String {
        var parts = ["用过 今天 \(s.today[.used] ?? 0) · 7天 \(s.week[.used] ?? 0) · 30天 \(s.month[.used] ?? 0) · 累计 \(s.usedLifetime)"]
        if s.seenDays > 0 { parts.append("出现 \(s.seenDays) 天") }
        let a = s.month[.abandoned] ?? 0, u = s.month[.undone] ?? 0, f = s.month[.failed] ?? 0
        if a > 0 { parts.append("没做完 \(a)" + (s.abandonRatio.map { "（\(Int(($0 * 100).rounded()))%）" } ?? "")) }
        if u > 0 { parts.append("撤销 \(u)") }
        if f > 0 { parts.append("出错 \(f)") }
        if let last = s.marks.lastUsed { parts.append("最后用 " + last.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}
