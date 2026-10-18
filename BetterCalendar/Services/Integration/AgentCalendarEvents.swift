//
//  AgentCalendarEvents.swift
//  BetterCalendar
//
//  P4 Q3（SPEC §19.13）：你在苹果日历里删掉 BetterCalendar 的块 → App 已照办（从时间线移走、收进待办区）；
//  这里把它写成桥接事件 calendar_user_deleted 的内容，交给智能体按上下文决定要不要问一句。
//  原则 8「只读到是外部改的」：系统接口不给改动者身份，按「你的操作」对待，把拿得到的线索一并给智能体。
//

import Foundation

enum AgentCalendarEvents {
    static func deletionSummary(_ ds: [CalendarUserDeletion]) -> String {
        let names = ds.prefix(3).map { "「\($0.block.title)」" }.joined(separator: "、") + (ds.count > 3 ? " 等 \(ds.count) 件" : "")
        let collected = ds.contains { $0.collectedToTodo }
        return "你在苹果日历里移出了 \(names)：已从今天的时间线移走" + (collected ? "、收进待办区（可找回）" : "")
    }

    static func deletionPayload(_ ds: [CalendarUserDeletion]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        return [
            "deletions": ds.map { d -> [String: Any] in
                var o: [String: Any] = [
                    "blockId": d.block.id.uuidString, "title": d.block.title,
                    "start": iso.string(from: d.block.start), "end": iso.string(from: d.block.end),
                    "fixed": d.block.isFixed, "important": d.block.priority == .important,
                    "logicalDay": DayContext.dayKey(d.label),
                    "handled": d.trimmedLive ? "trimmedRemainder" : (d.collectedToTodo ? "movedToTodo" : "removedFromTimeline"),
                ]
                if let ddl = d.block.deadline { o["deadline"] = iso.string(from: ddl) }
                if d.block.linkedTaskID != nil { o["fromLongTask"] = true }
                return o
            },
            // 来源线索：在哪本日历里删的、什么时候发现的、由哪台设备发现（系统不告诉我们是谁删的）
            "clues": [
                "calendar": "BetterCalendar · 计划",
                "detectedAt": iso.string(from: ds.first?.detectedAt ?? .now),
                "detectedBy": ProposalDevice.label,
                "actor": "unknown (system calendar does not report who edited; treated as Jason's own action)",
            ],
            "note": "已照办，不要加回去；只在上下文需要时问一句（比如今天不做了？要不要换个时间？）。",
        ]
    }
}
