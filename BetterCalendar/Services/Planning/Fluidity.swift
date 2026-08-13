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

/// kind → 流动性 查表（v1 桥接现有二分 + isAnchor；生活种类行后议）。
nonisolated enum FluidityTable {
    /// 生活锚（isAnchor：午饭/通勤/午休）的软锚范围：±60 分钟（保守初值，学习层将来可校准）。
    static let anchorSoftRangeMinutes = 60

    static func resolve(isFixed: Bool, isAnchor: Bool) -> Fluidity {
        if isFixed { return .pinned }                              // 会议/外部承诺：钉死
        if isAnchor { return .soft(anchorSoftRangeMinutes) }       // 生活锚：±60
        return .free                                               // 工作块：日内队列流动
    }

    static func resolve(_ b: ScheduledBlock) -> Fluidity {
        resolve(isFixed: b.isFixed, isAnchor: b.isAnchor)
    }
}
