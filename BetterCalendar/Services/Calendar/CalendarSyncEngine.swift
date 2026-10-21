//
//  CalendarSyncEngine.swift
//  BetterCalendar
//
//  日历同步引擎（P4.1 单一写者，2026-10-19；前身 ProjectionService，2026-07-07 单一真相源投影）：
//  **PlanStore = 计划与实际的唯一真相；Apple 日历 = 画面**。BetterCalendar 自家日历（绿/蓝/退役的橙）的
//  **全 App 唯一写者就是本引擎**——只有它拿得到写角色 `CalendarProjecting`（类型系统落实，见 CalendarStore.swift；
//  架构守卫单测 `calendarWriteCapabilityStaysInEngine`）。其他模块只改 PlanStore，再请引擎刷新：
//  - 绿色计划：project(label:) / repaintToday / projectUpcomingWindow（下面「投影」）；
//  - 蓝色实际：recordActuals / restoreActual（下面「蓝色实际」；执行页、复盘补一笔、回收站恢复都走这里）；
//  - 橙色预览日历退役清扫：retirePreviewCalendar；
//  - 入站（你在日历里的改动 → 真相）：ReconcileService 是引擎的入站半边，只拿只读角色，所有重画回到本引擎。
//  - P4（SPEC §19.13，2026-10-18）两色流水线：
//    · 橙色预览日历退役（Q1）：不再写；带章的旧橙块一次性清扫（retirePreviewCalendar），日历本身不删，
//      里面你的无章事件原样留下、在 App 里提示你挪走；
//    · 一件事只画一次（Q2）：开工后不再清空绿色；做完的只剩蓝、正在做的只画剩下那段绿（GreenPresentation）；
//    · 你的课和会只关联不复制（Q4）：关联上的块不画绿（ExternalEventLinker）。
//  - 匹配按 blockID（事件 URL 章，随 iCloud 同步跨设备一致）；无章事件是你的，永不认领/删改（P4.0-1）。
//  - 章 v2（Q7/Q8，CalendarStamp）：每次写都带上计划块的版本与内容指纹；日历里的章比本机真相新
//    （另一台设备刚改、本机的计划数据还在 CloudKit 路上）→ 原样保留、不拿旧真相去盖；
//    作者宽限：别的设备刚写的块，本机先不替它新建事件（防两台各建一份）。
//  - 日历里的手改由 ReconcileService 按章回流；对账判不清的块经 holding 原样保留（P4.0-4）。
//  - 蓝色仍是「读回 ∪ 新增」合并写（CalendarMerge.union，只增改不删）：P4.1 这一步只把写入口收进引擎、行为不变；
//    改成「蓝色纯由 PlanStore 投影」（会删掉真相里没有的蓝块）留到跨设备实际同步验证之后（见 SPEC §19.14）。
//

import Foundation
import EventKit   // 仅查权限用（避免冷启动弹权限框），不在此直接读写事件

/// 旧名（P4.1 前）：保留别名，免得同批并行线（HomeView / ApprovedPlanMover 等）合并冲突；新代码一律写 CalendarSyncEngine。
typealias ProjectionService = CalendarSyncEngine

@MainActor
final class CalendarSyncEngine {
    private let planStore: PlanReading   // 只读角色：投影只读真相、只写画面（这就是它可随时安全重跑的原因）
    private let actuals: ActualReading?
    private let calendarStore: CalendarStore
    private let fingerprintDefaults: UserDefaults
    private let now: () -> Date
    /// 本机写者 id（作者宽限判「是不是别的设备刚写的」）。
    private let localWriter: String?
    private var followTask: Task<Void, Never>?
    private var followDebounce: Task<Void, Never>?

    /// 作者宽限 / 等待另一台设备的窗口（P4 Q8）：超过它还对不上，真相赢（防时钟偏差把两端都卡在「等待」）。
    static let authorGrace: TimeInterval = 10 * 60

    /// 0.72.1：本机的 iCloud 数据同步此刻可信吗（组装点接 `!DataSyncMonitor.shared.isTransportWedged`；测试注入）。
    /// 不可信 = 导出被服务器拒收、镜像停摆：本机真相可能落后另一台设备任意久（10-20 Mac 落后了 4 小时）。
    /// 这时「章比本机真相新」不再受 10 分钟宽限限制——宽限是给「数据还在路上」的，不是给「路断了」的；
    /// 否则过了宽限本机就拿旧真相把另一台设备的新画面盖回去（10-20 19:52 Mac 一次盖回 5 处），两端来回打架。
    var transportTrusted: () -> Bool = { true }

