//
//  StartTodayIntent.swift
//  BetterCalendar
//
//  App Intents 起步桩：「开始今天」。之后接 ArrangeDayUseCase / re-flow，与 GUI 共用用例层。
//  快捷指令 / Siri / Spotlight 可调用。
//

import AppIntents

struct StartTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "开始今天"
    static var description = IntentDescription("记录今天的实际开工时间并刷新剩余日程（原型期占位）。")

    func perform() async throws -> some IntentResult {
        // TODO: 接 re-flow 用例（记录实际开工时间 → 重排剩余）
        return .result()
    }
}
