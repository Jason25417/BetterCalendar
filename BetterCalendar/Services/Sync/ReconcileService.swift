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
//  4. 删除（P4 Q3，2026-10-18 Jason 认可）：你在苹果日历里删了 BetterCalendar 的块 → **立即照办**：
//     从时间线移走、收进待办区可找回，并发桥接事件 calendar_user_deleted 让智能体按上下文决定要不要问一句。
//     不再弹窗四选（旧删除/新建策略与「记住选择」一并退役）。保护：同一天一半以上同时不见 → 先等一轮再照办。
//     日历里**新建**的无章事件 = 你的事件（原则 8）：不复制成计划块，只当「已占用」读取（P4 Q4）。
//  5. 对账窗口 = 逻辑今天…+7 天；过去永远不动（不审计历史）。读日历按扫描范围 逻辑昨天…+8 天
//     （P4.0-5/6：按章在全范围配对，拖到别的日子=改时间，不是删除）。
//  6. 判不清的块只挂起那一块（P4.0-4），同一天别的改动照常；同章多份按确定性规则取（P4.0-2）。
//  7. 章 v2（P4 Q7/Q8）：事件自证「写后有没有被动过」+ 版本比较，跨设备不靠本机记忆；旧章退回本机指纹。
//     开工的日子照常对账（Q2：绿色不再清空）；你在日历里改过时间的块 = 图钉（Q6，当天有效）。
//  措辞铁律：对话文案中性前向（"日历里移除了 N 件"），绝不审计式（"你删了"）。
//

