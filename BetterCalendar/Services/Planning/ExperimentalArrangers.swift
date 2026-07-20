//
//  ExperimentalArrangers.swift
//  BetterCalendar
//
//  #41 排程算法 A/B 实验组（2026-07-20 Jason 提，试验台专用——**不接生产**，跑分定论后再议）。
//  待验的两个设想：
//    ② 脱敏 ID 化：日程标题不出云，LLM 只看结构（时长/标记/时段）排布、只回索引 → `MaskedArranger`
//    ③ 分步管线：LLM 只做**语义判断**（认知负荷/宜排时段），排布交本地确定性算法 → `HybridArranger`
//  对照：`arrange.llm`（现行单步·全标题）与 `arrange.rule`（纯本地·零 token）两端。
//
//  设计要点（跑分才有意义的地方）：两个实验组都**保持与基线同一套断言**——
//  S1–S4 是标记驱动（★/DDL/固定/锚点），脱敏理应不掉分；S5–S6 是语义驱动（先后依赖/脑力活趁早），
//  脱敏必然掉分——差值即「标题语义值多少钱」。
//

import Foundation

// MARK: - ② 脱敏组：标题不出云

/// 脱敏排序器：只把**结构**发给 LLM（索引/时长/标记/起止时段），标题一律不出云；
/// LLM 返回索引数组，本地绑回真实块。隐私上限=云端永远不知道你在做什么事。
struct MaskedArranger: PlanningEngine {
    let client: AnthropicClient
    let fallback: PlanningEngine

    func arrange(_ blocks: [ScheduledBlock], now: Date) async throws -> PlanDecision {
        try await arrange(blocks, pool: [], now: now)
    }

    func arrange(_ blocks: [ScheduledBlock], pool: [LongTaskBrief], now: Date) async throws -> PlanDecision {
        guard !blocks.isEmpty else { return try await fallback.arrange(blocks, now: now) }
        // 脱敏清单：绝无标题。只给排序真正需要的结构信息。
        let listing = blocks.enumerated().map { i, b -> String in
            var tags: [String] = []
            if b.priority == .important { tags.append("★尽早") }
            if b.isFixed { tags.append("固定") }
            if b.isAnchor { tags.append("作息锚点") }
            if let d = b.deadline { tags.append("DDL \(Self.ymd(d))") }
            let mins = max(1, Int(b.end.timeIntervalSince(b.start) / 60))
            return "\(i): \(mins)分钟 \(Self.hm(b.start))–\(Self.hm(b.end)) [\(tags.isEmpty ? "无标记" : tags.joined(separator: ","))]"
        }.joined(separator: "\n")

        let user = """
        现在 \(Self.hm(now))。今日时间块（**已脱敏：只有结构，没有标题**）：
        \(listing)
        按规则排出推荐顺序：★尽早最前；其次有 DDL 的按截止升序；其余保持原时间顺序；作息锚点垫底。
        只输出 JSON：{"orderedIndexes":[按推荐顺序的索引数组]}
        """
        do {
            let raw = try await LLMWatchdog.run {
                try await client.complete(system: "", user: user, maxTokens: 1000,
                                          jsonMode: true, jsonSchema: Self.schema,
                                          cachedSystemPrefix: Self.systemPrompt)
            }
            let order = try Self.decodeOrder(raw, count: blocks.count)
            let ordered = order.map { blocks[$0] }
            // note 走本地文案库（脱敏组不可能让 LLM 写 note——它不知道事情叫什么）
            return PlanDecision(orderedBlocks: ordered,
                                note: RuleBasedArranger.note(for: ordered),
                                poolSuggestedTitles: [])
        } catch {
            DevLog.shared.warn("脱敏排序", "失败回退：\(error.localizedDescription)")
            return try await fallback.arrange(blocks, pool: pool, now: now)
        }
    }

    func reflow(_ blocks: [ScheduledBlock], from startTime: Date, now: Date) async throws -> PlanDecision {
        try await fallback.reflow(blocks, from: startTime, now: now)
    }

