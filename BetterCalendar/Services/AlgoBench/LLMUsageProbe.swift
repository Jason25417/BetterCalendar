//
//  LLMUsageProbe.swift
//  BetterCalendar
//
//  云端 token 用量探针（#41，2026-07-20，开发期·试验台专用）：
//  AnthropicClient 每次调用后记一笔；试验台跑单条用例前 reset()、跑完 take()——
//  用来量化「分步 / 脱敏」方案的**真实 token 成本**（#41 三指标之一：质量·延迟·成本）。
//  生产路径零影响（只写内存计数器，不落盘、不上传；随进程结束消失）。
//

import Foundation

final class LLMUsageProbe: @unchecked Sendable {
    struct Usage: Sendable, Equatable {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var calls = 0
        /// 计费口径的输入量（缓存命中部分按 0.1x 计——Anthropic 缓存读折扣）。
        var billedInputEquivalent: Int { inputTokens + cacheReadTokens / 10 }
    }

    static let shared = LLMUsageProbe()
    private let lock = NSLock()
    private var current = Usage()

    private init() {}

    func record(input: Int, output: Int, cacheRead: Int) {
        lock.lock(); defer { lock.unlock() }
        current.inputTokens += input
        current.outputTokens += output
        current.cacheReadTokens += cacheRead
        current.calls += 1
    }

    /// 归零（试验台每条用例开跑前调）。
    func reset() {
        lock.lock(); defer { lock.unlock() }
        current = Usage()
    }

    /// 取走本段累计（不归零——由下一次 reset 归零，避免并发下互相抹掉）。
    func take() -> Usage {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}
