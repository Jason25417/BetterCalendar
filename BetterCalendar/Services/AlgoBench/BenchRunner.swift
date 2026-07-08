//
//  BenchRunner.swift
//  BetterCalendar
//
//  试验台编排：用例 × 变体 → 构建被测管线（无回退版：失败就地暴露，不静默兜底）→
//  调用 → 计时 → 断言。**绝不写日历/真相源**，输出只进内存。
//  这里例外地在组装点之外拼装 Service：试验台的本职就是并排组装多个竞争变体（有意偏离，在案）。
//

import Foundation

@MainActor
final class BenchRunner {
    private let client: AnthropicClient

    init(client: AnthropicClient = AnthropicClient()) {
        self.client = client
    }

    /// 参考日 = 逻辑明天（未来日，模型不会碰上"排到过去"的歧义；一轮之内稳定）。
    var referenceDay: Date { DayContext.logicalDay(offset: 1) }

    // MARK: - 入口

    /// 云端变体集合（多模型对比只对它们生效；本地/端侧变体忽略 model）。
    static let cloudVariantIDs: Set<String> = [
        BenchVariantID.parseCloud, BenchVariantID.refineCloud, BenchVariantID.refineCloudGuard,
        BenchVariantID.reflowLLMV1, BenchVariantID.reflowLLMV2,
    ]

    /// model 非 nil 且是云端变体 → 用该模型跑（同一服务商换模型 ID；key/服务商仍取当前设置）。
    func run(_ c: BenchCase, variant: BenchVariant, graceMinutes: Int,
             model: String? = nil) async -> BenchCaseResult {
        var result: BenchCaseResult
        switch c.capability {
        case .parse: result = await runParse(c, variant: variant, model: model)
        case .refine: result = await runRefine(c, variant: variant, model: model)
        case .reflow: result = await runReflow(c, variant: variant, graceMinutes: graceMinutes, model: model)
        }
        if Self.cloudVariantIDs.contains(variant.id) { result.output.model = model ?? CloudSettings.activeModel }
        return result
    }

    private func cloudClient(_ model: String?) -> AnthropicClient {
        guard let model, !model.isEmpty else { return client }
        return AnthropicClient(model: { model })
    }

    /// prompt 预览（不发请求）：LLM 变体给实际会发送的 system+user；本地变体返回 nil。
    func promptPreview(_ c: BenchCase, variant: BenchVariant, graceMinutes: Int) -> (system: String, user: String)? {
        switch variant.id {
        case BenchVariantID.parseCloud:
            guard let text = c.text else { return nil }
            return (ClaudeScheduleParser.systemPrompt(referenceDate: referenceDay, context: ParseContext()), text)
        case BenchVariantID.parseFM:
            guard let text = c.text else { return nil }
            return (FoundationModelsScheduleParser.instructions(referenceDate: referenceDay), text)
        case BenchVariantID.reflowLLMV1, BenchVariantID.reflowLLMV2:
            guard let r = reflowInputs(c) else { return nil }
            let v2 = variant.id == BenchVariantID.reflowLLMV2
            let listing = Self.listing(r.input, windDown: r.windDown, v2: v2)
            let nowText = Self.hm(r.from)
            return v2
                ? (BenchPrompts.reflowSystemV2(windDownText: Self.hm(r.windDown), graceMinutes: graceMinutes),
                   BenchPrompts.reflowUserV2(nowText: nowText, listing: listing))
                : (BenchPrompts.reflowSystemV1(windDownText: Self.hm(r.windDown)),
                   BenchPrompts.reflowUserV1(nowText: nowText, listing: listing))
        default:
            return nil   // refine 的 prompt 在实现内部组装，暂不外显（试验台 v2 再接）
        }
    }

    // MARK: - 解析

