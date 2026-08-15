//
//  FluidLayoutEngine.swift
//  BetterCalendar
//
//  流动性排布引擎（统一时间线 P1b；E5b 升格 D8）：给定模块（各带流动性）+ 窗口硬边界（图钉），
//  输出具体排布 + 溢出集。纯函数、确定性、零 LLM（#41 路线：语义归模型、力学归本地）。
//  现有 ReflowLayout 是它的退化特例——新字段全带默认值，不传=旧行为（等价性有单测锁定）。
//
//  放置顺序（仲裁序，SPEC §13.A.3）：钉死 → 软锚 → 队列流动；
//  队列内 ★要紧事有救援置换（装不下时挤掉已放的最后一个普通槽——优先级低者先溢）。
//
//  E5b 升格四件（D8，SPEC §14.5）：
//  ① 并行组合槽：同 parallelGroup 的队列块合并为一槽、同起点铺开（口径同 ReflowLayoutV2）；
//  ② 占线宽度（D4）：光标按 occupied 前进、块自身保持标称长度——校准余量表现为块后呼吸间隙；
//  ③ 族 setup 间隙：队列序上族切换时光标先进 s(新块族负荷档)——同族连排免（聚簇省时=模型自然推论）；
//     任一侧族未知=0（E5e 标注上线前引擎保持中性）；
//  ④ 聚簇排序：同族队列槽相邻（键=族组首槽 plannedStart）；hardEndOverride 给 ★ 越收工线照排（映射=Coordinator）。
//  以上全部**不呈现**（隐式计价裁定），引擎观察窗里画出来。
//

import Foundation

/// 排布输入 DTO（实现无关；由 ScheduledBlock/PlanBlock 桥接生成）。
nonisolated struct FluidModule: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var duration: TimeInterval          // 标称长度（呈现口径，块自身宽度）
    var fluidity: Fluidity
    var priority: BlockPriority = .normal
    var plannedStart: Date              // 锚点基准（clock）/队列排序参考（queue）
    // —— E5b 升格字段：全带默认值，不传=旧行为 ——
    var occupiedDuration: TimeInterval? = nil   // 占线宽度（校准值；nil=duration）
    var family: String? = nil                   // 族（setup 计价与聚簇；nil=未标注，中性）
    var parallelGroup: String? = nil            // 并行组（同组合槽同起点）
    var hardEndOverride: Date? = nil            // 队列路径的硬边界覆写（★→日界线）

    var occupied: TimeInterval { occupiedDuration ?? duration }
}

/// 排布输出：具体位置 + 溢出集（策略 P1c 处理，这里只判定「谁装不下」）。
nonisolated struct FluidLayoutResult: Sendable {
    struct Placement: Equatable, Sendable { var id: UUID; var start: Date; var end: Date }
    var placed: [Placement]             // 按 start 升序（end=标称端点）
    var overflow: [UUID]                // 窗口内装不下的模块
}

/// 族 → 负荷档 → setup 分钟（§14.5 裁-1：轻 0 / 中 5 / 重 12；区间取中值）。
/// 同族连排免；任一侧未知不计价（族标注 E5e 上线前保持中性）。
nonisolated enum FamilySetup {
    static let heavyFamilies: Set<String> = ["写作", "编码", "创作设计"]
    static let lightFamilies: Set<String> = ["沟通协调", "事务杂务", "运动生活"]

    static func minutes(for family: String?) -> Int {
        guard let family else { return 0 }
        if heavyFamilies.contains(family) { return 12 }
        if lightFamilies.contains(family) { return 0 }
        return 5   // 阅读学习 / 其他 / 未来新增闭集值 = 中档
    }

    /// 切换计价：s 挂在切换的「边」上，取新块族的档位。
    static func transitionMinutes(from a: String?, to b: String?) -> Int {
        guard let a, let b, a != b else { return 0 }
        return minutes(for: b)
    }
}

