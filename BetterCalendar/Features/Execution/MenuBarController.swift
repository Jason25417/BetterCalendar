//
//  MenuBarController.swift
//  BetterCalendar
//
//  菜单栏计时（潮汐式）：用 AppKit NSStatusItem 自管菜单栏项 + 一个 Timer 每秒给 button.title 赋字符串
//  显示「▶ 12:34」/「☕ 02:10」。这条路绕开了 SwiftUI MenuBarExtra label 那个雷区
//  （label 里放 TimelineView/周期刷新会失控卡死+内存溢出）——这里只是给 NSButton 赋文字，轻量稳定。
//  点击弹 NSPopover，内容仍是 SwiftUI 的 MenuBarView（小窗里用 TimelineView 安全）。
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
        popover.contentViewController = NSHostingController(rootView: MenuBarView(model: model))

        // AppKit Timer + 字符串赋值：轻量、不失控（与 SwiftUI label 的周期重绘本质不同）
        timer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
        updateTitle()
    }

    @objc private func tick() { updateTitle() }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        if model.isOnBreak {
            button.title = " ☕ " + MenuBarView.hms(model.breakElapsed)
        } else if model.active != nil {
            button.title = " ▶ " + MenuBarView.hms(model.currentElapsed)
        } else {
            button.title = ""        // 空档只显图标
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            Task { await model.loadToday() }   // 打开即刷新今日
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
#endif
