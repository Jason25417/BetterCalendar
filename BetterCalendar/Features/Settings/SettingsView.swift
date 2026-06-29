//
//  SettingsView.swift
//  BetterCalendar
//
//  设置壳（M0 占位）。之后绑定到 AppSettings：calendarBackend / 默认计时风格 / 通知模式 / push 强度 / parser。
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("原型期占位（尚未接持久化）") {
                LabeledContent("默认计时风格", value: "轻计时")
                LabeledContent("通知", value: "早晚 + 固定块")
                LabeledContent("日历后端", value: "假日历（预览）")
                LabeledContent("解析引擎", value: "云端 LLM（待接）")
                LabeledContent("push 强度", value: "温和")
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 220)
    }
}
