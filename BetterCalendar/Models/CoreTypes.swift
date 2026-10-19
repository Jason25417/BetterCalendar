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
enum CompletionStatus: String, Codable, CaseIterable, Sendable {
    case done, partial, missed, over
    case extra   // 计划外 bonus
}

enum PlanCalendarKind: String, Codable, CaseIterable, Sendable {
    case planned    // 绿：预先设计 / 今日计划（对比基线）
    case actual     // 蓝：实际（当前时刻左侧，实时增长）
    case preview    // 橙：从现在起的可行预览（当前时刻右侧，随 re-flow 动态，被蓝色蚕食，日终消失）
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
    /// 命名阶段（#40 批3）：用户说「分三个阶段：A、B、C」时解析出来，按给出顺序。
    /// 红线：只是名字的有序列表——无嵌套、无各自 DDL（检查点无期限）。没说阶段就空。
    var checkpoints: [String] = []
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
    /// 图钉（P4 Q6，SPEC §19.13）：你亲手改过时间的块，到这一刻之前自动调整一律绕开；nil=没钉。只读回、不经 replacePlanned 写。
    var pinnedUntil: Date? = nil
    /// 同步版本（P4 Q7/Q8）：每次真改动单调递增（毫秒时间戳，Lamport 式 max(现在, 旧值+1)）；0=旧数据。只读回。
    var syncVersion: Int64 = 0
    /// 最后写入它的设备（作者宽限：别的设备先不替它新建日历事件）。只读回。
    var syncWriter: String? = nil
    /// 最后一次写入的来源（PlanWriteReason.rawValue）：你的改动 vs 自动调整谁赢。只读回。
    var syncSource: String? = nil
}

extension ScheduledBlock {
    /// 此刻是否是图钉（P4 Q6）。
    func isPinned(at now: Date) -> Bool { (pinnedUntil.map { $0 > now }) ?? false }
}

extension ScheduledBlock {
    static let parallelPrefix = "parallel:"
    /// 所属并行组标签（nil=不并行）。同组块 reflow/重排时作为整体同起点铺开。
    var parallelGroup: String? { labels.first { $0.hasPrefix(Self.parallelPrefix) } }

    /// 族（E5b/D2，§14.3 闭集）：labels `family:<族名>` 前缀——零 schema 变更走遍全链。
    /// E5e（FamilyResolver 三重一致性）开始写值；写值前恒 nil=引擎 setup/聚簇保持中性。
    static let familyPrefix = "family:"
    var family: String? {
        labels.first { $0.hasPrefix(Self.familyPrefix) }
            .map { String($0.dropFirst(Self.familyPrefix.count)) }
    }
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
    /// 下一个未完成阶段名（#40 批3）：排程大脑据此把块名写成「任务 · 阶段」——执行时知道具体干什么。
    var nextCheckpoint: String?
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

/// 写日历用的事件草稿：EventKitCalendarStore 消费（测试用 FakeCalendarStore 同款协议）。
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
    /// 读回时带上（P4.0-2 同章去重的确定性排序键：两台设备看到的相同）；写入时忽略。
    var creationDate: Date? = nil
    var externalID: String? = nil
    /// 写入用（P4.0-1 / D2）：用户明确选了「把日历里新建的这件加进计划」→ 允许认领同「标题＋起始分钟」的
    /// 无章事件并补章。默认 false：BetterCalendar 绝不认领、修改或删除不带章的事件。
    var claimsUnstamped: Bool = false
    /// 章 v2（P4 Q7/Q8，见 CalendarStamp）：写入时随章写进事件 URL、读回时解析出来。
    /// stampHash = 写入那一刻（起止分钟＋标题）的短哈希：事件内容的哈希仍等于它 = 没人动过（事件自证，跨设备有效）。
    /// 两者都 nil = 旧章（只有 bettercalendar://block/UUID）或不需要 v2 的写入（蓝色实际）。
    var stampVersion: Int64? = nil
    var stampHash: String? = nil
    /// 读回时带上：事件最后修改时间（两边都是你亲手改时「后改的赢」用）。写入时忽略。
    var lastModified: Date? = nil
}
