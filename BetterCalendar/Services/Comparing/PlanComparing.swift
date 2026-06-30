//
//  PlanComparing.swift
//  BetterCalendar
//
//  签名功能的引擎：预先设计（绿）× 实际（蓝）→ done/partial/missed/over/extra。
//  定位（见 产品设计与行为逻辑.md §1/§3.4）：服务于「自愈 + 温和洞察」，**不是打分器**。
//  原型期本地启发式（时间重叠 × 标题相似）；日后可换 LLM 实现，藏在本协议后、上层不动。
//

import Foundation

/// 对比中的一行：一个计划块与其实际匹配的关系，或一条计划外 bonus。
struct ComparedItem: Identifiable, Sendable {
    var id = UUID()
    var status: CompletionStatus
    var plannedTitle: String?     // extra(计划外) 为 nil
    var actualTitle: String?      // missed(未做) 为 nil
    var plannedMinutes: Int?
    var actualMinutes: Int?
    var anchor: Date              // 排序/展示锚点（实际优先，否则计划）

    var displayTitle: String { actualTitle ?? plannedTitle ?? "" }
    /// 匹配上但标题明显不同 = 内容变更（如 健身 → 跑步）。
    var isContentChange: Bool {
        guard status != .extra, status != .missed,
              let p = plannedTitle, let a = actualTitle else { return false }
        return TitleMatch.similarity(p, a) < 0.5
    }
}

/// 一天的对比结果：正反馈聚合（一级）+ 明细（含默认隐藏的缺口）。
struct DayComparison: Sendable {
    var items: [ComparedItem] = []

    /// 正反馈主面：做成了的（done/partial/over/extra），未做不进。
    var accomplished: [ComparedItem] { items.filter { $0.status != .missed } }
    /// 计划外 bonus（高亮、算赢）。
    var bonus: [ComparedItem] { items.filter { $0.status == .extra } }
    /// 默认隐藏的二级：没做的。
    var missed: [ComparedItem] { items.filter { $0.status == .missed } }

    var accomplishedCount: Int { accomplished.count }
    var bonusCount: Int { bonus.count }
    var missedCount: Int { missed.count }
    /// 有效投入分钟 = 所有实际块时长之和。
    var effectiveMinutes: Int { items.compactMap(\.actualMinutes).reduce(0, +) }
}

protocol PlanComparing {
    /// 纯函数、本地、确定：时间重叠 × 标题相似 → 归类。
    func compare(planned: [CalendarEventDraft], actual: [CalendarEventDraft]) -> DayComparison
}

// MARK: - 标题匹配（对比与 menu bar「是否已做」共用）

enum TitleMatch {
    /// 归一化：转小写、只留字母/数字/中日韩汉字，丢空白与标点。
    static func normalize(_ s: String) -> String {
        let kept = s.lowercased().unicodeScalars.filter { sc in
            CharacterSet.alphanumerics.contains(sc) || (sc.value >= 0x4E00 && sc.value <= 0x9FFF)
        }
        return String(String.UnicodeScalarView(kept))
    }

    /// 0…1 相似度：完全相同=1、互为子串≈0.9，否则字符集合 Jaccard。
    /// 注：英文按字母集合区分较弱（read/dear 同集合），原型期够用；日后可换 bigram/编辑距离。
    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a), nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return 0 }
        if na == nb { return 1 }
        if na.contains(nb) || nb.contains(na) { return 0.9 }
        let sa = Set(na), sb = Set(nb)
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}
