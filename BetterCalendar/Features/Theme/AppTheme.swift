//
//  AppTheme.swift
//  BetterCalendar
//
//  皮肤系统接口（§5.9，2026-07-08 Jason 定：先立缝+设置选项，新皮肤设计定稿后直接加主题）。
//  设计：主题 = 一组**语义色令牌**（不是散落的 Color 字面量）。视图逐步改读 @Environment(\.appTheme)；
//  新主题 = 在 ThemeSettings.all 里加一个 AppTheme 实例，设置页自动出现，零结构改动。
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// 双模动态色（令牌表 v1，2026-07-14）：light/dark 各一 hex，跟随系统外观。
/// 值来源=《美术执行Spec》§一（Jason 试衣间裁定：语义色 3A-v2、微暖中性阶 1B、暮色橙 accent）。
extension Color {
    init(light: UInt32, dark: UInt32) {
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            let (r, g, b) = rgb(hex)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            let (r, g, b) = rgb(hex)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

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
    // 中性阶（条文 1B 微暖，换装批次 A 起）
    var bg: Color = Color(light: 0xF7F4F0, dark: 0x1D1B18)         // 页底
    var surface: Color = Color(light: 0xFFFDFB, dark: 0x292623)    // 卡面
    // 计时数字字形（条文 8，Jason 裁=b Rounded；tabular 由使用点 monospacedDigit 恒开）
    var digitDesign: Font.Design = .rounded
}

enum ThemeSettings {
    /// 经典 v1（2026-07-14 试衣间裁定落值）：3A-v2 沉稳三色相 + 暮色橙 accent + 微暖中性阶。
    /// loose 紫沿用系统（微决策区待定）；positive=计划绿同族（做成=计划的兑现）。
    static let classic = AppTheme(id: "classic", name: "经典",
                                  accent: Color(light: 0xC97C4E, dark: 0xD98F5F),
                                  plannedTint: Color(light: 0x57806B, dark: 0x9FC4AC),
                                  actualTint: Color(light: 0x4A6B8A, dark: 0x8FAECE),
                                  previewTint: Color(light: 0xB8823F, dark: 0xC98E4F),
                                  looseTint: .purple,
                                  positiveTint: Color(light: 0x57806B, dark: 0x9FC4AC))

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
