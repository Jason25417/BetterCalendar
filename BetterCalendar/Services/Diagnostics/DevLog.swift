//
//  DevLog.swift
//  BetterCalendar
//
//  开发期集中日志：把任何层（含 service 里的静默回退）的失败显出来。
//  ⚠️ 这是**开发期**设施，与产品「正反馈优先 / 无感」原则有意冲突；当前以开发便利+稳定优先，上架前切回静默自愈。
//

import Foundation
import Observation

@Observable
final class DevLog {
    static let shared = DevLog()

    enum Level: String { case info, warning, error }

    struct Entry: Identifiable {
        let id = UUID()
        let time = Date()
        let level: Level
        let source: String
        let message: String
    }

    private(set) var entries: [Entry] = []

    /// 最近一条 警告/错误（首页横幅用）。
    var lastIssue: Entry? { entries.last { $0.level != .info } }

    func log(_ level: Level, _ source: String, _ message: String) {
        entries.append(Entry(level: level, source: source, message: message))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
        print("[\(level.rawValue.uppercased())] \(source): \(message)")  // 也进 Xcode 控制台
    }

    func info(_ source: String, _ message: String) { log(.info, source, message) }
    func warn(_ source: String, _ message: String) { log(.warning, source, message) }
    func error(_ source: String, _ message: String) { log(.error, source, message) }
    func clear() { entries.removeAll() }
}
