//
//  ProposalPanel.swift
//  BetterCalendar
//
//  SPEC §19 B3：App 内的多端审批入口——与系统通知、（将来）对话卡片指向同一份提案状态。
//  开发期面板：待确认列表 + 最近结果 + 操作留底 + 发一条测试改动（空改动，不碰真实数据）。
//

import SwiftUI

struct ProposalPanel: View {
    @Bindable var center: ProposalCenter
    var focusId: UUID?
    var bridge: AgentBridge? = nil
    var alertPush: ProposalAlertPushControl? = nil
    var messages: AgentMessageCenter? = nil
    @State private var eventsOn = AgentEventSettings.enabled
    @State private var notificationAllowed: Bool?

    var body: some View {
        List {
            if let error = center.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("知道了") { center.clearError() }
                }
            }
            Section("待你确认（\(center.pending.count)）") {
                if center.pending.isEmpty { Text("现在没有需要你确认的改动").foregroundStyle(.secondary) }
                ForEach(center.pending) { p in
                    pendingCard(p).listRowBackground(p.id == focusId ? Color.accentColor.opacity(0.08) : nil)
                }
            }
            Section("最近结果") {
                let closed = center.proposals.filter { $0.effectiveState(at: .now) != .pending }.prefix(20)
                if closed.isEmpty { Text("还没有").foregroundStyle(.secondary) }
                ForEach(Array(closed)) { p in historyRow(p) }
            }
            #if os(macOS)
            if let bridge {
                Section("BetterCalendar 智能体桥接（Mac）") {
                    Text(bridge.folderPath.map { "已连接：\($0)" } ?? "未连接：请选择智能体工作区里的 bridge 文件夹").font(.footnote)
                    if let last = bridge.lastSync { Text("上次同步 \(last.formatted(date: .omitted, time: .standard)) · 已导入 \(bridge.importedCount) 份提案").font(.caption).foregroundStyle(.secondary) }
                    if let error = bridge.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button(bridge.connected ? "重新选择文件夹" : "选择 bridge 文件夹") { bridge.chooseFolder() }
                        if bridge.connected { Button("断开", role: .destructive) { bridge.disconnect() } }
                    }
                }
            }
            #endif
            if let messages { attentionSection(messages) }
            if let alertPush {
                Section("App 关闭时也推送（实验，B5）") {
                    Toggle("新提案由 iCloud 直接推送", isOn: Binding(get: { alertPush.enabled }, set: { on in Task { await alertPush.set(on) } }))
                    Text("打开后，App 没运行也能弹出带批准/拒绝的通知；作用于你所有设备。和本机通知重复时只保留一条。").font(.caption).foregroundStyle(.secondary)
                    if let e = alertPush.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                }
                .task { await alertPush.reload() }
            }
            Section("开发期工具") {
                Text("本机：\(center.deviceLabel)").font(.footnote).foregroundStyle(.secondary)
                notificationRow
                Button("发一条测试改动（由批准的那台设备执行）") { Task { await sendTest(target: nil) } }
                Button("发一条测试改动（指定本机执行）") { Task { await sendTest(target: center.deviceId) } }
                Button("立即刷新") { Task { await center.refresh() } }
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
        .task {
            notificationAllowed = await center.notificationPermission()
            await center.refresh()
        }
    }

    @ViewBuilder private func attentionSection(_ m: AgentMessageCenter) -> some View {
        Section("智能体主动找你（实验，C1–C4）") {
            Toggle("关键时刻唤醒智能体（做完一件事、提案有结论）", isOn: Binding(get: { eventsOn }, set: { eventsOn = $0; AgentEventSettings.enabled = $0 }))
            Text("每次唤醒都会消耗 Claude 订阅额度（实测每次约 20 秒）。需要 Mac 上已连接 bridge 文件夹。").font(.caption).foregroundStyle(.secondary)
            Toggle("允许智能体主动通知你", isOn: Binding(get: { m.settings.enabled }, set: { m.settings.enabled = $0 }))
            Stepper("每小时最多 \(m.settings.maxPerHour) 条", value: Binding(get: { m.settings.maxPerHour }, set: { m.settings.maxPerHour = $0 }), in: 1...6)
            Stepper("每天最多 \(m.settings.maxPerDay) 条", value: Binding(get: { m.settings.maxPerDay }, set: { m.settings.maxPerDay = $0 }), in: 1...20)
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
            if let e = m.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
            #if DEBUG
            Button("发一条测试智能体消息（开发版）") {
                Task { await m.receive(AgentMessageDraft(title: "测试消息", body: "开发联调：这是一条测试消息，不需要任何操作。", reason: "建立云端数据结构 / 联调")) }
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

    private func pendingCard(_ p: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.title).font(.headline)
            Text(p.notificationBody).font(.callout)
            Text("\(p.action.kindLabel) · 截止 \(p.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("同意") { Task { await center.decide(p.id, .approve) } }.buttonStyle(.borderedProminent)
                Button("拒绝", role: .destructive) { Task { await center.decide(p.id, .decline) } }.buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func historyRow(_ p: Proposal) -> some View {
        let state = p.effectiveState(at: .now)
        let who = p.decidedByDeviceId.map { $0 == center.deviceId ? "本机" : "另一台设备" }
        return VStack(alignment: .leading, spacing: 2) {
            Text(p.title)
            Text([state.label, who.map { "决定于\($0)" }, p.resultNote].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(state == .failed ? .orange : .secondary)
            let l = center.latency(for: p.id)
            if l.notify != nil || l.withdraw != nil {
                Text("本机延迟：通知 \(l.notify.map { String(format: "%.1f 秒", $0) } ?? "—") · 收起 \(l.withdraw.map { String(format: "%.1f 秒", $0) } ?? "—")")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
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
