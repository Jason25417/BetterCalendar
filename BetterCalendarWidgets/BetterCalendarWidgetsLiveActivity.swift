//
//  BetterCalendarWidgetsLiveActivity.swift
//  BetterCalendarWidgets
//
//  执行陪伴的 Live Activity：灵动岛（compact/expanded/minimal）+ 锁屏/通知中心卡片。
//  计时用系统 Text(timerInterval:) 自动跑——轻计时正计时、番茄段倒计时、休息冻结。
//  数据来自共享的 ExecutionActivityAttributes（主 App 发起 + 本扩展渲染）。
//

import ActivityKit
import WidgetKit
import SwiftUI

struct BetterCalendarWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ExecutionActivityAttributes.self) { context in
            // 锁屏 / 通知中心卡片
            LockScreenView(state: context.state, isStale: context.isStale)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.isStale ? "arrow.triangle.2.circlepath" : iconName(s))
                        .font(.title3)   // 字阶收敛（C）：title 档
                        .foregroundStyle(tintColor(s))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timerText(s)
                        .font(TypeScale.display).monospacedDigit()   // 计时大数字=display 档（圆体，条文 8）
                        .foregroundStyle(tintColor(s))
                        .frame(maxWidth: 96, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(statusLine(s, isStale: context.isStale))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: context.isStale ? "arrow.triangle.2.circlepath" : iconName(s)).foregroundStyle(tintColor(s))
                    .accessibilityLabel(statusLine(s, isStale: context.isStale))
            } compactTrailing: {
                timerText(s).monospacedDigit()
                    .foregroundStyle(tintColor(s))
                    .frame(maxWidth: 60)
            } minimal: {
                Image(systemName: context.isStale ? "arrow.triangle.2.circlepath" : iconName(s)).foregroundStyle(tintColor(s))
                    .accessibilityLabel(statusLine(s, isStale: context.isStale))
            }
            .keylineTint(tintColor(s))
        }
    }
}

// MARK: - 锁屏卡片

private struct LockScreenView: View {
    let state: ExecutionActivityAttributes.ContentState
    var isStale = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isStale ? "arrow.triangle.2.circlepath" : iconName(state))
                .font(.title3)   // 字阶收敛（C）：title 档
                .foregroundStyle(tintColor(state))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.headline).lineLimit(1)
                Text(statusLine(state, isStale: isStale)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            timerText(state)
                .font(TypeScale.display).monospacedDigit()   // 计时大数字=display 档
                .foregroundStyle(tintColor(state))
        }
    }
}

// MARK: - 共享的展示逻辑

/// 计时文本：番茄段 → 倒计时；轻计时 → 正计时。休息（pausedAt）一律冻结，与 App 内一致。
@ViewBuilder
private func timerText(_ s: ExecutionActivityAttributes.ContentState) -> some View {
    if s.mode == .pomodoro, let end = s.phaseEndsAt {
        if let paused = s.pausedAt {
            // 休息中：冻结显示段剩余（否则倒计时会一边说「已暂停」一边继续减，自相矛盾）
            Text(clock(end.timeIntervalSince(paused)))
        } else if end > .now {
            Text(timerInterval: Date.now...end, countsDown: true)
        } else {
            Text("0:00")   // 段满、等点「确定」切段
        }
    } else {
        Text(timerInterval: s.timerStart...Date.distantFuture,
             pauseTime: s.pausedAt, countsDown: false)
    }
}

/// 秒 → m:ss（休息冻结时的静态显示；负数归零）。
private func clock(_ ti: TimeInterval) -> String {
    let t = max(0, Int(ti))
    return String(format: "%d:%02d", t / 60, t % 60)
}

private func iconName(_ s: ExecutionActivityAttributes.ContentState) -> String {
    if s.pausedAt != nil { return "pause.circle.fill" }          // 轻计时休息中
    if s.mode == .pomodoro { return s.phaseIsRest ? "cup.and.saucer.fill" : "timer" }
    return "play.circle.fill"
}

private func tintColor(_ s: ExecutionActivityAttributes.ContentState) -> Color {
    let theme = ThemeSettings.classic
    if s.pausedAt != nil { return .orange }   // 暂停=状态色（条文 2 附则）
    // 换装 B：专注红→实际蓝族（U7 同语义同组件：ExecutionPanel 专注即蓝；红=纪律隐喻，违「温柔陪伴」）
    if s.mode == .pomodoro { return s.phaseIsRest ? theme.positiveTint : theme.actualTint }   // 休息绿归队（D）
    return theme.actualTint
}

private func statusLine(_ s: ExecutionActivityAttributes.ContentState, isStale: Bool = false) -> String {
    if isStale { return s.pausedAt != nil ? "状态待更新 · 上次已暂停" : "状态待更新 · 按上次状态计时" }
    let status: String
    if s.pausedAt != nil { status = "已暂停" }
    else if s.mode == .pomodoro { status = s.phaseIsRest ? "番茄钟 · 休息" : "番茄钟 · 专注" }
    else { status = "计时中" }
    return s.isRemote ? "同步计时 · \(status)" : status
}

// MARK: - 预览

extension ExecutionActivityAttributes {
    fileprivate static var preview: ExecutionActivityAttributes { .init() }
}

extension ExecutionActivityAttributes.ContentState {
    fileprivate static var light: Self {
        .init(title: "trans 移到 MQTT（Hotaru 项目）",
              timerStart: .now.addingTimeInterval(-25 * 60), pausedAt: nil,
              mode: .light, phaseEndsAt: nil, phaseIsRest: false, isRemote: false)
    }
    fileprivate static var pomodoro: Self {
        .init(title: "游戏自动化配置", timerStart: .now.addingTimeInterval(-5 * 60), pausedAt: nil,
              mode: .pomodoro, phaseEndsAt: .now.addingTimeInterval(20 * 60), phaseIsRest: false)
    }
}

#Preview("Lock Screen", as: .content, using: ExecutionActivityAttributes.preview) {
    BetterCalendarWidgetsLiveActivity()
} contentStates: {
    ExecutionActivityAttributes.ContentState.light
    ExecutionActivityAttributes.ContentState.pomodoro
}
