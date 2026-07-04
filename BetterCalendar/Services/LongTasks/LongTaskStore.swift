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
             cadenceMinutesPerWeek: Int? = nil, note: String = "") -> LongTask {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = active().first(where: { TitleMatch.similarity($0.title, t) >= 0.6 }) {
            if let d = deadline { existing.deadline = d }
            if let c = cadenceMinutesPerWeek { existing.cadenceMinutesPerWeek = c }
            existing.modifiedAt = .now
            try? context.save()
            reload()
            return existing
        }
        let task = LongTask(title: t, note: note, deadline: deadline,
                            cadenceMinutesPerWeek: cadenceMinutesPerWeek)
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
}
