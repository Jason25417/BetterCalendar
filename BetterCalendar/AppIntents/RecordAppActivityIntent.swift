//
//  RecordAppActivityIntent.swift
//  BetterCalendar
//
//  W13：给 iPhone「快捷指令 → 自动化 → App 打开 / 关闭」用的动作「记录 App 打开/关闭」。
//  - 后台运行、不打开 App（openAppWhenRun = false）：写本机一条 ActivityEvent（来源 shortcut），再经 iCloud 汇到 Mac。
//  - 系统的 App 触发器**不会把「是哪个 App」传给快捷指令**（2026-10 核实：Apple 文档只写了选 App 与打开/关闭；
//    one sec 等同类 App 也要求每个 App 单建一条自动化、在动作里再选一次 App）。所以：
//      · 一条自动化选「全部 App」→ 只能知道「某个 App 被打开了」（appName 留空，detail.appUnknown = true）；
//      · 想知道具体是哪个 App → 为那个 App 单建一条，在动作的「App 名称」里填名字。
//  - 已注册成 App Shortcut：快捷指令 App 里零配置就能找到，不用导入任何东西。
//

import AppIntents
import Foundation

enum ActivityAppEventKind: String, AppEnum {
    case opened, closed
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "App 事件"
    static var caseDisplayRepresentations: [ActivityAppEventKind: DisplayRepresentation] = [
        .opened: "打开", .closed: "关闭",
    ]
}

struct RecordAppActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "记录 App 打开/关闭"
    static var description = IntentDescription(
        "给快捷指令自动化用：App 被打开或关闭时在后台记一笔（不打开 BetterCalendar），经 iCloud 汇到 Mac 给 BetterCalendar 智能体当情境。设置 → 设备活动记录（实验）可暂停或关闭。")
    static var openAppWhenRun = false

    @Parameter(title: "事件", default: .opened)
    var event: ActivityAppEventKind

    @Parameter(title: "App 名称（可留空）", description: "系统不会告诉快捷指令是哪个 App；为某个 App 单建自动化时在这里填它的名字。")
    var appName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("记录 App \(\.$event)") { \.$appName }
    }

    init() {}

    init(event: ActivityAppEventKind, appName: String? = nil) {
        self.event = event; self.appName = appName
    }

    func perform() async throws -> some IntentResult {
        let result = try await ActivityShortcutRecorder.record(
            opened: event == .opened, appName: appName, at: .now, deviceId: FocusFollow.deviceID,
            platform: ActivityShortcutRecorder.platform, sink: .shared, extra: ActivityShortcutRecorder.deviceExtras())
        if case let .recorded(o) = result, let e = o.uploadError {
            // 本机已记下、在队列里，下次再传；记一条可见的日志（开发期失败可见）。
            DevLog.shared.warn("设备活动", "快捷指令记下了，但这次没传上 iCloud（\(o.pendingUpload) 条待传）：\(e)")
        }
        return .result()
    }
}
