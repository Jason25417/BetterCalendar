//
//  FoundationModelsPlanRefiner.swift
//  BetterCalendar
//
//  端侧微调（试点）：Apple Foundation Models 做「自然语言调整已排日程」。
//  refine 是纯结构化（返回块清单、无 prose）→ 适合端侧：@Generable 直出、不截断、免费/私密。
//  链语义 v2（2026-07-11，与解析链同款）：默认=云端优先（Haiku 微调跑分 100%）、云端失败才 FM 兜底、
//  端云均败=保持原样+可见 warn（微调的失败契约=原样）；「只使用端侧」开=FM only 绝不出云。
//  分工：arrange/reflow 因带「温和前向 note」（= 生成文本/给建议）留云端；refine 纯格式化上端侧。
//

import Foundation
import FoundationModels

struct FoundationModelsPlanRefiner: PlanRefining {
    let fallback: PlanRefining   // 云端通道（默认模式的主路；「只使用端侧」开着时绝不调它）

    func refine(_ blocks: [ScheduledBlock], command: String,
                originalRequest: String, now: Date) async throws -> [ScheduledBlock] {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !blocks.isEmpty else { return blocks }
        if CloudSettings.onDeviceOnly {
            if let r = await onDeviceAttempt(blocks, cmd: cmd, originalRequest: originalRequest) { return r }
            DevLog.shared.warn("微调", "端侧未成功（「只使用端侧」不回退云端），保持原样")
            return blocks
        }
        do {
            return try await fallback.refine(blocks, command: command, originalRequest: originalRequest, now: now)
        } catch {
            DevLog.shared.warn("微调", "云端失败 → 试端侧 FM 兜底：\(error.localizedDescription)")
            if let r = await onDeviceAttempt(blocks, cmd: cmd, originalRequest: originalRequest) {
                DevLog.shared.info("微调", "端侧 FM 兜底成功")
                return r
            }
            DevLog.shared.warn("微调", "端云均未成功，保持原样")
            return blocks
        }
    }

    /// 端侧单尝试：不可用/失败/空 → nil（去留交给上面的链决定）。
    private func onDeviceAttempt(_ blocks: [ScheduledBlock], cmd: String,
                                 originalRequest: String) async -> [ScheduledBlock]? {
        // isTestHost 闸（2026-07-14）：单测绝不真跑端侧 3B 推理——模型输出不确定，
        // 「偶发 1 红」终于抓到名字：refinerKeepsDraftOnFailureOrEmptyCommand（FM 可用的机器上
        // 真推理 5.9s，偶尔把 1 块改成 2 块）。测试机视为不可用 → 链落「保持原样」，语义确定。
        if NSClassFromString("XCTestCase") != nil { return nil }
        switch SystemLanguageModel.default.availability {
        case .available: break
        default:
            DevLog.shared.info("端侧微调", "Foundation Models 不可用（设备不支持/未就绪）")
            return nil
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
                DevLog.shared.warn("端侧微调", "Foundation Models 返回空")
                return nil
            }
            DevLog.shared.info("端侧微调", "Foundation Models 成功 · \(result.count) 块（端侧·免费）")
            return result
        } catch {
            DevLog.shared.warn("端侧微调", "Foundation Models 失败：\(error.localizedDescription)")
            return nil
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
