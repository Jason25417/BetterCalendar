//
//  ActivityBridgeMirror.swift
//  BetterCalendar
//
//  W13：把本机活动日文件镜像到智能体桥接目录 bridge/activity/YYYY-MM-DD.jsonl（智能体 read_activity、W14 哨兵读）。
//  - 走 AgentBridge 已有的安全书签（同步时已在访问范围内），每轮同步跑一次；只拷有变化的日文件（大小或修改时间不同），原子替换。
//  - 桥接目录里同样只留 90 天（稳定性/体积边界）。
//  - 另写 bridge/activity/status.json：各来源状态 + 记录开关/暂停，智能体与哨兵据此区分「没在记」和「没发生」。
//  纯文件操作，测试用临时目录（绝不碰真 bridge/）。
//

import Foundation

nonisolated struct ActivityBridgeMirror: Sendable {
    let localRoot: URL
    let bridgeRoot: URL
    var calendar: Calendar = .current
    var retentionDays: Int = FileActivityLog.retentionDays

    nonisolated struct Result: Equatable, Sendable { var copied: [String] = []; var pruned: [String] = [] }

    var activityDir: URL { bridgeRoot.appendingPathComponent("activity", isDirectory: true) }

    func mirror(now: Date, status: [String: Any]? = nil) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: activityDir, withIntermediateDirectories: true)
        let local = ActivityDayFiles(root: localRoot, calendar: calendar)
        let remote = ActivityDayFiles(root: activityDir, calendar: calendar)
        var result = Result()
        let expired = Set(local.expiredDays(now: now, retentionDays: retentionDays))
        for day in local.allDays() where !expired.contains(day) {
            let src = local.url(forDay: day), dst = remote.url(forDay: day)
            if Self.same(src, dst) { continue }
            try Data(contentsOf: src).write(to: dst, options: .atomic)
            // 修改时间对齐源文件，下轮比较才稳定（只看大小会漏掉同长度改写，只看时间会被原子写打乱）。
            if let m = (try? fm.attributesOfItem(atPath: src.path))?[.modificationDate] as? Date {
                try? fm.setAttributes([.modificationDate: m], ofItemAtPath: dst.path)
            }
            result.copied.append(day)
        }
        for day in remote.expiredDays(now: now, retentionDays: retentionDays) {
            try fm.removeItem(at: remote.url(forDay: day)); result.pruned.append(day)
        }
        if let status {
            let data = try SafeJSON.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: activityDir.appendingPathComponent("status.json"), options: .atomic)
        }
        return result
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let x = try? fm.attributesOfItem(atPath: a.path), let y = try? fm.attributesOfItem(atPath: b.path) else { return false }
        return (x[.size] as? Int) == (y[.size] as? Int)
            && (x[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } == (y[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) }
    }
}
