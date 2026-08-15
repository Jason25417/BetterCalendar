//
//  ExecutionProgressReading.swift
//  BetterCalendar
//
//  执行进展只读接缝（0.24 C2，SPEC §11 ④）：排日程页的「实时日精修台」需要知道
//  哪些计划块已尘埃落定（已完成 / 前台进行中 / 后台并行中）——它们属于"过去只读"，
//  精修台不加载、确认写入时原样保留。协议放 Services 层：两个 Feature VM 之间不直接互赖。
//

import Foundation

/// 前台进行中块的活预报（E5b）：[实际开始, 预测结束]——绿色成为活的预报（D-2 改判）的口径来源。
nonisolated struct ActivePrediction: Equatable, Sendable {
    var id: UUID       // 对应计划块 id
    var start: Date    // 实际开始时刻
    var end: Date      // 预测结束 = now + max(60s, 计划时长 − 已投入)
}

@MainActor
protocol ExecutionProgressReading: AnyObject {
    /// 已尘埃落定的计划块 id：已完成 + 前台进行中 + 后台并行中。
    var settledPlannedIDs: Set<UUID> { get }
    /// 前台进行中块的活预报（nil=空档/计划外 bonus）。
    var activePrediction: ActivePrediction? { get }
}

extension ExecutionProgressReading {
    var activePrediction: ActivePrediction? { nil }   // 既有 conformer/测试 fake 免改
}

/// 执行进展变化信号（开始/完成/换件等动作后发出）：
/// 排日程页据此刷新精修台底（干净时）或亮新鲜度徽标（编辑中时）。
enum ExecutionProgressSignal {
    static let changed = Notification.Name("bc.execution.progressChanged")
}
