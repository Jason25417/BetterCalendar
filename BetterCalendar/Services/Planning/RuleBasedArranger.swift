//
//  RuleBasedArranger.swift
//  BetterCalendar
//
//  arrange 排序固化（#21 L2.5，2026-07-10 Jason 拍板「做出来进试验台对照」）：
//  LLM 排序的规则其实早已明确——把它写成确定性算法：**尽早★ 最前 → 有硬 DDL 的按截止升序 → 其余按原时间**；
//  固定块时间不动（arrange 只产顺序信息+note，不改时间）。note 从本地文案库出（B 通道固化预演，
//  措辞对齐宪法：前向、给掌控感、不施压）。零网络、零隐私面、确定可复现。
//  ⚠️ 尚未接生产（AppContainer 仍用 LLM arrange）——先在试验台与 LLM 对照跑分，数据好才切（同 reflow V2 流程）。
//  v1 不产池建议（LLM 独有增值，对照跑分会显示差距）。
//

import Foundation

struct RuleBasedArranger: PlanningEngine {
    /// reflow 委托现行本地 V2（本类只专注 arrange 的排序+note）。
    private let reflowEngine = NaivePlanningEngine()

    func arrange(_ blocks: [ScheduledBlock], now: Date) async throws -> PlanDecision {
        try await arrange(blocks, pool: [], now: now)
    }

    func arrange(_ blocks: [ScheduledBlock], pool: [LongTaskBrief], now: Date) async throws -> PlanDecision {
        let ordered = Self.ordered(blocks)
        return PlanDecision(orderedBlocks: ordered, note: Self.note(for: ordered),
                            poolSuggestedTitles: [])
    }

    func reflow(_ blocks: [ScheduledBlock], from startTime: Date, now: Date) async throws -> PlanDecision {
        try await reflowEngine.reflow(blocks, from: startTime, now: now)
    }

    // MARK: 纯函数（可单测）

    /// 推荐顺序：尽早★（组内按原时间）→ 硬 DDL（按截止升序）→ 其余（按原时间）。
    /// 锚点垫底（作息不是任务，不占推荐位）；不改任何块的时间。
    static func ordered(_ blocks: [ScheduledBlock]) -> [ScheduledBlock] {
        func rank(_ b: ScheduledBlock) -> Int {
            if b.isAnchor { return 3 }
            if b.priority == .important { return 0 }
            if b.deadline != nil { return 1 }
            return 2
        }
        return blocks.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if ra == 1, let da = a.deadline, let db = b.deadline, da != db { return da < db }
            return a.start < b.start
        }
    }

    /// 本地 note 文案库（B 通道固化预演）：前向、给掌控感、不施压；按当天结构选一句。
    static func note(for ordered: [ScheduledBlock]) -> String? {
        let tasks = ordered.filter { !$0.isAnchor }
        guard !tasks.isEmpty else { return nil }
        if let mit = tasks.first(where: { $0.priority == .important }) {
            return "先把「\(mit.title)」拿下，后面就都顺了。"
        }
        if let ddl = tasks.first(where: { $0.deadline != nil }), let d = ddl.deadline {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm"
            return "「\(ddl.title)」\(f.string(from: d)) 前收——位置给它留好了。"
        }
        if tasks.count == 1 {
            return "今天就这一件，做完就赢。"
        }
        return "按这个顺序走就行，累了随时调。"
    }
}
