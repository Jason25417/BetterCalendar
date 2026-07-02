//
//  ActivityKitLiveActivity.swift
//  BetterCalendar
//
//  iOS 实现：把执行状态桥到 ActivityKit（灵动岛 + 锁屏 / 通知中心实时模块）。
//  计时交给系统的 Text(timerInterval:) 自动跑——退后台、锁屏也走，不耗电、无需我们每秒推更新。
//  失败可见（开发期约定）：系统未授权 / 请求失败都 DevLog，不静默。
//

import Foundation
#if os(iOS)
import ActivityKit

@MainActor
final class ActivityKitLiveActivity: ExecutionLiveActivity {
    private var activity: Activity<ExecutionActivityAttributes>?

    func start(_ snapshot: LiveActivitySnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            DevLog.shared.info("LiveActivity", "系统未开启实时活动（设置→BetterCalendar→实时活动）→ 跳过")
            return
        }
        end()  // 保证同时只有一个活动
        do {
            activity = try Activity.request(
                attributes: ExecutionActivityAttributes(),
                content: .init(state: Self.state(from: snapshot), staleDate: nil))
            DevLog.shared.info("LiveActivity", "开始：\(snapshot.title)")
        } catch {
            DevLog.shared.warn("LiveActivity", "开始失败：\(error.localizedDescription)")
        }
    }

    func update(_ snapshot: LiveActivitySnapshot) {
        guard let activity else { return }
        let content = ActivityContent(state: Self.state(from: snapshot), staleDate: nil)
        Task { await activity.update(content) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private static func state(from s: LiveActivitySnapshot) -> ExecutionActivityAttributes.ContentState {
        .init(title: s.title, timerStart: s.timerStart, pausedAt: s.pausedAt,
              mode: s.mode == .pomodoro ? .pomodoro : .light,
              phaseEndsAt: s.phaseEndsAt, phaseIsRest: s.phaseIsRest)
    }
}
#endif
