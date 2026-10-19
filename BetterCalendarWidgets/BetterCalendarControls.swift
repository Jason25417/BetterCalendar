//
//  BetterCalendarControls.swift
//  BetterCalendarWidgets
//
//  Control Center 控件（iOS 18+，2026-07-04 v0.11）：一键「完成当前 / 开始下一件」。
//  控件的 intent 在 widget 扩展进程执行 → 经 App Group defaults 入队请求 + 打开主 App 消费
//  （AppIntentRequest 同编两 target；主 App 的 completeOrStartFromIntent 已有完成/开始语义）。
//

import WidgetKit
import SwiftUI
import AppIntents

struct CompleteOrStartControlIntent: AppIntent {
    static var title: LocalizedStringResource = "完成当前 / 开始下一件"
    static var description = IntentDescription("完成正在做的事；空档时开始下一件。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppIntentRequest.enqueue(.completeCurrent, source: "control")   // W21：来源 = 控件（功能使用探针分来源）
        return .result()
    }
}

struct BetterCalendarControls: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.jason.BetterCalendar.completeControl") {
            ControlWidgetButton(action: CompleteOrStartControlIntent()) {
                Label("完成 / 下一件", systemImage: "checkmark.circle.fill")
            }
        }
        .displayName("完成当前 / 下一件")
        .description("一键完成正在做的，或开始下一件。")
    }
}
