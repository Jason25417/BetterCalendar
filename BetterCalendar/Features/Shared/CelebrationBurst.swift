//
//  CelebrationBurst.swift
//  BetterCalendar
//
//  轻量庆祝视觉（#33，Jason 定：主动正反馈的小仪式）：一次性星光绽放，无声、1.2 秒自然消散。
//  措辞红线照旧：肯定「已经很努力」，不比较、不算账。
//

import SwiftUI

struct CelebrationBurst: View {
    @Environment(\.appTheme) private var theme   // 令牌表 v1（换装批次 B）
    @State private var animate = false
    var body: some View {
        ZStack {
            ForEach(0..<10, id: \.self) { i in
                let angle = Double(i) / 10 * 2 * .pi
                Image(systemName: i % 3 == 0 ? "sparkles" : "sparkle")
                    .font(.system(size: CGFloat(12 + (i % 3) * 5)))
                    .foregroundStyle(i % 2 == 0 ? theme.celebrationTint : theme.accent)   // 庆祝金+暮色橙（D，全令牌）
                    .offset(x: animate ? cos(angle) * 52 : 0, y: animate ? sin(angle) * 34 : 0)
                    .opacity(animate ? 0 : 1)
                    .scaleEffect(animate ? 1.5 : 0.3)
            }
        }
        .frame(height: 44)
        .onAppear { withAnimation(Motion.starlight) { animate = true } }   // 白名单件（条文10）
        .allowsHitTesting(false)
    }
}
