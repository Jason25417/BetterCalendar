//
//  RecordAppEventIntents.swift
//  BetterCalendar
//
//  W13：给 iPhone「快捷指令 → 自动化 → App 已打开 / 已关闭」用的两个动作（后台运行，不打开 BetterCalendar）。
//  做法来自 Jason 自己的快捷指令「打开/关闭游戏模式 v10.1」（原来用 Data Jar 记状态，现在搬进 BetterCalendar）：
//    - 「记录 App 打开」：自动化选「全部 App」，快捷指令先「获取当前 App」，把它传进 App 参数 → 记打开，并记住这是哪个 App。
//    - 「记录 App 关闭」：快捷指令先等 2 秒、再「获取当前 App」，把它传进「现在前台的 App」→ 与记住的比较：
//      相同 = 只是控制中心 / 通知盖了一层（记 overlay，不算关闭）；空 = 回主屏幕（真关闭）；别的 App = 切换（记上一个关闭）。
//    判断逻辑见 Services/Activity/PhoneAppSession.swift。
//  做好的两个快捷指令（可导入）在仓库 BetterCalendar/ActivityShortcuts/（随 App 打包，iPhone 设置引导里一键分享导入），自动化里直接「运行快捷指令」它们即可。
//  注册成 App Shortcut：快捷指令 App 里零配置就能找到这两个动作。
//  ⚠️ 快捷指令文件按类型名引用动作（com.jason.BetterCalendar.RecordAppOpenedIntent / RecordAppClosedIntent，参数 appName）：
//     改类型名或参数名会让已导入的快捷指令失效，要同步重新生成 BetterCalendar/ActivityShortcuts/（scripts/make-activity-shortcuts.py）。
//

import AppIntents
import Foundation

struct RecordAppOpenedIntent: AppIntent {
    static var title: LocalizedStringResource = "记录 App 打开"
    static var description = IntentDescription(
        "给「App 已打开」自动化用：把「获取当前 App」的结果传进 App，在后台记一笔（不打开 BetterCalendar），经 iCloud 汇到 Mac 给 BetterCalendar 智能体当情境。设置 → 设备活动记录（实验）可暂停或关闭。")
    static var openAppWhenRun = false

    @Parameter(title: "App", description: "接「获取当前 App」的结果；留空也能记，只是不知道是哪个 App。")
    var appName: String?

    static var parameterSummary: some ParameterSummary { Summary("记录 \(\.$appName) 打开") }

    init() {}
    init(appName: String?) { self.appName = appName }

    func perform() async throws -> some IntentResult {
        let r = try await ActivityShortcutRecorder.recordOpened(
            appName: appName, at: .now, deviceId: FocusFollow.deviceID, platform: ActivityShortcutRecorder.platform,
            sink: .shared, extra: ActivityShortcutRecorder.deviceExtras())
        ActivityShortcutRecorder.reportUpload(r)
        return .result()
    }
}

struct RecordAppClosedIntent: AppIntent {
    static var title: LocalizedStringResource = "记录 App 关闭"
    static var description = IntentDescription(
        "给「App 已关闭」自动化用：先等 2 秒，再把「获取当前 App」的结果传进「现在前台的 App」。和打开时记下的相同 = 只是控制中心 / 通知盖了一层，不算关闭；为空（回到主屏幕）或换了 App 才算关闭。后台运行，不打开 BetterCalendar。")
    static var openAppWhenRun = false

    @Parameter(title: "现在前台的 App", description: "关闭后等 2 秒再「获取当前 App」得到的那个；回到主屏幕时为空。")
    var appName: String?

    static var parameterSummary: some ParameterSummary { Summary("记录 App 关闭（现在前台：\(\.$appName)）") }

    init() {}
    init(appName: String?) { self.appName = appName }

    func perform() async throws -> some IntentResult {
        let r = try await ActivityShortcutRecorder.recordClosed(
            frontApp: appName, at: .now, deviceId: FocusFollow.deviceID, platform: ActivityShortcutRecorder.platform,
            sink: .shared, extra: ActivityShortcutRecorder.deviceExtras())
        ActivityShortcutRecorder.reportUpload(r)
        return .result()
    }
}

extension ActivityShortcutRecorder {
    /// 本机已记下、但这次没传上 iCloud：留在队列里下次再传；记一条可见的日志（开发期失败可见）。
    static func reportUpload(_ r: Result) {
        if case let .recorded(_, o) = r, let e = o.uploadError {
            DevLog.shared.warn("设备活动", "快捷指令记下了，但这次没传上 iCloud（\(o.pendingUpload) 条待传）：\(e)")
        }
    }
}
