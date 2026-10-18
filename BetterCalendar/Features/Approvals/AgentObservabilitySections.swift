//
//  AgentObservabilitySections.swift
//  BetterCalendar
//
//  「多端审批」面板里的两块可观测性区块（开发期）：
//    - AgentTranslationStatsSection：转译偏差统计（SPEC §19.1 / 批次 6，只统计不改行为），两端都有；
//    - AgentRuntimeSection：BetterCalendar 智能体运行时（批次 11：最近运行、调度失败、越权记录），Mac 上连了桥接才有。
//  单独成文件，ProposalPanel 只引用一行，减少与其他工作线的冲突。
//

import SwiftUI

struct AgentTranslationStatsSection: View {
    let center: ProposalCenter
    var messages: AgentMessageCenter?
    @State private var window: AgentStatsWindow = .week

    var body: some View {
        let s = AgentTranslationStatsCalculator.compute(proposals: center.proposals, messages: messages?.messages ?? [],
                                                        ledger: center.ledger.records(), window: window, now: .now)
        Section("智能体转译观察（只统计）") {
            Picker("时间窗", selection: $window) {
                ForEach(AgentStatsWindow.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if s.isEmpty {
                Text("这段时间还没有智能体的提案或消息").foregroundStyle(.secondary)
            } else {
                if s.proposals > 0 {
                    LabeledContent("提案", value: s.pending > 0 ? "\(s.proposals) 份（\(s.pending) 份待决定）" : "\(s.proposals) 份")
                    LabeledContent("同意 / 拒绝 / 过期", value: "\(s.approvalRate.percentText) / \(s.declineRate.percentText) / \(s.expiryRate.percentText)")
                    LabeledContent("执行失败", value: s.failureRate.text)
                    LabeledContent("撤销", value: s.undoRate.text + (s.undoFailed > 0 ? " · 撤销没成功 \(s.undoFailed)" : ""))
                    LabeledContent("批准后被手动改掉", value: s.overrideRate.text)
                }
                if s.messages > 0 {
                    LabeledContent("主动消息", value: "\(s.messages) 条：弹出 \(s.deliveredRate.percentText) · 拦下 \(s.suppressedRate.percentText)")
                    LabeledContent("你点了「好」/「静音」", value: "\(s.acknowledgedRate.text) / \(s.mutedRate.text)")
                }
            }
            Text("比例的分母：同意/拒绝/过期 = 已有决定的提案；执行失败 = 同意过的；撤销与手改 = 已应用的；好/静音 = 弹出过的。撤销按本机操作留底统计；「手动改掉」暂无数据来源。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
struct AgentRuntimeSection: View {
    let bridge: AgentBridge

    var body: some View {
        Section("BetterCalendar 智能体运行") {
            if let snap = bridge.runtime {
                ForEach(bridge.runtimeAlerts) { a in
                    Label(a.message, systemImage: a.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(a.severity == .error ? .red : .orange)
                        .font(.callout.weight(.semibold))
                }
                statusRows(snap.status)
                ForEach(snap.deadLetters) { d in deadLetterRow(d) }
                if snap.runs.isEmpty {
                    Text("还没有运行记录").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("最近运行").font(.footnote.weight(.semibold))
                    ForEach(Array(snap.runs.suffix(6).reversed())) { r in runRow(r) }
                }
                if !snap.overreach.isEmpty {
                    Text("越权记录（\(snap.overreach.count)）").font(.footnote.weight(.semibold))
                    ForEach(Array(snap.overreach.suffix(5).reversed())) { o in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(o.at.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? o.atText) · \(o.what)").font(.caption)
                            Text("为什么：\(o.why) → 结果：\(o.result)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("还没读到运行记录（桥接同步后显示）").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func statusRows(_ st: AgentDispatcherStatus?) -> some View {
        if let st {
            let updated = st.updatedAt.map { " · 更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            Text(st.state == "running" ? "调度器：运行中\(st.currentEvent.map { "（\($0)）" } ?? "")\(updated)" : "调度器：空闲\(updated)")
                .font(.footnote)
            if let s = st.session {
                Text(sessionLine(s, st.thresholds)).font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                Text("当前没有会话：下一个事件会开新会话").font(.caption).foregroundStyle(.secondary)
            }
            if let r = st.lastRotation {
                Text("上次轮换 \(r.at.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")：\(r.reason)\(r.handoffOk ? "" : "（交接没写成功）")")
                    .font(.caption).foregroundStyle(r.handoffOk ? Color.secondary : Color.orange)
            }
        } else {
            Text("未发现调度器状态（runtime/status.json）：调度器还没升级到 v2，或从未运行过").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sessionLine(_ s: AgentDispatcherStatus.Session, _ t: AgentDispatcherStatus.Thresholds) -> String {
        func of<T>(_ v: T?) -> String { v.map { " / \($0)" } ?? "" }
        let cost = String(format: "$%.2f", s.costUsd) + (t.costUsd.map { String(format: " / $%.0f", $0) } ?? "")
        let ctx = s.contextTokens.map { "≈\($0 / 1000)k\(t.contextTokens.map { " / \($0 / 1000)k" } ?? "")" } ?? "—"
        return "本会话 \(s.events)\(of(t.events)) 个事件 · \(cost) · \(s.turns)\(of(t.turns)) 轮 · 上下文 \(ctx)（到任一上限即轮换）"
    }

    private func deadLetterRow(_ d: AgentDeadLetter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("失败事件：\(d.kind ?? d.file)\(d.attempts.map { "（试了 \($0) 次）" } ?? "")").font(.callout).foregroundStyle(.red)
            Text(d.reason).font(.caption)
            HStack {
                Button("重新排队") { bridge.requeueDeadLetter(d.file) }
                Button("收起") { bridge.dismissDeadLetter(d.file) }
            }.font(.caption)
        }
    }

    private func runRow(_ r: AgentRunRecord) -> some View {
        var parts = [r.at.formatted(date: .omitted, time: .standard), r.kindLabel]
        if let l = r.latencySeconds { parts.append(String(format: "%.0f 秒", l)) }
        if let c = r.costUsd { parts.append(String(format: "$%.2f", c)) }
        if let n = r.numTurns { parts.append("\(n) 轮") }
        if let resumed = r.resumed { parts.append(resumed ? "续接" : "新会话") }
        if let a = r.attempt, a > 1 { parts.append("第 \(a) 次") }
        return VStack(alignment: .leading, spacing: 2) {
            Text(parts.joined(separator: " · ")).font(.caption.monospaced())
                .foregroundStyle(r.isError ? .red : .primary)
            if r.isError {
                Text("出错：\(r.error ?? "未知")\(r.willRetry ? "（会重试）" : r.deadLettered ? "（已进死信）" : "")").font(.caption2).foregroundStyle(.red)
            } else if let s = r.rotationReason ?? r.summary {
                Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
#endif
