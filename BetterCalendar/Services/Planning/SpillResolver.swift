//
//  SpillResolver.swift
//  BetterCalendar
//
//  溢出机制（统一时间线 P1c，SPEC §13.A.3）：FluidLayoutEngine 判定「谁装不下」（预见性，
//  排布时即知、非事后过期），本件裁决「去哪」。纯函数、零 LLM；连续顺延计数作输入
//  （持久化在 P1e 接线时挂真相源）。
//  策略四枚举与默认（哲学审核条件：「问一下」不得为任何 kind 的默认值）：
//    工作块 → 顺延明天；池投放件 → 回池；生活锚 → 溶解（零记录、明天照常、不进偏差叙事）。
//  升级为提议（escalate，橙色瞬态）只在预授权覆盖不了的三种局面：
//    撞 DDL 推不过去 / 连续自动顺延 ≥3 次（防僵尸模块天天静默滚）/ 用户显式设了 ask。
//  措辞红线（裁决书 B-3）：「作废/dissolve」是内部机制词，绝不上屏——面向用户走体面出口语系。
//

import Foundation

/// 溢出策略（每模块可显式设；nil = 按身份走默认）。
nonisolated enum SpillPolicy: String, Sendable {
    case forward        // 顺延到下一逻辑日
    case returnToPool   // 退回长期任务池
    case dissolve       // 溶解：零记录，模板明天照常（生活锚/routine 语义=占位让路，非承诺待验收）
    case ask            // 每次都问（只能用户显式选，不作默认）
}

/// 溢出候选（与排布 DTO 解耦；由 P1e 接线层从真相源装配）。
nonisolated struct SpillCandidate: Identifiable, Sendable {
    var id: UUID
    var title: String
    var deadline: Date?             // 硬 DDL（≠isFixed）
    var fromPool: Bool = false      // 池投放件（linkedTaskID != nil）
    var isAnchor: Bool = false      // 生活锚
    var policyOverride: SpillPolicy?   // 用户显式设置（恒压默认——数据只填空原则同族）
    var spillCount: Int = 0         // 已被连续自动顺延几次（P1e 持久化）
}

/// 裁决结果。
nonisolated enum SpillDecision: Equatable, Sendable {
    case forward(to: Date)              // 顺延到目标逻辑日（label）
    case returnToPool
    case dissolve
    case escalate(EscalationReason)     // 升级为提议（橙色瞬态，用户裁）

    enum EscalationReason: Equatable, Sendable {
        case deadlineBlocksForward      // 顺延目标日已超 DDL
        case repeatedSpills(count: Int) // 连续自动顺延达上限
        case userAskedToAsk             // 显式 ask 策略
    }
}

nonisolated enum SpillResolver {
    /// 连续自动顺延上限：达到即不再静默滚、升提议（防「僵尸模块每天自动滚一天」）。
    static let maxSilentSpills = 3

    /// 裁决一个溢出候选。reference = 当前窗口所在时刻（目标日 = 其下一逻辑日）。
    static func resolve(_ c: SpillCandidate, reference: Date) -> SpillDecision {
        // ① 显式 ask：用户要求每次过问
        if c.policyOverride == .ask { return .escalate(.userAskedToAsk) }

        // ② 连续顺延升级（对 forward 族生效；显式 override 为 forward 的同样受限——
        //    预授权范围不含「无限次滚」）
        let policy = c.policyOverride ?? defaultPolicy(for: c)
        if policy == .forward, c.spillCount >= maxSilentSpills {
            return .escalate(.repeatedSpills(count: c.spillCount))
        }

        switch policy {
        case .forward:
            let targetLabel = DayContext.logicalDay(offset: 1, from: reference)
            // ③ DDL 挡路：顺延目标日的窗口起点已在 DDL 之后 → 推不过去，升提议
            if let ddl = c.deadline,
               DayContext.logicalWindow(forLabel: targetLabel).start > ddl {
                return .escalate(.deadlineBlocksForward)
            }
            return .forward(to: targetLabel)
        case .returnToPool:
            return .returnToPool
        case .dissolve:
            return .dissolve
        case .ask:
            return .escalate(.userAskedToAsk)
        }
    }

    /// 身份 → 默认策略（「问一下」永不作默认——哲学审核条件）。
    static func defaultPolicy(for c: SpillCandidate) -> SpillPolicy {
        if c.isAnchor { return .dissolve }
        if c.fromPool { return .returnToPool }
        return .forward
    }

    /// 批量裁决（保持输入顺序）。
    static func resolveAll(_ candidates: [SpillCandidate], reference: Date) -> [(SpillCandidate, SpillDecision)] {
        candidates.map { ($0, resolve($0, reference: reference)) }
    }
}
