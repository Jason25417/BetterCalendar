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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            actions
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
                    Text(isWork ? "专注完成 🎉 该休息一下" : "休息好了，回到专注？")
                        .font(.callout).foregroundStyle(isWork ? .blue : .green)
                    Button(isWork ? "开始休息" : "回到专注") { model.confirmPomodoroNext() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            } else {
                Label("\(isWork ? "专注" : "番茄休息") \(Self.hms(phase.elapsedInPhase)) / \(Self.hms(phase.phaseLength))",
                      systemImage: isWork ? "timer" : "cup.and.saucer")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isWork ? .blue : .green)
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
            HStack { switchMenu; breakButton }
        } else if let s = model.selected {
            Button { Task { await model.startSelected() } } label: {
                Label("开始任务：\(s.title)", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            HStack { switchMenu; breakButton }
        } else {
            if let next = model.nextSuggested {
                Button { Task { await model.startBlock(next) } } label: {
                    Label("开始：\(next.title)", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            HStack { switchMenu; breakButton }
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

    private var breakButton: some View {
        Button { Task { await model.toggleBreak() } } label: {
            Label("开始休息", systemImage: "cup.and.saucer")
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Text("今日：完成 \(model.doneCount) · 剩 \(model.remaining.count)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            #if os(macOS)
            Button { NSApp.terminate(nil) } label: {
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
