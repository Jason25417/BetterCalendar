//
//  ActivitySettingsSection.swift
//  BetterCalendar
//
//  W13：设置页「设备活动记录（实验）」——白话披露（收什么、存哪、谁读、留多久、红线）+ 总开关 + 暂停 1 小时 + 各来源状态。
//  iPhone 另有快捷指令自动化的设置步骤页。界面只读 ActivityRecording（组装点注入的 .current），不直接调系统 API
//  （辅助功能授权按钮经 MacActivityProbe 的静态入口）。
//

import SwiftUI

struct ActivitySettingsSection: View {
    var recording: ActivityRecording? = ActivityRecording.current
    @State private var showDisclosure = false

    var body: some View {
        Section("设备活动记录（实验）") {
            if let recording {
                Toggle("记录设备活动", isOn: Binding(get: { recording.enabled }, set: { recording.setEnabled($0) }))
                if let until = recording.pausedUntil, until > .now, recording.enabled {
                    HStack {
                        Text("已暂停到 \(until.formatted(date: .omitted, time: .shortened))").foregroundStyle(.orange)
                        Spacer()
                        Button("现在恢复") { recording.resumeNow() }
                    }
                } else if recording.enabled {
                    Button("暂停 1 小时") { recording.pauseOneHour() }
                }
                Text("实验期默认打开，数据尽量记全，之后按使用情况删减。暂停与开关会同步到你的另一台设备。")
                    .font(.caption).foregroundStyle(.secondary)

                DisclosureGroup("收集什么、存在哪、谁会读（请看一遍）", isExpanded: $showDisclosure) {
                    ActivityDisclosureText()
                }

                ForEach(Self.sources, id: \.self) { source in
                    ActivityStatusRow(source: source, state: recording.status.states[source])
                }
                #if os(macOS)
                if !MacActivityProbe.accessibilityTrusted {
                    Button("允许读取其他 App 的窗口标题（打开辅助功能设置）") { MacActivityProbe.requestAccessibility() }
                }
                if let note = recording.launchAtLoginNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                #endif
                #if os(iOS)
                NavigationLink("设置 iPhone 快捷指令自动化（记录 App 打开/关闭）") {
                    ActivityShortcutGuide().navigationTitle("快捷指令自动化")
                }
                #endif
            } else {
                Text("设备活动记录没有启动（测试环境或组装点未接）。").foregroundStyle(.secondary)
            }
        }
    }

    static var sources: [ActivitySource] {
        #if os(macOS)
        [.frontApp, .browser, .windowTitle, .idle, .lockSleep, .power, .network, .storage, .bridgeMirror, .cloudImport, .shortcut, .launchAtLogin]
        #else
        [.shortcut, .cloudUpload, .motion, .health, .network, .storage]
        #endif
    }
}

private struct ActivityStatusRow: View {
    let source: ActivitySource
    let state: ActivitySourceState?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(source.label)
                Spacer()
                Text(label).font(.caption).foregroundStyle(color)
            }
            if let reason = state?.reason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
        switch state {
        case let .working(at?)?: "正常 · 最近 \(at.formatted(date: .omitted, time: .shortened))"
        case .working?: "正常"
        case .noPermission?: "没有权限"
        case .failed?: "失败"
        case .off?: "未在记录"
        case .waiting?: "等待中"
        case nil: "还没开始"
        }
    }
    private var icon: String {
        switch state {
        case .working?: "checkmark.circle.fill"
        case .noPermission?: "lock.circle"
        case .failed?: "exclamationmark.triangle.fill"
        default: "circle.dashed"
        }
    }
    private var color: Color {
        switch state {
        case .working?: .green
        case .noPermission?: .orange
        case .failed?: .red
        default: .secondary
        }
    }
}