    private static let systemPrompt = """
    你是日程排序器。输入是**脱敏**的时间块结构（无标题），按给定规则输出推荐顺序的索引数组。
    只输出 JSON，不要解释。
    """
    private static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["orderedIndexes"],
        "properties": ["orderedIndexes": ["type": "array", "items": ["type": "integer"]]],
    ]

    static func decodeOrder(_ raw: String, count: Int) throws -> [Int] {
        struct Wire: Decodable { let orderedIndexes: [Int]? }
        let json = JSONText.extractObject(raw)
        guard let data = json.data(using: .utf8) else { throw AnthropicError(message: "JSON 编码失败") }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        var seen = Set<Int>()
        var order: [Int] = []
        for i in (wire.orderedIndexes ?? []) where i >= 0 && i < count && !seen.contains(i) {
            seen.insert(i); order.append(i)
        }
        for i in 0..<count where !seen.contains(i) { order.append(i) }   // 补齐遗漏
        return order
    }

    private static func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    private static func ymd(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM-dd"
        return f.string(from: d)
    }
}

// MARK: - ③ 分步组：LLM 只做语义判断，排布交本地

/// 分步排序器：**第一步** LLM 只回答「每个块的认知负荷与宜排时段」（极小输出，无排序职责）；
/// **第二步** 本地确定性算法用这些标签 + 既有硬规则（★/DDL/固定/锚点）排出顺序。
/// 假设：LLM 的增值在语义理解，不在排布；把排布收回本地 → 约束天生不可违、结果可复现。
struct HybridArranger: PlanningEngine {
    let client: AnthropicClient
    let fallback: PlanningEngine

    /// 语义标签（第一步的产物）：只描述「这件事是什么性质」，不含任何排序结论。
    struct Label: Sendable {
        var index: Int
        var cognitiveLoad: Int      // 1=轻（杂务）…3=重（深度脑力）
        var preferEarly: Bool       // 是否宜趁早（精力好时做）
        var dependsOnIndex: Int?    // 语义先后依赖（买菜→做饭）；无则 nil
    }

    func arrange(_ blocks: [ScheduledBlock], now: Date) async throws -> PlanDecision {
        try await arrange(blocks, pool: [], now: now)
    }

    func arrange(_ blocks: [ScheduledBlock], pool: [LongTaskBrief], now: Date) async throws -> PlanDecision {
        guard !blocks.isEmpty else { return try await fallback.arrange(blocks, now: now) }
        do {
            let labels = try await label(blocks)
            let ordered = Self.layOut(blocks, labels: labels)
            return PlanDecision(orderedBlocks: ordered,
                                note: RuleBasedArranger.note(for: ordered),
                                poolSuggestedTitles: [])
        } catch {
            DevLog.shared.warn("分步排序", "失败回退：\(error.localizedDescription)")
            return try await fallback.arrange(blocks, pool: pool, now: now)
        }
    }

    func reflow(_ blocks: [ScheduledBlock], from startTime: Date, now: Date) async throws -> PlanDecision {
        try await fallback.reflow(blocks, from: startTime, now: now)
    }

