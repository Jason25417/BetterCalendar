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
    @State private var backend: CalendarBackend = CalendarSettings.backend
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

                Text("key 存系统 Keychain，不进 git。在 console.anthropic.com 创建。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("日历后端") {
                Picker("写入到", selection: $backend) {
                    Text("假日历（预览，不碰系统）").tag(CalendarBackend.fake)
                    Text("真 Apple 日历（Dev 专用）").tag(CalendarBackend.eventKit)
                }
                .pickerStyle(.inline)
                .onChange(of: backend) { _, newValue in CalendarSettings.backend = newValue }

                Text("可随时切换、即时生效。真模式首次写会请求日历权限，写进「BetterCalendar · 计划 (Dev)」日历（绿色），可整本删、不污染你别的日历。")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
                    if provider == .anthropic {
                        Picker("AI 模型", selection: $model) {
                            ForEach(CloudSettings.availableModels, id: \.self) { Text($0).tag($0) }
                        }
                        Text("省钱可切 claude-haiku-4-5；个人用每月约几分钱到一块多。改完点上方「保存」。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("硅基流动模型 ID", text: $sfModel)
                        Text("填 SiliconFlow 的模型 ID。排日程是结构化抽取、不需长思考——**优先选 Instruct（非推理）变体**（如 Qwen/Qwen3-30B-A3B-Instruct-2507），更快更省；Thinking 变体会先长篇推理、反而慢且浪费。改完点上方「保存」。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

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
        .padding()
        #if os(macOS)
        // 固定尺寸 → Form 内容超出时**内部滚动**（之前 minHeight 让窗口无限长、超屏后无法滚、被截断）
        .frame(width: 500, height: 560)
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
            case .success(let model): testResult = "✅ key 有效 · \(model) 可用"
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
        CalendarSettings.backend = backend
        ReminderSettings.leadMinutes = leadMinutes
        savedHint = "已保存"
    }
}
