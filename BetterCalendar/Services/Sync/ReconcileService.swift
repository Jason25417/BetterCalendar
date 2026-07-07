//
//  ReconcileService.swift
//  BetterCalendar
//
//  双向同步（0.20，五点设计 Jason 拍板 2026-07-08；产品哲学审查通过）：
//  在 Apple 日历里手改绿块 → **按事件 URL 章的 ID** 回流 PlanStore。与被删掉的旧 CalendarSyncService
//  本质不同：旧版按标题模糊匹配全量覆盖（历史 bug 之源）；本版按 ID 精确、且有指纹防自写回环。
//  1. 回流字段 = 时间 + 标题（固定/★/计时方式日历无对应概念，保持库值）。
//  2. 自写回环抑制 = 指纹：投影每次成功写完，记下当天 blockID→(起止,标题) 快照；
//     日历事件与指纹一致=我们自己写的（或没人动过），跳过；不一致=用户手改，回流。
//  3. 冲突仲裁 = 用户最后动作赢（App 有未保存草稿时列表不自动刷新，已有 hasUnsavedChanges 挡）。
//  4. 删除 = 弹窗确认（挂起到主窗口展示，不发通知打扰）+「记住选择」三态策略（设置页可反悔）。
//     日历里**新建**的无章事件不认领（下次投影清掉——日历不是新建入口）。
//  5. 对账窗口 = 逻辑今天…+7 天；过去永远不动（不审计历史）。
//  措辞铁律：对话文案中性前向（"日历里移除了 N 件"），绝不审计式（"你删了"）。
//

import Foundation
import Observation
import EventKit

// MARK: - 设置：日历删除的处置策略（三态，进阶设置可调）

enum ReconcileDeletionPolicy: String, CaseIterable {
    case ask = "ask"                   // 每次询问（默认）
    case alwaysDelete = "alwaysDelete" // 以后都同步移除
    case neverDelete = "neverDelete"   // 以后都保留（画回日历）

    var label: String {
        switch self {
        case .ask: return "每次询问"
        case .alwaysDelete: return "直接同步移除"
        case .neverDelete: return "保留计划（画回日历）"
        }
    }
}

enum ReconcileSettings {
    static var deletionPolicy: ReconcileDeletionPolicy {
        get { ReconcileDeletionPolicy(rawValue: UserDefaults.standard.string(forKey: "reconcile.deletionPolicy") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "reconcile.deletionPolicy") }
    }
}

// MARK: - 指纹（投影写、对账读）

/// 投影最后一次成功写下的画面快照：dayKey → [blockID: "起分|止分|标题"]。
/// 对账用它区分「我们自己写的」vs「用户在日历里手改的」——没有它，投影失败后的对账会把旧日历
/// 倒灌回真相源（正是要防的事故）。存 UserDefaults（每台设备自己的投影自己记）。
enum ProjectionFingerprints {
    private static let key = "projection.fingerprints"

    static func tuple(start: Date, end: Date, title: String) -> String {
        "\(Int(start.timeIntervalSinceReferenceDate / 60))|\(Int(end.timeIntervalSinceReferenceDate / 60))|\(title)"
    }

    static func set(_ label: Date, _ prints: [String: String]) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        all[DayContext.dayKey(label.addingTimeInterval(12 * 3600))] = prints   // 正午时刻求 dayKey，避开凌晨偏移
        // 只留 30 天内的键，防无限膨胀
        if all.count > 40 { all = Dictionary(uniqueKeysWithValues: Array(all.suffix(40))) }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func get(_ label: Date) -> [String: String] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        return all[DayContext.dayKey(label.addingTimeInterval(12 * 3600))] ?? [:]
    }
}

// MARK: - 对账服务

@MainActor
@Observable
final class ReconcileService {
    /// 待用户确认的日历删除（挂起，主窗口以对话框展示；中性文案）。
    struct PendingDeletion: Identifiable {
        let id: UUID       // blockID
        let title: String
        let label: Date    // 所属逻辑日标签
    }

    private let planReader: PlanReading
    private let planWriter: PlanWriting      // 显式授权：对账是 confirm 之外唯一的计划写者（权限表在案）
    private let calendarStore: CalendarStore
    private let projection: ProjectionService
    private let startedDays: StartedDayStore?
    private var listenTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    private(set) var pendingDeletions: [PendingDeletion] = []

    init(planReader: PlanReading, planWriter: PlanWriting, calendarStore: CalendarStore,
         projection: ProjectionService, startedDays: StartedDayStore? = nil) {
        self.planReader = planReader
        self.planWriter = planWriter
        self.calendarStore = calendarStore
        self.projection = projection
        self.startedDays = startedDays
    }

