//
//  FocusStateExporter.swift
//  BetterCalendar
//
//  聪音（《放松时光：与你共享 Lo-Fi 故事》）联动（Jason 2026-07-10，两侧哲学审核通过、见 SPEC §11 / 待讨论点子 #17）：
//  把当前专注状态写成 focus-state.json，供聪音的 BepInEx mod 读 → 驱动番茄/情绪/经验值。
//  单向 BC→聪音、本地文件桥（同 Mac、零云）。仅在设置开「聪音联动」时写；关掉即删文件（mod 见不到文件=不驱动）。
//  红线：落后=温柔陪着、完成=欢快，绝不失望——BC 只如实吐状态，聪音那边只放大做成。
//

import Foundation

enum FocusStateExporter {
    /// 联动总开关（热切换）。关掉时顺手删掉状态文件——mod 靠文件在不在判断是否驱动。
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "integration.chiyneSync") }
        set {
            UserDefaults.standard.set(newValue, forKey: "integration.chiyneSync")
            if !newValue { try? fileURL.map { try FileManager.default.removeItem(at: $0) } }
        }
    }

    struct State: Codable {
        var schemaVersion = 1
        var updatedAt: Date
        var active: Active?           // 当前正在做的事（nil=空档）
        var lastEvent: Event?         // 最近一次事件（mod 据此触发起止语音/经验值）
        struct Active: Codable {
            var title: String
            var timingStyle: String   // light / pomodoro / none
            var startedAt: Date
            var elapsedSec: Int
            var plannedSec: Int?      // 计划时长（轻计时的预算；nil=计划外）
        }
        struct Event: Codable {
            var kind: String          // start / complete / tick
            var title: String
            var durationSec: Int?     // complete 时=这件事投入时长（→换算经验值）
        }
    }

    /// 桥文件目录（沙盒容器内的 Application Support/BetterCalendar；mod 侧按容器路径优先来读）。
    private static func bridgeURL(_ name: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let bc = dir.appendingPathComponent("BetterCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: bc, withIntermediateDirectories: true)
        return bc.appendingPathComponent(name)
    }

    private static var fileURL: URL? { bridgeURL("focus-state.json") }

    /// 状态文件是否已存在（menu bar tick 用：联动开着+有任务在进行+文件缺失 → 补写一份，
    /// 让"任务进行中途才开开关"也立即接上，不用等下一个事件）。
    static var stateFileExists: Bool {
        guard let url = fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func write(active: State.Active?, event: State.Event?) {
        guard isEnabled, let url = fileURL else { return }
        let state = State(updatedAt: .now, active: active, lastEvent: event)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: 待办投影（SPEC §11 过审 2026-07-10）：今天的事项 → chiyne-todo.json → 游戏「Better Calendar」清单；
    // 游戏里勾完成 → mod 写 chiyne-inbox.json 回容器 → consumeInbox 消化成 BC 完成（同「提醒打勾」先例）。

    /// 待办投影开关（默认关）。mod 侧会写游戏存档（首次写入前 mod 自动备份）；关掉即删投影文件。
    static var todoProjectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "integration.chiyneTodoProjection") }
        set {
            UserDefaults.standard.set(newValue, forKey: "integration.chiyneTodoProjection")
            if !newValue { try? bridgeURL("chiyne-todo.json").map { try FileManager.default.removeItem(at: $0) } }
        }
    }

    struct TodoItem: Codable {
        var id: String       // PlanBlock UUID 字符串（mod 藏进待办文本、回流按它认块）
        var title: String
        var done: Bool
    }
    private struct TodoProjection: Codable {
        var schemaVersion = 1
        var updatedAt: Date
        var items: [TodoItem]
    }

    static func writeTodoProjection(_ items: [TodoItem]) {
        guard isEnabled, todoProjectionEnabled, let url = bridgeURL("chiyne-todo.json") else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(TodoProjection(updatedAt: .now, items: items)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 游戏里勾完成的回流：读并删 chiyne-inbox.json，返回完成的计划块 id。
    /// 不 gate 在开关上：开关关掉前游戏里勾的完成仍然是用户亲手勾的，照常消化。
    static func consumeInbox() -> [UUID] {
        guard let url = bridgeURL("chiyne-inbox.json"),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return [] }
        try? FileManager.default.removeItem(at: url)
        struct Inbox: Codable { var completedIDs: [String] }
        let ids = (try? JSONDecoder().decode(Inbox.self, from: data))?.completedIDs ?? []
        return ids.compactMap(UUID.init(uuidString:))
    }

    /// 是否有待消化的回流（menu bar tick 的轻量探测，只查文件存在）。
    static var hasPendingInbox: Bool {
        guard let url = bridgeURL("chiyne-inbox.json") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
