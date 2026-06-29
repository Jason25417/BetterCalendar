//
//  CoreTypes.swift
//  BetterCalendar
//
//  跨层共用的枚举 + 「实现无关」的 DTO。
//  DTO 是协议进出的数据契约：换实现（云端 Claude → 端侧 / 本地算法）时不动这些类型。
//

import Foundation

// MARK: - 枚举（均为 String + Codable，便于 SwiftData 存储与日后 CloudKit）

enum BlockKind: String, Codable, CaseIterable, Sendable {
    case planned   // 预先设计（绿）
    case actual    // 实际（蓝）
}

enum TimingStyle: String, Codable, CaseIterable, Sendable {
    case pomodoro  // 番茄钟（硬，强制休息）
    case light     // 轻计时（只显时长、不打断）—— 默认
    case none      // 不计时
}

/// 要紧事标签（自主支持式 push 的对象；默认 normal）。
enum BlockPriority: String, Codable, CaseIterable, Sendable {
    case normal
    case important   // 今日要紧事 (MIT)
}

/// 谁指派的（用于复盘措辞；外部硬 DDL 的处理与自设不同）。
enum AssignedBy: String, Codable, CaseIterable, Sendable {
    case selfAssigned = "self"
    case external
}

enum CompletionStatus: String, Codable, CaseIterable, Sendable {
    case done, partial, missed, over
    case extra   // 计划外 bonus
}

enum PlanCalendarKind: String, Codable, CaseIterable, Sendable {
    case planned, actual
}

// MARK: - 设置用枚举

enum CalendarBackend: String, Codable, CaseIterable, Sendable {
    case fake      // 开发期：写进 App 内、画预览，不碰系统日历
    case eventKit  // 真接系统日历（逻辑稳了再切）
}

enum NotifyMode: String, Codable, CaseIterable, Sendable {
    case minimal           // 早晚各一条
    case withFixedBlocks   // 早晚 + 固定块
    case silent
}

enum ParserMode: String, Codable, CaseIterable, Sendable {
    case cloudLLM   // 原型期：云端 Claude
    case onDevice   // 端侧 Foundation Models（留接口，后换）
    case manual
}

// MARK: - DTO（实现无关）

/// 解析输出：自然语言 → 结构化（未落库、未排程）。
struct ParsedBlock: Sendable, Identifiable {
    var id = UUID()
    var title: String
    var start: Date?
    var end: Date?
    var durationMinutes: Int?
    var isFixed: Bool = false
    var category: String = ""
    var timingStyle: TimingStyle = .light
    var priority: BlockPriority = .normal
    var deadline: Date?
}

struct ParsedPlan: Sendable {
    var blocks: [ParsedBlock] = []
}

/// 排程大脑的「已定时」块（已有明确起止）。
struct ScheduledBlock: Sendable, Identifiable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var isFixed: Bool = false
    var timingStyle: TimingStyle = .light
    var priority: BlockPriority = .normal
    var deadline: Date?
}

/// 排程大脑输出：排好序的块 + 温和措辞（正反馈/前向 nudge）。
struct PlanDecision: Sendable {
    var orderedBlocks: [ScheduledBlock] = []
    var note: String?
}

/// 写日历用的事件草稿：FakeCalendarStore / 未来 EventKitCalendarStore 都消费它。
struct CalendarEventDraft: Sendable, Identifiable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var kind: PlanCalendarKind
    var notes: String?
}
