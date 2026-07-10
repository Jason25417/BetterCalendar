//
//  BehaviorLog.swift
//  BetterCalendar
//
//  行为日志（2026-07-10 Jason 定）：与 DevLog（纠错/定位）平行的**第二通道**——记录用户行为事实
//  （确认写入/开始/完成/补一笔/自动日记…），**只存本地、绝不上传**（隐私）。
//  用途 = 未来跨日系统的地基：周结算/月计划/连续坚持天数等可以直接扫这份历史，把过去的成就一并补上。
//  存储 = 容器内 JSONL（追加写、逐行独立、坏一行不废全档）；同时镜像进 DevLog（source=「行为」，
//  🐞 日志页可筛选查看）。测试 host 不写（共享真容器）。
//

import Foundation

enum BehaviorLog {
    struct Event: Codable {
        var at: Date
        var kind: String     // 行为类别：确认写入 / 开始 / 完成 / 补一笔 / 自动日记 / …
        var detail: String   // 简短明细（件数/标题等）
    }

    private static var isTestHost: Bool { NSClassFromString("XCTestCase") != nil }

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let bc = dir.appendingPathComponent("BetterCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: bc, withIntermediateDirectories: true)
        return bc.appendingPathComponent("behavior-log.jsonl")
    }

    /// 记一条行为（追加 JSONL + 镜像 DevLog）。轻量同步；失败静默（行为日志不该打断行为本身）。
    static func record(_ kind: String, _ detail: String = "") {
        guard !isTestHost else { return }
        DevLog.shared.info("行为", detail.isEmpty ? kind : "\(kind)：\(detail)")
        guard let url = fileURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var data = try? enc.encode(Event(at: .now, kind: kind, detail: detail)) else { return }
        data.append(0x0A)   // 换行
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// 读某时间窗的行为（未来周结算/月计划/连续天数的查询口）。逐行解码、坏行跳过。
    static func events(from: Date, to: Date) -> [Event] {
        guard let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8), let e = try? dec.decode(Event.self, from: d) else { return nil }
            return (e.at >= from && e.at < to) ? e : nil
        }
    }

    /// 某逻辑日的行为（4 点日界线口径，与全 App 一致）。
    static func events(onLogicalDay day: Date) -> [Event] {
        let start = DayContext.logicalStartOfDay(day)
        return events(from: start, to: start.addingTimeInterval(24 * 3600))
    }
}
