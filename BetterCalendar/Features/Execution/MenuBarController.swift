//
//  MenuBarController.swift
//  BetterCalendar
//
//  菜单栏计时（潮汐式）：用 AppKit NSStatusItem 自管菜单栏项 + 一个 Timer 每秒给 button.title 赋字符串
//  显示「(SF符号) 12:34」（批次5 起 emoji 退场，图形走 button.image）。这条路绕开了 SwiftUI MenuBarExtra label 那个雷区
//  （label 里放 TimelineView/周期刷新会失控卡死+内存溢出）——这里只是给 NSButton 赋文字，轻量稳定。
//  点击弹 NSPopover，内容仍是 SwiftUI 的 ExecutionPanel（小窗里用 TimelineView 安全）。
//

#if os(macOS)
import AppKit
import SwiftUI

/// menu bar 弹窗「保持打开」标记：中文输入法按空格选字会让 transient 弹窗关掉（候选窗抢焦点）——
/// 「新事项」输入期间挂起自动关闭（applicationDefined），输入结束/取消恢复 transient。
/// 点菜单栏图标始终可关（togglePopover 走 performClose，不受 behavior 影响）。
@MainActor enum MenuBarPopoverHold {
    static var isHeld = false
    /// 弹窗即将重新打开 → 让面板清掉遗留的「新事项」输入态（防 hold 卡死/陈旧输入框）。
    static let resetAdHocNotice = Notification.Name("bc.menubar.resetAdHoc")
    /// menu bar「回看今天」→ 主窗口切到日记页（BetterCalendarApp 观察）。
    static let openJournalNotice = Notification.Name("bc.menubar.openJournal")
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
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
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])   // 左键弹执行面板、右键弹菜单
        }

        popover.behavior = .transient
        popover.delegate = self
        // 展开层（三层模型，S3-P1）：menu bar 宿主开 compactCapable——默认精简子集，chevron 就地展开
        popover.contentViewController = NSHostingController(rootView: ExecutionPanel(model: model, compactCapable: true))

        // AppKit Timer + 字符串赋值：轻量、不失控（与 SwiftUI label 的周期重绘本质不同）
        timer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
        updateTitle()
    }

    @objc private func tick() {
        updateTitle()
        // 蓝色实时增长 + 橙色A（自节流 5 分）：正在做时把蓝块延长到此刻、清掉被越过的橙块。不调 LLM。
        if model.shouldGrowActive { Task { await model.growActiveActual() } }
        // 聪音回流：游戏里勾完成 → inbox 文件出现 → 消化成 BC 完成（文件探测轻量；重复触发幂等）
        if FocusStateExporter.hasPendingInbox { Task { await model.consumeChiyneInbox() } }
        // 聪音状态 2 秒一导（2026-07-11 Jason 定「统一 2 秒」）：联动开着就持续写——mod 侧 2s 轮询
        // + 状态对账，错过任何事件都秒级自愈；空档也写（游戏内状态栏靠文件新鲜度判「BC 在线」）。
        // 事件不会被 tick 冲掉：见 ExecutionViewModel 的事件账本。文件 <1KB，写入压力可忽略。
        chiyneTick += 1
        if chiyneTick >= 2 {
            chiyneTick = 0
            if FocusStateExporter.isEnabled { model.exportFocusStateNow() }
        }
    }

    /// 聪音 2 秒导出的分频器（menu bar 计时器是 1 秒一跳）。
    private var chiyneTick = 0

    /// 直接显示**当前计时状态**（2026-07-09 Jason）：计时 / 不计时 / 番茄，而不只一个计时按钮。
    /// 重写为按 active.timingStyle 显式 switch（旧版用 `!= TimingStyle.none` 隐晦比较，轻计时/不计时都错显成不计时）。
    private func updateTitle() {
        guard let button = statusItem.button else { return }
        // 9A（批次5）：emoji 构件退场——menu bar 是系统场域，状态图形一律 SF Symbols（button.image），
        // 标题只留文字与数字。🍅 另有哲学层理由：番茄工作法的纪律隐喻与「温柔陪伴」相悖。
        func symbol(_ name: String, _ desc: String) {
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: desc)
        }
        if model.isOnBreak {
            symbol("cup.and.saucer.fill", "休息中")
            button.title = " 休息 " + ExecutionPanel.hms(model.breakElapsed)
        } else if let phase = model.pomodoroPhase {
            if phase.pendingConfirm {
                symbol(phase.kind == .work ? "timer" : "cup.and.saucer.fill", "段满待确认")
                button.title = phase.kind == .work ? " ✓段满" : " ✓回专注"
            } else {
                symbol(phase.kind == .work ? "timer" : "cup.and.saucer.fill", "番茄进行中")
                button.title = " \(phase.kind == .work ? "专注" : "休息") " + ExecutionPanel.hms(phase.remaining)
            }
        } else if let a = model.active {
            switch a.timingStyle {
            case .pomodoro:   // 兜底（正常走上面 phase 分支）
                symbol("timer", "番茄计时")
                button.title = " " + ExecutionPanel.hms(model.currentElapsed)
            case .light:
                symbol("play.fill", "轻计时进行中")
                button.title = " " + model.timerDisplay      // 已 X · 计划 Y（超计划撤计划），到分 XhYm
            case .none:
                symbol("circle.inset.filled", "进行中（不计时）")
                button.title = " " + model.timerDisplay      // 已 X，到分 XhYm
            }
        } else if let f = FollowRunState.shared.run {
            // 多端跟随（#30）：本机空档而另一台在做 → 陪伴显示（点开面板可退出跟随）
            symbol("ipad.and.iphone", "另一台设备进行中")
            button.title = " " + ExecutionPanel.hms(Date.now.timeIntervalSince(f.startedAt))
        } else {
            symbol("calendar.badge.clock", "BetterCalendar")
            button.title = ""        // 空档：只显图标
        }
    }

    /// 左键=执行面板；右键=菜单（打开主窗口 / 退出）。
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "打开主窗口", action: #selector(openMain), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 BetterCalendar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func openMain() { AppLifecycle.shared?.showMainWindow() }
    @objc private func quitApp() { AppLifecycle.shared?.reallyQuit() }

    /// 空格误关的正解（0.27.1）：behavior 在弹窗已显示后改动**不生效**（transient 监听 show 时装好）——
    /// 改用 delegate 否决：每次瞬态关闭前都会问这里，「新事项」输入中一律驳回（输入法候选窗抢焦点、
    /// 点外面都关不掉）；图标点击走 close() 强制关、不经此问。实时生效、无 1 秒竞态。
    func popoverShouldClose(_ popover: NSPopover) -> Bool { !MenuBarPopoverHold.isHeld }

    /// 弹窗生命周期兜底（0.26.19 修「点外面不自动收起」）：hold 标记只该活在"输入进行中且弹窗开着"——
    /// 弹窗关了（不管怎么关的）必须复位，否则下次点外面永远关不掉；重新打开时也顺手清掉遗留的输入态。
    func popoverDidClose(_ notification: Notification) {
        MenuBarPopoverHold.isHeld = false
    }

    func popoverWillShow(_ notification: Notification) {
        // 上次弹窗是在「新事项」输入中被图标点关的 → 面板状态还留着输入框：通知它复位（同时清 hold）
        NotificationCenter.default.post(name: MenuBarPopoverHold.resetAdHocNotice, object: nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.close()   // 强制关（不经 popoverShouldClose）：图标点击永远能关，即使输入进行中
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
