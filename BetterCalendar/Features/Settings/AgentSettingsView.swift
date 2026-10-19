//
//  AgentSettingsView.swift
//  BetterCalendar
//
//  W20：设置 → 智能体 → 当前智能体。选哪个实现接通（同一时刻只接通一个；没选的那个没有任何通道）、
//  内置智能体的 DeepSeek key / 模型 / 每日预算 / 用量与估算成本 / 运行状态、隐私披露、角色共享记忆。
//  低频设置（U2 第二层）：入口在 设置 → 智能体。
//

import SwiftUI

struct AgentSettingsView: View {
    @Bindable var hub: AgentHub
    @State private var keyInput = ""
    @State private var hasKey = KeychainStore.loadAPIKey(account: DeepSeekClient.keychainAccount) != nil
    @State private var model = BuiltinAgentSettings.model()
    @State private var budgetOn = BuiltinAgentSettings.budget() != nil
    @State private var budget = BuiltinAgentSettings.budget() ?? 1.0
    @State private var showMemory = false

    var body: some View {
        Form {
            Section {
                Picker("当前智能体", selection: Binding(get: { hub.selection.kind }, set: { hub.selection.select($0) })) {
                    ForEach(AgentKind.allCases) { Text($0.pickerLabel).tag($0) }
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("bc.settings.agent.kind")
            } footer: {
                Text("两者是同一个 BetterCalendar 智能体的不同实现：职责、预授权规则、共享记忆都一样。同一时刻只接通一个，没选的那个收不到任何事件、什么都不会做。选中的那个跑不了时会在对话里直说哪里坏了，不会自动换成另一个——要换由你在这里切。设置随 iCloud 同步，两台设备接的是同一个。")
            }

            if hub.active == .builtin {
                builtinSections
            } else {
                Section {
                    Text("Claude Code 跑在 Mac 上（经桥接文件夹与专用会话）：Mac 要开着、醒着，iPhone 上说的话由 Mac 转交。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                Button { showMemory.toggle() } label: {
                    Label(showMemory ? "收起共享记忆" : "看看共享记忆", systemImage: "brain")
                }
                if showMemory {
                    if let m = hub.memory.memory {
                        Text(m.text).font(.callout).textSelection(.enabled)
                        Text("最后更新：\(m.updatedAt.formatted(date: .abbreviated, time: .shortened))（\(m.updatedBy)）· \(m.text.count)/\(AgentSharedMemoryStore.maxCharacters) 字")
                            .font(.caption).foregroundStyle(.tertiary)
                        Button("清空共享记忆", role: .destructive) { hub.memory.clear() }.font(.callout)
                    } else {
                        Text("还是空的。").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let e = hub.memory.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
            } header: { Text("共享记忆") } footer: {
                Text("智能体这个角色的长期记忆（你的偏好、正在跟进的事、最近拒绝的提议）。哪个实现接通，就读写这同一份；随 iCloud 同步。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("当前智能体")
    }

    @ViewBuilder private var builtinSections: some View {
        let runtime = hub.builtin
        Section("运行状态") {
            if runtime.isRunning {
                Label("正在想…", systemImage: "ellipsis.bubble")
            } else if let p = runtime.problem {
                VStack(alignment: .leading, spacing: 4) {
                    Label(p.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("你可以：\(p.hint)").font(.callout)
                    if let at = runtime.problemAt { Text(at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary) }
                }
                Button("知道了") { runtime.clearProblem() }.font(.callout)
            } else if let r = runtime.lastRun {
                Text("上一轮 \(r.at.formatted(date: .omitted, time: .shortened))：\(r.turns) 步 · 回复 \(r.replies) · 提案 \(r.proposals)")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("还没跑过。在「智能体」页说一句试试。").font(.callout).foregroundStyle(.secondary)
            }
        }

        Section {
            if hasKey {
                Label("已填 DeepSeek API key（存在钥匙串，随 iCloud 钥匙串同步）", systemImage: "key.fill")
                Button("删除 key", role: .destructive) {
                    KeychainStore.deleteAPIKey(account: DeepSeekClient.keychainAccount)
                    hasKey = false
                }.font(.callout)
            } else {
                SecureField("粘贴 DeepSeek API key", text: $keyInput)
                    .textContentType(.password)
                Button("保存") {
                    let k = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !k.isEmpty else { return }
                    KeychainStore.saveAPIKey(k, account: DeepSeekClient.keychainAccount)
                    keyInput = ""
                    hasKey = KeychainStore.loadAPIKey(account: DeepSeekClient.keychainAccount) != nil
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Picker("模型", selection: $model) {
                Text("deepseek-flash（V4.1 Flash，快、便宜）").tag("deepseek-flash")
                Text("deepseek-v4-pro（V4 Pro，更强、更贵）").tag("deepseek-v4-pro")
            }
            .onChange(of: model) { _, v in UserDefaults.standard.set(v, forKey: BuiltinAgentSettings.modelKey) }
        } header: { Text("DeepSeek") } footer: {
            Text("key 只存在系统钥匙串，不进设置、不进日志。")
        }

        Section {
            let today = runtime.usage.today
            LabeledContent("今天（这台设备）", value: String(format: "约 $%.4f", today.costUSD))
            Text("\(today.runs) 轮 · \(today.calls) 次调用 · 输入 \(today.cacheHitTokens + today.cacheMissTokens) token（命中缓存 \(today.cacheHitTokens)）· 输出 \(today.completionTokens) token")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("最近 7 天（这台设备）", value: String(format: "约 $%.3f", runtime.usage.last7DaysCost))
            Toggle("设每日预算", isOn: $budgetOn)
                .onChange(of: budgetOn) { _, on in
                    if on { UserDefaults.standard.set(budget, forKey: BuiltinAgentSettings.budgetKey) }
                    else { UserDefaults.standard.removeObject(forKey: BuiltinAgentSettings.budgetKey) }
                }
            if budgetOn {
                Stepper(value: $budget, in: 0.1...20, step: 0.1) {
                    Text(String(format: "每日预算 $%.2f", budget))
                }
                .onChange(of: budget) { _, v in UserDefaults.standard.set(v, forKey: BuiltinAgentSettings.budgetKey) }
            }
        } header: { Text("用量与预算") } footer: {
            Text("成本按 DeepSeek 官方价目估算（高峰时段按双倍算），以 DeepSeek 账单为准。默认不设预算（试验阶段），只记账。打开「设每日预算」后每台设备各自按它停：用完当天就停下并在对话里说明，不会换成更便宜的方案继续跑。")
        }

        Section("隐私") {
            Text("打开内置智能体后，每次它被叫醒，这台设备会把你的一天发给 DeepSeek（中国公司的云端服务）：今天和未来几天的计划块、计时、待办与长期事项、你自己日历与提醒事项里的安排（标题与时间）、最近做过什么、最近设备活动摘要（在用的 App 与网站）、最近的对话，以及共享记忆；你在设置里允许时还有最近的日记。Claude Code 接通时这些只在你的 Mac 上经桥接给 Claude。")
                .font(.callout)
        }
    }
}
