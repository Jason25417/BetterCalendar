//
//  ExecutionActivityAttributes.swift
//  BetterCalendar
//
//  执行陪伴 Live Activity 的共享数据（灵动岛 / 锁屏实时模块）。
//  ⚠️ **同时编进主 App 与 Widget 扩展两个 target**：ActivityKit 要求「发起方」与「渲染方」
//  是同一个具体类型。故意只用 Foundation 基础类型 + 本地 Codable 枚举，不依赖主 App 其它模型，
//  跨 target 编译干净。仅 iOS/iPadOS 有 Live Activity（macOS 上 ActivityKit 能 import 但 Activity
//  类型 unavailable → 用 #if os(iOS) 而非 canImport 才能真正在 macOS 排除整文件）。
//

import Foundation
#if os(iOS)
import ActivityKit

struct ExecutionActivityAttributes: ActivityAttributes {
    /// 随执行状态变化的动态部分（换块 / 休息 / 番茄段切换都走 update，不重开活动）。
    public struct ContentState: Codable, Hashable {
        /// 当前在做的事。
        var title: String
        /// 正计时基准：令 (now − timerStart) = 当前块净投入时长；换块 / 休息结束时刷新。
        var timerStart: Date
        /// 非 nil = 休息暂停中，计时冻结在此刻（轻计时手动休息）。
        var pausedAt: Date?
        /// 计时风格。
        var mode: Mode
        /// 番茄钟当前段的结束时刻（倒计时用；nil = 非番茄钟）。
        var phaseEndsAt: Date?
        /// 番茄钟当前段是否为休息段。
        var phaseIsRest: Bool
    }

    enum Mode: String, Codable, Hashable { case light, pomodoro }

    // 无静态字段：标题等都放动态态，切块只 update。
}
#endif
