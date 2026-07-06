//
//  FoundationModelsPlanRefiner.swift
//  BetterCalendar
//
//  端侧微调（试点）：Apple Foundation Models 做「自然语言调整已排日程」。
//  refine 是纯结构化（返回块清单、无 prose）→ 适合端侧：@Generable 直出、不截断、免费/私密。
//  关闭 / 不可用 / 失败 / 空 → 回退云端 ClaudePlanRefiner。
//  分工：arrange/reflow 因带「温和前向 note」（= 生成文本/给建议）留云端；refine 纯格式化上端侧。
//

import Foundation
import FoundationModels

struct FoundationModelsPlanRefiner: PlanRefining {
    let fallback: PlanRefining

    func refine(_ blocks: [ScheduledBlock], command: String,
                originalRequest: String, now: Date) async throws -> [ScheduledBlock] {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CloudSettings.useOnDeviceParser, !cmd.isEmpty, !blocks.isEmpty else {
            return try await fallback.refine(blocks, command: command, originalRequest: originalRequest, now: now)
        }
        switch SystemLanguageModel.default.availability {
        case .available: break
        default:
            return try await fallback.refine(blocks, command: command, originalRequest: originalRequest, now: now)
        }
        do {
            let listing = blocks.map {
                "「\($0.title)」\(Self.fmt($0.start))–\(Self.fmt($0.end))\($0.isFixed ? " 固定" : "")"
            }.joined(separator: "\n")
            let req = originalRequest.trimmingCharacters(in: .whitespacesAndNewlines)
            // 端侧小模型：只喂规则。
            let instr = """
            你在调整一个已排好的一天日程。按用户的中文指令改对应的块。**未提到的块必须原样保留、一个都不能少**——返回**完整**清单，不是只返回改动的那几块。\(req.isEmpty ? "" : "用户最初需求（仍有效、别违背）：\(req)。")start/end 用 "YYYY-MM-DD HH:mm"。
            """
            let user = "当前日程（每行一个块）：\n\(listing)\n\n调整指令：\(cmd)"
            let session = LanguageModelSession(instructions: instr)
            let out = try await session.respond(to: user, generating: FMRefined.self).content
            let result: [ScheduledBlock] = out.blocks.compactMap { b in
                guard let s = DateParsing.parse(b.start), let e = DateParsing.parse(b.end) else { return nil }
                return ScheduledBlock(title: b.title, start: s, end: e, isFixed: b.isFixed,
                                      timingStyle: TimingStyle(rawValue: b.timingStyle) ?? .light,
                                      priority: BlockPriority(rawValue: b.priority) ?? .normal)
            }
            guard !result.isEmpty else {
                DevLog.shared.warn("端侧微调", "Foundation Models 返回空 → 回退云端")
                return try await fallback.refine(blocks, command: command, originalRequest: originalRequest, now: now)
            }
            DevLog.shared.info("端侧微调", "Foundation Models 成功 · \(result.count) 块（端侧·免费）")
            return result
        } catch {
            DevLog.shared.warn("端侧微调", "Foundation Models 失败 → 回退云端：\(error.localizedDescription)")
            return try await fallback.refine(blocks, command: command, originalRequest: originalRequest, now: now)
        }
    }

    static func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}

// MARK: - @Generable 输出（对齐 ScheduledBlock 的可微调字段）

@Generable
struct FMRefined {
    @Guide(description: "调整后的**完整**块清单，必须包含所有未改动的块，不能只返回改动的")
    var blocks: [FMRefinedBlock]
}

@Generable
struct FMRefinedBlock {
    @Guide(description: "任务标题")
    var title: String
    @Guide(description: "开始时间，格式 YYYY-MM-DD HH:mm")
    var start: String
    @Guide(description: "结束时间，格式 YYYY-MM-DD HH:mm")
    var end: String
    @Guide(description: "是否与他人约定、时刻不可改（会议/上课等）")
    var isFixed: Bool
    @Guide(description: "计时风格，只能取 pomodoro / light / none")
    var timingStyle: String
    @Guide(description: "优先级，只能取 normal / important")
    var priority: String
}