    init(planStore: PlanReading, calendarStore: CalendarStore, actuals: ActualReading? = nil,
         localWriter: String? = nil, fingerprintDefaults: UserDefaults = .standard,
         now: @escaping () -> Date = { .now }) {
        self.planStore = planStore
        self.actuals = actuals ?? (planStore as? ActualReading)
        self.calendarStore = calendarStore
        self.localWriter = localWriter ?? (planStore as? PlanStore)?.writerID
        self.fingerprintDefaults = fingerprintDefaults
        self.now = now
    }

    // MARK: - 呈现（投影与对账共用同一份规则）

    /// 某逻辑日的绿色该怎么画：两色规则 + 关联你的日历事件。读你的日历失败 → 不隐藏任何块（宁可多画一份）并记日志。
    func presentation(label: Date, blocks: [ScheduledBlock]) async -> GreenPresentation.Result {
        let window = DayContext.logicalWindow(forLabel: label)
        var byID: [UUID: ActualBlock] = [:]
        do {
            for a in try actuals?.actualBlocks(on: label) ?? [] { byID[a.id] = a }
        } catch {
            DevLog.shared.warn("投影", "读实际记录失败，绿色按完整计划画：\(error.localizedDescription)")
        }
        var linked: Set<UUID> = []
        do {
            let events = try await calendarStore.externalEvents(in: window)
            linked = Set(ExternalEventLinker.links(blocks: blocks, events: events).keys)
        } catch {
            DevLog.shared.warn("投影", "读你的日历失败，暂不按关联隐藏绿色：\(error.localizedDescription)")
        }
        return GreenPresentation.present(blocks: blocks, actuals: byID, linked: linked)
    }

    /// 版本时间戳是否还在宽限窗内（版本 = 写入时刻毫秒）。
    func isFresh(_ version: Int64) -> Bool {
        guard version > 0 else { return false }
        return now().timeIntervalSince1970 - Double(version) / 1000 < Self.authorGrace
    }

    /// 日历里这份是另一台设备写的、比本机真相新、还在宽限内 → 等本机真相到了再说（不拿旧真相去盖）。
    func isNewerElsewhere(_ e: CalendarEventDraft, than block: ScheduledBlock) -> Bool {
        guard let v = e.stampVersion else { return false }
        return v > block.syncVersion && (isFresh(v) || !transportTrusted())
    }

    // MARK: - 投影

