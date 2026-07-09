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

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let bc = dir.appendingPathComponent("BetterCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: bc, withIntermediateDirectories: true)
        return bc.appendingPathComponent("focus-state.json")
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
}
