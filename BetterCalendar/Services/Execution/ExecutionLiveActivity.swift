//
//  ExecutionLiveActivity.swift
//  BetterCalendar
//
//  执行陪伴 Live Activity 抽象（灵动岛 / 锁屏实时计时）。上层（ExecutionViewModel）只依赖本协议。
//  按平台注入：iOS = ActivityKitLiveActivity；macOS / 不支持 = NoLiveActivity（no-op）。
//

import Foundation

/// 一次「当前执行状态」的快照，喂给 Live Activity（把 VM 内部状态解耦成朴素值）。
struct LiveActivitySnapshot {
    var title: String
    var timerStart: Date       // now − 已投入 → 正计时基准
    var pausedAt: Date?        // 休息暂停：冻结时刻（轻计时）
    var mode: LiveActivityMode
    var phaseEndsAt: Date?     // 番茄段结束时刻（倒计时）
    var phaseIsRest: Bool
    /// true when this phone is presenting another device's run rather than owning it.
    var isRemote: Bool = false
    /// System marks the presentation out of date even while this app is
    /// suspended. This never pauses or ends the underlying timer.
    var staleAt: Date? = nil
}

enum LiveActivityMode { case light, pomodoro }

@MainActor
protocol ExecutionLiveActivity {
    /// 开始一个块的实时活动。
    func start(_ snapshot: LiveActivitySnapshot)
    /// 更新当前活动（休息切换 / 番茄段切换）。
    func update(_ snapshot: LiveActivitySnapshot)
    /// 结束活动（完成 / 换一件 / 回空档）。
    func end()
}

/// macOS / 不支持 Live Activity 的设备：什么都不做。
@MainActor
final class NoLiveActivity: ExecutionLiveActivity {
    func start(_ snapshot: LiveActivitySnapshot) {}
    func update(_ snapshot: LiveActivitySnapshot) {}
    func end() {}
}
