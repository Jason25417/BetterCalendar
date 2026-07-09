//
//  RememberableConfirmSheet.swift
//  BetterCalendar
//
//  统一的「带记住勾选」确认弹窗（2026-07-09 Jason 定）：一个「以后统一这样，不再询问」Toggle + 若干选项按钮。
//  取代散落的 confirmationDialog 多按钮（"X，并记住"）——confirmationDialog 放不下 Toggle，故用 sheet。
//  用处：运行态三选恢复、绿/蓝日历对账确认——同一个交互模板，勾选=记住并写设置（设置页可反悔）。
//

import SwiftUI

struct RememberableConfirmSheet: View {
    struct Option: Identifiable {
        let id = UUID()
        var label: String
        var role: ButtonRole?      // .destructive / .cancel / nil
        var appliesRemember: Bool  // false=本次动作不写记忆（如"取消/先不动"）
    }

    let title: String
    let message: String
    var rememberLabel: String = "以后统一这样，不再询问"
    let options: [Option]
    /// 回调：(选项下标, 是否记住)。记住仅在该选项 appliesRemember 时为真。
    let onChoose: (Int, Bool) -> Void

    @State private var remember = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(rememberLabel, isOn: $remember)
                #if os(macOS)
                .toggleStyle(.checkbox)   // macOS 真复选框；iOS 用默认开关
                #endif
                .font(.callout)
            Divider()
            VStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { i in
                    Button(role: options[i].role) {
                        onChoose(i, remember && options[i].appliesRemember)
                        dismiss()
                    } label: {
                        Text(options[i].label).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .interactiveDismissDisabled(true)   // 只能经按钮离开——避免误滑关闭丢选择
    }
}
