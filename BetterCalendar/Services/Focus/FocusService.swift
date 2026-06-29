//
//  FocusService.swift
//  BetterCalendar
//
//  执行陪伴会话：计时风格 番茄钟/轻计时/无（+ iOS 屏蔽）。轻计时为默认。
//  macOS 实现 = TimerOnlyFocusService（先做）；iOS 再叠 ScreenTimeFocusService（待 entitlement）。
//

import Foundation

protocol FocusService: AnyObject {
    var isRunning: Bool { get }
    func start(style: TimingStyle, blockID: UUID?)
    func stop()
}
