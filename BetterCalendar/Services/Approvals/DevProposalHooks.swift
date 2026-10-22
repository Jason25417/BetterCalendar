//
//  DevProposalHooks.swift
//  BetterCalendar
//
//  开发期联调钩子（仅 DEBUG + macOS，正式版不编译）：开发会话无法点界面时，
//  用分布式通知名触发「发测试提案 / 批准或拒绝最新一条 / 刷新并打印状态」，结果写 DevLog
//  （自动镜像到 ~/Downloads/BetterCalendar-logs，命令行可读）。只发空改动，不碰真实数据。
//  触发示例：osascript -l JavaScript -e 'ObjC.import("Foundation");$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.jason.BetterCalendar.dev.proposal.test",$(),$(),true)'
//

#if DEBUG && os(macOS)
import Foundation

@MainActor enum DevProposalHooks {
    static let prefix = "com.jason.BetterCalendar.dev.proposal."
    private static var tokens: [NSObjectProtocol] = []

    static func install(center: ProposalCenter, items: LongTaskStore? = nil) {
        guard tokens.isEmpty else { return }
        let hub = DistributedNotificationCenter.default()
        func on(_ name: String, _ action: @escaping @MainActor (ProposalCenter) async -> Void) {
            tokens.append(hub.addObserver(forName: Notification.Name(prefix + name), object: nil, queue: .main) { [weak center] _ in
                Task { @MainActor in
                    guard let center else { return }
                    await action(center)
                    dump(center, after: name)
                }
            })
        }
        on("test") { center in
            let stamp = Date.now.formatted(date: .omitted, time: .standard)
            await center.submit(ProposalDraft(
                origin: .user, originLabel: "Claude（替 Jason 测试）", title: "联调测试 \(stamp)",
                changes: [ProposalChange(field: "测试字段", before: "旧值", after: "新值 \(stamp)")],
                reason: "开发钩子：空改动，不碰真实数据", action: .experimentNoop(note: "钩子 \(stamp)"), experiment: true))
        }
        on("approve") { center in if let p = center.pending.first { await center.decide(p.id, .approve, actorLabel: "Claude（替 Jason 批准）") } }
        on("decline") { center in if let p = center.pending.first { await center.decide(p.id, .decline, actorLabel: "Claude（替 Jason 拒绝）") } }
        on("refresh") { center in await center.refresh() }
        // W34 发版前自测（见 DevW34SelfTest）
        on("w34seed") { [weak items] center in if let items { await DevW34SelfTest.seed(center: center, items: items) } }
        on("w34run") { [weak items] center in if let items { await DevW34SelfTest.run(center: center, items: items) } }
        on("w34undo") { center in await DevW34SelfTest.undoYours(center: center) }
        on("w34clean") { [weak items] _ in if let items { await DevW34SelfTest.clean(items: items) } }
        DevLog.shared.info("多端审批·钩子", "开发钩子已安装（\(prefix)test|approve|decline|refresh|w34seed|w34run|w34undo|w34clean）")
    }

    private static func dump(_ center: ProposalCenter, after name: String) {
        let lines = center.proposals.prefix(5).map { p in
            let l = center.latency(for: p.id)
            return "\(p.id.uuidString.prefix(8)) \(p.effectiveState(at: .now).rawValue) 决定端=\(p.decidedByDeviceId ?? "-") "
                + "通知延迟=\(l.notify.map { String(format: "%.1fs", $0) } ?? "-") 收起延迟=\(l.withdraw.map { String(format: "%.1fs", $0) } ?? "-") \(p.title)"
        }
        DevLog.shared.info("多端审批·钩子", "[\(name)] 本机=\(center.deviceLabel) 待确认=\(center.pending.count) 错误=\(center.lastError ?? "无")\n" + lines.joined(separator: "\n"))
    }
}
#endif
