//
//  AchievementToast.swift
//  BetterCalendar
//
//  成就应用内 toast（#36 过审 2026-07-13，三红线）：顶部小窗 8 秒自动收起、上划即走、点击进成就页；
//  ①执行中绝不弹（计时进行中缓存，空档再出）②同刻多枚合并一条 ③文案照成就红线（禁比较/禁催促）。
//  刻意不走系统通知：零通知中心残留、零系统额度占用（通知铁则的「极简」照顾到 App 内）。
//

import SwiftUI

@Observable
final class AchievementToastCenter {
    static let shared = AchievementToastCenter()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var line: String
    }

    private(set) var current: Item?
    private var pending: [Milestone] = []
    /// 执行态门控（红线①）：组装点接「有计时在进行吗」；true=先攒着。
    var isBusy: (() -> Bool)?
    /// 点击进成就页（组装点接路由）。
    var onTap: (() -> Void)?

    func push(_ milestones: [Milestone]) {
        guard !milestones.isEmpty else { return }
        pending.append(contentsOf: milestones)
        pump()
    }

    /// 出队（空档才出；执行中由下一次 push/进日记页时再试）。
    func pump() {
        guard current == nil, !pending.isEmpty, !(isBusy?() ?? false) else { return }
        let batch = pending
        pending = []
        let item: Item = batch.count == 1
            ? Item(title: batch[0].title, line: batch[0].line)
            : Item(title: "点亮了 \(batch.count) 枚成就", line: batch.map(\.title).joined(separator: "、"))
        withAnimation(.spring(duration: 0.35)) { current = item }
        let id = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if current?.id == id { withAnimation(.easeOut(duration: 0.3)) { current = nil }; pump() }
        }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) { current = nil }
        pump()
    }
}

/// 顶部浮层（挂在根视图 overlay(alignment: .top)）。
struct AchievementToastView: View {
    @Environment(\.appTheme) private var theme   // 令牌表 v1（换装批次 B）
    @State private var center = AchievementToastCenter.shared

    var body: some View {
        if let item = center.current {
            HStack(spacing: 10) {
                Image(systemName: "seal.fill").foregroundStyle(theme.accent)   // 成就=情感时刻族
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.bold())
                    Text(item.line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 16).padding(.top, 8)
            .frame(maxWidth: 460)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { center.dismiss(); center.onTap?() }
            .gesture(DragGesture(minimumDistance: 8).onEnded { v in
                if v.translation.height < -6 { center.dismiss() }   // 上划收掉
            })
        }
    }
}