    /// 第一步：LLM 语义标注（输出极小 → token 与延迟都比整排便宜）。
    private func label(_ blocks: [ScheduledBlock]) async throws -> [Label] {
        let listing = blocks.enumerated().map { "\($0): \($1.title)" }.joined(separator: "\n")
        let user = """
        给下面每件事标注性质（**不要排序、不要给时间**）：
        \(listing)
        cognitiveLoad：1=杂务/机械，2=一般，3=深度脑力（写作/编程/啃论文/背书）。
        preferEarly：精力好时做更划算 = true。
        dependsOnIndex：**必须在另一件之后**才能做的（如「做饭」依赖「买菜」）填那件的索引，否则 null。
        只输出 JSON：{"labels":[{"index":0,"cognitiveLoad":2,"preferEarly":false,"dependsOnIndex":null}]}
        """
        let raw = try await LLMWatchdog.run {
            try await client.complete(system: "", user: user, maxTokens: 1500,
                                      jsonMode: true, jsonSchema: Self.schema,
                                      cachedSystemPrefix: Self.systemPrompt)
        }
        struct WireLabel: Decodable { let index: Int; let cognitiveLoad: Int?; let preferEarly: Bool?; let dependsOnIndex: Int? }
        struct Wire: Decodable { let labels: [WireLabel]? }
        let json = JSONText.extractObject(raw)
        guard let data = json.data(using: .utf8) else { throw AnthropicError(message: "JSON 编码失败") }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        return (wire.labels ?? []).compactMap { l in
            guard l.index >= 0 && l.index < blocks.count else { return nil }
            let dep = l.dependsOnIndex.flatMap { $0 >= 0 && $0 < blocks.count && $0 != l.index ? $0 : nil }
            return Label(index: l.index,
                         cognitiveLoad: min(3, max(1, l.cognitiveLoad ?? 2)),
                         preferEarly: l.preferEarly ?? false,
                         dependsOnIndex: dep)
        }
    }

    /// 第二步（**纯本地、确定性、可单测**）：硬规则优先，语义标签只在同档内做次序微调；
    /// 最后按依赖关系做一次稳定拓扑修正（依赖者必须排在被依赖者之后）。
    static func layOut(_ blocks: [ScheduledBlock], labels: [Label]) -> [ScheduledBlock] {
        let byIndex = Dictionary(uniqueKeysWithValues: labels.map { ($0.index, $0) })
        func rank(_ i: Int) -> Int {
            let b = blocks[i]
            if b.isAnchor { return 3 }
            if b.priority == .important { return 0 }
            if b.deadline != nil { return 1 }
            return 2
        }
        var order = Array(blocks.indices).sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if ra == 1, let da = blocks[a].deadline, let db = blocks[b].deadline, da != db { return da < db }
            // 同档内：语义标签说话——宜趁早的在前，其次认知负荷重的在前（趁精力好）
            let la = byIndex[a], lb = byIndex[b]
            if (la?.preferEarly ?? false) != (lb?.preferEarly ?? false) { return la?.preferEarly ?? false }
            let ca = la?.cognitiveLoad ?? 2, cb = lb?.cognitiveLoad ?? 2
            if ca != cb { return ca > cb }
            return blocks[a].start < blocks[b].start
        }
        // 依赖修正：被依赖者必须在前（稳定、最多 n 轮、无环风险）。
        // ⚠️ **同档内才修正**（2026-07-20 跑分实锤：S4 分步组 5/10——模型把「写周报」标成依赖「组会」，
        // 于是推断出的依赖把 ★要紧事 挤到了固定块之后）。产品哲学「代理而不代权」：
        // 用户**显式**标的 ★/DDL 永远赢过模型**推断**的依赖；跨档依赖只忽略、不报错（宁可不修正也不越权）。
        for _ in 0..<blocks.count {
            var moved = false
            for (pos, i) in order.enumerated() {
                guard let dep = byIndex[i]?.dependsOnIndex,
                      rank(dep) == rank(i),                       // 跨档不修正（★ 不被推断挤走）
                      let depPos = order.firstIndex(of: dep), depPos > pos else { continue }
                order.remove(at: depPos)
                order.insert(dep, at: pos)
                moved = true
            }
            if !moved { break }
        }
        return order.map { blocks[$0] }
    }

    private static let systemPrompt = """
    你是任务性质标注器。只标注每件事的性质，绝不排序、绝不给时间。只输出 JSON，不要解释。
    """
    private static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["labels"],
        "properties": [
            "labels": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["index", "cognitiveLoad", "preferEarly", "dependsOnIndex"],
                    "properties": [
                        "index": ["type": "integer"],
                        "cognitiveLoad": ["type": "integer"],
                        "preferEarly": ["type": "boolean"],
                        "dependsOnIndex": ["type": ["integer", "null"]],
                    ],
                ],
            ],
        ],
    ]
}
