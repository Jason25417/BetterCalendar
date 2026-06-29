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
}
