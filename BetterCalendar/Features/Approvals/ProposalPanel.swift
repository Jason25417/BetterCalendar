//
//  ProposalPanel.swift
//  BetterCalendar
//
//  SPEC §19 B3：App 内的多端审批入口——与系统通知、对话卡片指向同一份提案状态。
//  面板：待确认列表 + 最近结果 + 预授权规则（W10）；操作留底 / 发一条测试改动 / 转译统计 / 运行记录 / 延迟
//  收在「开发者选项」后（W16）。
//

import SwiftUI

struct ProposalPanel: View {
    @Bindable var center: ProposalCenter
    var focusId: UUID?
    var bridge: AgentBridge? = nil
    var alertPush: ProposalAlertPushControl? = nil
    var messages: AgentMessageCenter? = nil
    /// W19：设置里的「审批记录与规则」不重复列待确认卡（它们置顶在「智能体」页）。
    var showsPending = true
    #if os(macOS)
    #endif
    @State private var eventsOn = AgentEventSettings.enabled
    @State private var journalOn = AgentContextSettings.allowRecentJournal
    @State private var planEditingOn = PlanEditingSettings.enabled
    @State private var notificationAllowed: Bool?
    @AppStorage(DeveloperSettings.key) private var developerOptions = DeveloperSettings.defaultValue   // W16：测试按钮 / 内部统计只在「开发者选项」里出现