    /// 把某逻辑日的 PlanStore 投影到日历。label = 逻辑日标签（该日零点）。
    /// 会前提醒规则收口在此：仅固定块（会议/外部承诺）挂 lead 提醒（原则4「仅固定块提醒」）。
    /// - holding（P4.0-4）：对账判不清的块（日历和真相都变了、缺共同版本）——画面原样保留、指纹不更新，
    ///   等核对；同一天别的块照常投影（此前是整天停摆）。
    func project(label: Date, restoring: ScheduledBlock? = nil, holding: Set<UUID> = []) async throws {
        let window = DayContext.logicalWindow(forLabel: label)
        var blocks = try planStore.plannedBlocks(on: label)
        if let restoring { blocks.append(restoring) }
        let deletedIDs = try planStore.deletedPlannedIDs(on: label)
        let fingerprint = ProjectionFingerprints.get(label, defaults: fingerprintDefaults)
        // ⚠️ 这里读日历不是把它当数据源（真相仍是 PlanStore），是对齐前查画面上有什么——
        // 已在真相源守卫单测白名单登记（ProjectionService.swift）。
        let onCalendar = try await calendarStore.read(kind: .planned, in: window)
            .filter { window.contains($0.start) }
        var copies: [UUID: [CalendarEventDraft]] = [:]
        for e in onCalendar { if let bid = e.blockID { copies[bid, default: []].append(e) } }
        let truthIDs = Set(blocks.map(\.id))
        let pres = await presentation(label: label, blocks: blocks)

        // 原样保留：对账挂起的块；以及日历里的章比本机真相新的块（另一台设备刚写、本机数据未到）
        var heldIDs: Set<UUID> = []
        for b in blocks {
            let here = copies[b.id] ?? []
            guard !here.isEmpty else { continue }
            if holding.contains(b.id) || here.contains(where: { isNewerElsewhere($0, than: b) }) { heldIDs.insert(b.id) }
        }
        var drafts: [CalendarEventDraft] = []
        var graced: [String] = []
        var prints: [String: String] = [:]
        for item in pres.drawn where !heldIDs.contains(item.block.id) {
            let b = item.block
            // 作者宽限：别的设备刚写的块、日历里还没有它 → 先不替它建（它自己会画；超过宽限再补）
            if (copies[b.id] ?? []).isEmpty, let w = b.syncWriter, w != localWriter, isFresh(b.syncVersion) {
                graced.append(b.title); continue
            }
            var d = CalendarEventDraft(title: b.title, start: item.start, end: item.end, kind: .planned,
                                       alarmLeadMinutes: b.isFixed ? MeetingSettings.leadMinutes : nil,
                                       blockID: b.id)
            d.stampV2(version: b.syncVersion)
            drafts.append(d)
            prints[b.id.uuidString] = ProjectionFingerprints.tuple(start: item.start, end: item.end, title: b.title)
        }
        for id in heldIDs {
            drafts.append(contentsOf: (copies[id] ?? []).map(Self.passThrough))
            if let old = fingerprint[id.uuidString] { prints[id.uuidString] = old }
        }
        // 多设备安全（0.35.0，修 TestFlight 反馈#5「双端画回死循环」）：带章、但**本机真相和
        // 本机指纹都不认识**的事件 = 多半是另一台设备刚写的（它的 PlanStore 真相还在 CloudKit
        // 路上）——原样保留（pass-through 进对齐清单），绝不清；真相到了按同 ID 自动接管。
        // 本机指纹认识而真相已删的照清（本机删计划的正常收敛不受影响）。
        let knownIDs = truthIDs.union(deletedIDs)
        drafts.append(contentsOf: onCalendar.filter { e in
            guard let bid = e.blockID else { return false }   // 无章 = 你的事件：不进清单，也永远不会被删
            return !knownIDs.contains(bid) && fingerprint[bid.uuidString] == nil
        }.map(Self.passThrough))
        try await calendarStore.apply(drafts, kind: .planned, window: window)
        // 指纹：记下这次成功写下的画面（对账分辨「自己写的」vs「你手改的」；旧章事件靠它，v2 章靠事件自证）。
        // 不画的块（做完/关联了你的事件/宽限中）不记——对账不会把「没画」当成「被你删了」。
        ProjectionFingerprints.set(label, prints, defaults: fingerprintDefaults, now: now())
        let hiddenNote = pres.hidden.isEmpty ? "" : "，\(pres.hidden.count) 块不画绿（做完/关联你的日历）"
        DevLog.shared.info("投影", "\(Self.dayStr(label)) → 绿 \(drafts.count) 块" + hiddenNote
                           + (heldIDs.isEmpty ? "" : "，\(heldIDs.count) 块原样保留（待核对/另一台设备更新）"))
        if !graced.isEmpty {
            DevLog.shared.info("投影", "另一台设备刚写的 \(graced.count) 块先不替它画（作者宽限 10 分钟）：\(graced.joined(separator: "、"))")
        }
    }

    /// 读回的事件原样进对齐清单（不改内容、不改提醒、不改章）：去掉只读字段，避免被当成写入意图。
    private static func passThrough(_ e: CalendarEventDraft) -> CalendarEventDraft {
        var d = e
        d.kind = .planned; d.creationDate = nil; d.externalID = nil; d.claimsUnstamped = false; d.lastModified = nil
        return d
    }

