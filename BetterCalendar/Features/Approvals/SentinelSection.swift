//
//  SentinelSection.swift
//  BetterCalendar
//
//  「多端审批」面板里的哨兵区块（SPEC §19 C1 W14，Mac）：开关、判断器（首选 / 正在用 / 兜底原因）、OpenRouter 与 OpenAI 的 key、
//  叫醒阈值、今天调用 / 叫醒次数与理由、攒着的叫醒、估算花费、上次运行、上次错误、节奏与稳定性上限。
//  单独成文件，ProposalPanel 只引用一行，减少与其他工作线的冲突。
//

import SwiftUI

struct SentinelSection: View {
    @Bindable var engine: SentinelEngine

    var body: some View {
        Section("哨兵：要不要叫醒智能体（实验）") {
            Toggle("开启哨兵", isOn: $engine.settings.enabled)
            Text("有变化就用一个专门做判断的小模型看一眼设备活动、计划和计时，判断此刻值不值得叫醒 BetterCalendar 智能体。它从不直接通知你；叫醒后由智能体决定要不要说话（仍受打扰规则约束）。智能体忙着或刚被叫过时，新的理由会先攒着、合并成一次再叫。")
                .font(.caption).foregroundStyle(.secondary)

            if case let .stop(reason) = engine.gate {
                Label(reason, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).font(.callout.weight(.semibold))
            } else if let reason = engine.gate.reason {
                Text("现在没在判断：\(reason)").font(.footnote).foregroundStyle(.secondary)
            }

            Picker("首选判断器", selection: $engine.settings.preferredJudge) {
                ForEach([SentinelJudgeKind.jev, .openai, .claude], id: \.self) { Text($0.label).tag($0) }
            }
            LabeledContent("正在用", value: engine.judgeInUse.label)
            if let why = engine.primaryUnavailableReason ?? engine.lastEntry?.fallbackReason {
                Label("没用上首选：\(why)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            }
            SentinelKeyField(title: "OpenRouter API key（Jev）", account: JevSentinelJudge.keychainAccount)
            SentinelKeyField(title: "OpenAI API key（可选）", account: OpenAIDecisionsSentinelJudge.keychainAccount)
            if engine.judgeInUse.isDecisionModel {
                VStack(alignment: .leading) {
                    Slider(value: $engine.settings.wakeThreshold, in: 0.5...0.99, step: 0.01) {
                        Text("把握超过 \(Int((engine.settings.wakeThreshold * 100).rounded()))% 才叫醒")
                    }
                    Text("越高越少打扰、越可能漏；按决策日志里的概率分布再调。").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let e = engine.lastError {
                Label("上次错误（\(e.at.formatted(date: .omitted, time: .shortened))）：\(e.message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
            if let e = engine.activityError { Text(e).font(.caption).foregroundStyle(.orange) }
            if let e = engine.lastStatusError { Text(e).font(.caption).foregroundStyle(.orange) }

            LabeledContent("上次判断", value: engine.lastRunAt?.formatted(date: .omitted, time: .standard) ?? "还没判断过")
            LabeledContent("今天", value: "判断 \(engine.judgmentsToday.count) 次 · 叫醒 \(engine.wakesToday.count) 次")
            LabeledContent("估算花费", value: String(format: "今天 $%.4f · 近 7 天 $%.4f", engine.costTodayUsd, engine.cost7dUsd))
            if let p = engine.pending {
                Label("攒着 \(p.reasons.count) 条叫醒理由（\(p.holdReason ?? "等待中")），条件满足后合并成一次发出", systemImage: "tray.full")
                    .font(.caption)
            }
            if !engine.wakesToday.isEmpty {
                Text("今天叫醒的理由").font(.footnote.weight(.semibold))
                ForEach(Array(engine.wakesToday.suffix(8).reversed())) { w in
                    Text("\(w.at.formatted(date: .omitted, time: .shortened)) · \(w.verdict.urgency.label) · \(w.verdict.reason)").font(.caption)
                }
            }
            if let last = engine.lastEntry, last.outcome != .woke {
                Text("上次判断：\(last.outcome.label) — \(last.verdict.reason)").font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("节奏与稳定性上限") {
                Stepper("决策模型两次判断至少隔 \(Int(engine.settings.minIntervalSeconds)) 秒",
                        value: $engine.settings.minIntervalSeconds, in: 1...300, step: 1)
                Stepper("Claude 兜底时两次判断至少隔 \(Int(engine.settings.llmMinIntervalSeconds / 60)) 分钟",
                        value: $engine.settings.llmMinIntervalSeconds, in: 60...1800, step: 60)
                Stepper("没变化时每 \(Int(engine.settings.idleIntervalSeconds / 60)) 分钟看一次",
                        value: $engine.settings.idleIntervalSeconds, in: 60...3600, step: 60)
                Stepper("两次叫醒至少隔 \(Int(engine.settings.minWakeGapSeconds / 60)) 分钟",
                        value: $engine.settings.minWakeGapSeconds, in: 60...3600, step: 60)
                Stepper("同一理由 \(Int(engine.settings.signatureCooldownMinutes)) 分钟内不重复叫醒",
                        value: $engine.settings.signatureCooldownMinutes, in: 5...240, step: 5)
                Stepper("每小时最多叫醒 \(engine.settings.maxWakesPerHour) 次", value: $engine.settings.maxWakesPerHour, in: 1...20)
                Stepper(String(format: "每天花费上限 $%.2f", engine.settings.dailyBudgetUsd),
                        value: $engine.settings.dailyBudgetUsd, in: 0.1...10, step: 0.1)
                Text("上限是防失控、防烧钱的稳定性上限，不是产品规则；花费到上限就停止调用并在这里标红。决策日志：\(engine.log.location)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button("立即判断一次") { Task { await engine.runNow() } }
        }
    }
}

/// 一个 API key 输入框：存 Keychain（kSecAttrSynchronizable，经 iCloud 钥匙串同步到另一台设备）。留空保存 = 不修改。
private struct SentinelKeyField: View {
    let title: String
    let account: String
    @State private var draft = ""
    @State private var hasKey = false
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(hasKey ? "\(title)：已存有（留空＝不修改）" : title, text: $draft)
                Button("保存") {
                    let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { hint = "没有输入，未修改"; return }
                    KeychainStore.saveAPIKey(key, account: account)
                    hasKey = KeychainStore.loadAPIKey(account: account) != nil
                    hint = hasKey ? "已保存（会经 iCloud 钥匙串同步）" : "保存失败：钥匙串里读不回来"
                    if !hasKey { DevLog.shared.error("哨兵", "\(title) 保存后读不回来") }
                    draft = ""
                }
                if hasKey {
                    Button("清除", role: .destructive) {
                        KeychainStore.deleteAPIKey(account: account); hasKey = false; hint = "已清除"
                    }
                }
            }
            if let hint { Text(hint).font(.caption2).foregroundStyle(.secondary) }
        }
        .onAppear { hasKey = KeychainStore.loadAPIKey(account: account) != nil }
    }
}
