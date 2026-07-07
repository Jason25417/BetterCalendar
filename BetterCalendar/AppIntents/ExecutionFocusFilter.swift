//
//  ExecutionFocusFilter.swift
//  BetterCalendar
//
//  Focus Filter（§5.7，Jason 拍板 2026-07-08）：**系统→App 方向**——
//  用户在系统「专注模式」设置里给任意专注（含自定义）添加本过滤器并勾选「进入时自动休息」，
//  进入该专注 → 系统带用户配置调 perform() → 自动开始休息；退出 → 系统按默认参数（false）再调一次 → 自动回来。
//  "针对哪个专注可调"由系统天然提供（每个专注各配各的），App 不自建选择器。
//  只结束**我们自己开的**休息：用户手动开的休息不被专注退出误关（掌控感）。
//

import AppIntents

struct ExecutionFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "BetterCalendar 执行陪伴"
    static let description: IntentDescription? =
        IntentDescription("进入此专注时自动开始休息（计时暂停），退出时自动回来继续。")

    @Parameter(title: "进入此专注时自动休息", default: false)
    var autoBreak: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "自动休息：\(autoBreak ? "开" : "关")")
    }

    func perform() async throws -> some IntentResult {
        await ExecutionBridge.shared?.focusAutoBreak(autoBreak)
        return .result()
    }
}

/// 供进程内 App Intents 直达执行状态（Focus 变化时系统可能后台拉起 App 执行 perform，
/// 组装点建好容器即挂上——与 AppIntentRequest 的"排队等前台消费"不同，休息切换需要即时生效）。
@MainActor
enum ExecutionBridge {
    static weak var shared: ExecutionViewModel?
}
