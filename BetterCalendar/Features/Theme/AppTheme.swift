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
    // 庆祝金（修正批 D，Jason 裁「进颜色系统」）：trophy/MVP 底/星光——庆祝白名单场域专用（轴 10）
    var celebrationTint: Color = Color(light: ClassicHex.celebration.light, dark: ClassicHex.celebration.dark)
    // 中性阶（条文 1B 微暖，换装批次 A 起）
    var bg: Color = Color(light: 0xF7F4F0, dark: 0x1D1B18)         // 页底
    var surface: Color = Color(light: 0xFFFDFB, dark: 0x292623)    // 卡面
    // 计时数字字形（条文 8，Jason 裁=b Rounded；tabular 由使用点 monospacedDigit 恒开）
    var digitDesign: Font.Design = .rounded
}

/// 字阶六档（条文 8，骨架令牌——换皮不换档；收敛表见《美术执行Spec》§二，换装批次 C 落地）。
/// 存量视图用系统档名但**只允许这六档的值**（display/title/headline/body/caption/caption2）；
/// 装饰性尺寸（庆祝星光）与开发件（试衣间）豁免。
enum TypeScale {
    /// 计时大数字（灵动岛/锁屏/未来的大计时版面）；tabular 由使用点 monospacedDigit 恒开
    static let display = Font.system(.title2, design: .rounded).weight(.medium)
    static let title = Font.title3        // 页面/分区标题（收敛自 largeTitle/title/title2/title3）
    static let headline = Font.headline   // 卡片/行标题（收敛自 headline 及标题性 subheadline）
    static let body = Font.callout        // 正文/引导句（收敛自 body/callout）
    static let caption = Font.caption     // 辅助说明/控件文字（收敛自 subheadline/caption）
    static let caption2 = Font.caption2   // 边缘状态/角注
}

/// 动效令牌（条文 10 执行层，2026-07-20 Jason 批）：常规=缓出、不弹跳、0.35s 上限。
/// 庆祝白名单（条文 10 例外）**逐件登记于此**——新增庆祝动效先登记再用，别散落字面量。
enum Motion {
    /// 小状态变化：勾选、显隐、行内收展、toast 手动收
    static let standard = Animation.easeOut(duration: 0.2)
    /// 布局级变化：面板展开、列表重排、大元素移出（=条文上限值）
    static let emphasis = Animation.easeOut(duration: 0.35)
    // —— 庆祝白名单（允许超上限/轻弹跳；件名与时长即登记）——
    /// 星光（CelebrationBurst，1.2s）
    static let starlight = Animation.easeOut(duration: 1.2)
    /// 成就 toast 滑入（spring 轻弹=「递到眼前」的手感；toast 整件在白名单）
    static let toastIn = Animation.spring(duration: 0.35)
}

/// 经典皮肤 hex 真相源（换装批次 B）：SwiftUI 之外的场景（EK 日历 cgColor 等）从这里取值，
/// 与 ThemeSettings.classic 同源——改色只改这一处。
enum ClassicHex {
    static let accent: (light: UInt32, dark: UInt32)  = (0xC97C4E, 0xD98F5F)
    static let planned: (light: UInt32, dark: UInt32) = (0x57806B, 0x9FC4AC)
    static let actual: (light: UInt32, dark: UInt32)  = (0x4A6B8A, 0x8FAECE)
    static let preview: (light: UInt32, dark: UInt32) = (0xB8823F, 0xC98E4F)
    /// 庆祝金（修正批 D）：与暮色橙同族的低饱和暖金——收编原系统 yellow
    static let celebration: (light: UInt32, dark: UInt32) = (0xCFA14D, 0xDFB768)
}

enum ThemeSettings {
    /// 经典 v1（2026-07-14 试衣间裁定落值）：3A-v2 沉稳三色相 + 暮色橙 accent + 微暖中性阶。
    /// loose 紫沿用系统（微决策区待定）；positive=计划绿同族（做成=计划的兑现）。
    static let classic = AppTheme(id: "classic", name: "经典",
                                  accent: Color(light: ClassicHex.accent.light, dark: ClassicHex.accent.dark),
                                  plannedTint: Color(light: ClassicHex.planned.light, dark: ClassicHex.planned.dark),
                                  actualTint: Color(light: ClassicHex.actual.light, dark: ClassicHex.actual.dark),
                                  previewTint: Color(light: ClassicHex.preview.light, dark: ClassicHex.preview.dark),
                                  looseTint: .purple,
                                  positiveTint: Color(light: ClassicHex.planned.light, dark: ClassicHex.planned.dark))

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
