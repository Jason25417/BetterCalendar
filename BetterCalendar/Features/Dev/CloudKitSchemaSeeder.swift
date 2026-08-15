//
//  CloudKitSchemaSeeder.swift
//  BetterCalendar
//
//  CloudKit schema 播种（开发件，M8 摘除）：SwiftData+CloudKit 的 Development schema 是
//  **按实际写入的记录推断**出来的——新 @Model 没写过记录、可选字段值为 nil，
//  Console 里就永远看不到变更、也就没法 Deploy 到 Production（=TestFlight 同步失效）。
//  本件插一条「全字段非 nil」的哨兵记录把 schema 顶上去；Deploy 完一键清除。
//
//  用法（Jason）：Xcode 运行 Debug 版（Debug=CloudKit Development 环境）→ 引擎观察窗
//  →「播种」→ 等同步（十几秒～1 分钟）→ CloudKit Console 的 **Development** 环境
//  能看到 DayPlanSnapshot / ResidualSample 两个新 record type 与 LongTask 三个新字段
//  → Deploy Schema Changes → 回来点「清除」。
//  哨兵记录设计成**不进任何 UI 列表**（LongTask 用 status=.done + zone=.todo，
//  两个列表的过滤条件都不命中），播种期间界面不会被污染。
//

import Foundation
import SwiftData

@MainActor
enum CloudKitSchemaSeeder {
    /// 哨兵日期（1970-01-01）：既作标记也作清除条件——真实数据绝不会落在这天。
    static let sentinel = Date(timeIntervalSince1970: 0)
    static let sentinelTitle = "⛳️ schema 播种（可删）"

    private static var context: ModelContext { SharedModelContainer.shared.mainContext }

    /// 插入三类哨兵记录（幂等：已存在则不重复插）。返回给 UI 显示的结果文字。
    static func seed() -> String {
        var created: [String] = []

        if !hasSnapshot() {
            let item = SnapshotItem(id: UUID(), title: sentinelTitle, plannedStart: sentinel,
                                    plannedMinutes: 60, isFixed: true, isAnchor: true,
                                    linkedTaskID: UUID(), labels: ["family:写作"],
                                    priorityRaw: BlockPriority.important.rawValue)
            context.insert(DayPlanSnapshot(dayLabel: sentinel, createdAt: sentinel, items: [item]))
            created.append("DayPlanSnapshot")
        }
        if !hasSample() {
            context.insert(ResidualSample(
                dayLabel: sentinel, blockID: UUID(), title: sentinelTitle,
                labels: ["family:写作"], linkedTaskID: UUID(),
                isFixed: true, isAnchor: true,
                plannedStart: sentinel, plannedMinutes: 60,
                actualStart: sentinel, actualMinutes: 75, source: .recall))
            created.append("ResidualSample")
        }
        if !hasLongTask() {
            // 三个新字段全部非 nil；status=.done + zone=.todo → items/todos/shelved/doneItems 全不命中
            let t = LongTask(title: sentinelTitle, note: "CloudKit schema 播种用，可随时删",
                             deadline: sentinel, cadenceMinutesPerWeek: 1,
                             totalMinutes: 1, unitMinutes: 1, status: .done,
                             createdAt: sentinel, doneAt: sentinel, modifiedAt: sentinel,
                             zone: .todo, family: "写作", spilledFromDay: sentinel)
            context.insert(t)
            created.append("LongTask(zoneRaw/family/spilledFromDay)")
        }

        guard !created.isEmpty else { return "已播种过（点「清除」可撤）" }
        do {
            try context.save()
            DevLog.shared.info("CloudKit", "schema 播种：\(created.joined(separator: " / "))")
            return "已插入：\(created.joined(separator: " / "))\n等十几秒同步，再去 Console 看 Development 环境"
        } catch {
            DevLog.shared.error("CloudKit", "schema 播种失败：\(error.localizedDescription)")
            return "插入失败：\(error.localizedDescription)"
        }
    }

    /// 清除哨兵记录（Deploy 完后调；schema 只增不减，删记录不影响已部署的 schema）。
    static func cleanup() -> String {
        var removed = 0
        for s in (try? context.fetch(FetchDescriptor<DayPlanSnapshot>())) ?? []
        where s.dayLabel == sentinel { context.delete(s); removed += 1 }
        for s in (try? context.fetch(FetchDescriptor<ResidualSample>())) ?? []
        where s.dayLabel == sentinel { context.delete(s); removed += 1 }
        for t in (try? context.fetch(FetchDescriptor<LongTask>())) ?? []
        where t.title == sentinelTitle { context.delete(t); removed += 1 }
        try? context.save()
        DevLog.shared.info("CloudKit", "schema 播种记录已清除（\(removed) 条）")
        return removed == 0 ? "没有可清除的播种记录" : "已清除 \(removed) 条哨兵记录"
    }

    /// 当前播种状态（观察窗显示）。
    static func status() -> String {
        let parts = [
            hasSnapshot() ? "快照✓" : "快照✗",
            hasSample() ? "残差✓" : "残差✗",
            hasLongTask() ? "池字段✓" : "池字段✗",
        ]
        return parts.joined(separator: " · ")
    }

    private static func hasSnapshot() -> Bool {
        ((try? context.fetch(FetchDescriptor<DayPlanSnapshot>())) ?? []).contains { $0.dayLabel == sentinel }
    }
    private static func hasSample() -> Bool {
        ((try? context.fetch(FetchDescriptor<ResidualSample>())) ?? []).contains { $0.dayLabel == sentinel }
    }
    private static func hasLongTask() -> Bool {
        ((try? context.fetch(FetchDescriptor<LongTask>())) ?? []).contains { $0.title == sentinelTitle }
    }
}
