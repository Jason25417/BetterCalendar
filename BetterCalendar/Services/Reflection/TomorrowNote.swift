//
//  TomorrowNote.swift
//  BetterCalendar
//
//  「给明天的一句话」（#23，2026-07-10 Jason 定形态）：**直接写在日记正文里**（无专门输入框），
//  本地规则解析提取（端侧、确定性、零模型依赖）→ 次日晨间：排日程页顶部消息条 +（若已排）并入早通知。
//  哲学定性（通知审核 2026-07-10）：这不是系统 push，是**用户自我 push 的传递管道**——发出者是昨晚的
//  用户自己（原则 4④ 预先授权的最纯形态）；不写=完全不存在；绝不提供默认模板（系统的话不许装成用户的话）。
//  存储：UserDefaults 按逻辑日 keyed（零 schema、免 CloudKit deploy）；档案天然留在日记正文里。
//

import Foundation

enum TomorrowNote {
    /// 识别前缀（行首匹配，全半角冒号/逗号都认）。刻意保守——宁可漏不误提（漏了明早只是没消息条，
    /// 误提会把普通句子当寄语推给明早的用户）。
    static let markers = ["给明天", "对明天说", "明天的我", "致明天"]

    /// 从日记正文提取寄语（纯函数、可单测）：取**最后一个**匹配行（用户改主意以最后写的为准）；
    /// 去掉前缀与标点，空则视为没写。nil = 正文里没有寄语。
    static func extract(from body: String) -> String? {
        var found: String?
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            for m in markers where line.hasPrefix(m) {
                var rest = String(line.dropFirst(m.count))
                rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "：: ，, 、—-"))
                if !rest.isEmpty { found = rest }
            }
        }
        return found
    }

    // MARK: 传递（昨晚 → 今晨）

    private static func key(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "tomorrowNote." + f.string(from: day)
    }

    /// 把今晚写的寄语存给**下一个逻辑日**；nil/空 = 清掉（用户删了那行）。
    static func store(_ note: String?, writtenOn now: Date = .now) {
        let target = DayContext.logicalStartOfDay(now).addingTimeInterval(24 * 3600)
        if let note, !note.isEmpty {
            UserDefaults.standard.set(note, forKey: key(target))
            // 埋点（调研 F 组）：有寄语的晚上——只记「今晚写了」这个事实（不记内容），按天去重
            BehaviorLog.recordOncePerDay(key: "寄语提取", "寄语", "今晚写了给明天的一句话")
        } else {
            UserDefaults.standard.removeObject(forKey: key(target))
        }
    }

    /// 今晨该显示的寄语（昨晚写的）。
    static func note(for now: Date = .now) -> String? {
        UserDefaults.standard.string(forKey: key(DayContext.logicalStartOfDay(now)))
    }

    /// 晨间消息条的「今天先收起」（只收当天，明天有新寄语照常出现）。
    static func dismiss(for now: Date = .now) {
        UserDefaults.standard.set(true, forKey: key(DayContext.logicalStartOfDay(now)) + ".dismissed")
        BehaviorLog.record("寄语", "晨间条收起（✕）")
    }
    static func isDismissed(for now: Date = .now) -> Bool {
        UserDefaults.standard.bool(forKey: key(DayContext.logicalStartOfDay(now)) + ".dismissed")
    }
}
