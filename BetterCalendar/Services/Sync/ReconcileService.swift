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
//     日历里**新建**的无章事件 = 用户的事件：询问要不要加进计划；选「忽略」就记住、不再问，
//     事件永远留在日历里（P4.0-1：BetterCalendar 绝不删无章事件）。
//  5. 对账窗口 = 逻辑今天…+7 天；过去永远不动（不审计历史）。读日历按扫描范围 逻辑昨天…+8 天
//     （P4.0-5/6：按章在全范围配对，拖到别的日子=改时间，不是删除）。
//  6. 判不清的块只挂起那一块（P4.0-4），同一天别的改动照常；同章多份按确定性规则取（P4.0-2）。
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

/// 日历里**新建**日程（无章事件）的处置策略（0.20.2，Jason 提：新建也询问、与删除弹窗合并）。
enum ReconcileAdditionPolicy: String, CaseIterable {
    case ask = "ask"               // 每次询问（默认）
    case alwaysAdd = "alwaysAdd"   // 以后都自动加进计划
    case ignore = "ignore"         // 以后都忽略（留在日历里、不加进计划——P4.0-1 起永不删除）

    var label: String {
        switch self {
        case .ask: return "每次询问"
        case .alwaysAdd: return "自动加进计划"
        case .ignore: return "忽略（留在日历里，不加进计划）"
        }
    }
}

enum ReconcileSettings {
    static var deletionPolicy: ReconcileDeletionPolicy {
        get { ReconcileDeletionPolicy(rawValue: UserDefaults.standard.string(forKey: "reconcile.deletionPolicy") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "reconcile.deletionPolicy") }
    }
    static var additionPolicy: ReconcileAdditionPolicy {
        get { ReconcileAdditionPolicy(rawValue: UserDefaults.standard.string(forKey: "reconcile.additionPolicy") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "reconcile.additionPolicy") }
    }
}

// MARK: - 指纹（投影写、对账读）

/// 投影最后一次成功写下的画面快照：dayKey → [blockID: "起分|止分|标题"]。
/// 对账用它区分「我们自己写的」vs「用户在日历里手改的」——没有它，投影失败后的对账会把旧日历
/// 倒灌回真相源（正是要防的事故）。存 UserDefaults（每台设备自己的投影自己记）。
enum ProjectionFingerprints {
    private static let key = "projection.fingerprints"
    /// 保留「今天前后 N 天」的指纹（P4.0-3）：对账只看今天…+7 天，30 天绰绰有余。
    static let retentionDays = 30

    static func tuple(start: Date, end: Date, title: String) -> String {
        "\(Int(start.timeIntervalSinceReferenceDate / 60))|\(Int(end.timeIntervalSinceReferenceDate / 60))|\(title)"
    }

    static func dayKey(_ label: Date) -> String {
        DayContext.dayKey(label.addingTimeInterval(12 * 3600))   // 正午时刻求 dayKey，避开凌晨偏移
    }

    static func set(_ label: Date, _ prints: [String: String],
                    defaults: UserDefaults = .standard, now: Date = .now) {
        var all = defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        let written = dayKey(label)
        all[written] = prints
        defaults.set(pruned(all, around: now, keeping: written), forKey: key)
    }

    static func get(_ label: Date, defaults: UserDefaults = .standard) -> [String: String] {
        let all = defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        return all[dayKey(label)] ?? [:]
    }

