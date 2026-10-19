//
//  AgentKind.swift
//  BetterCalendar
//
//  W20（SPEC §19.11 / §19.14「智能体多实现」，产品原则 9、10）：
//  「BetterCalendar 智能体」是一个角色；背后可以接不同的实现（Claude Code 专用会话 / App 内置 / 以后的 Dots）。
//  Jason 2026-10-19：各实现只是构建**同一个** BetterCalendar 智能体的不同方式——心智模型不变，按偏好或生态选。
//    · 同一时刻只接通一个（设置 → 智能体 选）；没选中的实现**没有任何通道**（不收事件、不写桥接、不轮询），自然不会有动作。
//    · 不设自动备用（原则 10）：选中的那个跑不了就在对话与状态区直说哪里坏了、你能做什么；要换由你手动切。
//    · 预授权规则、共享记忆都属于这个角色，所有实现共用；提案与留底记下是哪种实现提的，便于追溯。
//

import Foundation
import Observation

nonisolated enum AgentKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Claude Code 专用会话，经 Mac 上的桥接目录（开发调试实现；原则 9 不约束它）。
    case claudeCode
    /// App 内置智能体：在 App 进程里直接调 DeepSeek，iPhone 和 Mac 都能跑，不需要 Mac / Claude Code。
    case builtin

    var id: String { rawValue }

    /// 设置页选项上的名字。
    var pickerLabel: String {
        switch self {
        case .claudeCode: "Claude Code（开发调试，经 Mac 桥接）"
        case .builtin: "BetterCalendar 内置（DeepSeek）"
        }
    }

    /// 短名字（状态行、留底）。
    var shortLabel: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .builtin: "内置智能体"
        }
    }

    /// 提案 / 消息 / 留底上的发起者名字。
    var originLabel: String {
        switch self {
        case .claudeCode: "BetterCalendar 智能体"
        case .builtin: "BetterCalendar 内置智能体"
        }
    }

    /// Proposal.agentKey 的解读：nil（旧记录 / 经桥接导入）= Claude Code。
    static func of(_ key: String?) -> AgentKind { key.flatMap(AgentKind.init(rawValue:)) ?? .claudeCode }
}

/// 当前接通的是哪个实现（随 iCloud 设置同步：两端接的是同一个智能体）。
nonisolated enum AgentSelectionSettings {
    static let key = "agent.active.v1"
    /// W17 约定：日用版默认 = 现在的行为（Claude Code），Jason 自己切。Dev 版同样默认 Claude Code（不让开发版悄悄换实现）。
    static let defaultKind: AgentKind = .claudeCode

    static func kind(in d: UserDefaults = .standard) -> AgentKind {
        (d.string(forKey: key)).flatMap(AgentKind.init(rawValue:)) ?? defaultKind
    }
}

@MainActor @Observable final class AgentSelection {
    private(set) var kind: AgentKind
    private let defaults: UserDefaults
    /// 切换后通知组装点（开 / 关各实现的通道）。
    var onChange: ((AgentKind) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        kind = AgentSelectionSettings.kind(in: defaults)
    }

    /// 只由你在设置里点选触发。
    func select(_ new: AgentKind) {
        guard new != kind else { return }
        defaults.set(new.rawValue, forKey: AgentSelectionSettings.key)
        apply(new, source: "你在这台设备上切换")
    }

    /// 另一台设备切了（设置同步落到本地）→ 重读。
    func reload() {
        let latest = AgentSelectionSettings.kind(in: defaults)
        if latest != kind { apply(latest, source: "另一台设备切换后同步过来") }
    }

    private func apply(_ new: AgentKind, source: String) {
        let old = kind
        kind = new
        DevLog.shared.info("智能体", "当前智能体：\(old.shortLabel) → \(new.shortLabel)（\(source)）")
        onChange?(new)
    }
}