    private func runParse(_ c: BenchCase, variant: BenchVariant, model: String?) async -> BenchCaseResult {
        guard let text = c.text else { return Self.skipped("用例缺 text") }
        if let reason = gate(variant) { return Self.skipped(reason) }

        var out = BenchOutput()
        if let p = promptPreview(c, variant: variant, graceMinutes: 0) {
            out.promptSystem = p.system; out.promptUser = p.user
        }
        let t0 = Date()
        do {
            if variant.id == BenchVariantID.parseCloud {
                // 云端走**流式**（同线上体验路径）：记 TTFT（首包）+ 总时长——「流式表现」指标
                let mc = cloudClient(model)
                let system = ClaudeScheduleParser.systemPrompt(referenceDate: referenceDay,
                                                               context: ParseContext())
                var first: Int?
                let raw = try await mc.completeStreaming(system: system, user: text, maxTokens: 10000,
                                                         jsonSchema: ClaudeScheduleParser.parseSchema) { _ in
                    if first == nil { first = Self.ms(since: t0) }
                }
                out.latencyMS = Self.ms(since: t0)
                out.firstOutputMS = first
                out.raw = raw
                guard let decoded = ClaudeScheduleParser.decodePlan(JSONText.extractObject(raw)) else {
                    out.decodeOK = false
                    out.errorText = "JSON 解码失败"
                    let checks = BenchAssertions.evaluate(c.expects, output: out,
                                                          context: .init(referenceDay: referenceDay))
                    return BenchCaseResult(output: out, checks: checks)
                }
                out.blocks = decoded.blocks.compactMap { Self.scheduled(from: $0) }
                if decoded.dropped > 0 {
                    out.decodeOK = false
                    out.note = "\(decoded.dropped) 个损坏条目被丢弃（解码不完整）"
                }
            } else {
                let parser = FoundationModelsScheduleParser(fallback: BenchFailFastParser(), liveDraft: nil)
                let plan = try await parser.parse(text, referenceDate: referenceDay, context: ParseContext())
                out.latencyMS = Self.ms(since: t0)
                out.blocks = plan.blocks.compactMap { Self.scheduled(from: $0) }
                let dropped = plan.blocks.count - out.blocks.count
                if dropped > 0 {
                    out.decodeOK = false
                    out.note = "\(dropped) 块缺起止时间被丢弃（解码不完整）"
                }
            }
        } catch {
            out.latencyMS = Self.ms(since: t0)
            out.errorText = error.localizedDescription
            out.decodeOK = false
        }
        let checks = BenchAssertions.evaluate(c.expects, output: out,
                                              context: .init(referenceDay: referenceDay))
        return BenchCaseResult(output: out, checks: checks)
    }

    private static func scheduled(from pb: ParsedBlock) -> ScheduledBlock? {
        guard let s = pb.start, let e = pb.end else { return nil }
        return ScheduledBlock(title: pb.title, start: s, end: e,
                              isFixed: pb.isFixed, isAnchor: pb.isAnchor,
                              timingStyle: pb.timingStyle, priority: pb.priority,
                              labels: pb.labels)
    }

    // MARK: - 微调

    private func runRefine(_ c: BenchCase, variant: BenchVariant, model: String?) async -> BenchCaseResult {
        guard let command = c.command, let specs = c.blocks else { return Self.skipped("用例缺 command/blocks") }
        if let reason = gate(variant) { return Self.skipped(reason) }
        let input = specs.compactMap { $0.materialize(on: referenceDay) }
        guard input.count == specs.count else { return Self.skipped("用例块时间无效") }
        let isFM = variant.id == BenchVariantID.refineFM || variant.id == BenchVariantID.refineFMGuard
        let refiner: PlanRefining = isFM
            ? FoundationModelsPlanRefiner(fallback: BenchFailFastRefiner())
            : ClaudePlanRefiner(client: cloudClient(model))

        var out = BenchOutput()
        out.promptUser = command
        let now = BenchTime.date(hm: "08:00", on: referenceDay) ?? referenceDay
        let t0 = Date()
        do {
            var refined = try await refiner.refine(input, command: command,
                                                   originalRequest: c.originalRequest ?? "", now: now)
            if variant.id == BenchVariantID.refineCloudGuard || variant.id == BenchVariantID.refineFMGuard {
                // = 现行线上组合（0.23.1 起防呆三连）：部分返回并回 + 标志防翻 + 固定块时间还原
                refined = HomeViewModel.mergePartialRefine(original: input, refined: refined, command: command)
                refined = HomeViewModel.guardRefineFlags(original: input, refined: refined, command: command)
            }
            out.latencyMS = Self.ms(since: t0)
            out.blocks = refined
        } catch {
            out.latencyMS = Self.ms(since: t0)
            out.errorText = error.localizedDescription
            out.decodeOK = false
        }
        let checks = BenchAssertions.evaluate(c.expects, output: out,
                                              context: .init(referenceDay: referenceDay, inputBlocks: input))
        return BenchCaseResult(output: out, checks: checks)
    }

