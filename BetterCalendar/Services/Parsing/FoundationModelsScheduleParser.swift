//
//  FoundationModelsScheduleParser.swift
//  BetterCalendar
//
//  端侧解析（试点，D1 端侧目标）：Apple Foundation Models（macOS 26+/iOS 26+ 系统内置 ~3B 模型）。
//  @Generable 直出结构化日程——完全本地、免费、离线、私密、快。
//  不可用 / 失败 / 0 块 → 回退云端(fallback)。是 ScheduleParsing 的又一实现，和 ClaudeScheduleParser 平级。
//

import Foundation
import FoundationModels

struct FoundationModelsScheduleParser: ScheduleParsing {
    let fallback: ScheduleParsing   // 端侧关闭/不可用/失败 → 云端

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
            let plan = try await session.respond(to: text, generating: FMPlan.self).content
            let blocks: [ParsedBlock] = plan.blocks.compactMap { b in
                guard let s = DateParsing.parse(b.start), let e = DateParsing.parse(b.end) else { return nil }
                return ParsedBlock(title: b.title, start: s, end: e,
                                   durationMinutes: Int(e.timeIntervalSince(s) / 60),
                                   isFixed: b.isFixed, isAnchor: b.isAnchor, category: "",
                                   timingStyle: TimingStyle(rawValue: b.timingStyle) ?? .light,
                                   priority: BlockPriority(rawValue: b.priority) ?? .normal,
                                   deadline: nil)
            }
            let longTasks = plan.longTasks.map {
                ParsedLongTask(title: $0.title, deadline: nil, cadenceMinutesPerWeek: nil,
                               totalMinutes: nil, unitMinutes: nil)
            }
            guard !blocks.isEmpty || !longTasks.isEmpty || plan.loose else {
                DevLog.shared.warn("端侧解析", "Foundation Models 返回 0 块 → 回退云端")
                return try await fallback.parse(text, referenceDate: referenceDate, context: context)
            }
            DevLog.shared.info("端侧解析", "Foundation Models 成功 · \(blocks.count) 块（端侧·免费）")
            return ParsedPlan(blocks: blocks, longTasks: longTasks, isLoose: plan.loose)
        } catch {
            DevLog.shared.warn("端侧解析", "Foundation Models 失败 → 回退云端：\(error.localizedDescription)")
            return try await fallback.parse(text, referenceDate: referenceDate, context: context)
        }
    }

    /// 端侧模型小（~3B），指令保持精简；结构由 @Generable schema 承担、无需讲 JSON 格式。
    private static func instructions(referenceDate: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN"); df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd EEEE"; let target = df.string(from: referenceDate)
        df.dateFormat = "yyyy-MM-dd EEEE HH:mm"; let now = df.string(from: .now)
        // 端侧小模型：只喂规则，不喂产品哲学/措辞红线（那些对 @Generable 结构化输出是噪声）。
        return """
        把用户用自然语言描述的一天转成结构化日程。现在 \(now)。目标日 \(target)——所有块排在目标日当天，start/end 用 "YYYY-MM-DD HH:mm"，睡前跨午夜的块日期写次日。
        - isFixed=true 只给"与他人约定、时刻不可改"的事（会议/上课/约诊/班车）；个人任务（写作业/健身/读书/吃饭）即使有时间也 false。
        - 用户提到的每件事都出一个块、逐一保留不漏。
        - 默认互不重叠；仅当用户明说可并行时，让对应块重叠在同一时段、各自成块。
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
}

@Generable
struct FMLongTask {
    @Guide(description: "远期/长线任务的标题")
    var title: String
}
