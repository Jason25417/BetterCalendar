//
//  Fluidity.swift
//  BetterCalendar
//
//  流动性模型（统一时间线 P1b，SPEC §13.A.2）：模块在时间线上的可移动性，三维度——
//  锚点（相对什么流）× 范围（能移多远）× 溢出策略（挪到头怎么办，P1c 加）。
//  把现有 isFixed 二分推广为连续谱：会议=钉死(0)、生活锚=±范围、工作块=日内队列流动。
//  值由 kind 查表推导（不逐块存、不做一等设置面——哲学审核条件）；生活种类
//  （吃饭/锻炼/睡眠/routine）的行后议（Jason 2026-08-01：通用模型期只做通用行）。
//

import Foundation

/// 模块的流动性：锚点 + 范围。
nonisolated struct Fluidity: Equatable, Sendable {
    /// 锚点：模块相对什么流动。
    enum Anchor: Equatable, Sendable {
        case clock          // 锚定墙钟时刻（基准=plannedStart）：会议、外部承诺
        case queue          // 锚定队列顺序（具体时刻无所谓，排第几才重要）：工作块
        // case habit       // 习惯时刻（吃饭 12:30±30）——生活种类后议，行预留
    }

    var anchor: Anchor
    /// 可移范围（分钟）：0=钉死；>0=±范围；nil=窗口内自由（日内流动）。
    var rangeMinutes: Int?

    /// 钉死（流动性 0）。
    static let pinned = Fluidity(anchor: .clock, rangeMinutes: 0)
    /// 窗口内自由流动（工作块默认）。
    static let free = Fluidity(anchor: .queue, rangeMinutes: nil)
    /// 软锚：墙钟 ± 分钟（生活锚/isAnchor 块）。
    static func soft(_ minutes: Int) -> Fluidity { Fluidity(anchor: .clock, rangeMinutes: minutes) }
}

/// 生活锚细表（K4，2026-08-15 Jason 放行；SPEC §13.1.A.2 已裁行）：
/// 吃饭=±30 / 锻炼·睡眠=±120 / 其他锚（通勤/午休/routine 门块）=±60。
/// 判定权威序：K1 模板实例的 `routine:` 标签（显式）→ 标题启发式兜底 → 默认 ±60。
/// 习惯锚点时刻（「你总是 12:40 吃饭」）等 L3 节律有数据后再接——本表只管范围。
nonisolated enum AnchorKindTable {
    static let mealRangeMinutes = 30
    static let bodyRangeMinutes = 120      // 锻炼/睡眠（A.2：±2h）
    static let defaultRangeMinutes = 60

    static let routinePrefix = "routine:"

    private static let mealWords = ["饭", "餐", "宵夜", "lunch", "dinner", "breakfast", "brunch"]
    private static let bodyWords = ["锻炼", "健身", "运动", "跑步", "睡", "gym", "workout"]

    static func rangeMinutes(title: String, labels: [String]) -> Int {
        if let kind = labels.first(where: { $0.hasPrefix(routinePrefix) })
            .map({ String($0.dropFirst(routinePrefix.count)) }) {
            switch kind {
            case "meal": return mealRangeMinutes
            case "exercise", "sleep": return bodyRangeMinutes
            default: return defaultRangeMinutes   // morning/evening 门块等
            }
        }
        let t = title.lowercased()
        if mealWords.contains(where: t.contains) { return mealRangeMinutes }
        if bodyWords.contains(where: t.contains) { return bodyRangeMinutes }
        return defaultRangeMinutes
    }
}

/// kind → 流动性 查表（K4 起为种类查表；resolve(isFixed:isAnchor:) 保留为无标题信息时的桥接）。
nonisolated enum FluidityTable {
    /// 无种类信息时生活锚的软锚范围（桥接默认）。
    static let anchorSoftRangeMinutes = AnchorKindTable.defaultRangeMinutes

    static func resolve(isFixed: Bool, isAnchor: Bool) -> Fluidity {
        if isFixed { return .pinned }                              // 会议/外部承诺：钉死
        if isAnchor { return .soft(anchorSoftRangeMinutes) }       // 生活锚（无种类信息）：±60
        return .free                                               // 工作块：日内队列流动
    }

    static func resolve(_ b: ScheduledBlock) -> Fluidity {
        if b.isFixed { return .pinned }
        if b.isAnchor { return .soft(AnchorKindTable.rangeMinutes(title: b.title, labels: b.labels)) }
        return .free
    }
}
