//
//  FoundationModelsScheduleParser.swift
//  BetterCalendar
//
//  端侧解析（试点，D1 端侧目标）：Apple Foundation Models（macOS 26+/iOS 26+ 系统内置 ~3B 模型）。
//  @Generable 直出结构化日程——完全本地、免费、离线、私密、快。
//  **流式**：streamResponse 边生成边把"部分块"写进 LiveDraft，UI 边出边显示（不影响最终完整结果）。
//  不可用 / 失败 / 0 块 → 回退云端(fallback)。是 ScheduleParsing 的又一实现，和 ClaudeScheduleParser 平级。
//

import Foundation
import Observation
import FoundationModels

/// 端侧流式解析的「进行中部分块」——FM 边生成边写，排日程页边出边显示。
@MainActor
@Observable
final class LiveDraft {
    var streaming: [ScheduledBlock] = []
    func clear() { streaming = [] }
}

struct FoundationModelsScheduleParser: ScheduleParsing {
    let fallback: ScheduleParsing      // 端侧关闭/不可用/失败 → 云端
    var liveDraft: LiveDraft?          // 流式部分块出口（nil = 不流式，仅最终结果）

    func parse(_ text: String, referenceDate: Date) async throws -> ParsedPlan {
        try await parse(text, referenceDate: referenceDate, context: ParseContext())
    }

    func parse(_ text: String, referenceDate: Date, context: ParseContext) async throws -> ParsedPlan {
        guard CloudSettings.useOnDeviceParser else {
            return try await fallback.parse(text, referenceDate: referenceDate, context: context)
        }
        switch SystemLanguageModel.default.availability {
        case .available: break
        default:
            DevLog.shared.info("端侧解析", "Foundation Models 不可用 → 回退云端")
            return try await fallback.parse(text, referenceDate: referenceDate, context: context)
        }
        do {
            let session = LanguageModelSession(instructions: Self.instructions(referenceDate: referenceDate))
            // 流式：逐个部分快照 → 把已成形的块写进 LiveDraft（UI 边出边显示）
            var last: FMPlan.PartiallyGenerated?
            for try await snapshot in session.streamResponse(to: text, generating: FMPlan.self) {
                let partial = snapshot.content   // FMPlan.PartiallyGenerated
                last = partial
                let live = (partial.blocks ?? []).compactMap { Self.scheduled(from: $0) }
                liveDraft?.streaming = live.sorted { $0.start < $1.start }
            }
            liveDraft?.clear()
            guard let final = last else {
                return try await fallback.parse(text, referenceDate: referenceDate, context: context)
            }
            let blocks = (final.blocks ?? []).compactMap { Self.parsed(from: $0) }
            let longTasks = (final.longTasks ?? []).compactMap { lt -> ParsedLongTask? in
                guard let t = lt.title, !t.isEmpty else { return nil }
                return ParsedLongTask(title: t, deadline: nil, cadenceMinutesPerWeek: nil,
                                      totalMinutes: nil, unitMinutes: nil)
            }
            let loose = final.loose ?? false
            guard !blocks.isEmpty || !longTasks.isEmpty || loose else {
                DevLog.shared.warn("端侧解析", "Foundation Models 返回 0 块 → 回退云端")
                return try await fallback.parse(text, referenceDate: referenceDate, context: context)
            }
            DevLog.shared.info("端侧解析", "Foundation Models 成功 · \(blocks.count) 块（端侧·免费·流式）")
            return ParsedPlan(blocks: blocks, longTasks: longTasks, isLoose: loose)
        } catch {
            liveDraft?.clear()
            DevLog.shared.warn("端侧解析", "Foundation Models 失败 → 回退云端：\(error.localizedDescription)")
            return try await fallback.parse(text, referenceDate: referenceDate, context: context)
        }
    }

    /// 部分块 → ParsedBlock（最终结果用；字段没齐就跳过）。
    private static func parsed(from b: FMBlock.PartiallyGenerated) -> ParsedBlock? {
        guard let title = b.title, let ss = b.start, let es = b.end,
              let s = DateParsing.parse(ss), let e = DateParsing.parse(es) else { return nil }
        let parallel = (b.parallel ?? "").trimmingCharacters(in: .whitespaces)
        return ParsedBlock(title: title, start: s, end: e,
                           durationMinutes: Int(e.timeIntervalSince(s) / 60),
                           isFixed: b.isFixed ?? false, isAnchor: b.isAnchor ?? false, category: "",
                           timingStyle: TimingStyle(rawValue: b.timingStyle ?? "light") ?? .light,
                           priority: BlockPriority(rawValue: b.priority ?? "normal") ?? .normal, deadline: nil,
                           labels: parallel.isEmpty ? [] : [ScheduledBlock.parallelPrefix + parallel])
    }

