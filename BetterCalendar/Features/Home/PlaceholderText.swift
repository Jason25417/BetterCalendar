//
//  PlaceholderText.swift
//  BetterCalendar
//
//  输入框预设文本（2026-07-08 Jason 定，产品哲学审查通过）：
//  教程示例只属于最初阶段——排今天成功满 10 次自动"毕业"换成小提示（零配置、无通知打扰）；
//  毕业后的前 3 次排程期间，文案尾注说明发生了什么+怎么还原（温和过渡，不弹任何窗）。
//  设置→进阶 可手动三选：教程示例 / 小提示 / 轻问候（"保留教程"就是逃生舱）。
//  文案铁律：全部前向、无催促、无审计——问候不许变成催促。
//

import Foundation

enum PlaceholderMode: String, CaseIterable {
    case tutorial = "tutorial"
    case tips = "tips"
    case greetings = "greetings"

    var label: String {
        switch self {
        case .tutorial: return "教程示例"
        case .tips: return "小提示"
        case .greetings: return "轻问候"
        }
    }
}

enum PlaceholderSettings {
    private static let defaults = UserDefaults.standard
    static let graduationThreshold = 10   // 排今天成功满 10 次 = 教程毕业

    static var mode: PlaceholderMode {
        get { PlaceholderMode(rawValue: defaults.string(forKey: "placeholder.mode") ?? "") ?? .tutorial }
        set { defaults.set(newValue.rawValue, forKey: "placeholder.mode") }
    }
    private(set) static var arrangeCount: Int {
        get { defaults.integer(forKey: "placeholder.arrangeCount") }
        set { defaults.set(newValue, forKey: "placeholder.arrangeCount") }
    }
    /// 是否经历过"自动毕业"（区别于用户手动切换——只有自动切换才显示过渡尾注）。
    private static var graduated: Bool {
        get { defaults.bool(forKey: "placeholder.graduated") }
        set { defaults.set(newValue, forKey: "placeholder.graduated") }
    }

    /// 排今天成功一次记一笔；达到阈值且仍在教程 → 自动毕业到小提示（静默，无通知）。
    static func recordArrangeSuccess() {
        arrangeCount += 1
        if arrangeCount >= graduationThreshold && mode == .tutorial {
            mode = .tips
            graduated = true
            DevLog.shared.info("预设文本", "教程毕业（第 \(arrangeCount) 次排程）→ 自动换小提示")
        }
    }

    private static let tutorial = "例：明早9点写代码两小时，11点开会，下午健身"

    // 小提示：功能发现向，一天换一条；全部前向措辞
    private static let tips = [
        "说「同时推进 A 和 B」，几件事会排进同一时段",
        "把事项时限标成「尽早」，reflow 会优先把它排前面",
        "写「周五前必须交」会记为硬截止（🏁）",
        "睡前跨过午夜的事，仍算今天这一天",
        "在 Apple 日历里挪绿色块，这里会跟着更新",
        "从 menu bar 开始第一件事，这一天就进入实时模式",
        "说「明天想松散一下」，App 会安静退场一天",
        "长期的事说「下周投入三小时」就会进未来任务",
    ]

    // 轻问候：陪伴感、零催促
    private static let greetings = [
        "今天想怎么过？说一句就好",
        "慢慢来，先说说今天的打算",
        "想到什么说什么，剩下的交给这里",
        "先定个大概就好，细节随时能调",
        "新的一天，从一句话开始",
        "把今天说给我听听",
    ]

    /// 当前该显示的占位文案（毕业后前 3 次排程期间带过渡尾注）。
    static func currentText(on date: Date = .now) -> String {
        let index = abs(Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 0)
        switch mode {
        case .tutorial:
            return tutorial
        case .tips:
            let base = tips[index % tips.count]
            if graduated && arrangeCount < graduationThreshold + 3 {
                return base + "（教程阶段已结束，换成小提示；想要教程示例可去 设置→进阶 还原）"
            }
            return base
        case .greetings:
            return greetings[index % greetings.count]
        }
    }
}
