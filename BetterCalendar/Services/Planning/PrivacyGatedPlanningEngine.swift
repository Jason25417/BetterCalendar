//
//  PrivacyGatedPlanningEngine.swift
//  BetterCalendar
//
//  「只使用端侧」的排程闸（2026-07-11 Jason 定）：开关开着时，排序/reflow 也**绝不出云**——
//  否则「只使用端侧」的绝对隐私承诺被排今天的块标题打穿，名不副实。
//  代价=排序降级为本地 Naive（保序、零智能建议）；RuleBasedArranger 试验台毕业后换上来补智能。
//  闸放在组装点包装器而不是 LLMPlanningEngine 内部：试验台直接构造 LLM 引擎测云端，不受开关影响。
//

import Foundation

struct PrivacyGatedPlanningEngine: PlanningEngine {
    let llm: PlanningEngine     // 云端（默认模式）
    let local: PlanningEngine   // 本地（只使用端侧时的全部；也是 llm 自己的失败回退）

    private var active: PlanningEngine { CloudSettings.onDeviceOnly ? local : llm }

    func arrange(_ blocks: [ScheduledBlock], now: Date) async throws -> PlanDecision {
        try await active.arrange(blocks, now: now)
    }

    func arrange(_ blocks: [ScheduledBlock], pool: [LongTaskBrief], now: Date) async throws -> PlanDecision {
        try await active.arrange(blocks, pool: pool, now: now)
    }

    func reflow(_ blocks: [ScheduledBlock], from startTime: Date, now: Date) async throws -> PlanDecision {
        try await active.reflow(blocks, from: startTime, now: now)
    }
}
