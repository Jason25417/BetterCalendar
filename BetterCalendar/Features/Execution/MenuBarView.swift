//
//  MenuBarView.swift
//  BetterCalendar
//
//  menu bar 常驻面板（macOS）：当前块 · 已用时长 · 下一件，单键 完成/下一件/换一件 + 休息toggle。
//  这是「记录 = 导航」的入口：点一下既导航也顺手攒蓝色实际日历。
//

#if os(macOS)
import SwiftUI

struct MenuBarView: View {
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
        .frame(width: 280)
        .task { await model.loadToday() }
    }

    // MARK: 头部状态

    @ViewBuilder private var header: some View {
        if model.isOnBreak {
            Label("休息中", systemImage: "cup.and.saucer")
                .font(.headline).foregroundStyle(.secondary)
            // 小窗只在点开时渲染，TimelineView 不碰 App 启动期，安全
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
                Label(Self.hms(model.currentElapsed), systemImage: "timer")
                    .font(.callout.monospacedDigit()).foregroundStyle(.blue)
            }
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
            HStack {
                switchMenu
                breakButton
            }
        } else {
            if let next = model.nextSuggested {
                Button { Task { await model.startBlock(next) } } label: {
                    Label("开始：\(next.title)", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            HStack {
                switchMenu
                breakButton
            }
        }
    }

    private var switchMenu: some View {
        Menu {
            if model.remaining.isEmpty {
                Text("没有其它待做的事")
            } else {
                ForEach(model.remaining) { item in
                    Button(item.title) { Task { await model.startBlock(item) } }
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
            // 面板每次打开会自动重读今日计划（.task），不另设手动刷新按钮
            Button { NSApp.terminate(nil) } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            .help("退出 BetterCalendar")
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

// ⚠️ 不要在 MenuBarExtra 的 label 里放 TimelineView / 任何周期刷新：
// 菜单栏 label 桥接到 NSStatusItem button，启动即渲染，周期刷新会失控重绘
// → 主线程卡死、内存溢出、进程杀不掉（已两次踩雷）。
// label 用静态 systemImage；菜单栏直显计时（潮汐式）须走 AppKit NSStatusItem，另做。
#endif
