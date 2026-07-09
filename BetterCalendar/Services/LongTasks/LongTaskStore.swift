//
//  LongTaskStore.swift
//  BetterCalendar
//
//  「在途」池的数据访问（M10）。SwiftData 随 CloudKit 跨端。
//  防重：同名（TitleMatch ≥0.6）已有在途项时 add 幂等跳过——重复确认/两端并发不产生双份。
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LongTaskStore {
    @ObservationIgnored private let context: ModelContext
    /// 当前在途列表（缓存，mutator 后刷新——UI 直接观察它）。
    private(set) var items: [LongTask] = []

    init(context: ModelContext? = nil) {
        self.context = context ?? SharedModelContainer.shared.mainContext
        reload()
    }

    func reload() {
        let all = (try? context.fetch(FetchDescriptor<LongTask>())) ?? []
        items = all.filter { $0.status == .active }
            .sorted {
                switch ($0.deadline, $1.deadline) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.createdAt < $1.createdAt
                }
            }
    }

    /// 在途中的任务：有 DDL 的按 DDL 升序在前，无 DDL 的按创建时间。
    func active() -> [LongTask] { items }

    /// DDL 已过仍在途的（温和三选的对象）。
    func overdue(now: Date = .now) -> [LongTask] {
        active().filter { ($0.deadline ?? .distantFuture) < now }
    }

    /// 入池（幂等）：同名在途项已存在 → 只更新 DDL/节奏（取新值），不重复建。返回实际生效的任务。
    @discardableResult
    func add(title: String, deadline: Date? = nil,
             cadenceMinutesPerWeek: Int? = nil, totalMinutes: Int? = nil,
             unitMinutes: Int? = nil, note: String = "") -> LongTask {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = active().first(where: { TitleMatch.similarity($0.title, t) >= 0.6 }) {
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

    /// 进度是否已达/超估算（有总量且投入≥总量）——UI 出"看起来做完了？"邀请、并淡掉分数。
    func looksComplete(for task: LongTask) -> Bool {
        guard let total = task.totalMinutes, total > 0 else { return false }
        return investedMinutes(for: task) >= total
    }

    /// 进度文案（A，三红线：永远锚定"已"、无总量退时长、无焦虑运算）。
    /// 超/达估算（投入≥总量）：淡掉"N/M 单元"分数、只显已投入——估算安静地不再重要，绝不显"你超了"。
    func progressText(for task: LongTask) -> String {
        let invested = investedMinutes(for: task)
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
            guard today > 0 else { return nil }
            let total = investedMinutes(for: task)
            return "\(task.title) +\(ReviewSummaryText.hm(today))（累计 \(ReviewSummaryText.hm(total))）"
        }
        return parts.isEmpty ? nil : "长线推进：" + parts.joined(separator: " · ")
    }
}
