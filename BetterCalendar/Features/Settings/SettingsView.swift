//
//  SettingsView.swift
//  BetterCalendar
//
//  设置（⌘,）：填 Anthropic API key（存 Keychain）+ 选模型 + 云端开关。
//  未配 key / 关云端 / 调用失败时，解析与排程自动回退本地实现。
//

import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var model: String = CloudSettings.model
    @State private var useCloud: Bool = CloudSettings.useCloud
    @State private var hasKey: Bool = KeychainStore.loadAPIKey() != nil
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
        }
        .padding()
        .frame(minWidth: 440, minHeight: 280)
    }

    private func save() {
        if !apiKey.isEmpty {
            KeychainStore.saveAPIKey(apiKey)
            hasKey = true
            apiKey = ""
        }
        CloudSettings.model = model
        CloudSettings.useCloud = useCloud
        savedHint = "已保存"
    }
}
