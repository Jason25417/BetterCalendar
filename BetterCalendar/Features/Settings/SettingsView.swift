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
    @State private var autoCompleteFixed: Bool = MeetingSettings.autoCompleteFixedBlocks
    @State private var pomoLimit: Int = PomodoroDiscipline.weeklyEarlyEndLimit
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

            // 「日历后端」选择已退役（2026-07-07 Jason 定）：一律写真 系统日历（Dev 专用日历）；
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

                    Toggle("端侧解析（试验 · 端侧模型）", isOn: Binding(
                        get: { CloudSettings.useOnDeviceParser },
                        set: { CloudSettings.useOnDeviceParser = $0 }))
                    Text("打开后「排今天」解析 + 「AI 调整」优先用 端侧模型（免费/离线/私密），不可用或失败自动回退云端。排序/建议这类文本仍走云端。~3B 偏小、试验中。")
                        .font(.caption).foregroundStyle(.secondary)

                    #if os(macOS)
                    Toggle("退出时保留在菜单栏后台运行", isOn: Binding(
                        get: { MenuBarSettings.keepRunningOnQuit },
                        set: { MenuBarSettings.keepRunningOnQuit = $0 }))
                    Text("打开后 ⌘Q / Dock 右键退出 不会真退——收进菜单栏继续跑（计时不断），Dock 图标消失、防手滑误退。真要退出：点菜单栏图标 → 右键 → 退出 BetterCalendar。")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("聪音联动（把专注状态同步给《放松时光》）", isOn: Binding(
                        get: { FocusStateExporter.isEnabled },
                        set: { FocusStateExporter.isEnabled = $0 }))
                    Text("开启后，开始/完成事项、计时进度会写进本地 focus-state.json，供聪音的 mod 读来驱动番茄/情绪/经验值（需另装 mod）。关掉即停、删文件。")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("聪音待办投影（今天的事项进游戏待办）", isOn: Binding(
                        get: { FocusStateExporter.todoProjectionEnabled },
                        set: { FocusStateExporter.todoProjectionEnabled = $0 }))
                    Text("需先开聪音联动。把今天的事项同步成游戏里的「Better Calendar」待办清单：BC 完成的自动勾上；游戏里勾完成会回流记成 BC 完成。mod 首次写入前会自动备份游戏存档。")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack {
                        Button("一键添加「番茄⇄专注」快捷指令") { FocusShortcutRunner.importTemplates() }
                        Text("会弹出两个添加预览，各点一次「添加」即可").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("番茄开始时执行的快捷指令名（留空不启用）", text: Binding(
                        get: { FocusShortcutRunner.startShortcut },
                        set: { FocusShortcutRunner.startShortcut = $0 }))
                        .textFieldStyle(.roundedBorder)
                    TextField("番茄结束时执行的快捷指令名（留空不启用）", text: Binding(
                        get: { FocusShortcutRunner.endShortcut },
                        set: { FocusShortcutRunner.endShortcut = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Text("番茄 ⇄ 系统专注：番茄开始/结束时无界面执行上面的快捷指令（首次执行系统弹一次授权）。用「一键添加」装模板（开工作专注/关专注），或自己建含「设定专注」动作的快捷指令再填名字；想换开哪个专注=编辑快捷指令里那一处。")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif

                    Stepper(value: $pomoLimit, in: 0...7) {
                        Text("番茄「提前休息」每周上限：" + (pomoLimit == 0 ? "不限" : "\(pomoLimit) 次"))
                    }
                    .onChange(of: pomoLimit) { _, v in PomodoroDiscipline.weeklyEarlyEndLimit = v }
                    Text(pomoLimit >= 3
                         ? "设到 \(pomoLimit) 次了——预先承诺贵在少，多了就不太像约束了，要不要再想想？（每周一零点重置）"
                         : "给自己的可选约束：设了上限后，番茄工作段中的「提前休息」每周只能用这么多次（默认不限；每周一零点重置）。")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("输入框预设文本", selection: Binding(
                        get: { PlaceholderSettings.mode },
                        set: { PlaceholderSettings.mode = $0 })) {
                        ForEach(PlaceholderMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text("教程示例在「排今天」用满 10 次后自动换成小提示（这里随时可换回/换轻问候）。")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("皮肤", selection: Binding(
                        get: { ThemeSettings.current.id },
                        set: { id in if let t = ThemeSettings.all.first(where: { $0.id == id }) { ThemeSettings.current = t } })) {
                        ForEach(ThemeSettings.all) { Text($0.name).tag($0.id) }
                    }
                    Text("皮肤系统接口已就绪（§5.9）：新皮肤设计定稿后会出现在这里，选择后随视图迁移逐步生效。")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("界面披露风格", selection: Binding(
                        get: { DisclosureSettings.style },
                        set: { DisclosureSettings.style = $0 })) {
                        ForEach(DisclosureStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Text("排日程页信息密度（渐进披露 v2）：原皮「向导」按时刻只显当刻所需；控制台/禅暂未实现（选了暂回退向导）。")
                        .font(.caption).foregroundStyle(.secondary)

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
                    Text("双向同步（0.20）：在 系统日历里挪/改绿色计划块会自动同步回 App；删除/新建按上面两条策略处理。")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("退出时有任务在进行", selection: Binding(
                        get: { ExecutionViewModel.RunRestoreSettings.policy },
                        set: { ExecutionViewModel.RunRestoreSettings.policy = $0 })) {
                        Text("每次询问").tag(ExecutionViewModel.RunRestoreChoice?.none)
                        Text("继续（离开时间也算）").tag(ExecutionViewModel.RunRestoreChoice?.some(.continueWithGap))
                        Text("直接继续（离开时间不算）").tag(ExecutionViewModel.RunRestoreChoice?.some(.continueWithoutGap))
                        Text("重新开始").tag(ExecutionViewModel.RunRestoreChoice?.some(.discard))
                    }
                    Text("重开 App 时若有任务在计时：默认每次问怎么接；在恢复弹窗勾「不再询问」或这里改，即按固定选择自动处理。")
                        .font(.caption).foregroundStyle(.secondary)

                    Stepper("提醒提前 \(leadMinutes) 分钟", value: $leadMinutes, in: 0...120, step: 5)
                        .onChange(of: leadMinutes) { _, v in ReminderSettings.leadMinutes = v }
                    Text("确认写入时把「尽早」和有具体截止(DDL)的事项写进 系统「提醒事项」（带提前提醒）。")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("固定块（会议）过点自动记完成", isOn: Binding(
                        get: { autoCompleteFixed },
                        set: { autoCompleteFixed = $0; MeetingSettings.autoCompleteFixedBlocks = $0 }))
                    Text("会议等固定块=外部承诺、到点就真的发生了 → 默认自动记为完成（工作块仍手动）。关掉则固定块也彻底手动。删掉自动记的会议蓝块会一直保持删除。")
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