    /// 监听系统日历变更（1s 防抖合并连续通知）→ 对账窗口内逐日核对。
    func start() {
        listenTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                self?.scheduleReconcile()
            }
        }
    }

    private func scheduleReconcile() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            await self?.reconcileWindow()
        }
    }

    /// 对账 逻辑今天…+7 天（与启动对账同窗）；实时模式（已开始）的日子跳过（橙色归执行层）。
    func reconcileWindow() async {
        guard CalendarSettings.backend == .eventKit else { return }
        let events = (try? await calendarStore.read(kind: .planned)) ?? []
        for offset in 0..<8 {
            let label = DayContext.logicalDay(offset: offset)
            if startedDays?.isStarted(label) ?? false { continue }
            await reconcile(label: label, allGreenEvents: events)
        }
    }

    private func reconcile(label: Date, allGreenEvents: [CalendarEventDraft]) async {
        let window = DayContext.logicalWindow(forLabel: label)
        let events = allGreenEvents.filter { $0.start >= window.start && $0.start < window.end }
        guard let truth = try? planReader.plannedBlocks(on: label) else { return }
        let fp = ProjectionFingerprints.get(label)
        let plan = Self.diff(truth: truth, events: events, fingerprint: fp)

        var touchedLabels: Set<Date> = []
        for u in plan.updates {
            try? planWriter.updatePlanned(id: u.id, start: u.start, end: u.end, title: u.title)
            touchedLabels.insert(Calendar.current.startOfDay(for: label))
            touchedLabels.insert(DayContext.logicalStartOfDay(u.start))   // 拖去别的日子 → 新桶也要重投影
            DevLog.shared.info("对账", "日历手改回流：「\(u.title)」")
        }
        if !plan.deletions.isEmpty {
            switch ReconcileSettings.deletionPolicy {
            case .alwaysDelete:
                try? planWriter.deletePlanned(ids: plan.deletions.map(\.id))
                touchedLabels.insert(Calendar.current.startOfDay(for: label))
                DevLog.shared.info("对账", "日历删除已同步移除 \(plan.deletions.count) 块（策略=直接移除）")
            case .neverDelete:
                touchedLabels.insert(Calendar.current.startOfDay(for: label))   // 重投影=画回
                DevLog.shared.info("对账", "日历删除 \(plan.deletions.count) 块 → 按策略保留（画回）")
            case .ask:
                for d in plan.deletions where !pendingDeletions.contains(where: { $0.id == d.id }) {
                    pendingDeletions.append(PendingDeletion(id: d.id, title: d.title, label: label))
                }
            }
        }
        if plan.needsRepaint { touchedLabels.insert(Calendar.current.startOfDay(for: label)) }
        for l in touchedLabels { try? await projection.project(label: l) }
    }

    /// 用户对删除对话框的选择。remember=记住（写进设置，以后不再问）。
    /// **同步入口**：快照并清空挂起必须在按钮动作里立即发生——对话框 dismiss 回调会紧跟着触发
    /// "无选择=保留一次"的兜底，异步清空会造成二次结算。
    func resolveDeletions(delete: Bool, remember: Bool) {
        let items = pendingDeletions
        pendingDeletions = []
        guard !items.isEmpty else { return }
        if remember { ReconcileSettings.deletionPolicy = delete ? .alwaysDelete : .neverDelete }
        Task { [weak self] in
            guard let self else { return }
            if delete { try? self.planWriter.deletePlanned(ids: items.map(\.id)) }
            // 删=投影清掉残留；留=投影画回。两条路都收敛到真相源。
            for label in Set(items.map { Calendar.current.startOfDay(for: $0.label) }) {
                try? await self.projection.project(label: label)
            }
            DevLog.shared.info("对账", delete ? "已同步移除 \(items.count) 块" : "已保留 \(items.count) 块（画回日历）")
        }
    }

    // MARK: - 纯函数 diff（可单测）

    struct Update: Equatable { let id: UUID; let start: Date; let end: Date; let title: String }
    struct Deletion: Equatable { let id: UUID; let title: String }
    struct DiffPlan {
        var updates: [Update] = []
        var deletions: [Deletion] = []
        var needsRepaint = false   // 有无主事件/缺投影 → 让投影按真相源重画
    }

    /// 真相 × 日历事件 × 指纹 → 行动清单。
    /// - 事件在、与真相一致 → 无事。
    /// - 事件在、与真相不同：与指纹一致=没人动过日历（是真相变了没投影）→ 重画；
    ///   与指纹不同 = 用户手改 → 回流（时间+标题）。
    /// - 事件不在：指纹里有 = 我们写过、被用户删了 → 删除候选；指纹里没有 = 从没投影过 → 重画。
    /// - 无章/不认识的事件 → 重画（投影会清掉；日历不是新建入口）。
    static func diff(truth: [ScheduledBlock], events: [CalendarEventDraft],
                     fingerprint: [String: String]) -> DiffPlan {
        var plan = DiffPlan()
        var byID: [UUID: CalendarEventDraft] = [:]
        for e in events {
            if let bid = e.blockID { byID[bid] = e } else { plan.needsRepaint = true }
        }
        let truthIDs = Set(truth.map(\.id))
        if byID.keys.contains(where: { !truthIDs.contains($0) }) { plan.needsRepaint = true }
        for b in truth {
            let key = b.id.uuidString
            if let e = byID[b.id] {
                let evTuple = ProjectionFingerprints.tuple(start: e.start, end: e.end, title: e.title)
                let truthTuple = ProjectionFingerprints.tuple(start: b.start, end: b.end, title: b.title)
                if evTuple == truthTuple { continue }
                if evTuple == fingerprint[key] {
                    plan.needsRepaint = true   // 日历没人动，是真相更新未投影 → 真相赢
                } else {
                    plan.updates.append(Update(id: b.id, start: e.start, end: e.end, title: e.title))
                }
            } else if fingerprint[key] != nil {
                plan.deletions.append(Deletion(id: b.id, title: b.title))   // 我们写过 → 用户删了
            } else {
                plan.needsRepaint = true       // 从没投影过（失败/新设备）→ 补画，不是删除
            }
        }
        return plan
    }
}
