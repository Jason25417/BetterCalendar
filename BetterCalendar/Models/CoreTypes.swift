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
    case planned    // 绿：预先设计 / 今日计划（对比基线）
    case actual     // 蓝：实际（当前时刻左侧，实时增长）
    case preview    // 橙：从现在起的可行预览（当前时刻右侧，随 re-flow 动态，被蓝色蚕食，日终消失）
}

/// 反思层（日记）条目来源（数据预留，功能后做）。
enum JournalSource: String, Codable, CaseIterable, Sendable {
    case written
    case importedFromAppleJournal   // Apple 手记一次性导入（只进不出，见反思层文档 §7）
    case fromSuggestion
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
    var isAnchor: Bool = false   // 作息锚点（午饭/通勤/午休）：排进日程占时间，但不计完成度
    var category: String = ""
    var timingStyle: TimingStyle = .light
    var priority: BlockPriority = .normal
    var deadline: Date?
    var labels: [String] = []    // 0.22：并行组 "parallel:<组名>" 等扩展标签
}

/// 解析出的「在途」长期事项提案（M10）：远期 DDL 任务 / 长线作业，确认写入时入池。
struct ParsedLongTask: Sendable, Identifiable {
    var id = UUID()
    var title: String
    var deadline: Date?
    var cadenceMinutesPerWeek: Int?
    var totalMinutes: Int?
    var unitMinutes: Int?
}

struct ParsedPlan: Sendable {
    var blocks: [ParsedBlock] = []
    var longTasks: [ParsedLongTask] = []   // 长期事项另放（不占当日块）
    var isLoose: Bool = false              // 用户明说"想松散/休息一下"→标目标日松散（§5.12；解析显式意图非 App 自判）
}

/// 排程大脑的「已定时」块（已有明确起止）。
struct ScheduledBlock: Sendable, Identifiable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var isFixed: Bool = false
    var isAnchor: Bool = false   // 作息锚点（午饭/通勤/午休）：占时间但不计完成度
    var timingStyle: TimingStyle = .light
    var priority: BlockPriority = .normal
    var deadline: Date?
    var linkedTaskID: UUID?      // 精确归属：本块属于哪个未来任务（0.18.2）
    var labels: [String] = []    // 扩展标签（0.22 首用：并行组 "parallel:<组名>"，同组=同时段、reflow 绑定）
}

extension ScheduledBlock {
    static let parallelPrefix = "parallel:"
    /// 所属并行组标签（nil=不并行）。同组块 reflow/重排时作为整体同起点铺开。
    var parallelGroup: String? { labels.first { $0.hasPrefix(Self.parallelPrefix) } }
}

// ReflowResolution（压缩/跳过/分割三选）已退役（0.23 A）：「排不下」弹窗=羞辱（违 §3.3），
// 溢出语义改为候补——不弹、不标、留在 menu bar 列表可见可选（SPEC §11 ②）。

/// 目标日已被占用的时段（已有日历事件；排程避开它们）。
struct BusySlot: Sendable {
    var title: String
    var start: Date
    var end: Date
}

/// 解析上下文（0.13.1）：目标日已有日程 + 当天到期提醒——让排程大脑"看得见"现实。
struct ParseContext: Sendable {
    var busy: [BusySlot] = []
    var dueReminders: [String] = []
    var pool: [LongTaskBrief] = []   // 长期任务池（C/L1：识别"今天做N小时长期任务"委托→生成具体块）
    var isBackfill: Bool = false     // 复盘「补一笔今日完成事件」=记**过去**做的事 → 不套 now+5min 起排下限
    var isEmpty: Bool { busy.isEmpty && dueReminders.isEmpty }
}

/// 「在途」摘要（M10-2）：给排程大脑的池上下文（实现无关 DTO）。
struct LongTaskBrief: Sendable {
    var title: String
    var deadline: Date?
    var cadenceMinutesPerWeek: Int?
}

/// 排程大脑输出：排好序的块 + 温和措辞（正反馈/前向 nudge）+（reflow 时）候补。
struct PlanDecision: Sendable {
    var orderedBlocks: [ScheduledBlock] = []
    var note: String?
    /// 候补（0.23 B，SPEC §11 ②）：放不进收工线的弹性块——不铺时间、不画橙，
    /// 温和地留在 menu bar 列表可见可选；★与用户自排的晚间块永不进此。
    var deferred: [ScheduledBlock] = []
    /// 来自「在途」的建议块标题（M10-2：UI 标来源、删除零成本）。
    var poolSuggestedTitles: [String] = []
}

/// 写日历用的事件草稿：FakeCalendarStore / 未来 EventKitCalendarStore 都消费它。
struct CalendarEventDraft: Sendable, Identifiable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var kind: PlanCalendarKind
    var notes: String?
    /// 会前 N 分钟系统提醒（⑤会议自动化）：仅固定块/会议设它=挂 EKAlarm 提醒收尾当前事；
    /// nil=无提醒（绿/蓝/橙普通块的默认，原则4「仅固定块提醒」）。
    var alarmLeadMinutes: Int?
    /// 事件对应的计划块 id（重构 P1「稳定身份」）：写进事件 URL（bettercalendar://block/UUID），
    /// 随 iCloud 日历同步到所有设备——匹配一律按它，不再按标题模糊匹配。nil=无主（旧事件/外部事件）。
    var blockID: UUID?
}
