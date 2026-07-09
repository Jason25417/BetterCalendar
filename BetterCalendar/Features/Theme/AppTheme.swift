//
//  AppTheme.swift
//  BetterCalendar
//
//  皮肤系统接口（§5.9，2026-07-08 Jason 定：先立缝+设置选项，新皮肤设计定稿后直接加主题）。
//  设计：主题 = 一组**语义色令牌**（不是散落的 Color 字面量）。视图逐步改读 @Environment(\.appTheme)；
//  新主题 = 在 ThemeSettings.all 里加一个 AppTheme 实例，设置页自动出现，零结构改动。
//

import SwiftUI

struct AppTheme: Identifiable, Equatable {
    let id: String
    let name: String
    // 语义色板：按"含义"命名（不按颜色名），换肤时整组替换
    var accent: Color            // 主强调（按钮/选中态）
    var plannedTint: Color       // 计划（绿系语义）
    var actualTint: Color        // 实际（蓝系语义）
    var previewTint: Color       // 预览/从现在起（橙系语义）
    var looseTint: Color         // 松散/退场（紫系语义）
    var positiveTint: Color      // 正反馈（做成/兑现）
}

enum ThemeSettings {
    /// 经典（当前唯一主题=现状配色的语义化命名）。
    static let classic = AppTheme(id: "classic", name: "经典",
                                  accent: .accentColor,
                                  plannedTint: .green, actualTint: .blue,
                                  previewTint: .orange, looseTint: .purple,
                                  positiveTint: .green)

    /// 可选主题清单：新皮肤设计定稿后在这里加一项即可（设置页 Picker 自动出现）。
    static var all: [AppTheme] { [classic] }

    static var current: AppTheme {
        get { all.first { $0.id == UserDefaults.standard.string(forKey: "theme.id") } ?? classic }
        set { UserDefaults.standard.set(newValue.id, forKey: "theme.id") }
    }
}

// MARK: - 披露风格（0.26 渐进披露 v2）——皮肤的"信息密度"维度（与色板正交）

/// 皮肤 = 色板(AppTheme) + **披露密度(DisclosureStyle)**（2026-07-09 Jason：用皮肤区分披露程度）。
/// 本轮只实现 `guide`（原皮「向导」：按时刻只显当刻所需）；`console`/`zen` **先留枚举+设置接口**，设计定稿再填。
enum DisclosureStyle: String, CaseIterable, Identifiable {
    case guide     // 原皮·向导：克制、按时刻披露、最少项（已实现）
    case console   // 控制台：全露高密（ICS/批量/时间轴常驻）——接口预留，暂回退 guide
    case zen       // 禅：比原皮更少——接口预留，暂回退 guide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .guide: "向导（默认·克制）"
        case .console: "控制台（高密·暂未实现）"
        case .zen: "禅（极简·暂未实现）"
        }
    }
    /// 是否已实现（未实现的行为=回退 guide；设置页可选但标注暂未实现）。
    var implemented: Bool { self == .guide }
}

enum DisclosureSettings {
    static var style: DisclosureStyle {
        get { DisclosureStyle(rawValue: UserDefaults.standard.string(forKey: "disclosure.style") ?? "") ?? .guide }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "disclosure.style") }
    }
    /// 高密皮肤才露的深水功能（如 ICS 导出）：目前仅 console 概念上为真，但 console 未实现→回退 guide→false。
    static var showsDeepFeatures: Bool { style == .console && style.implemented }
}

// MARK: - Environment 注入点（视图消费口）

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = ThemeSettings.classic
}

extension EnvironmentValues {
    /// 用法：视图里 `@Environment(\.appTheme) var theme`，取 `theme.plannedTint` 等语义色。
    /// 现有视图的硬编码颜色随新皮肤落地逐个迁移到这里（接口先行，不一次性大改）。
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
