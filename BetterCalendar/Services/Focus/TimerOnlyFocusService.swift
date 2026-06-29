//
//  TimerOnlyFocusService.swift
//  BetterCalendar
//
//  纯计时陪伴（macOS 无硬屏蔽）。M0 只跟踪状态，真正的计时/提示后续补。
//

import Foundation
import Observation

@Observable
final class TimerOnlyFocusService: FocusService {
    private(set) var isRunning: Bool = false
    private(set) var currentStyle: TimingStyle = .light
    private(set) var startedAt: Date?
    private(set) var currentBlockID: UUID?

    func start(style: TimingStyle, blockID: UUID?) {
        currentStyle = style
        currentBlockID = blockID
        startedAt = .now
        isRunning = true
    }

    func stop() {
        isRunning = false
        startedAt = nil
        currentBlockID = nil
    }
}