import Foundation
import Observation
import EventKit

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

    /// 对账确认「日历上这块与真相一致」时把它记进本机指纹（P4：另一台设备画的、本机看到过的也算「画过」——
    /// 之后它在本机日历里消失才认得出是被你删了，而不是又给它补画回去）。
    static func merge(_ label: Date, _ seen: [String: String], defaults: UserDefaults = .standard, now: Date = .now) {
        guard !seen.isEmpty else { return }
        var all = defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        let written = dayKey(label)
        var day = all[written] ?? [:]
        var changed = false
        for (k, v) in seen where day[k] != v { day[k] = v; changed = true }
        guard changed else { return }
        all[written] = day
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

/// 你在苹果日历里删掉的一块（P4 Q3）：已照办，交给桥接写 calendar_user_deleted 事件。
struct CalendarUserDeletion: Sendable {
    let block: ScheduledBlock
    let label: Date
    /// 收进了待办区（可找回）；正在做的块只是把计划剩下那段删了（trimmedLive），不收待办。
    let collectedToTodo: Bool
    let trimmedLive: Bool
    let detectedAt: Date
    /// 发现删除的设备（nil = 本机；中继转交另一台设备的回执时 = 那台设备的名字）。
    var detectedBy: String? = nil
}

@MainActor
@Observable
final class ReconcileService {
    private let planReader: PlanReading
    private let planWriter: PlanWriting      // 显式授权：对账是 confirm 之外的计划写者之一（权限表在案）
    /// 只读角色（P4.1）：对账是日历同步引擎的「入站半边」——只读日历、只改真相，所有重画回到引擎（唯一写者）。
    private let calendarStore: CalendarReading
    private let projection: CalendarSyncEngine
    /// 指纹所在的库（注入=测试不污染真实 UserDefaults）；须与 ProjectionService 同一个。
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendarAuthorized: () -> Bool
    private var listenTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    /// 大面积删除保护（设计稿 §4.6）：同一天一半以上同时不见 → 第一次只记下、等下一轮（≥2 分钟后）仍不见才照办。
    private var massHold: [Date: (ids: Set<UUID>, since: Date)] = [:]
    static let massDeletionWait: TimeInterval = 120

    /// Q3：删掉的块收进待办区（组装点接 LongTaskStore.addTodo）。返回 true = 收进去了。
    var collectTodo: ((ScheduledBlock, Date) -> Bool)?
    /// Q3：照办之后通知（组装点接智能体桥接 calendar_user_deleted；只有 Mac 接）。
    var onUserDeleted: (([CalendarUserDeletion]) -> Void)?
    /// 写进删除回执的本机名（线索，给智能体看）。测试可改。
    var deviceLabel: String = ProposalDevice.label

    /// 给你看的一句话（不是错误）：BetterCalendar 自家日历里有你的事件——建议挪走（P4 Q1：预览日历退役后尤其）。
    private(set) var calendarNotice: String?
    private var previewForeign: [CalendarEventDraft] = []
    private var greenForeignCount = 0
    func dismissCalendarNotice() { calendarNotice = nil; noticeDismissedKey = noticeKey }
    private var noticeKey = ""
    private var noticeDismissedKey: String {
        get { defaults.string(forKey: "reconcile.noticeDismissed") ?? "" }
        set { defaults.set(newValue, forKey: "reconcile.noticeDismissed") }
    }

    /// 对账把日历手改回流进真相后发出（排日程页借此即时刷新，不用等重新进页）。
    /// userInfo["source"] 标来源（PlanChangeSource）；时间线协调器据此区分外部变更与本机回声（B10）。
    static let planChangedExternally = Notification.Name("bc.planChangedExternally")

    init(planReader: PlanReading, planWriter: PlanWriting, calendarStore: CalendarReading,
         projection: CalendarSyncEngine,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now },
         calendarAuthorized: @escaping () -> Bool = { EKEventStore.authorizationStatus(for: .event) == .fullAccess }) {
        self.planReader = planReader
        self.planWriter = planWriter
        self.calendarStore = calendarStore
        self.projection = projection
        self.defaults = defaults
        self.now = now
        self.calendarAuthorized = calendarAuthorized
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

    /// 对账 逻辑今天…+7 天（与启动对账同窗）。P4 Q2：开工的日子不再跳过（绿色一直在，你在日历里的改动照样认）。
    func reconcileWindow() async {
        guard calendarAuthorized() else { return }
        let events: [CalendarEventDraft]
        do { events = try await readScan() }
        catch { DataSyncMonitor.shared.report("日历读取失败，已停止对账：\(error.localizedDescription)"); return }
        let owners = truthOwners()
        for offset in 0..<8 {
            let label = DayContext.logicalDay(offset: offset, from: now())
            await reconcile(label: label, allGreenEvents: events, owners: owners)
        }
        greenForeignCount = events.filter { $0.blockID == nil }.count
        refreshNotice()
    }

    /// 启动同步（App 打开时调）：先清扫退役的橙色预览日历（只删带章、不删日历），再对账。
    func startupSync() async {
        guard calendarAuthorized() else { return }
        if let r = await projection.retirePreviewCalendar() { previewForeign = r.foreignRemaining }
        await reconcileWindow()
        // Startup is read/reconcile only: CloudKit, KVS and EventKit have no shared arrival barrier.
        // Blanket projection here could erase another device's changes before local import completes.
        // Explicit plan confirmation and verified three-way differences own projection writes.
    }

    private func refreshNotice() {
        var parts: [String] = []
        if !previewForeign.isEmpty {
            let names = Array(Set(previewForeign.map(\.title))).sorted().prefix(3).joined(separator: "、")
            parts.append("「BetterCalendar · 预览」这本日历已经退役，但里面还有 \(previewForeign.count) 个你的事件（如 \(names)）")
        }
        if greenForeignCount > 0 {
            parts.append("「BetterCalendar · 计划」日历里有 \(greenForeignCount) 个不是 BetterCalendar 写的事件")
        }
        guard !parts.isEmpty else { calendarNotice = nil; return }
        let key = "\(previewForeign.count)|\(greenForeignCount)"
        noticeKey = key
        calendarNotice = noticeDismissedKey == key ? nil
            : parts.joined(separator: "；") + "。BetterCalendar 不会删改它们，只当作你的安排来读；建议在系统日历里把它们挪到你自己的日历。"
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
        // 但那份若正是我们自己画在那天的旧画面（与那天的指纹一致 / v2 章写后没被动过），不算你的改动。
        var fpCache: [Date: [String: String]] = [:]
        let elsewhere = allGreenEvents.filter { e in
            guard !window.contains(e.start), let bid = e.blockID, truthIDs.contains(bid) else { return false }
            if let untouched = e.isUntouchedSinceStamped { return !untouched }
            let day = DayContext.logicalStartOfDay(e.start)
            let dayPrints = fpCache[day] ?? ProjectionFingerprints.get(day, defaults: defaults)
            fpCache[day] = dayPrints
            return dayPrints[bid.uuidString] != Self.tuple(e)
        }
        let ownedElsewhere = Set(owners.filter { $0.value != label }.keys).subtracting(truthIDs)
        let fp = ProjectionFingerprints.get(label, defaults: defaults)
        let pres = await projection.presentation(label: label, blocks: truth)
        var shown = pres.drawn.reduce(into: [UUID: (start: Date, end: Date, clipped: Bool)]()) {
            $0[$1.block.id] = ($1.start, $1.end, $1.clipped)
        }
        // 作者宽限中的块（另一台设备刚写、本机还没画）：照完整计划比对，但「日历里没有」不算删除
        var graced: Set<UUID> = []
        for b in truth where shown[b.id] == nil && pres.hidden[b.id] == nil {
            shown[b.id] = (b.start, b.end, false); graced.insert(b.id)
        }
        for b in truth where shown[b.id] != nil && !graced.contains(b.id) {
            if let w = b.syncWriter, w != (planWriter as? PlanStore)?.writerID, projection.isFresh(b.syncVersion) { graced.insert(b.id) }
        }
        let plan = Self.diff(truth: truth, shown: shown.mapValues { ($0.start, $0.end) },
                             hidden: Set(pres.hidden.keys), graced: graced,
                             events: events, fingerprint: fp,
                             elsewhere: elsewhere, ownedElsewhere: ownedElsewhere,
                             isNewerElsewhere: { [projection] e, b in projection.isNewerElsewhere(e, than: b) })
        if !plan.conflicts.isEmpty {
            // P4.0-4：只挂起判不清的那几块（画面原样保留、等核对），同一天别的改动照常处理
            DataSyncMonitor.shared.report("日历与数据库有 \(plan.conflicts.count) 项不同且缺少共同版本，这几项已保留两侧内容、等待核对；其他改动照常同步。")
        }

        // E5b 竞态加固：事件快照读于 8 日循环之前，循环期间 Coordinator 可能已写真相+投影
        // （指纹同步更新）——「旧事件 × 新真相 × 新指纹」会被误判成用户手改、把旧时间倒灌回真相。
        // 判到回流或删除时先重读该日事件再核一遍（只在真有改动时多读一次，代价极小）。
        if !isRetry, !plan.updates.isEmpty || !plan.deletions.isEmpty {
            let fresh: [CalendarEventDraft]
            do { fresh = try await readScan() }
            catch { DataSyncMonitor.shared.report("日历复核失败，保持原数据：\(error.localizedDescription)"); return }
            await reconcile(label: label, allGreenEvents: fresh, owners: owners, isRetry: true)
            return
        }
        ProjectionFingerprints.merge(label, plan.seen, defaults: defaults, now: now())

        let today = DayContext.logicalDay(offset: 0, from: now())
        let thisLabel = Calendar.current.startOfDay(for: label)
        var touchedLabels: Set<Date> = []
        let byID = Dictionary(truth.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changedIDs: [UUID] = []
        for u in plan.updates {
            guard let b = byID[u.id] else { continue }
            // 正在做的块只画了剩下那段：你改的是结束与标题，开始以真相（实际开始）为准
            let start = (shown[u.id]?.clipped ?? false) ? b.start : u.start
            do {
                try planWriter.updatePlanned(id: u.id, start: start, end: u.end, title: u.title, reason: .calendarReconcile)
                if start != b.start || u.end != b.end {
                    // Q6：你亲手改过时间 = 图钉（当天有效），自动调整从此绕开它
                    try planWriter.setPinned(ids: [u.id], until: ScheduledBlock.pinExpiry(forStart: start))
                }
            } catch {
                DevLog.shared.error("对账", "日历手改回流失败「\(u.title)」：\(error.localizedDescription)")
                continue
            }
            changedIDs.append(u.id)
            touchedLabels.insert(thisLabel)
            touchedLabels.insert(DayContext.logicalStartOfDay(start))   // 拖去别的日子 → 新桶也要重投影
            DevLog.shared.info("对账", "日历手改回流：「\(u.title)」" + (start != b.start || u.end != b.end ? "（已钉住，当天自动调整不再挪它）" : ""))
        }
        var deletions: [CalendarUserDeletion] = []
        if !plan.deletions.isEmpty {
            let ids = Set(plan.deletions.map(\.id))
            if Self.isMassDeletion(count: ids.count, drawn: pres.drawn.count),
               !(massHold[thisLabel].map { $0.ids == ids && now().timeIntervalSince($0.since) >= Self.massDeletionWait } ?? false) {
                if massHold[thisLabel]?.ids != ids { massHold[thisLabel] = (ids, now()) }
                DataSyncMonitor.shared.report("日历里同一天有 \(ids.count) 件同时不见了，先等两分钟确认不是同步延迟，再照日历移走（收进待办区）。")
            } else {
                massHold[thisLabel] = nil
                for d in plan.deletions {
                    guard let b = byID[d.id] else { continue }
                    if let s = shown[d.id], s.clipped {
                        // 正在做：你删的是计划剩下那段 → 计划到此为止（不删这件事、不收待办）
                        do {
                            try planWriter.updatePlanned(id: d.id, start: b.start, end: s.start, title: b.title, reason: .calendarReconcile)
                            try planWriter.setPinned(ids: [d.id], until: ScheduledBlock.pinExpiry(forStart: b.start))
                        } catch { DevLog.shared.error("对账", "「\(b.title)」计划收尾失败：\(error.localizedDescription)"); continue }
                        changedIDs.append(d.id)
                        deletions.append(.init(block: b, label: thisLabel, collectedToTodo: false, trimmedLive: true, detectedAt: now()))
                        DevLog.shared.info("对账", "日历里移出了「\(b.title)」剩下的计划：这件照常在做，计划到此为止")
                    } else {
                        do { try planWriter.deletePlanned(ids: [d.id], reason: .calendarReconcile) }
                        catch { DevLog.shared.error("对账", "照日历移走「\(b.title)」失败：\(error.localizedDescription)"); continue }
                        let collected = collectTodo?(b, thisLabel) ?? false
                        if collectTodo != nil, !collected { DevLog.shared.warn("对账", "「\(b.title)」已从时间线移走，但没能收进待办区（可在回收站找回）") }
                        // P4.1：回执写进被删的那一行（随 iCloud 同步）——iPhone 先发现时，Mac 据此把事件转交给智能体
                        do {
                            try planWriter.recordCalendarDeletion(id: d.id, receipt: CalendarDeletionReceipt(
                                detectedAt: now(), detectedBy: deviceLabel, collectedToTodo: collected))
                        } catch {
                            DevLog.shared.warn("对账", "「\(b.title)」的删除回执没写上（另一台设备的智能体可能收不到这次删除）：\(error.localizedDescription)")
                        }
                        deletions.append(.init(block: b, label: thisLabel, collectedToTodo: collected, trimmedLive: false, detectedAt: now()))
                        DevLog.shared.info("对账", "「\(b.title)」从日历移出，已从时间线移走" + (collected ? "、收进待办区" : ""))
                    }
                    touchedLabels.insert(thisLabel)
                }
            }
        } else {
            massHold[thisLabel] = nil
        }
        // 回流改了真相 → 通知界面刷新（排日程页无未保存修改时重新加载，0.22.2 Jason 报"改了不实时"）；
        // E5b：带上回流块 id → TimelineCoordinator 手改冷却（D12 用户最后动作赢）
        if !changedIDs.isEmpty || !deletions.isEmpty {
            NotificationCenter.default.post(name: Self.planChangedExternally, object: nil,
                                            userInfo: ["updatedIDs": changedIDs,
                                                       "source": PlanChangeSource.calendarReconcile])
        }
        if !deletions.isEmpty { onUserDeleted?(deletions) }
        if plan.needsRepaint { touchedLabels.insert(thisLabel) }
        // 过去的日子不重画（不审计历史）
        for l in touchedLabels where l >= today {
            let holding = l == thisLabel ? Set(plan.conflicts) : []
            do { try await projection.project(label: l, holding: holding) }
            catch { DevLog.shared.warn("对账", "重画 \(DayContext.dayKey(l)) 失败：\(error.localizedDescription)") }
        }
    }

    /// 同一天一半以上（且至少 3 件）同时不见 = 像通道错序，不像你一件件删的。
    nonisolated static func isMassDeletion(count: Int, drawn: Int) -> Bool {
        count >= 3 && count * 2 > drawn
    }

    // MARK: - 纯函数 diff（可单测）

    struct Update: Equatable { let id: UUID; let start: Date; let end: Date; let title: String }
    struct Deletion: Equatable { let id: UUID; let title: String }
    struct DiffPlan {
        var updates: [Update] = []
        var deletions: [Deletion] = []
        /// 日历里新建的无章事件 = 你的事件（只读：当「已占用」，不复制、不删）。
        var foreign: [CalendarEventDraft] = []
        var conflicts: [UUID] = []
        var needsRepaint = false   // 带章但真相没有/缺投影/画面旧了 → 让投影按真相源重画
        /// 与真相一致的画面（记进本机指纹：以后它消失才认得出是被你删了）。
        var seen: [String: String] = [:]
    }

    /// 真相 × 日历事件 → 行动清单。shown = 每块此刻**该画成什么样**（两色规则后的起止）；hidden = 不该画的块。
    /// - 事件在、与该画的一致 → 无事（记进 seen）。
    /// - 章比本机真相新（另一台设备刚写、本机数据未到，宽限内）→ 等，不重画也不采纳。
    /// - 章 v2（事件自证）：写后没被动过 = 我们画的旧画面 → 重画；被动过 = 你在日历里改了：
    ///   版本相同 → 采纳；真相在那之后也变了 → 那次变动是自动调整的 → 你赢；也是你的操作 → 后改的赢（看事件修改时间），判不出 → 冲突。
    /// - 旧章（无 v2）：与指纹一致=没人动过（是真相变了没投影）→ 重画；指纹=真相 = 你手改 → 回流；两边都变/缺共同版本 → 冲突。
    /// - 事件不在本日：在扫描范围别的日子找到（elsewhere）= 被拖过去了 → 同上判定（P4.0-6）；
    ///   哪都没有：画过（指纹里有）= 被你删了 → 删除；没画过 / 宽限中 → 补画 / 等。
    /// - 同章多份（P4.0-2）：有一份一致 → 一致（投影按确定性规则去重）；各份内容相同 → 按那份判定；不同 → 冲突。
    /// - ownedElsewhere：属于扫描范围里别的日子的块（被拖进本日，由它所属那天处理）——本日不为它重画。
    static func diff(truth: [ScheduledBlock], events: [CalendarEventDraft],
                     fingerprint: [String: String], elsewhere: [CalendarEventDraft] = [],
                     ownedElsewhere: Set<UUID> = []) -> DiffPlan {
        diff(truth: truth, shown: Dictionary(truth.map { ($0.id, ($0.start, $0.end)) }, uniquingKeysWith: { a, _ in a }),
             hidden: [], graced: [], events: events, fingerprint: fingerprint,
             elsewhere: elsewhere, ownedElsewhere: ownedElsewhere, isNewerElsewhere: { _, _ in false })
    }

    static func diff(truth: [ScheduledBlock], shown: [UUID: (start: Date, end: Date)], hidden: Set<UUID>,
                     graced: Set<UUID>, events: [CalendarEventDraft],
                     fingerprint: [String: String], elsewhere: [CalendarEventDraft],
                     ownedElsewhere: Set<UUID>,
                     isNewerElsewhere: (CalendarEventDraft, ScheduledBlock) -> Bool) -> DiffPlan {
        var plan = DiffPlan()
        var copies: [UUID: [CalendarEventDraft]] = [:]
        for e in events {
            if let bid = e.blockID { copies[bid, default: []].append(e) } else { plan.foreign.append(e) }
        }
        var away: [UUID: [CalendarEventDraft]] = [:]
        for e in elsewhere { if let bid = e.blockID { away[bid, default: []].append(e) } }
        let truthIDs = Set(truth.map(\.id))
        for (bid, list) in copies where !truthIDs.contains(bid) {
            if ownedElsewhere.contains(bid) {
                // 别的日子的块落在本日：是我们自己画在这里的旧画面（与本日指纹一致 / v2 写后没动过）→ 重画清掉；否则是你拖来的，归原来那天处理
                if list.contains(where: { $0.isUntouchedSinceStamped ?? (tuple($0) == fingerprint[bid.uuidString]) }) { plan.needsRepaint = true }
            } else {
                plan.needsRepaint = true
            }
        }
        for b in truth {
            let key = b.id.uuidString
            let here = copies[b.id] ?? []
            if hidden.contains(b.id) {
                // 不该画（做完了 / 关联了你的事件）：日历上还有就让投影收掉；没有不算删除
                if !here.isEmpty, !here.contains(where: { isNewerElsewhere($0, b) }) { plan.needsRepaint = true }
                continue
            }
            guard let target = shown[b.id] else { continue }
            let candidates = here.isEmpty ? (away[b.id] ?? []) : here
            guard !candidates.isEmpty else {
                if graced.contains(b.id) { continue }              // 另一台设备刚写、还没画：等它画
                if fingerprint[key] != nil {
                    plan.deletions.append(Deletion(id: b.id, title: b.title))   // 画过 → 被你删了
                } else {
                    plan.needsRepaint = true       // 从没投影过（失败/新设备）→ 补画，不是删除
                }
                continue
            }
            if here.count > 1 { plan.needsRepaint = true }   // 同章多份 → 投影按确定性规则收敛成一份
            let targetTuple = ProjectionFingerprints.tuple(start: target.start, end: target.end, title: b.title)
            let tuples = Set(candidates.map(tuple))
            if tuples.contains(targetTuple) {
                plan.seen[key] = targetTuple
                // 章过时（旧章 / 采纳你的改动后版本已升 / 指纹对不上内容）→ 重盖章：否则下次真相再变时会把这份旧内容误当成你的新改动
                if !here.isEmpty, !here.contains(where: { isNewerElsewhere($0, b) }),
                   here.contains(where: { $0.stampHash == nil || $0.isUntouchedSinceStamped == false || $0.stampVersion != b.syncVersion }) {
                    plan.needsRepaint = true
                }
                continue
            }
            if candidates.contains(where: { isNewerElsewhere($0, b) }) { continue }   // 另一台设备更新的画面：等本机真相
            guard tuples.count == 1, let e = CalendarSyncPlanner.keeper(candidates) else {
                plan.conflicts.append(b.id)   // 多份内容各不相同：判不清，不猜
                continue
            }
            let adopt = Update(id: b.id, start: e.start, end: e.end, title: e.title)
            if let untouched = e.isUntouchedSinceStamped, let ev = e.stampVersion {
                if untouched { plan.needsRepaint = true; continue }        // 我们画的旧画面 → 真相赢
                if ev == b.syncVersion { plan.updates.append(adopt); continue }   // 写后只有你动过 → 采纳
                if ev < b.syncVersion {
                    if !PlanWriteReason(stored: b.syncSource).isUsersOwn { plan.updates.append(adopt); continue }   // 你的操作 ＞ 自动调整
                    if let lm = e.lastModified {
                        let lmMs = Int64((lm.timeIntervalSince1970 * 1000).rounded())
                        if lmMs > b.syncVersion { plan.updates.append(adopt) } else { plan.needsRepaint = true }   // 两边都是你：后改的赢
                        continue
                    }
                }
                plan.conflicts.append(b.id)   // 判不出谁新：只挂起这一块
                continue
            }
            let evTuple = tuple(e)
            if evTuple == fingerprint[key] {
                plan.needsRepaint = true   // 日历没人动，是真相更新未投影 → 真相赢
            } else if fingerprint[key] == targetTuple {
                plan.updates.append(adopt)
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
