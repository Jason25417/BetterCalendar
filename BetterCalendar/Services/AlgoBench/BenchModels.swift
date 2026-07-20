//
//  BenchModels.swift
//  BetterCalendar
//
//  算法试验台（2026-07-08 Jason 拍板）：把 解析/微调/reflow 从真实链路里隔离出来单测算法本身。
//  纪律：不碰真日历、不碰真相源——输出只进内存和界面（比假日历更彻底）。
//  用例四维：理解力（解析对不对）/ 服从性（听没听指令）/ 执行力（排得合不合规）/ 约束解码（格式抽风率，跑时自动记）。
//  上架前随「开发期可见报错」条款一起隐藏（CLAUDE.md 开发期约定）。
//

import Foundation

/// 被测能力（试验台三条被测管线，对应 ScheduleParsing / PlanRefining / PlanningEngine.reflow）。
nonisolated enum BenchCapability: String, Codable, CaseIterable, Sendable {
    case parse    // 自然语言 → 计划块
    case refine   // 草稿 + 一句指令 → 调整后草稿
    case reflow   // 剩余块从此刻重排
    case arrange  // 排序+note（0.28.1：RuleBased 固化 vs LLM 对照）
    case polish   // 日记润色（0.28.2：云端 vs 端侧对照——合成样例文集，真日记绝不进）
    case longTaskEdit  // 长期任务「说一句」（#43，2026-07-20：加新的/改现有的意图判断+字段抽取）

    var label: String {
        switch self {
        case .parse: "解析"
        case .refine: "微调"
        case .reflow: "reflow"
        case .arrange: "排序"
        case .polish: "润色"
        case .longTaskEdit: "长期"
        }
    }
}

/// 用例输入里的块描述（JSON 友好：时间用 HH:mm + 时长，跑时锚到参考日）。
/// nonisolated：Codable 合成需要（同 DraftSnapshot 的既有 idiom）。
nonisolated struct BenchBlockSpec: Codable, Sendable {
    var title: String
    var startHM: String          // "HH:mm"（参考日当天；凌晨块配 startDayOffset=1）
    var durationMinutes: Int
    var isFixed: Bool? = nil
    var isAnchor: Bool? = nil
    var timingStyle: String? = nil   // TimingStyle rawValue，缺省 light
    var priority: String? = nil      // BlockPriority rawValue，缺省 normal
    var parallelGroup: String? = nil // 并行组名（自动加 "parallel:" 前缀）
    var startDayOffset: Int? = nil   // 相对参考日的日历日偏移（跨午夜块用）

    /// 锚到参考日，物化成 ScheduledBlock（每个用例每轮跑物化一次，块 ID 轮内稳定）。
    func materialize(on referenceDay: Date) -> ScheduledBlock? {
        guard let start = BenchTime.date(hm: startHM, dayOffset: startDayOffset ?? 0, on: referenceDay)
        else { return nil }
        var labels: [String] = []
        if let g = parallelGroup, !g.isEmpty { labels.append(ScheduledBlock.parallelPrefix + g) }
        return ScheduledBlock(title: title, start: start,
                              end: start.addingTimeInterval(TimeInterval(durationMinutes * 60)),
                              isFixed: isFixed ?? false, isAnchor: isAnchor ?? false,
                              timingStyle: TimingStyle(rawValue: timingStyle ?? "light") ?? .light,
                              priority: BlockPriority(rawValue: priority ?? "normal") ?? .normal,
                              labels: labels)
    }
}

/// 断言（JSON 友好的扁平结构：kind + 按需参数；求值在 BenchAssertions）。
nonisolated struct BenchExpectation: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case blockCountExact       // count
        case blockCountAtLeast     // count
        case hasBlock              // title（标题匹配即可）
        case hasBlockStart         // title + hm（+ dayOffset）
        case hasBlockEnd           // title + hm（+ dayOffset）
        case noBlock               // title
        case fixedUnmoved          // 输入里所有固定块在输出中原时间原样存在
        case noOverlaps            // 两两不重叠（同并行组豁免）
        case allTimingStyle        // style：所有块都是该计时风格
        case noTimingStyle         // style：任何块都不许是该风格（防「全番茄」抽风）
        case anchorFlag            // title + flag：匹配块的 isAnchor 必须等于 flag
        case fixedFlag             // title + flag：匹配块的 isFixed 必须等于 flag（解析"雷打不动"）
        case sameStart             // title + title2：两块同一起点（并行）
        case orderBefore           // title 的起点必须早于 title2（eat-the-frog 等）
        case arrayOrderBefore      // title 在输出**数组顺序**里必须先于 title2（arrange 推荐顺序用）
        case rawContains           // title=子串：润色输出全文必须包含（错字修正后的正确词/关键事实）
        case rawNotContains        // title=子串：润色输出全文绝不能包含（原错字/病句）
        case rawLengthRatio        // count=最大百分比（如 150）：输出长度 ≤ 原文 × count%（防瞎扩写）
        case allWithinWindDown     // 排定块结束 ≤ 收工线+宽限（★与晚间豁免块除外）
        case deferredContains      // title：候补里必须有它
        case deferredNotContains   // title：候补里绝不能有它（★/晚间豁免）
        case deferredEmpty         // 候补必须为空
        case flagsUnchangedExcept  // title=逗号分隔的可改标题；其余块 固定/★/计时 必须与输入一致
        case hasLongTask           // title：解析出的长期事项里必须有它（标题匹配）
        case longTaskCheckpoints   // title + title2=逗号分隔的阶段名：该长期事项的阶段须**按序**等于它
        // #43 长期任务「说一句」：加新的 vs 改现有的意图判断
        case editUpdatesTarget     // title：updates 里必须有针对它的修改（改对了人）
        case editAddsCheckpoint    // title + title2=阶段名：对该任务的修改须包含加这个阶段
        case editSetsDeadline      // title：对该任务的修改须改了截止（有值）
        case editCreatesOnly       // 必须只产生新增、零修改（防把「加新的」误判成「改现有」）
        case editNoCreates         // 必须零新增（防把「改现有」误判成「加新的」——最常见的错）
    }

    var kind: Kind
    var title: String? = nil
    var title2: String? = nil
    var hm: String? = nil
    var dayOffset: Int? = nil
    var count: Int? = nil
    var flag: Bool? = nil
    var style: String? = nil
}