    var body: some View {
        List {
            // W16：同一判定（IssueTriage）——短暂的 iCloud / 网络失败升级前不在这里显示，日志与 🐞 计数里照样有
            if let error = center.lastError, DevLog.shared.shouldShowInline(source: "多端审批", message: error) {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("知道了") { center.clearError() }
                }
            }
            if showsPending {
                Section("待你确认（\(center.pending.count)）") {
                    if center.pending.isEmpty { Text("现在没有需要你确认的改动").foregroundStyle(.secondary) }
                    ForEach(center.pending) { p in
                        ProposalCard(center: center, proposal: p, highlighted: p.id == focusId)   // W19：与「智能体」页、对话气泡同一张卡
                    }
                }
            } else {
                Section {
                    Text(center.pending.isEmpty ? "现在没有等你确认的改动。" : "有 \(center.pending.count) 件等你确认——在「智能体」页顶部。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("最近结果") {
                let closed = center.proposals.filter { $0.effectiveState(at: .now) != .pending }.prefix(20)
                if closed.isEmpty { Text("还没有").foregroundStyle(.secondary) }
                ForEach(Array(closed)) { p in historyRow(p) }
            }
            PreauthRulesSection(center: center)   // W10 A3a：预授权规则（查看 / 改效果 / 删除，随设置同步）
            if developerOptions {
                AgentTranslationStatsSection(center: center, messages: messages)   // SPEC §19 批次 6：转译偏差统计（只统计；W16 收进开发者选项）
            }
            #if os(macOS)
            if let bridge {
                Section("BetterCalendar 智能体桥接（Mac）") {
                    Text(bridge.folderPath.map { "已连接：\($0)" } ?? "未连接：请选择智能体工作区里的 bridge 文件夹").font(.footnote)
                    if let last = bridge.lastSync { Text("上次同步 \(last.formatted(date: .omitted, time: .standard)) · 已导入 \(bridge.importedCount) 份提案").font(.caption).foregroundStyle(.secondary) }
                    InlineIssueText(source: "智能体桥接", message: bridge.lastError)
                    HStack {
                        Button(bridge.connected ? "重新选择文件夹" : "选择 bridge 文件夹") { bridge.chooseFolder() }
                        if bridge.connected { Button("断开", role: .destructive) { bridge.disconnect() } }
                    }
                }
                if bridge.connected, developerOptions { AgentRuntimeSection(bridge: bridge) }   // W16：运行内部数据收进开发者选项（失败照样进日志 / 横幅）   // SPEC §19 批次 11：最近运行 / 调度失败 / 越权记录
            }
            #endif
            Section("智能体能看到什么（A2）") {
                Text("只读：今天的计划、正在计时的事、待办池与长期事项、系统日历（今天及未来 3 天）、最近 3 天的实际；「智能体排时间线」开着时还有未来 7 天的计划块和你日历里的安排（当已占用）。智能体不能借此改动任何数据。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("允许智能体读最近日记", isOn: Binding(get: { journalOn }, set: { journalOn = $0; AgentContextSettings.allowRecentJournal = $0 }))
                Text("默认关。打开后附最近 3 天日记的摘要（每篇最多前 500 字，不含照片）；随设置同步到你的所有设备，随时可关。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("智能体排时间线") {
                Toggle("允许智能体提议排时间线", isOn: Binding(get: { planEditingOn }, set: { planEditingOn = $0; PlanEditingSettings.enabled = $0 }))
                Text("默认开。打开后智能体能提议：往今天到 7 天后加计划块、改块的标题 / 时长 / 固定 / 要紧 / 截止、删块（进回收站）、跨天挪块、一次排好一天。每一项仍要你批准，批准后可撤销；放不放得下由 BetterCalendar 按规则判（固定安排不动、不重叠、不越截止、你日历里的安排当已占用）。关掉 = 只能挪今天的块，和以前一样。随设置同步到你的所有设备。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let messages { attentionSection(messages) }
            if let alertPush {
                Section("App 关闭时也推送（实验，B5）") {
                    Toggle("新提案由 iCloud 直接推送", isOn: Binding(get: { alertPush.enabled }, set: { on in Task { await alertPush.set(on) } }))
                    Text("打开后，App 没运行也能弹出带批准/拒绝的通知；作用于你所有设备。和本机通知重复时只保留一条。默认开：你没手动关过时，App 启动会自动打开。").font(.caption).foregroundStyle(.secondary)
                    InlineIssueText(source: "多端审批", message: alertPush.lastError)
                }
                .task { await alertPush.reload() }
            }
            Section("通知与刷新") {
                notificationRow
                Button("立即刷新") { Task { await center.refresh() } }
            }
            if developerOptions {
                Section("开发期工具") {
                    Text("本机：\(center.deviceLabel)").font(.footnote).foregroundStyle(.secondary)
                    Button("发一条测试改动（由批准的那台设备执行）") { Task { await sendTest(target: nil) } }
                    Button("发一条测试改动（指定本机执行）") { Task { await sendTest(target: center.deviceId) } }
                }
                Section("操作留底（最近 30 条）") {
                    ForEach(Array(center.ledger.records().suffix(30).reversed())) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.at.formatted(date: .omitted, time: .standard)) · \(r.actorLabel) · \(r.event)").font(.caption.monospaced())
                            Text(r.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task {
            notificationAllowed = await center.notificationPermission()
            await center.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsSync.didSyncRemotely)) { _ in
            journalOn = AgentContextSettings.allowRecentJournal   // 另一台设备改了开关
            planEditingOn = PlanEditingSettings.enabled
        }
    }

    @ViewBuilder private func attentionSection(_ m: AgentMessageCenter) -> some View {
        Section("智能体主动找你（实验，C1–C4）") {
            Toggle("关键时刻唤醒智能体（做完一件事、提案有结论）", isOn: Binding(get: { eventsOn }, set: { eventsOn = $0; AgentEventSettings.enabled = $0 }))
            Text("每次唤醒都会消耗 Claude 订阅额度（实测每次约 20 秒）。需要 Mac 上已连接 bridge 文件夹。").font(.caption).foregroundStyle(.secondary)
            Toggle("允许智能体主动通知你", isOn: Binding(get: { m.settings.enabled }, set: { m.settings.enabled = $0 }))
            Toggle("频率上限", isOn: Binding(get: { m.settings.capsOn }, set: { m.settings.capsOn = $0 }))
            Text("测试期默认关（不限每小时/每天条数，具体数字待重新讨论）；安静时段与一键静音始终有效。").font(.caption).foregroundStyle(.secondary)
            if m.settings.capsOn {
                Stepper("每小时最多 \(m.settings.maxPerHour) 条", value: Binding(get: { m.settings.maxPerHour }, set: { m.settings.maxPerHour = $0 }), in: 1...6)
                Stepper("每天最多 \(m.settings.maxPerDay) 条", value: Binding(get: { m.settings.maxPerDay }, set: { m.settings.maxPerDay = $0 }), in: 1...20)
            }
            Stepper("安静时段从 \(m.settings.quietStartHour):00", value: Binding(get: { m.settings.quietStartHour }, set: { m.settings.quietStartHour = $0 }), in: 0...23)
            Stepper("安静时段到 \(m.settings.quietEndHour):00", value: Binding(get: { m.settings.quietEndHour }, set: { m.settings.quietEndHour = $0 }), in: 0...23)
            if let until = m.settings.mutedUntil, until > .now {
                HStack {
                    Text("静音到 \(until.formatted(date: .omitted, time: .shortened))").font(.footnote)
                    Button("取消静音") { m.settings.mutedUntil = nil }
                }
            } else {
                Button("静音 2 小时") { m.settings.mutedUntil = .now.addingTimeInterval(2 * 3600) }
            }
            InlineIssueText(source: "智能体消息", message: m.lastError)
            #if DEBUG
            if developerOptions {
                Button("发一条测试智能体消息（开发版）") {
                    Task { await m.receive(AgentMessageDraft(title: "测试消息", body: "开发联调：这是一条测试消息，不需要任何操作。", reason: "建立云端数据结构 / 联调")) }
                }
            }
            #endif
            ForEach(Array(m.messages.prefix(10))) { msg in
                VStack(alignment: .leading, spacing: 2) {
                    Text(msg.title).font(.subheadline)
                    Text(msg.body).font(.caption)
                    Text([msg.delivery == .delivered ? "已通知" : "已拦下：\(msg.suppressReason ?? "")",
                          msg.reaction.map { $0 == .muted ? "你选了静音" : "你点了好" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                    if msg.delivery == .delivered, msg.reaction == nil {
                        HStack {
                            Button("好") { Task { await m.react(msg.id, .acknowledged) } }
                            Button("静音 2 小时") { Task { await m.react(msg.id, .muted) } }
                        }.font(.caption)
                    }
                }
            }
        }
        .task { await m.refresh() }
    }

    private func historyRow(_ p: Proposal) -> some View {
        let state = p.effectiveState(at: .now)
        let who = p.decidedByDeviceId.map { $0 == center.deviceId ? "本机" : "另一台设备" }
        return VStack(alignment: .leading, spacing: 2) {
            Text(p.title)
            if p.action.touchesRealData, !p.changes.isEmpty {
                Text(p.notificationBody.components(separatedBy: "\n").filter { !$0.hasPrefix("理由：") && !$0.hasPrefix("发起：") }
                    .joined(separator: "\n")).font(.caption)
            }
            Text([state.label, who.map { "决定于\($0)" }, p.resultNote].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(state == .failed ? .orange : .secondary)
            ProposalOutcomeNotes(proposal: p)   // W10：你回的话 / 选了哪个方案 / 代你决定的规则 / 越级理由
            undoRow(p)
            let l = center.latency(for: p.id)
            if developerOptions, l.notify != nil || l.withdraw != nil {
                Text("本机延迟：通知 \(l.notify.map { String(format: "%.1f 秒", $0) } ?? "—") · 收起 \(l.withdraw.map { String(format: "%.1f 秒", $0) } ?? "—")")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }

        }
    }

    /// SPEC §19 A3 后半：已完成的真改动可撤销（撤销 = 一条来源为「你」的操作，写进操作留底）。
    @ViewBuilder private func undoRow(_ p: Proposal) -> some View {
        if let at = p.undoneAt {
            Text("已撤销 \(at.formatted(date: .omitted, time: .shortened))" + (p.undoNote.map { " · \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        } else if p.state == .applied, p.action.touchesRealData {
            if center.canUndo(p) {
                Button("撤销") { Task { await center.undo(p.id) } }.font(.caption).buttonStyle(.bordered)
                if let hint = p.undoHint { Text(hint).font(.caption2).foregroundStyle(.secondary) }
            } else if let reason = center.undoBlockedReason(p) {
                Text("不能撤销：\(reason)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var notificationRow: some View {
        switch notificationAllowed {
        case true?: Text("系统通知已允许").font(.footnote).foregroundStyle(.secondary)
        case false?: Text("系统通知已关闭：到系统设置里允许 BetterCalendar 通知").font(.footnote).foregroundStyle(.orange)
        case nil:
            Button("允许审批通知") {
                Task { _ = await center.requestNotificationPermission(); notificationAllowed = await center.notificationPermission() }
            }
        }
    }

    private func sendTest(target: String?) async {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        await center.submit(ProposalDraft(
            origin: .user, originLabel: "测试按钮（\(center.deviceLabel)）", targetDeviceId: target,
            title: "测试改动 \(stamp)",
            changes: [ProposalChange(field: "测试字段", before: "旧值", after: "新值 \(stamp)")],
            reason: "多端审批联调：空改动，不碰真实数据",
            action: .experimentNoop(note: "面板测试 \(stamp)"), experiment: true))
    }
}
