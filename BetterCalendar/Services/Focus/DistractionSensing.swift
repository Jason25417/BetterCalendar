//
//  DistractionSensing.swift
//  BetterCalendar
//
//  分心检测 → 自动休息（#26，2026-07-11 Jason 拍板 V1）：专注中检测「你去休息了」
//  （前台切到自选名单里的 App / 网站）→ 自动开始休息（复用既有 休息=暂停计时+扣净投入 语义），
//  切回来 → 自动结束休息。定性=**被动信号的又一来源，不是「抓摸鱼」**。
//  四红线（哲学审核 2026-07-11，违一条即回炉）：
//  ① 默认关 + 名单用户自建（预先授权，原则 4④/7）
//  ② 来源永不入账本——日志/复盘只见「自动休息」，绝不见 App/网站名（羞辱铁律：不审计）
//  ③ 静默切换零通知——菜单栏 ☕ 就是全部反馈（通知铁则）
//  ④ 单次可撤销「刚才不算休息」（事后可改，原则 7）
//  平台：mac=本文件的感知器（NSWorkspace + AppleScript 问浏览器，apple-events entitlement 0.27 已有）；
//  iOS 不开放前台检测 → 走快捷指令个人自动化调 StartAutoBreakIntent/EndAutoBreakIntent。
//

import Foundation

/// 名单与开关（跨平台可读；感知器仅 macOS）。名单=关键词：命中 App 名 / bundle id / 网页地址 任一即算。
enum DistractionSettings {
    private static let defaults = UserDefaults.standard

    /// 总开关（默认关）。
    static var enabled: Bool {
        get { defaults.bool(forKey: "distraction.enabled") }
        set { defaults.set(newValue, forKey: "distraction.enabled") }
    }

    /// 关键词名单原文（逗号/顿号/分号/换行分隔）。空名单=不检测。
    static var keywordsText: String {
        get { defaults.string(forKey: "distraction.keywords") ?? "" }
        set { defaults.set(newValue, forKey: "distraction.keywords") }
    }

    /// 解析后的小写关键词（纯函数口径，可单测：见 parse）。
    static var keywords: [String] { parse(keywordsText) }

    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，、;；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

#if os(macOS)
import AppKit

/// mac 前台感知器：10 秒轮询（休息以分钟为尺度，秒级精度无意义还费电）。
/// 进入阈值 30s / 退出阈值 60s（内部参数不进设置，原则 6）——切走查个东西不算休息、
/// 切回来晃一眼也不算回来，防抖动。
@MainActor
final class MacDistractionSensor {
    private var timer: Timer?
    private var distractedSince: Date?
    private var cleanSince: Date?
    private var breakOn = false
    private let onChange: (Bool) async -> Void   // true=进自动休息，false=回来

    /// 外部条件（组装点注入）：有没有正在专注的事——空档不检测也不误触发。
    var isRelevant: () -> Bool = { false }

    private static let enterThreshold: TimeInterval = 30
    private static let exitThreshold: TimeInterval = 60

    /// 支持问当前页地址的浏览器（AppleScript；每个浏览器首次会弹一次系统「自动化」授权）。
    private static let browserScripts: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to if (count of windows) > 0 then return URL of current tab of front window",
        "com.google.Chrome": "tell application \"Google Chrome\" to if (count of windows) > 0 then return URL of active tab of front window",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to if (count of windows) > 0 then return URL of active tab of front window",
        "company.thebrowser.Browser": "tell application \"Arc\" to if (count of windows) > 0 then return URL of active tab of front window",
    ]

    init(onChange: @escaping (Bool) async -> Void) {
        self.onChange = onChange
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard DistractionSettings.enabled, !DistractionSettings.keywords.isEmpty, isRelevant() else {
            distractedSince = nil
            cleanSince = nil
            if breakOn { breakOn = false; Task { await onChange(false) } }   // 中途关开关/任务结束 → 收尾
            return
        }
        let hit = Self.frontmostHits(keywords: DistractionSettings.keywords)
        let now = Date.now
        if hit {
            cleanSince = nil
            if distractedSince == nil { distractedSince = now }
            if !breakOn, let s = distractedSince, now.timeIntervalSince(s) >= Self.enterThreshold {
                breakOn = true
                Task { await onChange(true) }
            }
        } else {
            distractedSince = nil
            if cleanSince == nil { cleanSince = now }
            if breakOn, let s = cleanSince, now.timeIntervalSince(s) >= Self.exitThreshold {
                breakOn = false
                Task { await onChange(false) }
            }
        }
    }

    /// 前台是否命中名单（红线②：命中的是谁不外传、不入任何日志）。
    private static func frontmostHits(keywords: [String]) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let name = (app.localizedName ?? "").lowercased()
        let bundle = (app.bundleIdentifier ?? "").lowercased()
        if keywords.contains(where: { name.contains($0) || bundle.contains($0) }) { return true }
        // 浏览器：问当前标签页地址（只在前台是已知浏览器时才发 AppleScript，10s 一次不扰）
        if let script = browserScripts[app.bundleIdentifier ?? ""],
           let url = runAppleScript(script)?.lowercased(), !url.isEmpty {
            return keywords.contains(where: { url.contains($0) })
        }
        return false
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { return nil }   // 未授权/浏览器没开脚本口：静默按不命中算（开发期不刷屏）
        return result?.stringValue
    }
}
#endif
