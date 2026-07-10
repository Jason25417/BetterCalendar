//
//  LLMWatchdog.swift
//  BetterCalendar
//
//  生产 LLM 看门狗（Jason 2026-07-10 定值 = p95 ≈ 10s，依据试验台延迟分布）：
//  单次云端调用最长 10s——极端慢答/流卡死/模型退化死循环不拖住确认按钮，到点取消走各自回退
//  （解析=对冲另两路或本地回退、排程/reflow=Naive、微调=保持原样）。
//  取值逻辑：清尾巴不清中位数——haiku 慢任务 p95≈9s，10s 极少误杀合法慢答案；3-5s 会误杀。
//  URLSession 层的 60s/150s 空闲超时仍在（网络级兜底），这里是业务级"总时长"兜底。
//

import Foundation

enum LLMWatchdog {
    /// 生产超时（秒）。调这里即可全局改（解析对冲/排程/reflow/微调 共用）。
    static let seconds: TimeInterval = 10

    /// 让 op 与超时赛跑：超时抛 AnthropicError，op 先完成则取消计时。
    static func run<T: Sendable>(seconds: TimeInterval = LLMWatchdog.seconds,
                                 _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AnthropicError(message: "LLM 看门狗超时（\(Int(seconds))s）")
            }
            guard let first = try await group.next() else {
                throw AnthropicError(message: "看门狗异常")
            }
            group.cancelAll()
            return first
        }
    }
}
