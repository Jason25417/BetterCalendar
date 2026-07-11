//
//  RefineGuards.swift
//  BetterCalendar
//
//  微调防呆（纯函数集，模型无关）：原在 HomeViewModel 的静态函数，因试验台（Services/AlgoBench）
//  也要用、Services 引 Features 是反向依赖，抽到这里（2026-07-12 架构地图清零）。
//  VM 与 BenchRunner 共同引用；行为与单测口径不变。
//

import Foundation

enum RefineGuards {

    /// 明显的作息锚点标题（模型漏标时的确定性兜底；只加不减——模型标了的照样是）。纯函数、可单测。
    /// （原 ArrangeDayUseCase.isObviousAnchor，随 guardRefineFlags 一起下沉——Services 不得反向引用例层。）
    static func isObviousAnchor(_ title: String) -> Bool {
        let anchors = ["午饭", "晚饭", "早饭", "午餐", "晚餐", "早餐", "吃饭", "午休", "通勤", "睡觉", "洗漱"]
        return anchors.contains { title.contains($0) }
    }

    /// 微调防呆之二（0.23.1，点子簿 #9，试验台 R1 实锤）：模型偶尔**只返回改动的那块**（契约要求全量）。
    /// 部分返回按 标题相似度≥0.6 并回原清单：模型没回的 = 未改（不是删了）；匹配上的继承**原块 id**
    /// （盖章/归属稳定）；模型新增的块保留。命令含删除词（删/去掉/移除/取消）时信任模型的省略（删除仍可用）。
    /// 纯函数、模型无关（端侧/云端同吃）。
    static func mergePartialRefine(original: [ScheduledBlock], refined: [ScheduledBlock],
                                   command: String) -> [ScheduledBlock] {
        guard !refined.isEmpty else { return original }
        let deleteWords = ["删", "去掉", "移除", "取消"]
        let deleteIntent = deleteWords.contains { command.localizedCaseInsensitiveContains($0) }
        var usedRefined = Set<UUID>()
        var result: [ScheduledBlock] = []
        for o in original {
            let match = refined.first { !usedRefined.contains($0.id) && $0.id == o.id }
                ?? refined.first { !usedRefined.contains($0.id) && TitleMatch.similarity($0.title, o.title) >= 0.6 }
            if let r = match {
                usedRefined.insert(r.id)
                var nb = r
                nb.id = o.id   // 身份保持：投影盖章/完成判定不换章
                result.append(nb)
            } else if !deleteIntent {
                result.append(o)   // 没回 = 未改
            }
        }
        result += refined.filter { !usedRefined.contains($0.id) }   // 模型新增的块（"加一件"）保留
        return result
    }

    /// 微调防呆（端侧小模型爱过度概化：一次微调把所有块都改成 固定/★/番茄钟）：
    /// 命令里没提到相关词，就把 isFixed / priority / timingStyle 恢复为原值（按 id 配对、标题兜底）。
    /// 纯函数、可单测；新增块（原稿里没有的）不动。
    static func guardRefineFlags(original: [ScheduledBlock], refined: [ScheduledBlock],
                                 command: String) -> [ScheduledBlock] {
        let fixedWords = ["固定", "锁", "不能动", "雷打不动", "fix"]
        let priorityWords = ["星", "要紧", "重要", "优先"]
        let timingWords = ["番茄", "计时", "轻计", "不计"]
        let allowFixed = fixedWords.contains { command.localizedCaseInsensitiveContains($0) }
        let allowPriority = priorityWords.contains { command.localizedCaseInsensitiveContains($0) }
        let allowTiming = timingWords.contains { command.localizedCaseInsensitiveContains($0) }
        // isAnchor 永远守（作息锚点=结构性、无对应用户命令词；微调绝不能把午饭/晚饭悄悄变成「要完成的任务」）。
        // 只加不减：还原原块 isAnchor，或标题兜底（新加的午饭也锚）。独立于上面三个 allow——bug 修复 2026-07-09。
        func anchored(_ r: ScheduledBlock) -> ScheduledBlock {
            let o = original.first { $0.id == r.id } ?? original.first { TitleMatch.similarity($0.title, r.title) >= 0.6 }
            var nb = r
            nb.isAnchor = r.isAnchor || (o?.isAnchor ?? false) || isObviousAnchor(r.title)
            return nb
        }
        if allowFixed && allowPriority && allowTiming { return refined.map(anchored) }
        return refined.map { r in
            let base = anchored(r)
            guard let o = original.first(where: { $0.id == r.id })
                    ?? original.first(where: { TitleMatch.similarity($0.title, r.title) >= 0.6 })
            else { return base }
            var nb = base
            if !allowFixed { nb.isFixed = o.isFixed }
            if !allowPriority { nb.priority = o.priority }
            if !allowTiming { nb.timingStyle = o.timingStyle }
            // 微调防呆之三（0.23.1，点子簿 #9，试验台 R3 实锤）：命令既没提"固定"这类词、
            // 也没点名这个固定块 → 它的**起止时间**也还原（与 reflow「固定块绝不动」口径对齐）。
            // 局限：点名判定=命令包含完整标题；改固定块请带上它的名字。
            if o.isFixed, !allowFixed, !command.localizedCaseInsensitiveContains(o.title) {
                nb.start = o.start
                nb.end = o.end
            }
            return nb
        }
    }
}
