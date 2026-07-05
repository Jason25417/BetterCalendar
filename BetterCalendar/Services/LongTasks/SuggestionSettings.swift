//
//  SuggestionSettings.swift
//  BetterCalendar
//
//  L3 建议强度（§5.11：只做单一档 push 强度）：温和=每天≤1条 / 更主动=至多2条 / 关闭。默认温和。
//  「别再提」永久静音的任务集（先放下=体面出口的一部分）。本地 UserDefaults。
//

import Foundation

enum PushIntensity: String, CaseIterable, Sendable {
    case gentle    // 温和：≤1 条/天（默认）
    case proactive // 更主动：≤2 条
    case off       // 关闭

    var cap: Int { self == .gentle ? 1 : (self == .proactive ? 2 : 0) }
    var label: String { self == .gentle ? "温和（每天最多 1 条）" : (self == .proactive ? "更主动（最多 2 条）" : "关闭") }
}

enum SuggestionSettings {
    private static let defaults = UserDefaults.standard

    static var intensity: PushIntensity {
        get { PushIntensity(rawValue: defaults.string(forKey: "push.intensity") ?? "") ?? .gentle }
        set { defaults.set(newValue.rawValue, forKey: "push.intensity") }
    }

    /// 「别再提」永久静音的任务 id 集。
    static var mutedTaskIDs: Set<UUID> {
        get { Set((defaults.array(forKey: "push.muted") as? [String] ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString), forKey: "push.muted") }
    }

    static func mute(_ id: UUID) { var s = mutedTaskIDs; s.insert(id); mutedTaskIDs = s }
}