/// 白话披露（两端同一份，平台专属的写明是哪台设备）。
struct ActivityDisclosureText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                Text("收集什么").bold()
                Text("Mac：前台用的是哪个 App、什么时候切换；浏览器（Safari、Chrome、Edge、Arc、Brave、Vivaldi）当前页的网址和标题（网址里像密码、令牌的参数会被抹成 REDACTED）；其他 App 的窗口标题（要你在辅助功能里允许）；多久没碰键盘鼠标（超过 3 分钟记一次「离开」，不记你按了什么）；锁屏 / 解锁、睡眠 / 唤醒；插电 / 电池和网络类型的变化。")
                Text("iPhone：快捷指令自动化报告的「App 打开 / 关闭」——是哪个 App（快捷指令里「获取当前 App」取的名字）、什么时候；拉下控制中心 / 通知这种「盖一层」单独记，不算关闭；还有当时的电量；运动状态（步行、乘车、静止等）；健康里的睡眠段和锻炼；网络类型的变化。")
                Text("智能体那边（不在 App 里）：它能直接读 Mac 上 Edge、Chrome、Arc、Safari 的浏览历史，以及 macOS「屏幕使用时间」数据库里过去几周的 App 使用时段（要给 node「完全磁盘访问权限」）。")
            }
            Group {
                Text("存在哪").bold()
                Text("每台设备本机 App 容器里按天存一个文件。Mac 每 20 秒把文件复制到智能体工作区的 bridge/activity/。iPhone 的记录经你自己的 iCloud 私有数据库（只有你的账户能读）传到 Mac，云端副本 14 天后删除。")
                Text("谁会读").bold()
                Text("BetterCalendar 智能体（Mac 上的 Claude Code 专用会话，读本机文件）。哨兵（W14，Mac）会把一份摘要（含 App 名、网站域名）发给云端的判断模型来决定要不要叫醒智能体：首选 TypeSafe Jev（经 OpenRouter），也可选 OpenAI Decisions，兜底时用 Claude（Anthropic API）——也就是说摘要会离开你的设备。")
                Text("留多久").bold()
                Text("本机与 bridge 里保留 90 天，过期自动删除（这是防止文件无限变大的稳定性边界）。关掉开关不会删已有记录。")
                Text("红线").bold()
                Text("App 和网站名只用来帮智能体理解你此刻的情境和时机，永远不会出现在复盘、操作留底、成就和反馈里，也不会被拿来评判你——不会有「你刷了 2 小时 X」这种话。")
            }
        }
        .font(.caption)
        .padding(.vertical, 4)
    }
}

#if os(iOS)
/// iPhone 快捷指令自动化的最少步骤。个人自动化不能分享、不能由 App 创建，只能手动建；
/// 但「快捷指令」可以导入：两个做好的快捷指令随 App 打包（BetterCalendar/ActivityShortcuts/，已签名），这里一键分享给「快捷指令」。
struct ActivityShortcutGuide: View {
    private static let openName = "BetterCalendar 记录 App 打开"
    private static let closeName = "BetterCalendar 记录 App 关闭"

    var body: some View {
        List {
            Section("第一步：导入两个做好的快捷指令") {
                shareRow(Self.openName, note: "获取当前 App → 记录 App 打开")
                shareRow(Self.closeName, note: "等 2 秒 → 获取当前 App → 记录 App 关闭")
                Text("点了之后在分享面板里选「快捷指令」，再点「添加快捷指令」。两个都要加。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("第二步：建两条自动化（各约 30 秒）") {
                Text("① 打开「快捷指令」→ 底部「自动化」→ 右上角「+」→ 往下找到「App」。")
                Text("② 点「选取」→ 把列表里的 App 全部勾上 → 完成；只勾「已打开」；选「立即运行」，关掉「运行时通知」→ 下一步。")
                Text("③ 选「运行快捷指令」→ 选「\(Self.openName)」→ 完成。")
                Text("④ 再建一条：第 ② 步只勾「已关闭」，第 ③ 步选「\(Self.closeName)」。")
            }
            Section("为什么这样就够了") {
                Text("「获取当前 App」会把前台 App 的名字交给 BetterCalendar，所以一条自动化选全部 App 就行，不用每个 App 单建。")
                Text("iOS 拉下控制中心 / 通知中心时也会触发「已关闭」。所以关闭那个快捷指令先等 2 秒，再看前台是谁：还是同一个 App = 只是盖了一层，不算关闭；回到主屏幕或换了 App 才算关闭（换 App 时新 App 的打开由它自己的触发记，不重复）。")
            }
            Section("验证") {
                Text("随便打开一个 App 再回来：设置 → 设备活动记录（实验）里「快捷指令：App 打开 / 关闭」应变成「正常」。几分钟内 Mac 上也会收到（Mac 每 2 分钟从 iCloud 拉一次）。")
                Text("想暂停：设置里点「暂停 1 小时」或关掉开关，快捷指令照常运行但什么都不记。")
            }
            Section("导入不了时（手动拼）") {
                Text("在快捷指令里新建：打开用「获取当前 App」+「记录 App 打开」（App 选「当前 App」）；关闭用「等待 2 秒」+「获取当前 App」+「记录 App 关闭」（现在前台的 App 选「当前 App」）。")
            }
        }
    }

    @ViewBuilder private func shareRow(_ name: String, note: String) -> some View {
        if let url = Bundle.main.url(forResource: name, withExtension: "shortcut") {
            ShareLink(item: url) {
                VStack(alignment: .leading) {
                    Label("导入「\(name)」", systemImage: "square.and.arrow.down")
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("App 包里没找到「\(name).shortcut」（打包出错，请用下面的手动步骤）").foregroundStyle(.red)
        }
    }
}
#endif
