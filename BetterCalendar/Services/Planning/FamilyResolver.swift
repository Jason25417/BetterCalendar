//
//  FamilyResolver.swift
//  BetterCalendar
//
//  族治理（E5e，SPEC §14.3「族与桶的治理」2026-08-15 裁）：
//  唯一治理闭集=族（setup 计价与学习层分桶的单位，起步 8）；负荷档=族的查表属性（FamilySetup）。
//  三重一致性（稳定＞正确）：①归属继承（同一长期任务自动同族，零 LLM）
//  ②历史复用（FamilyLedger 按归一化标题缓存，命中即继承，零 LLM）
//  ③LLM 闭集标注兜底（解析时顺带产出，缓存进 Ledger 一次终身）。
//  不给用户建族入口（防碎化饿死学习层）；纠错=块详情手改（E5e 后续）+ 同名继承。
//

import Foundation

/// 族闭集（§14.3：8 个起步；扩展=数据驱动提议式，v2）。
nonisolated enum FamilyTaxonomy {
    static let closedSet: Set<String> = [
        "写作", "编码", "阅读学习", "沟通协调", "事务杂务", "创作设计", "运动生活", "其他",
    ]
    static let fallback = "其他"
}

/// 历史复用缓存（三重一致性第②级）：归一化标题 → 族。UserDefaults JSON，容量 500 按最近使用淘汰。
/// defaults 注入=测试不污染真实库（共享 UserDefaults 老坑）。
@MainActor
enum FamilyLedger {
    static let storageKey = "bc.family.ledger"
    static let capacity = 500

    private struct Entry: Codable { var t: String; var f: String }   // 数组序=最近使用在尾

    private static func load(_ defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }
    private static func save(_ entries: [Entry], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: storageKey) }
    }

    /// 精确（归一化）优先；不中则对缓存键做 TitleMatch 模糊（≥0.6 取最相似）。
    static func lookup(_ title: String, defaults: UserDefaults = .standard) -> String? {
        let key = TitleMatch.normalize(title)
        guard !key.isEmpty else { return nil }
        let entries = load(defaults)
        if let hit = entries.last(where: { $0.t == key }) { return hit.f }
        let best = entries.map { ($0, TitleMatch.similarity($0.t, key)) }
            .filter { $0.1 >= 0.6 }
            .max { $0.1 < $1.1 }
        return best?.0.f
    }

    /// 记录（LRU：命中的挪到尾部；超容量掐头）。「其他」不入账——留给下次 LLM 再试。
    static func record(_ title: String, family: String, defaults: UserDefaults = .standard) {
        guard family != FamilyTaxonomy.fallback, FamilyTaxonomy.closedSet.contains(family) else { return }
        let key = TitleMatch.normalize(title)
        guard !key.isEmpty else { return }
        var entries = load(defaults).filter { $0.t != key }
        entries.append(Entry(t: key, f: family))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        save(entries, defaults)
    }
}

/// 三重一致性定案（E5e）：给一个块定族。
@MainActor
enum FamilyResolver {
    /// ①归属继承 → ②历史复用 → ③LLM 标注（parsedFamily）→ 兜底「其他」。
    /// 定案后回写 Ledger（③命中时），让同名块下次走②零 LLM。
    static func resolve(title: String, linkedTaskID: UUID?, parsedFamily: String?,
                        longTasks: LongTaskStore?,
                        defaults: UserDefaults = .standard) -> String {
        // ① 归属继承：同一长期任务下的块自动同族
        if let linked = linkedTaskID,
           let task = longTasks.flatMap({ s in
               s.items.first { $0.id == linked } ?? s.todos.first { $0.id == linked }
           }),
           let fam = task.family, FamilyTaxonomy.closedSet.contains(fam) {
            return fam
        }
        // ② 历史复用
        if let fam = FamilyLedger.lookup(title, defaults: defaults) { return fam }
        // ③ LLM 标注（闭集校验，非法落兜底）
        if let fam = parsedFamily, FamilyTaxonomy.closedSet.contains(fam), fam != FamilyTaxonomy.fallback {
            FamilyLedger.record(title, family: fam, defaults: defaults)
            // 归属任务还没有族 → 顺手继承上去（下次①直接命中；也是长期任务拿族的主通道）
            if let linked = linkedTaskID, let s = longTasks,
               let task = s.items.first(where: { $0.id == linked }), task.family == nil {
                task.family = fam
            }
            return fam
        }
        return FamilyTaxonomy.fallback
    }
}
