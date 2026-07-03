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
    @State private var useCloud: Bool = CloudSettings.useCloud
    @State private var hasKey: Bool = KeychainStore.loadAPIKey() != nil
    @State private var backend: CalendarBackend = CalendarSettings.backend
    @State private var leadMinutes: Int = ReminderSettings.leadMinutes
    @State private var journalLock: Bool = JournalSettings.privacyLock
    @State private var savedHint: String?

    var body: some View {
        Form {
            Section("云端排程大脑（Anthropic API）") {
                Toggle("启用云端", isOn: $useCloud)

                Picker("模型", selection: $model) {
                    ForEach(CloudSettings.availableModels, id: \.self) { Text($0).tag($0) }
                }
                Text("省钱可切 claude-haiku-4-5；个人用每月约几分钱到一块多。")
                    .font(.caption).foregroundStyle(.secondary)

                SecureField(hasKey ? "已存有 key（留空＝不修改）" : "粘贴 Anthropic API key",
                            text: $apiKey)

                HStack {
                    Button("保存") { save() }
                    if hasKey {
                        Button("清除 key", role: .destructive) {
                            KeychainStore.deleteAPIKey(); hasKey = false; savedHint = "已清除 key"
                        }
                    }
                    if let hint = savedHint {
                        Text(hint).font(.caption).foregroundStyle(.green)
                    }
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

            Section("提醒事项") {
                Stepper("要紧事提前 \(leadMinutes) 分钟提醒", value: $leadMinutes, in: 0...120, step: 5)
                    .onChange(of: leadMinutes) { _, v in ReminderSettings.leadMinutes = v }
                Text("确认写入时把 ★要紧事 写进 Apple 提醒事项（带提前提醒）。真模式首次写弹权限。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func save() {
        if !apiKey.isEmpty {
            KeychainStore.saveAPIKey(apiKey)
            hasKey = true
            apiKey = ""
        }
        CloudSettings.model = model
        CloudSettings.useCloud = useCloud
        CalendarSettings.backend = backend
        ReminderSettings.leadMinutes = leadMinutes
        savedHint = "已保存"
    }
}
