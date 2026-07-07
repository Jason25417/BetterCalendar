//
//  SettingsView.swift
//  BetterCalendar
//
//  设置（⌘,）：Anthropic API key/模型/云端开关 + 日历后端（假/真，可热切换）。
//

import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var model: String = CloudSettings.model
    @State private var provider: LLMProvider = CloudSettings.provider
    @State private var sfModel: String = CloudSettings.siliconflowModel
    @State private var useCloud: Bool = CloudSettings.useCloud
    @State private var hasKey: Bool = KeychainStore.loadAPIKey(account: CloudSettings.provider.keychainAccount) != nil
    @State private var leadMinutes: Int = ReminderSettings.leadMinutes
    @State private var windDownHour: Int = WorkHoursSettings.windDownHour
    @State private var pushIntensity: PushIntensity = SuggestionSettings.intensity
    @State private var journalLock: Bool = JournalSettings.privacyLock
    @State private var savedHint: String?
    @State private var testing = false
    @State private var testResult: String?
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section("云端排程大脑") {
                Toggle("启用云端", isOn: $useCloud)

                Picker("服务商", selection: $provider) {
                    ForEach(LLMProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: provider) { _, p in
                    CloudSettings.provider = p
                    hasKey = KeychainStore.loadAPIKey(account: p.keychainAccount) != nil
                    apiKey = ""; testResult = nil
                }

                SecureField(hasKey ? "已存有 key（留空＝不修改）"
                            : (provider == .siliconflow ? "粘贴硅基流动 API key" : "粘贴 Anthropic API key"),
                            text: $apiKey)

                HStack {
                    Button("保存") { save() }
                    Button("测试") { testKey() }
                        .disabled(testing || (apiKey.isEmpty && !hasKey))
                    if testing { ProgressView().controlSize(.small) }
                    if hasKey {
                        Button("清除 key", role: .destructive) {
                            KeychainStore.deleteAPIKey(account: provider.keychainAccount); hasKey = false; savedHint = "已清除 key"
                        }
                    }
                    if let hint = savedHint {
                        Text(hint).font(.caption).foregroundStyle(.green)
                    }
                }
                if let result = testResult {
                    Text(result).font(.caption)
                        .foregroundStyle(result.hasPrefix("✅") ? .green : .red)
                }

                // 硅基流动必须填模型 ID（没有能通用的默认）→ 放主区、别埋进阶设置
                if provider == .siliconflow {
                    TextField("模型 ID（如 Qwen/Qwen2.5-7B-Instruct）", text: $sfModel)
                        .onChange(of: sfModel) { _, v in CloudSettings.siliconflowModel = v }
                    Text("必填 SiliconFlow 上真实存在的模型 ID。先用 Qwen/Qwen2.5-7B-Instruct 测通，再换成想要的 <200B MoE Instruct。填完点「保存」再「测试」。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text(provider == .siliconflow
                     ? "key 存系统 Keychain，不进 git。在 siliconflow.cn 创建 + 看模型列表。"
                     : "key 存系统 Keychain，不进 git。在 console.anthropic.com 创建。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // 「日历后端」选择已退役（2026-07-07 Jason 定）：一律写真 Apple 日历（Dev 专用日历）；
            // 假日历仅存于单测/预览页，不再暴露给用户。

            Section("日记") {
                Toggle("隐私锁（Face ID / Touch ID / 密码）", isOn: $journalLock)
                    .onChange(of: journalLock) { _, v in JournalSettings.privacyLock = v }
                Text("开启后进入日记页需解锁；退后台自动重新上锁。设备没设密码时不拦。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // 进阶设置（渐进披露，§5.9）：手动折叠（DisclosureGroup 在 macOS Form 里收不回）
            Section("进阶设置") {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() } } label: {
                    HStack {
                        Text(showAdvanced ? "收起" : "展开进阶设置")
                        Spacer()
                        Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    // 硅基流动模型 ID 已挪到上方主区（必填、别埋这里）；进阶只留 Anthropic 模型
                    if provider == .anthropic {
                        Picker("AI 模型", selection: $model) {
                            ForEach(CloudSettings.availableModels, id: \.self) { Text($0).tag($0) }
                        }
                        Text("省钱可切 claude-haiku-4-5；个人用每月约几分钱到一块多。改完点上方「保存」。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Toggle("端侧解析（试验 · Apple 端侧模型）", isOn: Binding(
                        get: { CloudSettings.useOnDeviceParser },
                        set: { CloudSettings.useOnDeviceParser = $0 }))
                    Text("打开后「排今天」解析 + 「AI 调整」优先用 Apple 端侧模型（免费/离线/私密），不可用或失败自动回退云端。排序/建议这类文本仍走云端。~3B 偏小、试验中。")
                        .font(.caption).foregroundStyle(.secondary)

                    #if os(macOS)
                    Toggle("退出时保留在菜单栏后台运行", isOn: Binding(
                        get: { MenuBarSettings.keepRunningOnQuit },
                        set: { MenuBarSettings.keepRunningOnQuit = $0 }))
                    Text("打开后 ⌘Q / Dock 右键退出 不会真退——收进菜单栏继续跑（计时不断），Dock 图标消失、防手滑误退。真要退出：点菜单栏图标 → 右键 → 退出 BetterCalendar。")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif

                    Picker("日历里删除计划块时", selection: Binding(
                        get: { ReconcileSettings.deletionPolicy },
                        set: { ReconcileSettings.deletionPolicy = $0 })) {
                        ForEach(ReconcileDeletionPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("日历里新建日程时", selection: Binding(
                        get: { ReconcileSettings.additionPolicy },
                        set: { ReconcileSettings.additionPolicy = $0 })) {
                        ForEach(ReconcileAdditionPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text("双向同步（0.20）：在 Apple 日历里挪/改绿色计划块会自动同步回 App；删除/新建按上面两条策略处理。")
                        .font(.caption).foregroundStyle(.secondary)

                    Stepper("要紧事提前 \(leadMinutes) 分钟提醒", value: $leadMinutes, in: 0...120, step: 5)
                        .onChange(of: leadMinutes) { _, v in ReminderSettings.leadMinutes = v }
                    Text("确认写入时把 ★要紧事 写进 Apple 提醒事项（带提前提醒）。")
                        .font(.caption).foregroundStyle(.secondary)

                    Stepper("最晚工作到 \(windDownHour):00", value: $windDownHour, in: 18...24)
                        .onChange(of: windDownHour) { _, v in WorkHoursSettings.windDownHour = v }
                    Text("软收工：AI 排/重排时尽量别把事排到这个点之后（略超一点点能多做完一件大事则可以）；你明确说的晚间事不受限。当天想早睡/晚睡，直接在排日程里说一句即可。")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("主动建议强度", selection: $pushIntensity) {
                        ForEach(PushIntensity.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .onChange(of: pushIntensity) { _, v in SuggestionSettings.intensity = v }
                    Text("排日程页顶部偶尔提醒一句临近 DDL / 久放的未来任务（休息日全静音、可「别再提」永久静音某件）。默认温和。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)   // System-Settings 风格分组卡片（修「排版不好看」）
        #if os(macOS)
        // macOS `Settings` 场景的窗口不随内容长高、也不给用户缩放 → **固定尺寸**让 Form 内容超出时**内部滚动**。
        // 别再改成 min/ideal/max 弹性尺寸追「可缩放」：那会让窗口撑到内容高、超屏后无法滚被截断（0.18.22 踩过、0.18.38 回退）。
        .frame(width: 520, height: 600)
        #endif
    }

    /// 测试当前服务商的 key：输入框有内容测输入框的（未保存也能测），否则测已保存的。
    private func testKey() {
        let candidate = apiKey.isEmpty ? (KeychainStore.loadAPIKey(account: provider.keychainAccount) ?? "") : apiKey
        guard !candidate.isEmpty else { return }
        testing = true; testResult = nil
        let m = provider == .anthropic ? model : sfModel
        let p = provider
        Task {
            let r = await AnthropicClient.test(key: candidate, model: m, provider: p)
            switch r {
            case .success(let detail): testResult = "✅ key 有效 · \(detail)"
            case .failure(let e): testResult = "❌ \(e.message)"
            }
            testing = false
        }
    }

    private func save() {
        if !apiKey.isEmpty {
            KeychainStore.saveAPIKey(apiKey, account: provider.keychainAccount)   // 存到当前服务商账户
            hasKey = true
            apiKey = ""
        }
        CloudSettings.provider = provider
        CloudSettings.model = model
        CloudSettings.siliconflowModel = sfModel
        CloudSettings.useCloud = useCloud
        ReminderSettings.leadMinutes = leadMinutes
        savedHint = "已保存"
    }
}
