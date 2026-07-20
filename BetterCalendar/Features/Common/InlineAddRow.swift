//
//  InlineAddRow.swift
//  BetterCalendar
//
//  列表尾行「加一项」（2026-07-20 长期页审计 #11 抽出，进组件登记表）：
//  与排日程页 addTailRow 同形态——默认一行低调的「＋ 文案」，点开变行内输入，
//  回车提交、Escape/失焦取消。U7：全 App 的「就地新增」都长这样。
//  （HomeView 原实现耦合其局部状态，暂未迁移到本件——登记表已注明「待迁移」。）
//

import SwiftUI

struct InlineAddRow: View {
    let prompt: String            // 收起态文案，如「手动加一件」
    let placeholder: String       // 输入态占位
    let onSubmit: (String) -> Void

    @State private var active = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if active {
            HStack {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { submit() }
                Button("加入") { submit() }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    active = false; text = ""
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("取消添加")
            }
            #if os(macOS)
            .onExitCommand { active = false; text = "" }   // Escape 取消（macOS 专属 API；iOS 用 ✕ 钮）
            #endif
        } else {
            Button {
                active = true
                DispatchQueue.main.async { focused = true }
            } label: {
                Label(prompt, systemImage: "plus")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        onSubmit(t)
        text = ""
        // 保持输入态，方便连续加多项（同排日程页行为）
    }
}
