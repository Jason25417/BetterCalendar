//
//  TerrainSummary.swift
//  BetterCalendar
//
//  剩余地形（E5e，§14.6）：投放画面显示当日剩余真实空间——**空间事实措辞**，
//  绝不做「排太多」评判（R 线）；超订不显负数，只说「今天已排满」。纯函数、可单测。
//

import Foundation

nonisolated enum TerrainSummary {
    /// [from, until) 内扣除已占时段后的自由分钟数（时段可乱序可重叠，统一裁剪合并）。
    static func freeMinutes(spans: [(start: Date, end: Date)], from: Date, until: Date) -> Int {
        guard until > from else { return 0 }
        let clipped = spans
            .map { (max($0.start, from), min($0.end, until)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var cursor = from
        var busy: TimeInterval = 0
        for (s, e) in clipped {
            if e <= cursor { continue }
            busy += e.timeIntervalSince(max(s, cursor))
            cursor = max(cursor, e)
        }
        return max(0, Int((until.timeIntervalSince(from) - busy) / 60))
    }

    /// 呈现一行（空间事实）：≥1 小时报小时、<1 小时报分钟、≤5 分钟=「今天已排满」。
    static func line(freeMinutes m: Int) -> String {
        if m <= 5 { return "今天已排满" }
        if m < 60 { return "到收工还有约 \(m) 分钟自由区" }
        let h = m / 60
        let rem = m % 60
        return rem >= 15 ? "到收工还有约 \(h) 小时 \(rem) 分自由区" : "到收工还有约 \(h) 小时自由区"
    }
}