nonisolated enum FluidLayoutEngine {

    /// 内部：队列放置单位（并行组合槽；单模块=单成员槽）。
    private struct Slot {
        let members: [FluidModule]
        let plannedStart: Date          // 组内最早（排序参考）
        let occupied: TimeInterval      // 组内最宽占线（光标推进量）
        let family: String?             // 第一个有族的成员
        let priority: BlockPriority     // 组内含 ★ 即 ★
        let hardEndOverride: Date?      // 组内 ★ 成员的覆写（取最大）
        var memberIDs: [UUID] { members.map(\.id) }
    }

    /// 在 [from, hardEnd) 内排布。hardEnd = 收工图钉（或跨日图钉）＝硬边界。
    static func layOut(modules: [FluidModule], from: Date, hardEnd: Date) -> FluidLayoutResult {
        var placements: [FluidLayoutResult.Placement] = []
        var spans: [FluidLayoutResult.Placement] = []   // 内部避障（占线宽度，含 setup/校准/槽宽）
        var overflow: [UUID] = []

        // ① 钉死块：原位放置（起点在窗口前/后的不参与本窗口，也不算溢出——它们属于别的窗口）
        let pinned = modules.filter { $0.fluidity.rangeMinutes == 0 }
        for m in pinned where m.plannedStart >= from && m.plannedStart < hardEnd {
            placements.append(.init(id: m.id, start: m.plannedStart,
                                    end: m.plannedStart.addingTimeInterval(m.duration)))
            spans.append(.init(id: m.id, start: m.plannedStart,
                               end: m.plannedStart.addingTimeInterval(m.occupied)))
        }

        // ② 软锚块（clock ± range）：尽量原位；冲突则在 ± 范围内找最近可行位；找不到 → 溢出
        let soft = modules
            .filter { $0.fluidity.anchor == .clock && ($0.fluidity.rangeMinutes ?? 0) > 0 }
            .sorted { $0.plannedStart < $1.plannedStart }
        for m in soft {
            let range = TimeInterval(m.fluidity.rangeMinutes! * 60)
            let lo = max(from, m.plannedStart.addingTimeInterval(-range))
            let hi = min(hardEnd, m.plannedStart.addingTimeInterval(range).addingTimeInterval(m.duration))
            if let slot = firstFit(duration: m.occupied, notBefore: max(lo, m.plannedStart),
                                   notAfter: hi, avoiding: spans)
                ?? firstFit(duration: m.occupied, notBefore: lo, notAfter: hi, avoiding: spans) {
                placements.append(.init(id: m.id, start: slot, end: slot.addingTimeInterval(m.duration)))
                spans.append(.init(id: m.id, start: slot, end: slot.addingTimeInterval(m.occupied)))
            } else {
                overflow.append(m.id)
            }
        }

        // ③ 队列流动块：并行组合槽 → 聚簇排序 → 依次首次适配（含族切换 setup 间隙）
        let queue = modules.filter { $0.fluidity.anchor == .queue }
        let slots = makeSlots(queue)

        var lastFamily: String? = nil
        var placedNormalSlots: [Slot] = []
        for slot in slots {
            let setup = TimeInterval(FamilySetup.transitionMinutes(from: lastFamily, to: slot.family) * 60)
            let limit = slot.hardEndOverride ?? hardEnd
            if let found = firstFit(duration: setup + slot.occupied, notBefore: from,
                                    notAfter: limit, avoiding: spans) {
                place(slot, at: found, setup: setup, into: &placements, spans: &spans)
                if slot.priority == .normal { placedNormalSlots.append(slot) }
                if slot.family != nil { lastFamily = slot.family }
            } else if slot.priority == .important, let victim = placedNormalSlots.last {
                // ★救援置换：优先级低者先溢（仲裁序）——挤掉已放的最后一个普通槽（整槽）
                let victimIDs = Set(victim.memberIDs)
                placements.removeAll { victimIDs.contains($0.id) }
                spans.removeAll { victimIDs.contains($0.id) }
                placedNormalSlots.removeLast()
                overflow.append(contentsOf: victim.memberIDs)
                if let found = firstFit(duration: setup + slot.occupied, notBefore: from,
                                        notAfter: limit, avoiding: spans) {
                    place(slot, at: found, setup: setup, into: &placements, spans: &spans)
                    if slot.family != nil { lastFamily = slot.family }
                } else {
                    overflow.append(contentsOf: slot.memberIDs)   // 挤了还装不下：两者都进溢出，P1c 定去向
                }
            } else {
                overflow.append(contentsOf: slot.memberIDs)
            }
        }

        return FluidLayoutResult(placed: placements.sorted { $0.start < $1.start },
                                 overflow: overflow)
    }

    /// 队列块 → 槽序列：并行组合槽（同组同起点、槽宽=组内最宽）+ 聚簇排序
    /// （键 = 族组首槽 plannedStart → 槽 plannedStart → id；无族槽自成一组=纯 plannedStart 序，退化等价）。
    private static func makeSlots(_ queue: [FluidModule]) -> [Slot] {
        var groups: [String: [FluidModule]] = [:]
        var singles: [FluidModule] = []
        for m in queue {
            if let g = m.parallelGroup { groups[g, default: []].append(m) } else { singles.append(m) }
        }
        var slots: [Slot] = singles.map { slot(members: [$0]) }
        slots += groups.values.map { slot(members: $0.sorted { $0.plannedStart < $1.plannedStart }) }

        // 族组首槽时间（聚簇键）：同族槽聚到该族最早槽的位置附近
        var familyFirst: [String: Date] = [:]
        for s in slots {
            guard let f = s.family else { continue }
            familyFirst[f] = min(familyFirst[f] ?? .distantFuture, s.plannedStart)
        }
        return slots.sorted { a, b in
            let ka = a.family.flatMap { familyFirst[$0] } ?? a.plannedStart
            let kb = b.family.flatMap { familyFirst[$0] } ?? b.plannedStart
            if ka != kb { return ka < kb }
            if a.plannedStart != b.plannedStart { return a.plannedStart < b.plannedStart }
            return (a.members.first?.id.uuidString ?? "") < (b.members.first?.id.uuidString ?? "")
        }
    }

    private static func slot(members: [FluidModule]) -> Slot {
        Slot(members: members,
             plannedStart: members.map(\.plannedStart).min() ?? .distantPast,
             occupied: members.map(\.occupied).max() ?? 0,
             family: members.compactMap(\.family).first,
             priority: members.contains { $0.priority == .important } ? .important : .normal,
             hardEndOverride: members.compactMap(\.hardEndOverride).max())
    }

    /// 放置一槽：块起点 = found + setup（setup 是间隙不是块）；成员各保标称长度、同起点；
    /// 占线 span = [found, found + setup + 槽占线宽]。
    private static func place(_ slot: Slot, at found: Date, setup: TimeInterval,
                              into placements: inout [FluidLayoutResult.Placement],
                              spans: inout [FluidLayoutResult.Placement]) {
        let start = found.addingTimeInterval(setup)
        for m in slot.members {
            placements.append(.init(id: m.id, start: start, end: start.addingTimeInterval(m.duration)))
        }
        spans.append(.init(id: slot.members[0].id, start: found,
                           end: start.addingTimeInterval(slot.occupied)))
    }

    /// 首次适配：在 [notBefore, notAfter) 内找第一个能放下 duration、不与已放占线重叠的起点。
    private static func firstFit(duration: TimeInterval, notBefore: Date, notAfter: Date,
                                 avoiding placements: [FluidLayoutResult.Placement]) -> Date? {
        guard notBefore.addingTimeInterval(duration) <= notAfter else { return nil }
        let obstacles = placements.sorted { $0.start < $1.start }
        var cursor = notBefore
        for ob in obstacles {
            if cursor.addingTimeInterval(duration) <= ob.start { return cursor }   // 塞进障碍前的空隙
            if ob.end > cursor { cursor = ob.end }                                  // 顺延到障碍之后
        }
        return cursor.addingTimeInterval(duration) <= notAfter ? cursor : nil
    }
}
