//
//  CloudDeadline.swift
//  BetterCalendar
//
//  W31/W31b：给 iCloud（CloudKit）调用限时。没登录 iCloud / 网络卡住时 CloudKit 可能永远不回——
//  界面就一直「发送中…」「等待读取计时状态」（模拟器实测 9 分钟以上），P4 不让你猜。
//  不用 task group：group 要等子任务结束，而卡住的 CloudKit 调用可能根本不响应取消；这里谁先到用谁，晚到的被丢弃。
//

import Foundation

@MainActor enum CloudDeadline {
    struct Timeout: LocalizedError {
        var seconds: TimeInterval
        var errorDescription: String? { "\(Int(seconds)) 秒内 iCloud 没有回应（可能没登录 iCloud 或网络不通）" }
    }

    private final class Once { var done = false; var timer: Task<Void, Never>? }

    static func race<T: Sendable>(seconds: TimeInterval, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let once = Once()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let work = Task { @MainActor in
                do {
                    let value = try await op()
                    once.timer?.cancel()
                    if !once.done { once.done = true; cont.resume(returning: value) }
                } catch {
                    once.timer?.cancel()
                    if !once.done { once.done = true; cont.resume(throwing: error) }
                }
            }
            once.timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, !once.done else { return }
                once.done = true; work.cancel(); cont.resume(throwing: Timeout(seconds: seconds))
            }
        }
    }
}
