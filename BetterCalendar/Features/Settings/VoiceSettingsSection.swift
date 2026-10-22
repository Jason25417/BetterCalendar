//
//  VoiceSettingsSection.swift
//  BetterCalendar
//
//  W38：设置里的「语音输入」——端侧 Whisper 开关（随 iCloud 同步，日用版默认关）+ 这台设备的模型状态 + 删除模型。
//

import SwiftUI

struct VoiceSettingsSection: View {
    @Environment(\.speechTranscriber) private var transcriber
    @State private var on = WhisperSettings.enabled
    @State private var confirmDelete = false

    var body: some View {
        if let transcriber {
            Section("语音输入") {
                Toggle("更准的语音输入（端侧 Whisper）", isOn: $on)
                    .onChange(of: on) { _, v in if v != WhisperSettings.enabled { transcriber.setEnabled(v) } }
                    .accessibilityIdentifier("bc.settings.whisper")
                if on {
                    LabeledContent("这台设备", value: transcriber.state.label)
                    if case let .downloading(p) = transcriber.state { ProgressView(value: p) }
                }
                if transcriber.modelOnDisk {
                    Button("删除这台设备上的模型（约 630 MB）", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("删除这台设备上的语音模型？", isPresented: $confirmDelete) {
                            Button("删除", role: .destructive) { Task { await transcriber.deleteModel() } }
                        } message: { Text(on ? "开关还开着，之后会重新下载。" : "需要时打开开关会重新下载。") }
                }
                Text("打开后，每台设备各自下载约 630 MB 的识别模型（只在 Wi-Fi 下下载），第一次还要准备一两分钟；之后点麦克风说话、再点一下停，约 1 秒出字，中英混说比苹果听写准。识别全在本机，录音不出设备，转完即删。模型还没准备好时，这一次会用苹果听写，并在输入框上方写明原因。关掉 = 只用苹果听写。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onReceive(NotificationCenter.default.publisher(for: SettingsSync.didSyncRemotely)) { _ in on = WhisperSettings.enabled }
        }
    }
}
