//
//  InvestedBar.swift
//  BetterCalendar
//
//  burnup 投入条（2026-07-20 长期页审计 #6/#12 抽出，进组件登记表）：
//  只增不减的「已投入」呈现。**红线**：这不是完成率条、不是剩余量条——
//  fraction 只用来画「从零长起来的那段」，绝不派生「还差多少」的任何表达（羞辱铁律）。
//  单一高度 4pt（8pt 网格半格）；空轨 quaternary、填充 positiveTint。
//

import SwiftUI

struct InvestedBar: View {
    @Environment(\.appTheme) private var theme
    /// 0…1；调用方自行 clamp（LongTaskStore.progressFraction 已 min(1.0, …)）。
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(theme.positiveTint)
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)   // 数值信息由旁边的「已投入 X」文字承载，条只是视觉冗余
    }
}