    // MARK: - reflow

    private struct ReflowInputs {
        var input: [ScheduledBlock]
        var from: Date
        var windDown: Date
    }

    private func reflowInputs(_ c: BenchCase) -> ReflowInputs? {
        guard let specs = c.blocks,
              let fromHM = c.fromHM,
              let from = BenchTime.date(hm: fromHM, on: referenceDay),
              let windDown = BenchTime.date(hm: c.windDownHM ?? "23:00", on: referenceDay)
        else { return nil }
        let input = specs.compactMap { $0.materialize(on: referenceDay) }
        guard input.count == specs.count else { return nil }
        return ReflowInputs(input: input, from: from, windDown: windDown)
    }

    private func runReflow(_ c: BenchCase, variant: BenchVariant, graceMinutes: Int,
                           model: String?) async -> BenchCaseResult {
        guard let r = reflowInputs(c) else { return Self.skipped("用例缺 blocks/fromHM 或时间无效") }
        let fixed = r.input.filter(\.isFixed)
        let flexibleByStart = r.input.filter { !$0.isFixed }.sorted { $0.start < $1.start }

        var out = BenchOutput()
        let t0 = Date()
        switch variant.id {
        case BenchVariantID.reflowNaiveV1:
            out.blocks = ReflowLayout.layOut(flexible: flexibleByStart, fixed: fixed, from: r.from)
            out.latencyMS = Self.ms(since: t0)

        case BenchVariantID.reflowNaiveV2:
            let laid = ReflowLayoutV2.layOut(flexible: flexibleByStart, fixed: fixed, from: r.from,
                                             windDown: r.windDown, graceMinutes: graceMinutes)
            out.blocks = laid.scheduled
            out.deferred = laid.deferred
            out.latencyMS = Self.ms(since: t0)

        case BenchVariantID.reflowLLMV1, BenchVariantID.reflowLLMV2:
            if let reason = gate(variant) { return Self.skipped(reason) }
            let v2 = variant.id == BenchVariantID.reflowLLMV2
            guard let p = promptPreview(c, variant: variant, graceMinutes: graceMinutes) else {
                return Self.skipped("prompt 组装失败")
            }
            out.promptSystem = p.system; out.promptUser = p.user
            do {
                let raw = try await cloudClient(model).complete(system: p.system, user: p.user, maxTokens: 4000,
                                                    jsonMode: true,
                                                    jsonSchema: v2 ? BenchPrompts.reflowSchemaV2
                                                                   : BenchPrompts.reflowSchemaV1)
                out.raw = raw
                let json = JSONText.extractObject(raw)
                guard let data = json.data(using: .utf8),
                      let wire = try? JSONDecoder().decode(BenchReflowWire.self, from: data) else {
                    out.decodeOK = false
                    out.errorText = "JSON 解码失败"
                    out.latencyMS = Self.ms(since: t0)
                    break
                }
                out.note = wire.note
                // 索引 → 弹性块（越界/固定/重复的丢弃；没点到的弹性块补在队尾——同线上语义）
                var seen = Set<Int>()
                var ordered: [ScheduledBlock] = []
                for i in (wire.flexibleOrder ?? [])
                where i >= 0 && i < r.input.count && !r.input[i].isFixed && !seen.contains(i) {
                    seen.insert(i); ordered.append(r.input[i])
                }
                let llmDeferredIDs = Set((wire.deferred ?? [])
                    .filter { $0 >= 0 && $0 < r.input.count && !r.input[$0].isFixed && !seen.contains($0) }
                    .map { r.input[$0].id })
                for (i, b) in r.input.enumerated()
                where !b.isFixed && !seen.contains(i) && !llmDeferredIDs.contains(b.id) {
                    ordered.append(b)
                }
                if v2 {
                    let laid = ReflowLayoutV2.layOut(
                        flexible: ordered + r.input.filter { llmDeferredIDs.contains($0.id) },
                        fixed: fixed, from: r.from,
                        windDown: r.windDown, graceMinutes: graceMinutes,
                        llmDeferred: llmDeferredIDs)
                    out.blocks = laid.scheduled
                    out.deferred = laid.deferred
                } else {
                    out.blocks = ReflowLayout.layOut(flexible: ordered, fixed: fixed, from: r.from)
                }
                out.latencyMS = Self.ms(since: t0)
            } catch {
                out.latencyMS = Self.ms(since: t0)
                out.errorText = error.localizedDescription
                out.decodeOK = false
            }

        default:
            return Self.skipped("未知变体 \(variant.id)")
        }

        let isV2 = variant.id == BenchVariantID.reflowNaiveV2 || variant.id == BenchVariantID.reflowLLMV2
        let checks = BenchAssertions.evaluate(c.expects, output: out,
                                              context: .init(referenceDay: referenceDay,
                                                             inputBlocks: r.input,
                                                             windDown: r.windDown,
                                                             // V1 没有候补语义：收工线断言按无宽限判（暴露 V1 铺到深夜）
                                                             graceMinutes: isV2 ? graceMinutes : 0))
        return BenchCaseResult(output: out, checks: checks)
    }

