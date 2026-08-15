//
//  SpillResolver.swift
//  BetterCalendar
//
//  溢出机制（统一时间线 P1c；E5c 裁定版=I1 收口 2026-08-14）：FluidLayoutEngine 判定「谁装不下」
//  （预见性，排布时即知、非事后过期），本件裁决「去哪」。纯函数、零 LLM。
//  两阶段溢出：软标记（TimelineCoordinator 派生态，随时可逆）→ 收工复盘硬执行（executeSpills）。
//  裁定默认（待办池一池两区）：生活锚 → 溶解（零记录、明天照常、不进偏差叙事）；
//  其余 → **收待办区**（returnToPool；池投放件=回它的长期任务）——溢出物不自动滚明天，
//  连滚问题结构性消失（原「连续顺延 ≥3 次升级」机制随之退役）。
//  forward 保留为用户显式选项（复盘展开逐件可改「排到明天」）。
//  升提议（escalate）只剩两种局面：撞 DDL 推不过去（晨间摘要置顶）/ 用户显式设了 ask。
//  哲学审核条件不变：「问一下」不得为任何 kind 的默认值（机器检查锁定）。
//  措辞红线（裁决书 B-3）：「作废/dissolve」是内部机制词，绝不上屏——面向用户走体面出口语系。
//

import Foundation

/// 溢出策略（每模块可显式设；nil = 按身份走默认）。
nonisolated enum SpillPolicy: String, Sendable {
    case forward        // 顺延到下一逻辑日（用户显式选项，非默认）
    case returnToPool   // 收待办区 / 回长期池（裁定默认）
    case dissolve       // 溶解：零记录，模板明天照常（生活锚/routine 语义=占位让路，非承诺待验收）
    case ask            // 每次都问（只能用户显式选，不作默认）
}

/// 溢出候选（与排布 DTO 解耦；由接线层从真相源装配）。
nonisolated struct SpillCandidate: Identifiable, Sendable {
    var id: UUID
    var title: String
    var deadline: Date?             // 硬 DDL（≠isFixed）
    var fromPool: Bool = false      // 池投放件（linkedTaskID != nil）
    var isAnchor: Bool = false      // 生活锚
    var policyOverride: SpillPolicy?   // 用户显式设置（恒压默认——数据只填空原则同族）
}

/// 裁决结果。
nonisolated enum SpillDecision: Equatable, Sendable {
    case forward(to: Date)              // 顺延到目标逻辑日（label）
    case returnToPool
    case dissolve
    case escalate(EscalationReason)     // 升级为提议（晨间摘要置顶，用户裁）

    enum EscalationReason: Equatable, Sendable {
        case deadlineBlocksForward      // 明天窗口起点已超 DDL——静默收池会错过，必须露脸
        case userAskedToAsk             // 显式 ask 策略
    }
}

nonisolated enum SpillResolver {

    /// 裁决一个溢出候选。reference = 当前窗口所在时刻（顺延目标日 = 其下一逻辑日）。
    static func resolve(_ c: SpillCandidate, reference: Date) -> SpillDecision {
        // ① 显式 ask：用户要求每次过问
        if c.policyOverride == .ask { return .escalate(.userAskedToAsk) }
        let policy = c.policyOverride ?? defaultPolicy(for: c)
        let targetLabel = DayContext.logicalDay(offset: 1, from: reference)

        // ② DDL 挡路：明天窗口起点已在 DDL 之后——顺延/收池都会静默错过 → 升提议（晨间置顶）
        if policy != .dissolve, let ddl = c.deadline,
           DayContext.logicalWindow(forLabel: targetLabel).start > ddl {
            return .escalate(.deadlineBlocksForward)
        }

        switch policy {
        case .forward: return .forward(to: targetLabel)
        case .returnToPool: return .returnToPool
        case .dissolve: return .dissolve
        case .ask: return .escalate(.userAskedToAsk)
        }
    }

    /// 身份 → 默认策略（E5c 裁定版；「问一下」永不作默认——哲学审核条件）。
    static func defaultPolicy(for c: SpillCandidate) -> SpillPolicy {
        if c.isAnchor { return .dissolve }
        return .returnToPool   // 工作块收待办区；池投放件回长期池——都不自动滚明天
    }

    /// 批量裁决（保持输入顺序）。
    static func resolveAll(_ candidates: [SpillCandidate], reference: Date) -> [(SpillCandidate, SpillDecision)] {
        candidates.map { ($0, resolve($0, reference: reference)) }
    }
}
