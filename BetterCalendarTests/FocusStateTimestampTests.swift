//
//  FocusStateTimestampTests.swift
//  BetterCalendarTests
//
//  聪音联动·时间戳授时协议（0.66）：游戏侧要能用 startedAt + pausedSec 纯算术推回净投入，
//  且推算结果与 BC 自己的 elapsedSec 一致——这是「忽略轮询延迟与掉帧」的地基。
//

import Testing
import Foundation
@testable import BetterCalendar

@Suite struct FocusStateTimestampTests {
    /// 游戏侧的推算公式（mod C# 侧 SyncClock 的等价实现，在这里锁住语义）。
    private func gameSideNet(startedAt: Date, pausedSec: Int, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt)) - pausedSec)
    }

    /// 无休息：净投入 = 墙钟差。
    @Test func netEqualsWallClockWhenNoBreak() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let now = start.addingTimeInterval(1800)   // 30 分钟
        #expect(gameSideNet(startedAt: start, pausedSec: 0, now: now) == 1800)
    }

    /// 有休息：pausedSec 被扣掉——这正是 elapsedSec 的语义（currentElapsed 扣 pausedTotal）。
    @Test func pausedSecondsAreDeducted() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let now = start.addingTimeInterval(3600)   // 墙钟 60 分
        let paused = 600                            // 休息 10 分
        #expect(gameSideNet(startedAt: start, pausedSec: paused, now: now) == 3000, "净投入 50 分")
    }

    /// 轮询延迟不影响：游戏晚 T 秒才读到文件，推算值自然多出 T 秒（跟真实墙钟一致）——
    /// 而快照量 elapsedSec 会停在写文件那一刻、少 T 秒。这就是改协议的理由。
    @Test func timestampImmuneToPollingDelay() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let writtenAt = start.addingTimeInterval(600)      // BC 写文件时：已 10 分
        let snapshotElapsed = 600
        let readAt = writtenAt.addingTimeInterval(8)       // 游戏 8 秒后才读到
        let recomputed = gameSideNet(startedAt: start, pausedSec: 0, now: readAt)
        #expect(recomputed == 608, "时间戳推算跟到真实此刻")
        #expect(snapshotElapsed == 600, "快照量停在写入时刻")
        #expect(recomputed - snapshotElapsed == 8, "差额=轮询延迟，正是旧协议的漂移来源")
    }

    /// 协议兼容：pausedSec 是 optional，老 mod 不读它也能照常解析（缺省按 0 处理）。
    @Test func pausedSecIsOptionalForBackCompat() throws {
        // schemaVersion 虽有默认值，Codable 合成解码器仍要求键存在——真实导出文件恒带它。
        let json = """
        {"schemaVersion":1,"updatedAt":"2026-08-21T00:00:00Z","active":{"title":"写作",
        "timingStyle":"light","startedAt":"2026-08-21T00:00:00Z","elapsedSec":600}}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let state = try dec.decode(FocusStateExporter.State.self, from: Data(json.utf8))
        #expect(state.active?.pausedSec == nil, "缺字段=nil，游戏侧按 0 兜底")
        #expect(state.active?.elapsedSec == 600)
    }
}
