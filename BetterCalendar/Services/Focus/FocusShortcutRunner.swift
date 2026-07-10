//
//  FocusShortcutRunner.swift
//  BetterCalendar
//
//  番茄 ⇄ 系统专注（2026-07-10 spike 通过后落地 v1，初审见待讨论点子/会话记录）：
//  番茄工作循环开始 → 执行「开始快捷指令」（内含系统"设定专注"动作）；退出番茄（完成/换件/转轻计时）→
//  执行「结束快捷指令」。系统没有开关专注的公开 API，这是同类工具的通行折中。
//  通道 = Shortcuts Events 的 AppleScript（**无界面、不跳转**；沙盒合法 = apple-events entitlement，
//  首次执行系统弹一次「想控制 Shortcuts Events」授权）。
//  原则 4④/7：快捷指令是用户**自己建**的（预先授权）、名字自己填、留空 = 不启用；失败 DevLog 可见不静默。
//

#if os(macOS)
import Foundation

enum FocusShortcutRunner {
    /// 番茄开始时执行的快捷指令名（空 = 不启用）。
    static var startShortcut: String {
        get { UserDefaults.standard.string(forKey: "focus.shortcut.start") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "focus.shortcut.start") }
    }
    /// 番茄结束时执行的快捷指令名（空 = 不启用）。
    static var endShortcut: String {
        get { UserDefaults.standard.string(forKey: "focus.shortcut.end") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "focus.shortcut.end") }
    }

    static func pomodoroDidStart() { run(startShortcut, phase: "开始") }
    static func pomodoroDidEnd() { run(endShortcut, phase: "结束") }

    /// 后台线程执行（AppleScript 会阻塞到快捷指令跑完/TCC 授权响应，不能占主线程）。
    private static func run(_ name: String, phase: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let escaped = n.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
            let source = "tell application \"Shortcuts Events\" to run the shortcut named \"\(escaped)\""
            var errInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errInfo)
            let failure = errInfo.map { String(describing: $0[NSAppleScript.errorMessage] ?? $0) }
            Task { @MainActor in
                if let failure {
                    DevLog.shared.warn("专注", "番茄\(phase)快捷指令「\(n)」执行失败：\(failure)")
                } else {
                    DevLog.shared.info("专注", "番茄\(phase) → 已执行快捷指令「\(n)」")
                }
            }
        }
    }
}
#endif
