//
//  Changelog.swift
//  BetterCalendar
//
//  应用基本信息 + 应用内更新日志（左下角可点版本号 → 弹更新日志）。
//  版本号读自工程的 MARKETING_VERSION（CFBundleShortVersionString）。
//  规则：第三节（补丁）每次改动自增；大/中版本要改先与作者确认。
//

import Foundation

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
    static let author = "Jason Tu"
    static let name = "BetterCalendar"
    static var copyright: String { "© 2026 \(author) · \(name)" }
}

struct ChangelogEntry: Identifiable {
    let id = UUID()
    let version: String
    let date: String
    let changes: [String]
}

/// 更新日志：以后每改一版，在最前面加 / 更新一条。
enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(version: "0.1", date: "2026-06", changes: [
            "M0 骨架：分层架构（App / Models / Services 协议+实现 / Features / UseCases）",
            "SwiftData 数据模型（PlanDay / PlanBlock / CompletionLink / ExecutionSession / AppSettings）",
            "协议桩 + 假日历预览（FakeCalendarStore）：开发期不污染系统日历",
            "排程大脑接口（ScheduleParsing / PlanningEngine）+ 朴素本地兜底实现，空界面跑通",
        ]),
    ]
}