    /// 部分块 → ScheduledBlock（流式预览用；要求起止都成形且有效）。
    private static func scheduled(from b: FMBlock.PartiallyGenerated) -> ScheduledBlock? {
        guard let title = b.title, !title.isEmpty, let ss = b.start, let es = b.end,
              let s = DateParsing.parse(ss), let e = DateParsing.parse(es), e > s else { return nil }
        return ScheduledBlock(title: title, start: s, end: e, isFixed: b.isFixed ?? false,
                              timingStyle: TimingStyle(rawValue: b.timingStyle ?? "light") ?? .light,
                              priority: BlockPriority(rawValue: b.priority ?? "normal") ?? .normal)
    }

    /// 端侧模型小（~3B），指令保持精简；结构由 @Generable schema 承担、无需讲 JSON 格式。
    /// internal（原 private，0.22.3 放开）：算法试验台要展示"实际发送的 prompt"。
    static func instructions(referenceDate: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN"); df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd EEEE"; let target = df.string(from: referenceDate)
        df.dateFormat = "yyyy-MM-dd EEEE HH:mm"; let now = df.string(from: .now)
        // 端侧小模型：只喂规则，不喂产品哲学/措辞红线（那些对 @Generable 结构化输出是噪声）。
        return """
        把用户用自然语言描述的一天转成结构化日程。现在 \(now)。目标日 \(target)——所有块排在目标日当天，start/end 用 "YYYY-MM-DD HH:mm"，睡前跨午夜的块日期写次日。
        - 晚上语境的钟点按深夜理解：说"晚上10点到12点半"= 22:00 到次日 00:30、"到凌晨1点"= 次日 01:00，绝不是中午 12:30 或下午。
        - isFixed=true 只给"与他人约定、时刻不可改"的事（会议/上课/约诊/班车）；个人任务（写作业/健身/读书/吃饭）即使有时间也 false。
        - 用户提到的每件事都出一个块、逐一保留不漏。
        - 默认互不重叠；仅当用户明说可并行时，让对应块重叠在同一时段、各自成块，并给同一个 parallel 组名（如 P1）；不并行的块 parallel 留空。
        - 作息（吃饭/通勤/午休/睡觉）isAnchor=true。
        - timingStyle 默认 light，只有背书/写卷子/啃论文这类高摩擦才 pomodoro。
        - priority 默认 normal，要紧/紧急用 important。
        - 截止在目标日之后的远期/长线任务放 longTasks、不放 blocks。
        - 用户明说"想松散/放松/摆烂"才 loose=true。
        """
    }
}

// MARK: - @Generable 输出结构（端侧结构化生成，对齐 ParsedPlan）

@Generable
struct FMPlan {
    @Guide(description: "用户是否明确表达想整段松散/放松/摆烂")
    var loose: Bool
    @Guide(description: "目标日当天的时间块")
    var blocks: [FMBlock]
    @Guide(description: "截止在目标日之后的远期/长线任务，不放进 blocks")
    var longTasks: [FMLongTask]
}

@Generable
struct FMBlock {
    @Guide(description: "任务标题")
    var title: String
    @Guide(description: "开始时间，格式 YYYY-MM-DD HH:mm")
    var start: String
    @Guide(description: "结束时间，格式 YYYY-MM-DD HH:mm")
    var end: String
    @Guide(description: "是否与他人约定、时刻不可改（会议/上课/约诊/班车）；个人任务即使有时间也为 false")
    var isFixed: Bool
    @Guide(description: "是否作息锚点（吃饭/通勤/午休/睡觉）")
    var isAnchor: Bool
    @Guide(description: "计时风格，只能取 pomodoro / light / none，默认 light")
    var timingStyle: String
    @Guide(description: "优先级，只能取 normal / important，默认 normal")
    var priority: String
    @Guide(description: "并行组名：用户明说同时进行的几件事给同一个组名（如 P1）；不并行留空字符串")
    var parallel: String
}

@Generable
struct FMLongTask {
    @Guide(description: "远期/长线任务的标题")
    var title: String
}
