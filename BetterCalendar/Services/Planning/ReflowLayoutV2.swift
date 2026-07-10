//
//  ReflowLayoutV2.swift
//  BetterCalendar
//
//  reflow 铺时间 v2 —— 「候补」方案（SPEC §11 ②）。试验台孵化（F 组 5/5 全绿）后 0.23 B 毕业为线上算法；
//  试验台仍持有 v1 冻结快照与本类的对照跑分。
//  与 V1 的区别：收工线是**硬执法**——整块放不进 收工线+宽限 的弹性块进候补（不铺时间、不画橙），
//  而不是无限往深夜铺。三条豁免规则（设计见 SPEC §11 ②）：
//  - ★要紧事永不自动让路（超线也照排——它的去向由已授权的温和 nudge 管，不由算法定）；
//  - 用户原本就排在收工线之后的晚间块 = 自己的选择，钉在原时间不动；
//  - LLM 建议的候补（deferred 通道）尊重，但 ★/晚间豁免块除外（本地执法不信任模型）。
//  宽限（graceMinutes）= 算法内部参数（拍板：不进设置页），试验台可调 10/20/30 实验定值。
//

import Foundation

enum ReflowLayoutV2 {

    struct Result: Sendable {
        var scheduled: [ScheduledBlock] = []
        var deferred: [ScheduledBlock] = []   // 候补：保原始时间返回（列表展示用，不上画布）
    }

    /// 锚点顺延容忍（Jason 2026-07-10 拍板定死，不进设置）：生活锚点（午饭/通勤）是**软固定**——
    /// 保持原时刻，为让上一件事收尾可顺延最多 20 分钟；超过容忍就当固定障碍、弹性块绕到它后面。
    static let anchorShiftTolerance: TimeInterval = 20 * 60

    /// flexible 按给定顺序铺（LLM 定序或原顺序），fixed 锚住；windDown = 收工线时刻。
    /// llmDeferred = LLM 建议进候补的块 id（★/晚间豁免块会被本地否决）。
    static func layOut(flexible: [ScheduledBlock], fixed: [ScheduledBlock],
                       from startTime: Date, windDown: Date, graceMinutes: Int,
                       llmDeferred: Set<UUID> = []) -> Result {
        let line = windDown.addingTimeInterval(TimeInterval(graceMinutes * 60))
        var result = Result()

        // 生活锚点 = 软固定：不进槽（不被重铺、不进候补），作可顺延 ≤20 分钟的障碍参与避让
        var anchors = flexible.filter(\.isAnchor)
        let anchorOriginalStarts = anchors.map(\.start)
        let nonAnchor = flexible.filter { !$0.isAnchor }

        // 晚间豁免：原计划 start ≥ 收工线的弹性块钉原时间（参与避让，同固定块地位）
        let evening = nonAnchor.filter { $0.start >= windDown }
        let obstacles = fixed + evening
        let movable = nonAnchor.filter { $0.start < windDown }

        // 并行组合槽（同 V1）：同组合并为一个槽，槽长 = 组内最长时长，整组同起点
        var slots: [[ScheduledBlock]] = []
        var seenGroups = Set<String>()
        for b in movable {
            if let g = b.parallelGroup {
                guard !seenGroups.contains(g) else { continue }
                seenGroups.insert(g)
                slots.append(movable.filter { $0.parallelGroup == g })
            } else {
                slots.append([b])
            }
        }

        var cursor = startTime
        for slot in slots {
            let hasImportant = slot.contains { $0.priority == .important }
            // LLM 建议候补：整槽都被点名才让路；★槽否决
            if !hasImportant, !slot.isEmpty, slot.allSatisfy({ llmDeferred.contains($0.id) }) {
                result.deferred += slot
                continue
            }
            let slotDur = slot.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0
            var s = cursor
            var e = s.addingTimeInterval(slotDur)
            var moved = true
            while moved {
                moved = false
                for f in obstacles where s < f.end && e > f.start {
                    s = f.end
                    e = s.addingTimeInterval(slotDur)
                    moved = true
                }
                // 锚点避让（软固定）：撞上锚点时，若把锚点顺延（累计 ≤20 分钟）就能让本槽收尾 → 顺延锚点；
                // 顺延后不得撞上刚性障碍（固定/晚间），否则回退——锚点当刚性障碍、本槽绕后。
                for i in anchors.indices where s < anchors[i].end && e > anchors[i].start {
                    let need = e.timeIntervalSince(anchors[i].start)                       // 本槽需要锚点让出多少
                    let already = anchors[i].start.timeIntervalSince(anchorOriginalStarts[i])
                    var shifted = anchors[i]
                    shifted.start = shifted.start.addingTimeInterval(need)
                    shifted.end = shifted.end.addingTimeInterval(need)
                    let hitsRigid = obstacles.contains { shifted.start < $0.end && shifted.end > $0.start }
                    if need + already <= Self.anchorShiftTolerance, !hitsRigid {
                        anchors[i] = shifted                                               // 午饭晚 ≤20 分钟，事收得完
                    } else {
                        s = anchors[i].end                                                 // 容忍不够：锚点即墙，绕后
                        e = s.addingTimeInterval(slotDur)
                        moved = true
                    }
                }
            }
            // 收工线硬执法：整槽放不进 线+宽限 → 候补（★槽豁免：超线照排，主权在用户）
            if !hasImportant && e > line {
                result.deferred += slot
                continue   // cursor 不动：后面更短的槽还有机会塞进剩余空间
            }
            for b in slot {
                var nb = b
                nb.start = s
                nb.end = s.addingTimeInterval(b.end.timeIntervalSince(b.start))
                result.scheduled.append(nb)
            }
            cursor = e   // 顺序推进：排定槽之间天然不重叠
        }

        result.scheduled += fixed + evening + anchors
        result.scheduled.sort { $0.start < $1.start }
        return result
    }
}
