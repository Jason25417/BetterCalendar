//
//  PlanRefining.swift
//  BetterCalendar
//
//  二次调整：拿当前草稿 + 一句中文指令 → 调整后的草稿（自然语言微调）。
//  原型期走云端 Claude；失败则原样返回（不破坏用户已排的草稿）。
//

import Foundation

protocol PlanRefining {
    /// originalRequest = 用户最初的排程原文（约束上下文，微调不违背；可空串）。
    func refine(_ blocks: [ScheduledBlock], command: String,
                originalRequest: String, now: Date) async throws -> [ScheduledBlock]
}