/// 一条用例：输入 + 期望。capability 决定消费哪些输入字段。
nonisolated struct BenchCase: Codable, Identifiable, Sendable {
    var id: String               // 稳定短 id（"P1"…），结果表/导出引用
    var name: String
    var capability: BenchCapability
    var dimension: String        // 理解力 / 服从性 / 执行力（约束解码跑时自动记，不占维度）
    var text: String? = nil            // parse：自然语言原文
    var command: String? = nil         // refine：一句指令
    var originalRequest: String? = nil // refine：最初排程原文（约束上下文）
    var blocks: [BenchBlockSpec]? = nil  // refine/reflow：输入块
    var fromHM: String? = nil          // reflow：从几点起重排
    var windDownHM: String? = nil      // reflow：收工线（缺省 23:00；用例自带保证确定性，不读用户设置）
    /// 长期任务池（#43，2026-07-20）：arrange 的池上下文 / longTaskEdit 的「现有任务」。
    var pool: [BenchPoolSpec]? = nil
    var expects: [BenchExpectation]
    var rev: Int? = nil                // 内置修订号：本地同 id 且 rev 落后 → 新内置覆盖下发（会盖手改；删除仍不复活）
}

/// 长期任务的用例输入（#43）：喂给 arrange 当池上下文，或当 longTaskEdit 的「现有任务」。
nonisolated struct BenchPoolSpec: Codable, Sendable {
    var title: String
    var deadlineYMD: String? = nil          // "yyyy-MM-dd"
    var cadenceMinutesPerWeek: Int? = nil
    var totalMinutes: Int? = nil
    var checkpoints: [String]? = nil        // 阶段名（有序）；第一个未完成的即「下一阶段」

    var brief: LongTaskBrief {
        LongTaskBrief(title: title, deadline: Self.date(deadlineYMD),
                      cadenceMinutesPerWeek: cadenceMinutesPerWeek,
                      nextCheckpoint: checkpoints?.first)
    }
    var context: LongTaskContext {
        LongTaskContext(title: title, deadline: Self.date(deadlineYMD),
                        cadenceMinutesPerWeek: cadenceMinutesPerWeek,
                        totalMinutes: totalMinutes, checkpoints: checkpoints ?? [])
    }
    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

/// 单次运行的产出（所有变体统一出口；断言引擎只认它）。
struct BenchOutput: Sendable {
    var blocks: [ScheduledBlock] = []      // 排定/解析/微调结果
    var deferred: [ScheduledBlock] = []    // 候补（reflow v2 才有）
    var longTasks: [ParsedLongTask] = []   // 解析出的长期事项（#40 批3：护航 checkpoints 解析）
    var edit: LongTaskPlanEdit? = nil      // 长期任务「说一句」的产物（#43：creates + updates）
    var note: String? = nil
    var raw: String? = nil                 // LLM 原始返回（可看）
    var promptSystem: String? = nil        // 实际发送的 system prompt（可看）
    var promptUser: String? = nil          // 实际发送的 user 消息（可看）
    var latencyMS: Int = 0
    var firstOutputMS: Int? = nil          // 流式首包延迟（TTFT；解析走 SSE 时记；非流式路径 nil）
    var model: String? = nil               // 本次运行用的云端模型 ID（多模型对比；本地/端侧 nil）
    var decodeOK: Bool = true              // 约束解码维度的原料：格式/解码是否一次成功
    var errorText: String? = nil
    // #41 成本指标（云端变体才非零）：计费口径输入等效量 / 输出 token / 本条用例的 LLM 调用次数
    var tokensIn: Int = 0
    var tokensOut: Int = 0
    var llmCalls: Int = 0
}

/// 单条断言的判定结果。
struct BenchCheck: Sendable {
    var expectation: BenchExpectation
    var passed: Bool
    var detail: String
}

/// 用例 × 变体 的一格结果。
struct BenchCaseResult: Sendable {
    var output: BenchOutput
    var checks: [BenchCheck]
    var skippedReason: String? = nil       // 非 nil = 该变体没跑（开关未开/无 key 等）
    var passed: Bool {
        skippedReason == nil && output.errorText == nil && checks.allSatisfy(\.passed)
    }
}

/// 时间小工具：HH:mm 锚到某天。
nonisolated enum BenchTime {
    static func date(hm: String, dayOffset: Int = 0, on day: Date) -> Date? {
        let parts = hm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...24).contains(h), (0..<60).contains(m) else { return nil }
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: day)) ?? day
        // 允许 "24:00"（= 次日零点，收工线常用）
        if h == 24 { return cal.date(byAdding: .day, value: 1, to: base) }
        return cal.date(bySettingHour: h, minute: m, second: 0, of: base)
    }
}
