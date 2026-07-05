//
//  MenuBarController.swift
//  BetterCalendar
//
//  菜单栏计时（潮汐式）：用 AppKit NSStatusItem 自管菜单栏项 + 一个 Timer 每秒给 button.title 赋字符串
//  显示「▶ 12:34」/「☕ 02:10」。这条路绕开了 SwiftUI MenuBarExtra label 那个雷区
//  （label 里放 TimelineView/周期刷新会失控卡死+内存溢出）——这里只是给 NSButton 赋文字，轻量稳定。
//  点击弹 NSPopover，内容仍是 SwiftUI 的 ExecutionPanel（小窗里用 TimelineView 安全）。
//

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: ExecutionViewModel
    private var timer: Timer?

    init(model: ExecutionViewModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "calendar.badge.clock",
                                   accessibilityDescription: "BetterCalendar")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ExecutionPanel(model: model))

        // AppKit Timer + 字符串赋值：轻量、不失控（与 SwiftUI label 的周期重绘本质不同）
        timer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
        updateTitle()
    }

    @objc private func tick() { updateTitle() }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        if model.isOnBreak {
            button.title = " ☕ " + ExecutionPanel.hms(model.breakElapsed)
        } else if let phase = model.pomodoroPhase {
            if phase.pendingConfirm {
                button.title = phase.kind == .work ? " 🍅 ✓段满" : " ☕ ✓回专注"
            } else {
                button.title = " \(phase.kind == .work ? "🍅" : "☕") " + ExecutionPanel.hms(phase.remaining)
            }
        } else if model.active != nil, model.activeStyle != TimingStyle.none {
            button.title = " ▶ " + ExecutionPanel.hms(model.currentElapsed)
        } else {
            button.title = ""        // 不计时 / 空档：只显图标
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            Task { await model.loadToday() }   // 打开即刷新今日
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // 让弹窗能出现在任何 Space / 全屏 App 之上：
            // 弹窗窗口默认只属于本 App 的 Space（桌面）——在别的 App/全屏页点图标时会"看不见"。
            // 不用 NSApp.activate（会把你拽回主窗口所在桌面），只把弹窗窗口设为跨 Space + 全屏辅助层。
            if let win = popover.contentViewController?.view.window {
                win.collectionBehavior.insert(.canJoinAllSpaces)
                win.collectionBehavior.insert(.fullScreenAuxiliary)
                win.makeKey()
            }
        }
    }
}
#endif
