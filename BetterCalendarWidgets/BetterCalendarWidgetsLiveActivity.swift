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
            LockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: iconName(s))
                        .font(.title2)
                        .foregroundStyle(tintColor(s))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timerText(s)
                        .font(.title2).monospacedDigit()
                        .foregroundStyle(tintColor(s))
                        .frame(maxWidth: 96, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(statusLine(s))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: iconName(s)).foregroundStyle(tintColor(s))
            } compactTrailing: {
                timerText(s).monospacedDigit()
                    .foregroundStyle(tintColor(s))
                    .frame(maxWidth: 60)
            } minimal: {
                Image(systemName: iconName(s)).foregroundStyle(tintColor(s))
            }
            .keylineTint(tintColor(s))
        }
    }
}

// MARK: - 锁屏卡片

private struct LockScreenView: View {
    let state: ExecutionActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(state))
                .font(.title)
                .foregroundStyle(tintColor(state))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.headline).lineLimit(1)
                Text(statusLine(state)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            timerText(state)
                .font(.system(.title, design: .rounded)).monospacedDigit()
                .foregroundStyle(tintColor(state))
        }
    }
}

// MARK: - 共享的展示逻辑

/// 计时文本：番茄段 → 倒计时；轻计时 → 正计时（休息时用 pauseTime 冻结）。
@ViewBuilder
private func timerText(_ s: ExecutionActivityAttributes.ContentState) -> some View {
    if s.mode == .pomodoro, let end = s.phaseEndsAt {
        if end > .now {
            Text(timerInterval: Date.now...end, countsDown: true)
        } else {
            Text("0:00")   // 段满、等点「确定」切段
        }
    } else {
        Text(timerInterval: s.timerStart...Date.distantFuture,
             pauseTime: s.pausedAt, countsDown: false)
    }
}

private func iconName(_ s: ExecutionActivityAttributes.ContentState) -> String {
    if s.pausedAt != nil { return "pause.circle.fill" }          // 轻计时休息中
    if s.mode == .pomodoro { return s.phaseIsRest ? "cup.and.saucer.fill" : "timer" }
    return "play.circle.fill"
}

private func tintColor(_ s: ExecutionActivityAttributes.ContentState) -> Color {
    if s.pausedAt != nil { return .orange }
    if s.mode == .pomodoro { return s.phaseIsRest ? .green : .red }
    return .blue
}

private func statusLine(_ s: ExecutionActivityAttributes.ContentState) -> String {
    if s.pausedAt != nil { return "休息中 · 已暂停" }
    if s.mode == .pomodoro { return s.phaseIsRest ? "番茄钟 · 休息" : "番茄钟 · 专注" }
    return "计时中"
}

// MARK: - 预览

extension ExecutionActivityAttributes {
    fileprivate static var preview: ExecutionActivityAttributes { .init() }
}

extension ExecutionActivityAttributes.ContentState {
    fileprivate static var light: Self {
        .init(title: "trans 移到 MQTT（Hotaru 项目）",
              timerStart: .now.addingTimeInterval(-25 * 60), pausedAt: nil,
              mode: .light, phaseEndsAt: nil, phaseIsRest: false)
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
