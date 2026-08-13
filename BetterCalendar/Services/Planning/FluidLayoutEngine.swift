//
//  FluidLayoutEngine.swift
//  BetterCalendar
//
//  流动性排布引擎（统一时间线 P1b）：给定模块（各带流动性）+ 窗口硬边界（图钉），
//  输出具体排布 + 溢出集。纯函数、确定性、零 LLM（#41 路线：语义归模型、力学归本地）。
//  现有 ReflowLayout 是它的退化特例（全部钉死/自由、无软锚、无硬边界）——等价性有单测锁定。
//  P1b=引擎本体（不接生产，生产仍走老 reflow；接线=P1e）；溢出的「去向策略」=P1c。
//
//  放置顺序（仲裁序，SPEC §13.A.3）：钉死 → 软锚 → 队列流动；
//  队列内 ★要紧事有救援置换（装不下时挤掉已放的最后一个普通块——优先级低者先溢）。
//

import Foundation

/// 排布输入 DTO（实现无关；由 ScheduledBlock/PlanBlock 桥接生成）。
nonisolated struct FluidModule: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var duration: TimeInterval          // 模块长度
    var fluidity: Fluidity
    var priority: BlockPriority = .normal
    var plannedStart: Date              // 锚点基准（clock）/队列排序参考（queue）
}

/// 排布输出：具体位置 + 溢出集（策略 P1c 处理，这里只判定「谁装不下」）。
nonisolated struct FluidLayoutResult: Sendable {
    struct Placement: Equatable, Sendable { var id: UUID; var start: Date; var end: Date }
    var placed: [Placement]             // 按 start 升序
    var overflow: [UUID]                // 窗口内装不下的模块
}

nonisolated enum FluidLayoutEngine {

    /// 在 [from, hardEnd) 内排布。hardEnd = 收工图钉（或跨日图钉）＝硬边界。
    static func layOut(modules: [FluidModule], from: Date, hardEnd: Date) -> FluidLayoutResult {
        var placements: [FluidLayoutResult.Placement] = []
        var overflow: [UUID] = []

        // ① 钉死块：原位放置（起点在窗口前/后的不参与本窗口，也不算溢出——它们属于别的窗口）
        let pinned = modules.filter { $0.fluidity.rangeMinutes == 0 }
        for m in pinned where m.plannedStart >= from && m.plannedStart < hardEnd {
            placements.append(.init(id: m.id, start: m.plannedStart,
                                    end: m.plannedStart.addingTimeInterval(m.duration)))
        }

        // ② 软锚块（clock ± range）：尽量原位；冲突则在 ± 范围内找最近可行位；找不到 → 溢出
        let soft = modules
            .filter { $0.fluidity.anchor == .clock && ($0.fluidity.rangeMinutes ?? 0) > 0 }
            .sorted { $0.plannedStart < $1.plannedStart }
        for m in soft {
            let range = TimeInterval(m.fluidity.rangeMinutes! * 60)
            let lo = max(from, m.plannedStart.addingTimeInterval(-range))
            let hi = min(hardEnd, m.plannedStart.addingTimeInterval(range).addingTimeInterval(m.duration))
            if let slot = firstFit(duration: m.duration, notBefore: max(lo, m.plannedStart),
                                   notAfter: hi, avoiding: placements)
                ?? firstFit(duration: m.duration, notBefore: lo, notAfter: hi, avoiding: placements) {
                placements.append(.init(id: m.id, start: slot, end: slot.addingTimeInterval(m.duration)))
            } else {
                overflow.append(m.id)
            }
        }

        // ③ 队列流动块：按 plannedStart 顺序（上游已定的相对顺序）依次首次适配
        let queue = modules.filter { $0.fluidity.anchor == .queue }
            .sorted { $0.plannedStart < $1.plannedStart }
        var placedQueueNormals: [FluidModule] = []
        for m in queue {
            if let slot = firstFit(duration: m.duration, notBefore: from, notAfter: hardEnd,
                                   avoiding: placements) {
                placements.append(.init(id: m.id, start: slot, end: slot.addingTimeInterval(m.duration)))
                if m.priority == .normal { placedQueueNormals.append(m) }
            } else if m.priority == .important,
                      let victim = placedQueueNormals.last {
                // ★救援置换：优先级低者先溢（仲裁序）——挤掉已放的最后一个普通队列块
                placements.removeAll { $0.id == victim.id }
                placedQueueNormals.removeLast()
                overflow.append(victim.id)
                if let slot = firstFit(duration: m.duration, notBefore: from, notAfter: hardEnd,
                                       avoiding: placements) {
                    placements.append(.init(id: m.id, start: slot, end: slot.addingTimeInterval(m.duration)))
                } else {
                    overflow.append(m.id)   // 挤了还装不下（★比被挤者更长）：两者都进溢出，P1c 定去向
                }
            } else {
                overflow.append(m.id)
            }
        }

        return FluidLayoutResult(placed: placements.sorted { $0.start < $1.start },
                                 overflow: overflow)
    }

    /// 首次适配：在 [notBefore, notAfter) 内找第一个能放下 duration、不与已放块重叠的起点。
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