    // MARK: - 工具

    /// 变体运行前置条件（开关/key）；nil = 可跑。
    private func gate(_ variant: BenchVariant) -> String? {
        switch variant.id {
        case BenchVariantID.parseFM, BenchVariantID.refineFM, BenchVariantID.refineFMGuard:
            return CloudSettings.useOnDeviceParser ? nil : "端侧开关未开（设置→进阶）"
        case BenchVariantID.parseCloud, BenchVariantID.refineCloud, BenchVariantID.refineCloudGuard,
             BenchVariantID.reflowLLMV1, BenchVariantID.reflowLLMV2:
            guard CloudSettings.useCloud else { return "云端开关未开" }
            let key = KeychainStore.loadAPIKey(account: CloudSettings.provider.keychainAccount)
            return (key?.isEmpty == false) ? nil : "未配 API key（设置→云端）"
        default:
            return nil
        }
    }

    private static func skipped(_ reason: String) -> BenchCaseResult {
        BenchCaseResult(output: BenchOutput(), checks: [], skippedReason: reason)
    }

    /// reflow 块清单（v2 版带 ★/并行/晚间 标记，给模型完整决策信息）。
    static func listing(_ blocks: [ScheduledBlock], windDown: Date, v2: Bool) -> String {
        blocks.enumerated().map { i, b in
            var marks = ""
            if v2 {
                if b.priority == .important { marks += "[★]" }
                if let g = b.parallelGroup { marks += "[并行:\(g.replacingOccurrences(of: ScheduledBlock.parallelPrefix, with: ""))]" }
                if !b.isFixed && b.start >= windDown { marks += "[晚间]" }
            }
            return "\(i): \(b.title) [\(b.isFixed ? "固定" : "弹性")]\(marks) 原 \(hm(b.start))–\(hm(b.end))"
        }.joined(separator: "\n")
    }

    static func hm(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private static func ms(since t0: Date) -> Int {
        Int(Date().timeIntervalSince(t0) * 1000)
    }
}

/// LLM reflow 线格式（V1 只有 flexibleOrder；V2 多 deferred——同一结构宽容解码）。
private nonisolated struct BenchReflowWire: Decodable {
    let flexibleOrder: [Int]?
    let deferred: [Int]?
    let note: String?
}

/// 无回退版兜底：被测实现失败时就地抛错（试验台要看到真实失败，不许静默回退）。
private struct BenchFailFastParser: ScheduleParsing {
    func parse(_ text: String, referenceDate: Date) async throws -> ParsedPlan {
        throw AnthropicError(message: "被测实现失败（试验台无回退，失败就地暴露）")
    }
}

private struct BenchFailFastRefiner: PlanRefining {
    func refine(_ blocks: [ScheduledBlock], command: String,
                originalRequest: String, now: Date) async throws -> [ScheduledBlock] {
        throw AnthropicError(message: "被测实现失败（试验台无回退，失败就地暴露）")
    }
}