    /// 按日期淘汰（P4.0-3 修 B6）：只留 now 前后 retentionDays 天的键（键是 yyyy-MM-dd，字典序=时间序），
    /// 刚写的那天永远保留。旧实现 `Dictionary(...suffix(40))` 在无序字典上取后 40 个=随机淘汰，
    /// 今天/明天的指纹也可能被丢掉 → 手改被判成冲突、删除被当成「从没画过」又画回去。
    static func pruned(_ all: [String: [String: String]], around now: Date,
                       keeping written: String? = nil) -> [String: [String: String]] {
        let day: TimeInterval = 24 * 3600
        let lo = DayContext.dayKey(now.addingTimeInterval(-Double(retentionDays) * day))
        let hi = DayContext.dayKey(now.addingTimeInterval(Double(retentionDays) * day))
        return all.filter { k, _ in k == written || (k >= lo && k <= hi) }
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
    /// 待用户确认的日历新建（无章事件 → 问要不要加进计划；与删除同一个对话框，不跳两次）。
    struct PendingAddition: Identifiable {
        var id: String { key }
        let key: String    // 标题+起始分钟 去重键
        let title: String
        let start: Date
        let end: Date
        let label: Date
    }

    private let planReader: PlanReading
    private let planWriter: PlanWriting      // 显式授权：对账是 confirm 之外的计划写者之一（权限表在案）
    private let calendarStore: CalendarStore
    private let projection: ProjectionService
    private let startedDays: StartedDayStore?
    /// 指纹 + 「已忽略的日历新建」所在的库（注入=测试不污染真实 UserDefaults）；须与 ProjectionService 同一个。
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendarAuthorized: () -> Bool
    private let deletionPolicy: () -> ReconcileDeletionPolicy
    private let additionPolicy: () -> ReconcileAdditionPolicy
    private var listenTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    private(set) var pendingDeletions: [PendingDeletion] = []
    private(set) var pendingAdditions: [PendingAddition] = []
    var hasPendingChanges: Bool { !pendingDeletions.isEmpty || !pendingAdditions.isEmpty }

    /// 对账把日历手改回流进真相后发出（排日程页借此即时刷新，不用等重新进页）。
    /// userInfo["source"] 标来源（PlanChangeSource）；时间线协调器据此区分外部变更与本机回声（B10）。
    static let planChangedExternally = Notification.Name("bc.planChangedExternally")

    init(planReader: PlanReading, planWriter: PlanWriting, calendarStore: CalendarStore,
         projection: ProjectionService, startedDays: StartedDayStore? = nil,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now },
         calendarAuthorized: @escaping () -> Bool = { EKEventStore.authorizationStatus(for: .event) == .fullAccess },
         deletionPolicy: @escaping () -> ReconcileDeletionPolicy = { ReconcileSettings.deletionPolicy },
         additionPolicy: @escaping () -> ReconcileAdditionPolicy = { ReconcileSettings.additionPolicy }) {
        self.planReader = planReader
        self.planWriter = planWriter
        self.calendarStore = calendarStore
        self.projection = projection
        self.startedDays = startedDays
        self.defaults = defaults
        self.now = now
        self.calendarAuthorized = calendarAuthorized
        self.deletionPolicy = deletionPolicy
        self.additionPolicy = additionPolicy
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

    /// 扫描范围（P4.0-5/6）：逻辑昨天 4:00 … 逻辑今天+8 天的日界。只有 今天…+7 天 会被对账/重画，
    /// 两端各多读一天只用来按章配对（拖到昨天/第 8 天不被当成删除）。
    static func scanWindow(now: Date) -> DateInterval {
        let lo = DayContext.logicalWindow(forLabel: DayContext.logicalDay(offset: -1, from: now)).start
        let hi = DayContext.logicalWindow(forLabel: DayContext.logicalDay(offset: 8, from: now)).end
        return DateInterval(start: lo, end: max(lo, hi))
    }

    /// 对账 逻辑今天…+7 天（与启动对账同窗）；实时模式（已开始）的日子跳过（橙色归执行层）。
    func reconcileWindow() async {
        guard calendarAuthorized() else { return }
        let events: [CalendarEventDraft]
        do { events = try await readScan() }
        catch { DataSyncMonitor.shared.report("日历读取失败，已停止对账：\(error.localizedDescription)"); return }
        let owners = truthOwners()
        for offset in 0..<8 {
            let label = DayContext.logicalDay(offset: offset, from: now())
            if startedDays?.isStarted(label) ?? false { continue }
            await reconcile(label: label, allGreenEvents: events, owners: owners)
        }
    }

    /// 启动同步（App 打开时调，取代直接投影）：先对账（把日历里攒的手改/新建/删除都识别出来），
    /// 再投影补章自愈——**跳过有待确认新建的日子**（先投影会把用户新建的事件当无主清掉，问都没问）。
    func startupSync() async {
        guard calendarAuthorized() else { return }
        await reconcileWindow()
        // Startup is read/reconcile only: CloudKit, KVS and EventKit have no shared arrival barrier.
        // Blanket projection here could erase another device's changes before local import completes.
        // Explicit plan confirmation and verified three-way differences own projection writes.
    }

    private func readScan() async throws -> [CalendarEventDraft] {
        let scan = Self.scanWindow(now: now())
        return try await calendarStore.read(kind: .planned, in: scan).filter { scan.contains($0.start) }
    }

    /// 扫描范围内每个计划块归哪个逻辑日（P4.0-6 跨天配对用）。
    private func truthOwners() -> [UUID: Date] {
        var owners: [UUID: Date] = [:]
        for offset in -1..<9 {
            let label = DayContext.logicalDay(offset: offset, from: now())
            for b in (try? planReader.plannedBlocks(on: label)) ?? [] { owners[b.id] = label }
        }
        return owners
    }

    private func reconcile(label: Date, allGreenEvents: [CalendarEventDraft], owners: [UUID: Date],
                           isRetry: Bool = false) async {
        let window = DayContext.logicalWindow(forLabel: label)
        let deletedIDs: Set<UUID>
        let truth: [ScheduledBlock]
        do {
            deletedIDs = try planReader.deletedPlannedIDs(on: label)
            truth = try planReader.plannedBlocks(on: label)
        } catch { DataSyncMonitor.shared.report("计划读取失败，已停止对账：\(error.localizedDescription)"); return }
        let truthIDs = Set(truth.map(\.id))
        let events = allGreenEvents.filter {
            window.contains($0.start) && !($0.blockID.map { deletedIDs.contains($0) } ?? false)
        }
        // 跨天配对（P4.0-6）：本日的块出现在扫描范围里的别的日子 = 被拖过去了（不是删除）。
        // 但那份若正是我们自己画在那天的旧画面（与那天的指纹一致），不算你的改动。
        var fpCache: [Date: [String: String]] = [:]
        let elsewhere = allGreenEvents.filter { e in
            guard !window.contains(e.start), let bid = e.blockID, truthIDs.contains(bid) else { return false }
            let day = DayContext.logicalStartOfDay(e.start)
            let dayPrints = fpCache[day] ?? ProjectionFingerprints.get(day, defaults: defaults)
            fpCache[day] = dayPrints
            return dayPrints[bid.uuidString] != Self.tuple(e)
        }
        let ownedElsewhere = Set(owners.filter { $0.value != label }.keys).subtracting(truthIDs)
        let fp = ProjectionFingerprints.get(label, defaults: defaults)
        var plan = Self.diff(truth: truth, events: events, fingerprint: fp,
                             elsewhere: elsewhere, ownedElsewhere: ownedElsewhere)
        // 你选过「忽略」的日历新建：不再询问（事件本身永远留在日历里）
        let ignored = ignoredAdditionKeys()
        plan.additions.removeAll { ignored.contains(CalendarSyncPlanner.claimKey($0.title, $0.start)) }
        if !plan.conflicts.isEmpty {
            // P4.0-4：只挂起判不清的那几块（画面原样保留、等核对），同一天别的改动照常处理
            DataSyncMonitor.shared.report("日历与数据库有 \(plan.conflicts.count) 项不同且缺少共同版本，这几项已保留两侧内容、等待核对；其他改动照常同步。")
        }

        // E5b 竞态加固：事件快照读于 8 日循环之前，循环期间 Coordinator 可能已写真相+投影
        // （指纹同步更新）——「旧事件 × 新真相 × 新指纹」会被误判成用户手改、把旧时间倒灌回真相。
        // 判到回流时先重读该日事件再核一遍（只在真有 updates 时多读一次，代价极小）。
        if !isRetry, !plan.updates.isEmpty {
            let fresh: [CalendarEventDraft]
            do { fresh = try await readScan() }
            catch { DataSyncMonitor.shared.report("日历复核失败，保持原数据：\(error.localizedDescription)"); return }
            await reconcile(label: label, allGreenEvents: fresh, owners: owners, isRetry: true)
            return
        }

        let today = DayContext.logicalDay(offset: 0, from: now())
        let thisLabel = Calendar.current.startOfDay(for: label)
        var touchedLabels: Set<Date> = []
        var adopting: Set<UUID> = []
        for u in plan.updates {
            try? planWriter.updatePlanned(id: u.id, start: u.start, end: u.end, title: u.title, reason: .calendarReconcile)
            touchedLabels.insert(thisLabel)
            touchedLabels.insert(DayContext.logicalStartOfDay(u.start))   // 拖去别的日子 → 新桶也要重投影
            DevLog.shared.info("对账", "日历手改回流：「\(u.title)」")
        }
        // 回流改了真相 → 通知界面刷新（排日程页无未保存修改时重新加载，0.22.2 Jason 报"改了不实时"）；
        // E5b：带上回流块 id → TimelineCoordinator 手改冷却（D12 用户最后动作赢）
        if !plan.updates.isEmpty {
            NotificationCenter.default.post(name: Self.planChangedExternally, object: nil,
                                            userInfo: ["updatedIDs": plan.updates.map(\.id),
                                                       "source": PlanChangeSource.calendarReconcile])
        }
        if !plan.deletions.isEmpty {
            switch deletionPolicy() {
            case .alwaysDelete:
                try? planWriter.deletePlanned(ids: plan.deletions.map(\.id), reason: .calendarReconcile)
                touchedLabels.insert(thisLabel)
                DevLog.shared.info("对账", "日历删除已同步移除 \(plan.deletions.count) 块（策略=直接移除）")
            case .neverDelete:
                touchedLabels.insert(thisLabel)   // 重投影=画回
                DevLog.shared.info("对账", "日历删除 \(plan.deletions.count) 块 → 按策略保留（画回）")
            case .ask:
                for d in plan.deletions where !pendingDeletions.contains(where: { $0.id == d.id }) {
                    pendingDeletions.append(PendingDeletion(id: d.id, title: d.title, label: label))
                }
            }
        }
        // 日历里新建的无章事件（0.20.2）：按策略 加进计划（认领补章）/ 忽略（记住，不再问）/ 询问
        if !plan.additions.isEmpty {
            switch additionPolicy() {
            case .alwaysAdd:
                let blocks = plan.additions.map { ScheduledBlock(title: $0.title, start: $0.start, end: $0.end) }
                try? planWriter.insertPlanned(blocks, reason: .calendarReconcile)
                adopting.formUnion(blocks.map(\.id))
                touchedLabels.insert(thisLabel)   // 投影认领盖章（只认领这几件）
                DevLog.shared.info("对账", "日历新建 \(plan.additions.count) 件已加进计划（策略=自动添加）")
            case .ignore:
                rememberIgnored(plan.additions.map { ($0.title, $0.start) })
            case .ask:
                for e in plan.additions {
                    let key = CalendarSyncPlanner.claimKey(e.title, e.start)
                    if !pendingAdditions.contains(where: { $0.key == key }) {
                        pendingAdditions.append(PendingAddition(key: key, title: e.title,
                                                                start: e.start, end: e.end, label: label))
                    }
                }
            }
        }
        if plan.needsRepaint { touchedLabels.insert(thisLabel) }
        // 有待确认改动的日子先不重画（等你选完再按真相源收敛）；过去的日子不重画（不审计历史）
        let holdLabels = Set((pendingAdditions.map(\.label) + pendingDeletions.map(\.label)).map { Calendar.current.startOfDay(for: $0) })
        for l in touchedLabels where !holdLabels.contains(l) && l >= today {
            let holding = l == thisLabel ? Set(plan.conflicts) : []
            try? await projection.project(label: l, holding: holding, adopting: l == thisLabel ? adopting : [])
        }
    }

    /// 用户对「日历改动」对话框的选择（删除+新建合并结算，0.20.2）。
    /// sync=true：删除照删、新建入库（认领补章）；sync=false：删的画回、新建的记住不再问（事件留在日历里）。
    /// remember=记住：只对**本批出现过的类别**写设置（没出现的类别不动）。
    /// **同步入口**：快照并清空挂起必须在按钮动作里立即发生——对话框 dismiss 回调会紧跟着触发
    /// "无选择=保留一次"的兜底，异步清空会造成二次结算。
    func resolveChanges(sync: Bool, remember: Bool) {
        guard let work = takeResolution(sync: sync, remember: remember) else { return }
        Task { [weak self] in await self?.apply(work) }
    }

    /// 同上，但等结算落地（测试/串行调用用；生产对话框走 resolveChanges）。
    func resolveChangesAndWait(sync: Bool, remember: Bool) async {
        guard let work = takeResolution(sync: sync, remember: remember) else { return }
        await apply(work)
    }

    private struct Resolution { let sync: Bool; let dels: [PendingDeletion]; let adds: [PendingAddition] }

    /// 同步部分：快照并清空挂起、写「记住」设置、记下被忽略的新建。
    private func takeResolution(sync: Bool, remember: Bool) -> Resolution? {
        let dels = pendingDeletions
        let adds = pendingAdditions
        pendingDeletions = []
        pendingAdditions = []
        guard !dels.isEmpty || !adds.isEmpty else { return nil }
        if remember {
            if !dels.isEmpty { ReconcileSettings.deletionPolicy = sync ? .alwaysDelete : .neverDelete }
            if !adds.isEmpty { ReconcileSettings.additionPolicy = sync ? .alwaysAdd : .ignore }
        }
        if !sync { rememberIgnored(adds.map { ($0.title, $0.start) }) }
        return Resolution(sync: sync, dels: dels, adds: adds)
    }

    private func apply(_ r: Resolution) async {
        var adopting: Set<UUID> = []
        if r.sync {
            if !r.dels.isEmpty { try? planWriter.deletePlanned(ids: r.dels.map(\.id), reason: .calendarReconcile) }
            if !r.adds.isEmpty {
                let blocks = r.adds.map { ScheduledBlock(title: $0.title, start: $0.start, end: $0.end) }
                try? planWriter.insertPlanned(blocks, reason: .calendarReconcile)
                adopting = Set(blocks.map(\.id))
            }
        }
        // 同步/保留 两条路都以真相源重画收敛：删的清残留或画回；新建的被认领盖章（保留则原样留在日历里）。
        let labels = Set((r.dels.map(\.label) + r.adds.map(\.label)).map { Calendar.current.startOfDay(for: $0) })
        for label in labels { try? await projection.project(label: label, adopting: adopting) }
        DevLog.shared.info("对账", r.sync
            ? "已同步日历改动：移除 \(r.dels.count) · 新增 \(r.adds.count)"
            : "已保留现状：画回 \(r.dels.count) · 新建 \(r.adds.count) 件留在日历里、不再询问")
    }

    // MARK: - 已忽略的日历新建（P4.0-1 配套：无章事件不再被清除，「忽略」必须记住，否则每次日历变更都会再问）

    private static let ignoredKey = "reconcile.ignoredAdditions"

    private func ignoredAdditionKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.ignoredKey) ?? [])
    }

    private func rememberIgnored(_ items: [(title: String, start: Date)]) {
        guard !items.isEmpty else { return }
        var keys = ignoredAdditionKeys()
        for i in items { keys.insert(CalendarSyncPlanner.claimKey(i.title, i.start)) }
        // 只留 30 天内的（键尾是起始分钟）；存成 Array（UserDefaults 只收 plist 类型）
        let floor = Int(now().addingTimeInterval(-30 * 24 * 3600).timeIntervalSinceReferenceDate / 60)
        let kept = keys.filter { k in Int(k.split(separator: "#").last ?? "").map { $0 >= floor } ?? false }
        defaults.set(kept.sorted(), forKey: Self.ignoredKey)
    }

    // MARK: - 纯函数 diff（可单测）

    struct Update: Equatable { let id: UUID; let start: Date; let end: Date; let title: String }
    struct Deletion: Equatable { let id: UUID; let title: String }
    struct DiffPlan {
        var updates: [Update] = []
        var deletions: [Deletion] = []
        var additions: [CalendarEventDraft] = []   // 日历里新建的无章事件 → 按策略 加/清/问（0.20.2）
        var conflicts: [UUID] = []
        var needsRepaint = false   // 带章但真相没有/缺投影 → 让投影按真相源重画
    }

    /// 真相 × 日历事件 × 指纹 → 行动清单。
    /// - 事件在、与真相一致 → 无事。
    /// - 事件在、与真相不同：与指纹一致=没人动过日历（是真相变了没投影）→ 重画；
    ///   与指纹不同、且指纹=真相 = 用户手改 → 回流（时间+标题）；两边都变/缺共同版本 → 冲突（只挂起这一块）。
    /// - 事件不在本日：在扫描范围别的日子找到（elsewhere）= 被拖过去了 → 同上判定（P4.0-6）；
    ///   哪都没有：指纹里有 = 我们写过、被用户删了 → 删除候选；指纹里没有 = 从没投影过 → 重画。
    /// - 同章多份（P4.0-2，不再「最后一个赢」）：有一份与真相一致 → 一致（投影按确定性规则去重）；
    ///   各份内容都相同 → 按那份判定；各份内容不同 → 冲突（判不清，不猜）。
    /// - 无章事件 = 用户在日历里新建 → additions（按策略处理，绝不删除）。
    /// - ownedElsewhere：属于扫描范围里别的日子的块（被拖进本日，由它所属那天处理）——本日不为它重画。
    static func diff(truth: [ScheduledBlock], events: [CalendarEventDraft],
                     fingerprint: [String: String], elsewhere: [CalendarEventDraft] = [],
                     ownedElsewhere: Set<UUID> = []) -> DiffPlan {
        var plan = DiffPlan()
        var copies: [UUID: [CalendarEventDraft]] = [:]
        for e in events {
            if let bid = e.blockID { copies[bid, default: []].append(e) } else { plan.additions.append(e) }
        }
        var away: [UUID: [CalendarEventDraft]] = [:]
        for e in elsewhere { if let bid = e.blockID { away[bid, default: []].append(e) } }
        let truthIDs = Set(truth.map(\.id))
        for (bid, list) in copies where !truthIDs.contains(bid) {
            if ownedElsewhere.contains(bid) {
                // 别的日子的块落在本日：是我们自己画在这里的旧画面（与本日指纹一致）→ 重画清掉；否则是你拖来的，归原来那天处理
                if list.contains(where: { tuple($0) == fingerprint[bid.uuidString] }) { plan.needsRepaint = true }
            } else {
                plan.needsRepaint = true
            }
        }
        for b in truth {
            let key = b.id.uuidString
            let here = copies[b.id] ?? []
            let candidates = here.isEmpty ? (away[b.id] ?? []) : here
            guard !candidates.isEmpty else {
                if fingerprint[key] != nil {
                    plan.deletions.append(Deletion(id: b.id, title: b.title))   // 我们写过 → 用户删了
                } else {
                    plan.needsRepaint = true       // 从没投影过（失败/新设备）→ 补画，不是删除
                }
                continue
            }
            if here.count > 1 { plan.needsRepaint = true }   // 同章多份 → 投影按确定性规则收敛成一份
            let truthTuple = ProjectionFingerprints.tuple(start: b.start, end: b.end, title: b.title)
            let tuples = Set(candidates.map(tuple))
            if tuples.contains(truthTuple) { continue }
            guard tuples.count == 1, let e = CalendarSyncPlanner.keeper(candidates) else {
                plan.conflicts.append(b.id)   // 多份内容各不相同：判不清，不猜
                continue
            }
            let evTuple = tuple(e)
            if evTuple == fingerprint[key] {
                plan.needsRepaint = true   // 日历没人动，是真相更新未投影 → 真相赢
            } else if fingerprint[key] == truthTuple {
                plan.updates.append(Update(id: b.id, start: e.start, end: e.end, title: e.title))
            } else {
                // No common base, or both channels changed: no reliable last-writer evidence.
                plan.conflicts.append(b.id)
            }
        }
        return plan
    }

    static func tuple(_ e: CalendarEventDraft) -> String {
        ProjectionFingerprints.tuple(start: e.start, end: e.end, title: e.title)
    }
}
