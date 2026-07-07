//
//  ExecutionPanel.swift
//  BetterCalendar
//
//  执行陪伴面板（跨平台）：当前块 · 已用时长 · 下一件，单键 完成/下一件/换一件 + 休息toggle + 番茄段确认。
//  macOS：装进 menu bar 的 NSPopover；iOS：直接嵌进排日程页（没 menu bar）。「记录 = 导航」的入口。
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct ExecutionPanel: View {
    @Bindable var model: ExecutionViewModel
    @State private var earlyBreakConfirming = false   // 「提前休息」的小摩擦确认（0.20.5）

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            mitStrip
            Divider()
            actions
            focusHint
            backgroundSection
            Divider()
            footer
            if let err = model.lastError {
                Text(err).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(12)
        #if os(macOS)
        .frame(width: 280)
        #endif
        .task { await model.loadToday() }
    }

    // MARK: 今日最要紧（★兑现红利）——做成打 🎯，没做成不罚（只是不亮），至多软限 ≤2 件
    @ViewBuilder private var mitStrip: some View {
        if !model.importantItems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.importantItems) { item in
                    if model.isImportantDone(item) {
                        Text("🎯 最要紧的「\(item.title)」做成了")
                            .font(.caption.weight(.medium)).foregroundStyle(.green)
                    } else {
                        Label("今日最要紧：\(item.title)", systemImage: "star.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: 头部状态

    @ViewBuilder private var header: some View {
        if model.isOnBreak {
            Label("休息中", systemImage: "cup.and.saucer")
                .font(.headline).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Label(Self.hms(model.breakElapsed), systemImage: "timer")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let a = model.active {
                Text("回来继续：\(a.title)").font(.caption).foregroundStyle(.secondary)
            }
        } else if let a = model.active {
            Text("正在做").font(.caption).foregroundStyle(.secondary)
            Text(a.title).font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                activeTiming
            }
        } else if let s = model.selected {
            Text("待开始").font(.caption).foregroundStyle(.secondary)
            Text(s.title).font(.headline)
        } else {
            Text("空档").font(.headline).foregroundStyle(.secondary)
            if let next = model.nextSuggested {
                Text("下一件：\(next.title)").font(.caption).foregroundStyle(.secondary)
            } else if model.loaded {
                Text(model.planned.isEmpty ? "今天还没排计划" : "今天的计划都做完了 🎉")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // 番茄钟显段(专注/休息+段内进度/段满确认)、轻计时显已用、不计时不显
    @ViewBuilder private var activeTiming: some View {
        if let phase = model.pomodoroPhase {
            let isWork = phase.kind == .work
            if phase.pendingConfirm {
                VStack(alignment: .leading, spacing: 4) {
                    if isWork {
                        // 工作段满：两选（顶替原「开始休息」）——继续=转不计时逃生舱、再来一段=休息+专注循环
                        Text("专注完成 🎉").font(.callout).foregroundStyle(.blue)
                        HStack(spacing: 8) {
                            Button("继续计时") { model.continueUntimed() }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("不休息、接着做——转成往上记的计时（从已专注时长起），从此不再打断")
                            Button("再来一段") { model.confirmPomodoroNext() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .help("先休息一小段，再来一段专注")
                        }
                    } else {
                        // 休息段满：回到专注 / 转轻计时（段间=可改计时方式的窗口，工作段中锁定——Jason 定 2026-07-08）
                        Text("休息好了，回到专注？").font(.callout).foregroundStyle(.green)
                        HStack(spacing: 8) {
                            Button("回到专注") { model.confirmPomodoroNext() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Button("继续计时") { model.continueUntimed() }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("不再来一段——转成往上记的计时（净专注续走）")
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Label("\(isWork ? "专注" : "番茄休息") \(Self.hms(phase.elapsedInPhase)) / \(Self.hms(phase.phaseLength))",
                          systemImage: isWork ? "timer" : "cup.and.saucer")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(isWork ? .blue : .green)
                    if isWork {
                        // 工作段中逃生口：小摩擦确认 + 自设周上限（预先承诺，默认不限；用完=温和禁用）
                        let remaining = PomodoroDiscipline.remaining()
                        if remaining == 0 {
                            Text("本周自设的提前休息次数已用完")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("这是你在 设置→进阶 给自己设的约束，随时可调")
                        } else {
                            Button(remaining.map { "提前休息（本周还可 \($0) 次）" } ?? "提前休息") {
                                earlyBreakConfirming = true
                            }
                            .font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary).underline()
                            .help("不必等满，现在就去休息")
                            .confirmationDialog(
                                "这段还剩 \(Self.hms(phase.remaining))，现在就休息？",
                                isPresented: $earlyBreakConfirming, titleVisibility: .visible
                            ) {
                                Button(remaining.map { "休息（之后本周还可 \($0 - 1) 次）" } ?? "休息") {
                                    PomodoroDiscipline.consume()
                                    model.confirmPomodoroNext()
                                }
                                Button("继续专注", role: .cancel) {}
                            }
                        }
                    } else {
                        Button("提前结束") { model.confirmPomodoroNext() }
                            .font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary).underline()
                            .help("不必等满，现在就回到专注")
                        Button("继续计时") { model.continueUntimed() }
                            .font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary).underline()
                            .help("休息段中改主意——转成往上记的计时（净专注续走）")
                    }
                }
            }
        } else if model.activeStyle == TimingStyle.none {
            Text("不计时").font(.caption).foregroundStyle(.secondary)
        } else {
            Label(Self.hms(model.currentElapsed), systemImage: "timer")
                .font(.callout.monospacedDigit()).foregroundStyle(.blue)
        }
    }

    // MARK: 动作区

    @ViewBuilder private var actions: some View {
        if model.isOnBreak {
            Button { Task { await model.toggleBreak() } } label: {
                Label("结束休息，回来", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else if let a = model.active {
            Button { Task { await model.completeCurrent() } } label: {
                Label("完成「\(a.title)」", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            HStack { switchMenu; alsoMenu; breakButton }
        } else if let s = model.selected {
            Button { Task { await model.startSelected() } } label: {
                Label("开始任务：\(s.title)", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            HStack { switchMenu; alsoMenu; breakButton }
        } else {
            if let next = model.nextSuggested {
                Button { Task { await model.startBlock(next) } } label: {
                    Label("开始：\(next.title)", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            HStack { switchMenu; alsoMenu; breakButton }
        }
    }

    private var switchMenu: some View {
        Menu {
            if model.remaining.isEmpty {
                Text("没有其它待做的事")
            } else {
                ForEach(model.remaining) { item in
                    Button(item.title) { Task { await model.switchTo(item) } }
                }
            }
        } label: {
            Label("换一件", systemImage: "arrow.triangle.swap")
        }
        .menuStyle(.borderlessButton)
        .disabled(model.remaining.isEmpty)
    }

    /// 同时做另一件（后台并行，不打断前台计时）。
    private var alsoMenu: some View {
        Menu {
            if model.remaining.isEmpty {
                Text("没有其它待做的事")
            } else {
                ForEach(model.remaining) { item in
                    Button(item.title) { model.startAlso(item) }
                }
            }
        } label: {
            Label("同时做", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .disabled(model.remaining.isEmpty)
    }

    private var breakButton: some View {
        Button { Task { await model.toggleBreak() } } label: {
            Label("开始休息", systemImage: "cup.and.saucer")
        }
    }

    // MARK: 专注引导（macOS 无屏蔽 API 的降级：番茄钟时温和提示可开系统专注模式，不强推）

    @ViewBuilder private var focusHint: some View {
        #if os(macOS)
        if model.activeStyle == .pomodoro, !model.isOnBreak {
            HStack(spacing: 6) {
                Image(systemName: "moon.circle").font(.caption).foregroundStyle(.indigo)
                Text("想更沉浸？可顺手开系统专注模式").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("打开设置") {
                    // 专注模式无公开 API 可编程开启 → 引导到系统设置的专注面板
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption2).controlSize(.mini)
            }
        }
        #endif
    }

    // MARK: 后台并行区（同时进行的其它事，各自按墙钟计时；点 ✓ 完成即记蓝色实际）

    @ViewBuilder private var backgroundSection: some View {
        if !model.background.isEmpty {
            Divider()
            Text("同时进行（后台）").font(.caption).foregroundStyle(.secondary)
            ForEach(model.background) { run in
                HStack(spacing: 8) {
                    Image(systemName: "circle.dotted").foregroundStyle(.purple).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.title).font(.caption).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Self.hms(model.backgroundElapsed(run)))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { Task { await model.completeBackground(run.id) } } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(.green)
                    .help("完成这件后台任务")
                }
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Text("今日：完成 \(model.doneCount)"
                 + (model.background.isEmpty ? "" : " · 同时 \(model.background.count)"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            #if os(macOS)
            // 走 reallyQuit：菜单栏面板里明确的「退出」，即使开了「保留在菜单栏」也应真退（否则被 applicationShouldTerminate 拦成隐藏）
            Button { AppLifecycle.shared?.reallyQuit() } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            .help("退出 BetterCalendar")
            #endif
        }
    }

    // 时:分:秒 / 分:秒
    static func hms(_ ti: TimeInterval) -> String {
        let total = Int(ti)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}
