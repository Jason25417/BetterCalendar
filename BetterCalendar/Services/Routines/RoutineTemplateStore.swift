//
//  RoutineTemplateStore.swift
//  BetterCalendar
//
//  例行模板（K1，2026-08-15 Jason 裁三点全过）：routine=流水线模块，不是页面。
//  机制四条（已裁）：①实例与模板分离——日内拖动恒「仅此次」（改实例），永久改点走设置（改模板），
//  不弹「仅此次/所有将来」对话框 ②跳过=溶解（实例 isAnchor=true 走 E5c 生活锚通道：零记录、
//  明天照常、永不打卡链）③存储=iCloud KV（不动 CloudKit schema；SettingsSync/Milestone 先例）
//  ④v1 只内置五件、默认全关（opt-in 铁律）、不开用户自建（防配置面滑坡，M10 反需求）。
//  实例不落库——物化成普通草稿块（arrange 时补插，走确认制），带 `routine:<kind>` 标签
//  （K4 细表的权威判定来源）。K2 已裁：早 routine=晨间摘要的块化（门块，opt-in 呈现升级）、
//  晚 routine=收尾流程的入口时间线化（复盘宿主消歧就此结案）。
//

import Foundation
import Observation

/// 一个例行模板（Codable 存 iCloud KV）。
nonisolated struct RoutineTemplate: Codable, Identifiable, Equatable, Sendable {
    var id: String                   // 内置件固定 id（"routine.morning" 等）——存储合并键
    var name: String
    var kind: String                 // morning / evening / meal / exercise（→ routine: 标签，K4 查表）
    var hour: Int
    var minute: Int = 0
    var durationMinutes: Int
    /// 生效日（Calendar.weekday：1=周日…7=周六）；默认每天。
    var weekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    var enabled: Bool = false        // opt-in 铁律：默认全关
}

@MainActor
@Observable
final class RoutineTemplateStore {
    static let storageKey = "routine.templates"
    /// 组装点/设置页共用一份（模板是全局偏好，iCloud KV 本就全局；测试用 init(persisted:false)）。
    static let shared = RoutineTemplateStore()

    /// v1 内置五件（默认全关）。新增内置件时：老用户存储里没有的 id 会在 load 时自动补进。
    static let builtins: [RoutineTemplate] = [
        RoutineTemplate(id: "routine.morning", name: "开始今天", kind: "morning",
                        hour: 9, durationMinutes: 15),
        RoutineTemplate(id: "routine.evening", name: "收个尾", kind: "evening",
                        hour: 21, minute: 30, durationMinutes: 15),
        RoutineTemplate(id: "meal.lunch", name: "午饭", kind: "meal",
                        hour: 12, minute: 0, durationMinutes: 45),
        RoutineTemplate(id: "meal.dinner", name: "晚饭", kind: "meal",
                        hour: 18, minute: 30, durationMinutes: 45),
        RoutineTemplate(id: "life.exercise", name: "锻炼", kind: "exercise",
                        hour: 17, durationMinutes: 60),
    ]

    private let kv: NSUbiquitousKeyValueStore?
    private(set) var templates: [RoutineTemplate] = []

    init(persisted: Bool = true) {
        kv = persisted ? .default : nil
        load()
        if persisted {
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: kv, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.load() }
            }
            kv?.synchronize()
        }
    }

    private func load() {
        var stored: [String: RoutineTemplate] = [:]
        if let data = kv?.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([RoutineTemplate].self, from: data) {
            for t in decoded { stored[t.id] = t }
        }
        // 内置序为骨架，存储覆盖同 id（老用户自动补新内置件；用户不可自建=不会有内置外的 id）
        templates = Self.builtins.map { stored[$0.id] ?? $0 }
    }

    func update(_ t: RoutineTemplate) {
        guard let idx = templates.firstIndex(where: { $0.id == t.id }) else { return }
        templates[idx] = t
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(templates) {
            kv?.set(data, forKey: Self.storageKey)
            kv?.synchronize()
        }
    }

    /// 某日生效的启用模板。
    func enabled(on day: Date) -> [RoutineTemplate] {
        let weekday = Calendar.current.component(.weekday, from: day)
        return templates.filter { $0.enabled && $0.weekdays.contains(weekday) }
    }

    /// 物化一个实例块（纯函数）：isAnchor 占位语义（不进执行列表、溢出走溶解、不计完成度）+
    /// `routine:<kind>` 标签（K4 细表权威判定；也是「这是例行实例」的标识）。
    nonisolated static func instantiate(_ t: RoutineTemplate, on day: Date) -> ScheduledBlock {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let start = cal.date(byAdding: .minute, value: t.hour * 60 + t.minute, to: dayStart) ?? dayStart
        return ScheduledBlock(title: t.name, start: start,
                              end: start.addingTimeInterval(TimeInterval(t.durationMinutes * 60)),
                              isAnchor: true, timingStyle: .none,
                              labels: [AnchorKindTable.routinePrefix + t.kind])
    }
}