    /// 启动对账（存量补章/自愈，2026-07-07 Jason 报"老事件没补章"后加）：
    /// 把 逻辑今天…+N-1 天 逐日投影一遍——任何漂移被真相源纠正。
    /// **过去的日子不动**（不审计历史）。只在 已授权 时跑：不让冷启动弹权限框。
    func projectUpcomingWindow(days: Int = 8, skipping: Set<Date> = []) async {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }   // 后端恒真日历（假日历族已删）
        for offset in 0..<days {
            let label = DayContext.logicalDay(offset: offset, from: now())
            if skipping.contains(Calendar.current.startOfDay(for: label)) { continue }
            do { try await project(label: label) }
            catch {
                DevLog.shared.warn("投影", "启动对账 +\(offset) 天失败：\(error.localizedDescription)")
            }
        }
        DevLog.shared.info("投影", "启动对账完成：今天…+\(days - 1) 天已按真相源对齐/补章")
    }

    // MARK: - 橙色预览日历退役（P4 Q1）

    /// 清扫窗口：过去一年多到未来两个月（8/28 的僵尸橙块要扫得到；EventKit 单次查询上限 4 年）。
    static func previewRetirementWindow(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-400 * 86400), end: now.addingTimeInterval(60 * 86400))
    }

    /// 清掉预览日历里**带章**的事件（BetterCalendar 写的旧橙块），**不删日历本身**；
    /// 无章事件（你的，例如误存进来的课程）原样留下并返回，由界面提示你挪走。清单留底写日志。
    @discardableResult
    func retirePreviewCalendar() async -> CalendarRetirement? {
        do {
            let r = try await calendarStore.retireStampedEvents(kind: .preview,
                                                                in: Self.previewRetirementWindow(now: now()))
            if !r.removed.isEmpty {
                let list = r.removed.prefix(30).map { "「\($0.title)」\(Self.stamp($0.start))" }.joined(separator: "、")
                DevLog.shared.info("投影", "橙色预览日历已退役：清掉 BetterCalendar 写的旧橙块 \(r.removed.count) 个（留底：\(list)\(r.removed.count > 30 ? "…" : "")）")
            }
            if !r.foreignRemaining.isEmpty {
                DevLog.shared.warn("日历", "预览日历里还有 \(r.foreignRemaining.count) 个不是 BetterCalendar 写的事件，已保留；这本日历已退役，建议挪到你自己的日历")
            }
            return r
        } catch {
            DevLog.shared.warn("投影", "清扫旧橙块失败（下次启动再试）：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 蓝色实际（P4.1：执行页 / 复盘补一笔 / 回收站恢复 的日历写入收口到这里；语义与搬家前逐字等价）

    /// 把这些实际块并进蓝色日历——**合并不覆盖**：先读日历已有实际（此刻前后 7 天）、与 drafts 做 union 再写，
    /// 别处产生的实际（复盘补一笔 / 另一台设备）不会被删（CalendarMerge.union：同「标题＋起始分钟」= 同一件）。
    /// drafts 为空 = 不碰日历。返回写入集大小（日志用）。失败抛出，由调用方照旧记日志 / 显示。
    /// - readFailureIsEmpty：读日历失败时按「日历里还没有」继续写（执行页 flushActuals 原语义 `try?`）；
    ///   false = 读失败直接抛（复盘补一笔 / 蓝色延长原语义）。
    @discardableResult
    func recordActuals(_ drafts: [CalendarEventDraft], readFailureIsEmpty: Bool = false) async throws -> Int {
        guard !drafts.isEmpty else { return 0 }
        let existing: [CalendarEventDraft]
        if readFailureIsEmpty {
            existing = (try? await calendarStore.read(kind: .actual)) ?? []
        } else {
            existing = try await calendarStore.read(kind: .actual)
        }
        let merged = CalendarMerge.union(existing: existing, additions: drafts, kind: .actual)
        try await calendarStore.write(merged)
        return merged.count
    }

    /// 回收站恢复一条实际记录：它所在逻辑日的蓝色 = 日历里该日别的蓝块 ＋ 这一条（按窗口对齐）。
    /// 必须先成功才确认恢复（失败抛出，记录留在回收站可再试）。
    func restoreActual(id: UUID, title: String, start: Date, end: Date) async throws {
        let window = DayContext.logicalWindow(forLabel: DayContext.logicalStartOfDay(start))
        var existing = try await calendarStore.read(kind: .actual).filter {
            $0.start >= window.start && $0.start < window.end && $0.blockID != id
        }
        existing.append(CalendarEventDraft(title: title, start: start, end: end, kind: .actual, blockID: id))
        try await calendarStore.apply(existing, kind: .actual, window: window)
    }

    // MARK: - 跟随时间线协调器（P4 Q2：绿色开工后照常在日历里，协调器改了真相就跟着重画今天）

    /// 协调器写回真相后（planChangedExternally 来源 = timelineCoordinator）防抖 1 秒重画今天。
    /// 只跟本机协调器的写：它的真相是本机最新的；另一台设备的改动由那台设备自己画（作者原则）。
    func startFollowingTimeline() {
        guard !TestHost.isActive, followTask == nil else { return }
        followTask = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: ReconcileService.planChangedExternally) {
                guard let self else { return }
                guard (note.userInfo?[PlanChangeSource.key] as? String) == PlanChangeSource.timelineCoordinator else { continue }
                self.scheduleTodayRepaint()
            }
        }
    }

    private func scheduleTodayRepaint() {
        followDebounce?.cancel()
        followDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.repaintToday(reason: "时间线调整")
        }
    }

    /// 重画今天（执行层记下/延长实际后、协调器写回后）。失败只记日志（开发期可见）。
    func repaintToday(reason: String) async {
        guard calendarAuthorized() else { return }
        do { try await project(label: DayContext.logicalStartOfDay(now())) }
        catch { DevLog.shared.warn("投影", "\(reason)后重画今天失败：\(error.localizedDescription)") }
    }

    /// 是否已授权（生产 = EventKit full access；测试替身恒真，不碰系统权限）。
    var calendarAuthorized: () -> Bool = { TestHost.isActive || EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    private static func dayStr(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }

    private static func stamp(_ d: Date) -> String {
        d.formatted(.dateTime.month().day().hour().minute())
    }
}
