//
//  LongTaskStore.swift
//  BetterCalendar
//
//  「在途」池的数据访问（M10）。SwiftData 随 CloudKit 跨端。
//  防重：同名（TitleMatch ≥0.6）已有在途项时 add 幂等跳过——重复确认/两端并发不产生双份。
//  一池两区（E5a，I1 裁定 2026-08-15）：items 口径=长期区在途（老消费者零改动自动排除待办区）；
//  待办区走独立缓存 todos（小愿望+溢出物，丢弃=溶解硬删除，仅限该区）。
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LongTaskStore {
    @ObservationIgnored private let context: ModelContext
    /// 当前**长期区**在途列表（缓存，mutator 后刷新——UI 直接观察它）。
    /// ⚠️ 口径（E5a）：不含待办区——arrange 喂池/归属匹配/L3/进度统计等直取 items 的消费者天然不被待办区污染。
    private(set) var items: [LongTask] = []
    /// 待办区列表（缓存）：昨日溢出在前（晨间露脸序），其余按创建时间新的在前。
    private(set) var todos: [LongTask] = []

    init(context: ModelContext? = nil) {
        self.context = context ?? SharedModelContainer.shared.mainContext
        reload()
    }

    func reload() {
        let all = (try? context.fetch(FetchDescriptor<LongTask>())) ?? []
        items = all.filter { $0.status == .active && $0.poolZone == .longterm }
            .sorted {
                switch ($0.deadline, $1.deadline) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.createdAt < $1.createdAt
                }
            }
        todos = all.filter { $0.status == .active && $0.poolZone == .todo }
            .sorted {
                switch ($0.spilledFromDay, $1.spilledFromDay) {
                case let (a?, b?): return a > b                      // 新溢出的在前
                case (_?, nil): return true                          // 溢出物先于手动愿望
                case (nil, _?): return false
                case (nil, nil): return $0.createdAt > $1.createdAt  // 愿望按新到旧
                }
            }
    }

    /// 长期区在途任务：有 DDL 的按 DDL 升序在前，无 DDL 的按创建时间。
    func active() -> [LongTask] { items }

    /// 待办区条目（E5a）：溢出物在前、手动愿望在后。
    func todoItems() -> [LongTask] { todos }

    /// DDL 已过仍在途的（温和三选的对象）。
    func overdue(now: Date = .now) -> [LongTask] {
        active().filter { ($0.deadline ?? .distantFuture) < now }
    }

    /// 入池（长期区，幂等）：同名长期区在途项已存在 → 只更新 DDL/节奏（取新值），不重复建。
    /// 跨区幂等（E5a）：同名条目在**待办区** → 升格为长期区并回填字段，不重建（防跨区重复）。
    @discardableResult
    func add(title: String, deadline: Date? = nil,
             cadenceMinutesPerWeek: Int? = nil, totalMinutes: Int? = nil,
             unitMinutes: Int? = nil, note: String = "") -> LongTask {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = active().first(where: { TitleMatch.similarity($0.title, t) >= 0.6 })
            ?? todoItems().first(where: { TitleMatch.similarity($0.title, t) >= 0.6 })
        if let existing {
            if existing.poolZone == .todo {
                existing.zoneRaw = PoolZone.longterm.rawValue
                existing.spilledFromDay = nil
                DevLog.shared.info("在途", "待办区条目升格为长期：\(existing.title)")
            }
            if let d = deadline { existing.deadline = d }
            if let c = cadenceMinutesPerWeek { existing.cadenceMinutesPerWeek = c }
            if let tm = totalMinutes { existing.totalMinutes = tm }
            if let um = unitMinutes { existing.unitMinutes = um }
            existing.modifiedAt = .now
            try? context.save()
            reload()
            return existing
        }
        let task = LongTask(title: t, note: note, deadline: deadline,
                            cadenceMinutesPerWeek: cadenceMinutesPerWeek,
                            totalMinutes: totalMinutes, unitMinutes: unitMinutes)
        context.insert(task)
        try? context.save()
        reload()
        DevLog.shared.info("在途", "入池：\(t)" + (deadline != nil ? "（有 DDL）" : ""))
        return task
    }

    // MARK: 待办区（E5a，一池两区）

    /// 收进待办区（幂等）：同名待办条目已在 → 更新来源日/族；同名**长期区**在途项已在 → 不重复建、
    /// 返回长期项（它已有家——溢出的池块本来就该回它的长期任务）。
    @discardableResult
    func addTodo(title: String, family: String? = nil, spilledFromDay: Date? = nil) -> LongTask {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = todoItems().first(where: { TitleMatch.similarity($0.title, t) >= 0.6 }) {
            if let s = spilledFromDay { existing.spilledFromDay = s }
            if let f = family { existing.family = f }
            existing.modifiedAt = .now
            try? context.save()
            reload()
            return existing
        }
        if let home = active().first(where: { TitleMatch.similarity($0.title, t) >= 0.6 }) {
            DevLog.shared.info("待办区", "「\(t)」已有长期任务归属，不重复收待办")
            return home
        }
        let entry = LongTask(title: t, zone: .todo, family: family, spilledFromDay: spilledFromDay)
        context.insert(entry)
        try? context.save()
        reload()
        DevLog.shared.info("待办区", "收进待办：\(t)" + (spilledFromDay != nil ? "（溢出）" : "（愿望）"))
        return entry
    }

    /// 丢弃（=溶解，零记录零愧疚）：**仅限待办区**的硬删除；长期区维持「无删除只改状态」裁决。
    func discard(_ entry: LongTask) {
        guard entry.poolZone == .todo else {
            DevLog.shared.warn("待办区", "discard 只用于待办区，长期区走 shelve/complete：\(entry.title)")
            return
        }
        context.delete(entry)
        try? context.save()
        reload()
    }

    func complete(_ task: LongTask) {
        task.status = .done
        task.doneAt = .now
        task.modifiedAt = .now
        try? context.save()
        reload()
    }

    /// 「先放下」：体面出口，随时可在历史里捞回（后续做）。
    func shelve(_ task: LongTask) {
        task.status = .shelved
        task.modifiedAt = .now
        try? context.save()
        reload()
    }

    /// 改期：DDL 顺延 N 天（默认一周）；无 DDL 的设为 N 天后。
    func pushDeadline(_ task: LongTask, days: Int = 7) {
        let base = task.deadline ?? .now
        task.deadline = Calendar.current.date(byAdding: .day, value: days, to: base)
        task.modifiedAt = .now
        try? context.save()
        reload()
    }

    // MARK: 长期页（#40 批1）：分组查询 / 捞回 / 三量编辑 / 检查点

    /// 「先放下」的任务（长期页折叠区，捞回入口）——按放下时间近的在前。只看长期区（待办区无三态）。
    func shelved() -> [LongTask] {
        let all = (try? context.fetch(FetchDescriptor<LongTask>())) ?? []
        return all.filter { $0.status == .shelved && $0.poolZone == .longterm }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 「做成了」的任务（长期页折叠区，正反馈存档）——按做成时间近的在前。只看长期区。
    func doneItems() -> [LongTask] {
        let all = (try? context.fetch(FetchDescriptor<LongTask>())) ?? []
        return all.filter { $0.status == .done && $0.poolZone == .longterm }
            .sorted { ($0.doneAt ?? $0.modifiedAt) > ($1.doneAt ?? $1.modifiedAt) }
    }

    /// 捞回（先放下 → 在途）：放下是体面出口，捞回同样零成本。
    func unshelve(_ task: LongTask) {
        task.status = .active
        task.modifiedAt = .now
        try? context.save()
        reload()
    }

    /// 捞回（做成了 → 在途）：D2-C（2026-07-20 Jason 裁）——「做成了」可逆化后破坏性消失，
    /// U10 距离不再需要（误触无所谓＞防误触）；也补上「误标做成/做成后还要继续」的真实缺口。
    /// 清 doneAt；已投入记录不动（做过的都算数）。
    func reopen(_ task: LongTask) {
        task.status = .active
        task.doneAt = nil
        task.modifiedAt = .now
        try? context.save()
        reload()
    }

    /// 三量编辑（详情页；nil 语义=清空该量——与 add 的「nil=不改」不同，这里是显式表单）。
    func update(_ task: LongTask, title: String? = nil, note: String? = nil,
                deadline: Date??, cadenceMinutesPerWeek: Int??, totalMinutes: Int??, unitMinutes: Int??) {
        if let t = title { task.title = t }
        if let n = note { task.note = n }
        if let d = deadline { task.deadline = d }
        if let c = cadenceMinutesPerWeek { task.cadenceMinutesPerWeek = c }
        if let tm = totalMinutes { task.totalMinutes = tm }
        if let um = unitMinutes { task.unitMinutes = um }
        task.modifiedAt = .now
        try? context.save()
        reload()
    }

    /// 加检查点（追加到末尾；空标题不加）。
    @discardableResult
    func addCheckpoint(to task: LongTask, title: String, estimatedMinutes: Int? = nil) -> LongTaskCheckpoint? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let order = (task.sortedCheckpoints.last?.order ?? -1) + 1
        let cp = LongTaskCheckpoint(title: t, estimatedMinutes: estimatedMinutes, order: order)
        cp.task = task
        context.insert(cp)
        task.modifiedAt = .now
        try? context.save()
        reload()
        return cp
    }

    /// 勾/取消勾检查点（勾=doneAt 盖章；取消=清章，零惩罚可反悔）。
    func toggleCheckpoint(_ cp: LongTaskCheckpoint) {
        cp.doneAt = cp.doneAt == nil ? .now : nil
        cp.task?.modifiedAt = .now
        try? context.save()
        reload()
    }

    func deleteCheckpoint(_ cp: LongTaskCheckpoint) {
        cp.task?.modifiedAt = .now
        context.delete(cp)
        try? context.save()
        reload()
    }

    /// 拖动重排：整组重写 order（0…n）。
    func reorderCheckpoints(_ task: LongTask, ordered: [LongTaskCheckpoint]) {
        for (i, cp) in ordered.enumerated() { cp.order = i }
        task.modifiedAt = .now
        try? context.save()
        reload()
    }

    // MARK: 累计投入（M10-3，正反馈口径：只算做了多少，不算剩多少）

    private func sessions() -> [ExecutionSession] {
        (try? context.fetch(FetchDescriptor<ExecutionSession>())) ?? []
    }

    /// 块 id → 归属未来任务 id（只含已归属的块）。0.18.2 精确归属：让投入统计锚 id、不靠标题漂移。
    private func blockLinkMap() -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        // 只认「计划」块：蓝对账后库里也存 .actual 行（同 UUID 换幕布），不按 kind 过滤会把实际块也算进归属。
        for b in (try? context.fetch(FetchDescriptor<PlanBlock>())) ?? [] where b.kind == .planned {
            if let linked = b.linkedTaskID { map[b.id] = linked }
        }
        return map
    }

    /// 某未来任务的累计投入分钟。**精确优先**：会话所属块显式归属到某任务→只记给它（标题相同也不串味）；
    /// 未归属的块 → 退回标题相似（0.18.1 前的口径，兼容旧数据）。
    func investedMinutes(for task: LongTask, on day: Date? = nil) -> Int {
        let linkMap = blockLinkMap()
        return sessions()
            .filter { s in
                if let day, !DayContext.isSameLogicalDay(s.start, day) { return false }
                if let bid = s.blockID, let linked = linkMap[bid] { return linked == task.id }  // 精确
                return TitleMatch.similarity(s.title, task.title) >= 0.6                          // 兜底
            }
            .compactMap { s in s.end.map { Int($0.timeIntervalSince(s.start) / 60) } }
            .reduce(0, +)
    }

    /// 最近 7 个逻辑日的投入分钟（长期页卡「本周已投入」；口径=滚动 7 天，只陈述不判达标）。
    func investedThisWeek(for task: LongTask, now: Date = .now) -> Int {
        (0..<7).reduce(0) { sum, offset in
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: now) ?? now
            return sum + investedMinutes(for: task, on: day)
        }
    }

    /// 进度是否已达/超估算（有总量且投入≥总量）——UI 出"看起来做完了？"邀请、并淡掉分数。
    func looksComplete(for task: LongTask) -> Bool {
        guard let total = task.totalMinutes, total > 0 else { return false }
        return investedMinutes(for: task) >= total
    }

    /// 进度文案（A，三红线：永远锚定"已"、无总量退时长、无焦虑运算）。
    /// 超/达估算（投入≥总量）：淡掉"N/M 单元"分数、只显已投入——估算安静地不再重要，绝不显"你超了"。
    func progressText(for task: LongTask) -> String {
        let invested = investedMinutes(for: task)
        // 清单型（#40）：设了检查点 → 进度按「已推进 m/n · 下一个」口径（计数不百分比，红线）
        let cps = task.sortedCheckpoints
        if !cps.isEmpty {
            let done = cps.filter { $0.doneAt != nil }.count
            var s = "已推进 \(done)/\(cps.count)"
            if let next = task.nextCheckpoint { s += " · 下一个：\(next.title)" }
            if invested > 0 { s += " · 已投入 \(ReviewSummaryText.hm(invested))" }
            return s
        }
        if let total = task.totalMinutes, total > 0, invested >= total {
            return "已投入 \(ReviewSummaryText.hm(invested))"
        }
        if let unit = task.unitMinutes, unit > 0, let total = task.totalMinutes, total > 0 {
            return "已推进 \(invested / unit)/\(max(1, total / unit)) 单元 · 已投入 \(ReviewSummaryText.hm(invested))"
        }
        return invested > 0 ? "已投入 \(ReviewSummaryText.hm(invested))" : ""
    }
    /// 增长条填充比例（0…1）；无总量返回 nil（无条，只显投入）。
    func progressFraction(for task: LongTask) -> Double? {
        guard let total = task.totalMinutes, total > 0 else { return nil }
        return min(1.0, Double(investedMinutes(for: task)) / Double(total))
    }

    /// 复盘用的一行长线推进（今天动过的在途才上榜；没有则 nil——不无中生有）。
    /// 例：「长线推进：论文 +2 小时（累计 6 小时）· 学 Swift +45 分钟（累计 3 小时）」
    func progressLine(now: Date = .now) -> String? {
        let parts: [String] = active().compactMap { task in
            let today = investedMinutes(for: task, on: now)
            // #40 批2：今天勾了检查点的也上榜（哪怕投入未记到——推进本身就是事实）
            let cpToday = task.sortedCheckpoints.filter {
                $0.doneAt.map { DayContext.isSameLogicalDay($0, now) } ?? false
            }
            guard today > 0 || !cpToday.isEmpty else { return nil }
            let total = investedMinutes(for: task)
            var s = task.title
            if let last = cpToday.last { s += " 推进到「\(last.title)」" }   // 阶段名比时长更有推进感
            if today > 0 { s += " +\(ReviewSummaryText.hm(today))（累计 \(ReviewSummaryText.hm(total))）" }
            return s
        }
        return parts.isEmpty ? nil : "长线推进：" + parts.joined(separator: " · ")
    }
}
