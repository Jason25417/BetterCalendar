//
//  SharedTimerBackendPanel.swift
//  BetterCalendar
//
//  W5 开发期开关：共享计时的真相改记在 iCloud（默认关）。只在下次启动生效；切换闸门见 SharedTimerSettings。
//

import SwiftUI

struct SharedTimerBackendPanel: View {
    @Bindable var control: SharedTimerBackendControl
    @AppStorage(DeveloperSettings.key) private var developerOptions = false   // W16：播种按钮只在「开发者选项」里出现
    #if DEBUG
    @State private var seeding = false
    @State private var seedResult: String?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("共享计时改记在 iCloud（开发期）", isOn: Binding(get: { control.requested },
                                                                  set: { control.setRequested($0) }))
            Text("计时记在：\(control.active.label)。切换在下次启动 App 时生效；当前通道还有正在计时或待同步的操作时不会切换，旧记录保留在原处。两台设备需各自打开。")
                .font(.caption).foregroundStyle(.secondary)
            if let notice = control.notice {
                Text(notice).font(.caption).foregroundStyle(control.restartPending ? Color.secondary : Color.orange)
            }
            #if DEBUG
            if developerOptions {
            Button(seeding ? "正在写入…" : "在 Development 建出计时 schema（DEBUG）") {
                seeding = true
                Task {
                    do { try await CloudKitSharedTimerStore().seedDevelopmentSchema(now: Date()); seedResult = "已写入探针记录（已结束、不显示）与 zone 订阅" }
                    catch { seedResult = "写入失败：\(error.localizedDescription)"; DevLog.shared.error("共享计时", seedResult ?? "") }
                    seeding = false
                }
            }.disabled(seeding)
            if let seedResult { Text(seedResult).font(.caption).foregroundStyle(.secondary) }
            }
            #endif
        }
    }
}
