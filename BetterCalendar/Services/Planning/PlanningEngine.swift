//
//  PlanningEngine.swift
//  BetterCalendar
//
//  排程大脑：排序 / 优先级 / re-flow / 温和 push 决策。
//  原型期实现 = 云端 Claude（LLMPlanningEngine，待接），按「产品设计与行为逻辑.md §3」决策。
//  现用 NaivePlanningEngine 兜底。缝是 async throws + 输入输出皆为实现无关的 DTO。
//

import Foundation

protocol PlanningEngine {
    func arrange(_ blocks: [ScheduledBlock], now: Date) async throws -> PlanDecision

    /// 带「在途」池上下文的排程（M10-2）：可在空档给 0–2 个来自池的建议块（标来源、删除零成本）。
    func arrange(_ blocks: [ScheduledBlock], pool: [LongTaskBrief], now: Date) async throws -> PlanDecision

    /// 自愈 re-flow：从 startTime 起把剩余弹性块铺开、固定块锚住，返回「从现在起可行」的安排。
    /// 晨间（开工晚了整体平移）与全天连续（某块超时后重排剩余）都走它。
    func reflow(_ blocks: [ScheduledBlock], from startTime: Date, now: Date) async throws -> PlanDecision
}

extension PlanningEngine {
    /// 默认实现：忽略池（Naive 等本地引擎不做建议——建议是 LLM 的活）。
    func arrange(_ blocks: [ScheduledBlock], pool: [LongTaskBrief], now: Date) async throws -> PlanDecision {
        try await arrange(blocks, now: now)
    }
}
