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

/// 分心自动休息·iOS 腿（#26 V1，2026-07-11）：iOS 不开放前台 App 检测（隐私设计），
/// 走**快捷指令个人自动化**——用户建「当打开〔某 App〕→ 运行 自动休息开始」「当关闭 → 自动休息结束」，
/// 系统在后台调 perform 直达执行状态。mac 上这两个指令同样可用（给不想开感知器的人手动/脚本触发）。
/// 红线同 mac 感知：日志只记「自动休息」，绝不记是哪个 App 触发的。
struct StartAutoBreakIntent: AppIntent {
    static var title: LocalizedStringResource = "自动休息开始"
    static var description = IntentDescription(
        "给快捷指令自动化用：打开分心 App 时调用，正在专注的计时自动暂停（休息）。空档或已在休息则什么都不做。")

    func perform() async throws -> some IntentResult {
        await ExecutionBridge.shared?.distractionAutoBreak(true)
        return .result()
    }
}

struct EndAutoBreakIntent: AppIntent {
    static var title: LocalizedStringResource = "自动休息结束"
    static var description = IntentDescription(
        "给快捷指令自动化用：离开分心 App 时调用，自动结束刚才的自动休息、计时继续。只收自动开的休息，不动手动休息。")

    func perform() async throws -> some IntentResult {
        await ExecutionBridge.shared?.distractionAutoBreak(false)
        return .result()
    }
}

/// 供进程内 App Intents 直达执行状态（Focus 变化时系统可能后台拉起 App 执行 perform，
/// 组装点建好容器即挂上——与 AppIntentRequest 的"排队等前台消费"不同，休息切换需要即时生效）。
@MainActor
enum ExecutionBridge {
    static weak var shared: ExecutionViewModel?
}
