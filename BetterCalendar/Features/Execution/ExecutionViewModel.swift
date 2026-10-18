//
//  ExecutionViewModel.swift
//  BetterCalendar
//
//  menu bar 单键导航的大脑（Feature 层 VM，不新增协议；建在 CalendarStore 上）。
//  「记录 = 导航」：点 完成/下一件/换一件 顺手攒出蓝色「实际」日历——无感采集，替代手动回填。
//  状态机：空档 ⇄ 进行中某块 ⇄ 休息（休息=暂停当前块，不结束；回来继续同一件）。
//  实时性：进行中的块不落盘（避免半截事件）；**每块「完成/切走」时**把全量实际刷进蓝日历。
//

import Foundation
import Observation
#if os(iOS)
import WidgetKit
#endif

@Observable
final class ExecutionViewModel {
    private let calendarStore: CalendarStore
    private let reschedule: RescheduleService   // P4：橙色连续预览退役后执行层不再调它；注入保留到 E5f 算法半重审时定去留
    // 执行层：读计划 + 读/写蓝色实际（真相源，蓝对账 A2）；**不改计划结构**（title/time/固定 仍只由确认写入 & 对账回流）。
    private let planStore: PlanReading & ActualReading & ActualWriting
    private let reminderStore: ReminderStore
    private let liveActivity: ExecutionLiveActivity   // 灵动岛/锁屏实时计时（iOS 有实现，macOS no-op）
    private var presentingFollowActivity = false
    private let sessionStore: ExecutionSessionStore?  // 执行会话落库（趋势统计数据源；nil=不记，测试用）
    let canonicalTasks: BridgeTaskViewModel?
    private var presentingCanonicalActivity = false
    private var canonicalActivityID: String?
    private var canonicalProjectionSignature: String?
    private var canonicalProjectionHasPublished = false
    private var canonicalProjectedReadAt: Date?
    var usesCanonicalTiming: Bool {
        canonicalTasks?.isEnabled == true && active == nil && background.isEmpty && pendingRunRestore == nil
    }
    private let persistsRunState: Bool                // 运行态快照开关（测试关：test host 与真 App 共享 UserDefaults，别互相污染）
    private let startedDays: StartedDayStore?         // 实时模式标记（0.23 A：首次开始一件事=进实时模式）；nil=不标
    private let projection: ProjectionService?        // 进实时模式时重投影该日（绿淡出）；nil=不投

    /// 今日计划块（绿），按开始时间排序。
    private(set) var planned: [PlannedItem] = []
    /// 已记录的实际块（蓝日历的来源）。
    private(set) var done: [ActualRecord] = []
    /// 当前进行中的块（nil = 空档）。前台块：占用 menu bar + Live Activity + 计时风格控制。
    private(set) var active: ActiveBlock?
    /// 后台并行进行的块（不占 menu bar/前台、不显灵动岛，自己按墙钟计时、完成时自动记蓝色实际）。
    /// 支持「一次做多件」：前台一件精细计时，其余同时在后台慢慢跑。
    private(set) var background: [BackgroundRun] = []
    /// 已选中、待开始的块（换一件后切到它，但要点「开始任务」才真正开始计时）。
    private(set) var selected: PlannedItem?
    /// 休息态（可发生在空档，或某块中途=暂停那块）。
    private(set) var isOnBreak = false
    private var breakStart: Date?
    private var pomoSegStart: Date?   // 番茄钟当前段开始时刻（nil = 非番茄）
    private var pomoIsRest = false    // 当前番茄段是否休息段
    private var pomoWorkSegmentsDone = 0   // 本次会话完成的番茄工作段数（落 ExecutionSession）
    private var pomoTargetSegments: Int?   // 自设目标段数（0.21 转番茄时选）：做满自动转轻计时续走；nil=不限
    private var pomoRestAccumulated: TimeInterval = 0   // 本次番茄休息段累计时长（「继续计时」算净专注=总时长-番茄休息）
    private var breakCount = 0             // 本次会话中途休息次数（落 ExecutionSession）

    private(set) var loaded = false
    var lastError: String?

    struct PlannedItem: Identifiable, Sendable {
        var id = UUID()   // = PlanStore 块 id（loadToday 传入）：蓝色实际盖同一章，计划×实际按 ID 可配对
        var title: String
        var start: Date
        var end: Date
        var timingStyle: TimingStyle = .light
        var isFixed: Bool = false
        var priority: BlockPriority = .normal
    }
    struct ActualRecord: Identifiable, Sendable {
        let id = UUID()
        var plannedID: UUID?
        var title: String
        var start: Date
        var end: Date
        /// 被动推断（固定块到点自动完成，P4 Q4c）：算做成、记数据，但**不画蓝**（你点完成或计过时才画）。
        var isAuto: Bool = false
    }
    struct ActiveBlock {
        var plannedID: UUID?
        var title: String
        var start: Date
        var pausedTotal: TimeInterval = 0   // 休息累计（从已用时长里扣）
        var timingStyle: TimingStyle = .light
        /// 并行接替（点子 #20）：true=完成前台后从「同时做」自动顶上来的——被「换一件/开始别件」时
        /// 回同时做队首（计时保留）而不是被结束（原则7：自动接替只是显示提升、随时可逆）。
        var cameFromBackground: Bool = false
        /// 开始那一刻的计划时长（W8 修「活动预报被暂停反复拉长」，Jason 2026-10-18 批准）：
        /// 预测结束 = 现在 +（计划时长 − 已投入）；计划时长若每次都从 planned 现读，读到的是时间线协调器
        /// 按上一次预测写回、已被拉长的那一行——暂停/休息越久越长、后面的块被一路推后。故开始时定格。nil=计划外/无对应。
        var plannedDuration: TimeInterval? = nil
    }
    /// 后台并行块：只记起点，按墙钟计时。休息时也一起冻结（0.17：rest=从所有正在做的事休息）。
    struct BackgroundRun: Identifiable, Sendable {
        let id = UUID()
        var plannedID: UUID?
        var title: String
        var start: Date
        var pausedTotal: TimeInterval = 0
    }

    // MARK: - 运行态快照（0.20，Jason 定 2026-07-08：重启/iOS 清后台不丢计时；同逻辑日才恢复）

    /// 进行中的计时状态整份快照（Codable，存 UserDefaults——每台设备自己的计时自己记，不跨端）。
    struct RunStateSnapshot: Codable {
        struct ActiveSnap: Codable {
            var plannedID: UUID?; var title: String; var start: Date
            var pausedTotal: TimeInterval; var timingStyleRaw: String
            var cameFromBackground: Bool?   // 并行接替标记（Optional：老快照缺此键照常解码）
            var plannedSec: TimeInterval?   // W8：开始时定格的计划时长（Optional：老快照缺此键照常解码）
        }
        struct RunSnap: Codable {
            var plannedID: UUID?; var title: String; var start: Date; var pausedTotal: TimeInterval
        }
        var active: ActiveSnap?
        var background: [RunSnap] = []
        var isOnBreak = false
        var breakStart: Date?
        var pomoSegStart: Date?
        var pomoIsRest = false
        var pomoWorkSegmentsDone = 0
        var pomoRestAccumulated: TimeInterval = 0
        var pomoTargetSegments: Int?   // 0.21 自设目标段数（Optional：老快照缺此键照常解码）
        var breakCount = 0
        var savedAt = Date()

        /// 是否可恢复：锚定时刻（进行中块的开始，退而求其次存盘时刻）与现在同一逻辑日才接上；
        /// 跨逻辑日=昨天的计时，不恢复（纯函数、可单测）。
        static func isRestorable(_ snap: RunStateSnapshot, now: Date = .now) -> Bool {
            guard snap.active != nil || !snap.background.isEmpty else { return false }
            let anchor = snap.active?.start ?? snap.background.first?.start ?? snap.savedAt
            return DayContext.isSameLogicalDay(anchor, now)
        }
    }

    private static let runStateKey = "execution.runState"

    /// 每次运行态变化整份落盘（几百字节 JSON）；空档且无并行 → 清掉。
    private func persistRunState() {
        guard persistsRunState else { return }
        updateScreenTimeShield()   // 幂等收敛：任何运行态变更后把屏蔽对齐（工作段=屏蔽，其余=解除）
        guard active != nil || !background.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.runStateKey)
            return
        }
        var snap = RunStateSnapshot()
        if let a = active {
            snap.active = .init(plannedID: a.plannedID, title: a.title, start: a.start,
                                pausedTotal: a.pausedTotal, timingStyleRaw: a.timingStyle.rawValue,
                                cameFromBackground: a.cameFromBackground, plannedSec: a.plannedDuration)
        }
        snap.background = background.map { .init(plannedID: $0.plannedID, title: $0.title,
                                                 start: $0.start, pausedTotal: $0.pausedTotal) }
        snap.isOnBreak = isOnBreak
        snap.breakStart = breakStart
        snap.pomoSegStart = pomoSegStart
        snap.pomoIsRest = pomoIsRest
        snap.pomoWorkSegmentsDone = pomoWorkSegmentsDone
        snap.pomoRestAccumulated = pomoRestAccumulated
        snap.pomoTargetSegments = pomoTargetSegments
        snap.breakCount = breakCount
        snap.savedAt = .now
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.runStateKey)
        }
    }

    /// 三选恢复（0.22.1，Jason 设计）：同逻辑日的快照不再静默接上，挂起弹窗问——
    /// 继续（把离开的时间也算上）/ 直接继续（离开时间不算）/ 重新开始（当作没做过）。
    enum RunRestoreChoice: String { case continueWithGap, continueWithoutGap, discard }

    /// 恢复策略（0.25.6，Jason：恢复弹窗加「不再询问」勾选 + 设置可改）：ask=每次问；其余=记住的选择自动应用。
    enum RunRestoreSettings {
        private static let key = "execution.runRestorePolicy"
        /// nil = ask（每次询问）。
        static var policy: RunRestoreChoice? {
            get { UserDefaults.standard.string(forKey: key).flatMap(RunRestoreChoice.init) }
            set { newValue.map { UserDefaults.standard.set($0.rawValue, forKey: key) }
                  ?? UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// 待用户三选的退出前运行态（非 nil → 执行面板弹恢复对话框）。
    var pendingRunRestore: RunStateSnapshot?

    /// 启动检查：同逻辑日 → 挂起三选（或按记住的策略自动应用）；跨逻辑日 → 丢弃快照。
    private func restoreRunStateIfNeeded() {
        guard persistsRunState else { return }
        guard active == nil, background.isEmpty, pendingRunRestore == nil,
              let data = UserDefaults.standard.data(forKey: Self.runStateKey),
              let snap = try? JSONDecoder().decode(RunStateSnapshot.self, from: data) else { return }
        guard RunStateSnapshot.isRestorable(snap) else {
            UserDefaults.standard.removeObject(forKey: Self.runStateKey)
            DevLog.shared.info("执行", "跨逻辑日的旧计时快照已丢弃（昨天的事不接续）")
            return
        }
        if let remembered = RunRestoreSettings.policy {   // 记住过 → 直接应用、不打扰
            pendingRunRestore = snap
            resolveRunRestore(remembered)
            DevLog.shared.info("执行", "按记住的恢复策略自动处理（\(remembered.rawValue)）")
            return
        }
        pendingRunRestore = snap
        DevLog.shared.info("执行", "发现退出前的运行态：\(snap.active?.title ?? snap.background.first?.title ?? "")（等你选怎么继续）")
    }

    /// 用户对恢复对话框的选择。
    func resolveRunRestore(_ choice: RunRestoreChoice) {
        guard let snap = pendingRunRestore else { return }
        pendingRunRestore = nil
        switch choice {
        case .discard:
            UserDefaults.standard.removeObject(forKey: Self.runStateKey)
            DevLog.shared.info("执行", "按选择丢弃退出前的运行态（当作没做过）")
        case .continueWithGap, .continueWithoutGap:
            applyRunState(snap)
            if choice == .continueWithoutGap {
                // 离开的时间不算投入：整段空档按"休息"扣除（计时/番茄段/休息起点一并平移）
                let gap = max(0, Date.now.timeIntervalSince(snap.savedAt))
                active?.pausedTotal += gap
                for i in background.indices { background[i].pausedTotal += gap }
                if let seg = pomoSegStart { pomoSegStart = seg.addingTimeInterval(gap) }
                if let bs = breakStart { breakStart = bs.addingTimeInterval(gap) }
            }
            persistRunState()
            if active != nil, let s = liveSnapshot() { liveActivity.start(s) }
            DevLog.shared.info("执行", "恢复运行态：\(active?.title ?? "")（\(choice == .continueWithGap ? "含离开时间" : "不含离开时间")）· 并行 \(background.count)")
            syncFocusShortcut()
        }
    }

    private func applyRunState(_ snap: RunStateSnapshot) {
        if let a = snap.active {
            active = ActiveBlock(plannedID: a.plannedID, title: a.title, start: a.start,
                                 pausedTotal: a.pausedTotal,
                                 timingStyle: TimingStyle(rawValue: a.timingStyleRaw) ?? .light,
                                 cameFromBackground: a.cameFromBackground ?? false, plannedDuration: a.plannedSec)
        }
        background = snap.background.map { BackgroundRun(plannedID: $0.plannedID, title: $0.title,
                                                         start: $0.start, pausedTotal: $0.pausedTotal) }
        isOnBreak = snap.isOnBreak
        breakStart = snap.breakStart
        pomoSegStart = snap.pomoSegStart
        pomoIsRest = snap.pomoIsRest
        pomoWorkSegmentsDone = snap.pomoWorkSegmentsDone
        pomoRestAccumulated = snap.pomoRestAccumulated
        pomoTargetSegments = snap.pomoTargetSegments
        breakCount = snap.breakCount
    }

    init(calendarStore: CalendarStore, reschedule: RescheduleService,
         planStore: PlanReading & ActualReading & ActualWriting, reminderStore: ReminderStore,
         liveActivity: ExecutionLiveActivity, sessionStore: ExecutionSessionStore? = nil,
         persistsRunState: Bool = true,
         startedDays: StartedDayStore? = nil, projection: ProjectionService? = nil,
         canonicalTasks: BridgeTaskViewModel? = nil) {
        self.calendarStore = calendarStore
        self.reschedule = reschedule
        self.planStore = planStore
        self.reminderStore = reminderStore
        self.liveActivity = liveActivity
        self.sessionStore = sessionStore
        self.canonicalTasks = canonicalTasks
        if let previous = canonicalTasks?.primary {
            canonicalProjectionSignature = "\(previous.id):\(previous.revision)"
        }
        self.persistsRunState = persistsRunState
        self.startedDays = startedDays
        self.projection = projection
        // 番茄绝对专注（iOS）：启动即收敛一次——上次崩溃/被杀残留的屏蔽在这里解除
        if persistsRunState { updateScreenTimeShield() }
        startGuardianTicker()   // 0.34：段界自动推进 + 过日界线收尾（真 App 才启）
    }

    /// 番茄绝对专注（iOS，SPEC §5.5）：屏蔽状态=纯函数(运行态)——番茄**工作段**且没在手动休息才屏蔽。
    /// 挂在 persistRunState 必经点 + init，幂等廉价；macOS 空实现（系统不支持硬屏蔽）。
    func updateScreenTimeShield() {
        #if os(iOS)
        let working = active?.timingStyle == .pomodoro && !pomoIsRest && !isOnBreak
        // 多端跟随（#30）：另一台设备的番茄也参与屏蔽（跟随=同一份预先承诺的延伸）
        ScreenTimeBlocker.shared.sync(shouldShield: working || FollowRunState.shared.shouldShield)
        #endif
    }

    /// 把另一台设备的只读运行态映射到本机锁屏/灵动岛；不创建 session、实际记录或日历事件。
    /// 本机有 active 时始终由本机状态占据 Live Activity。
    func syncFollowPresentation() {
        guard !usesCanonicalTiming else { return }
        updateScreenTimeShield()
        guard active == nil else {
            presentingFollowActivity = false
            return
        }
        guard let followed = FollowRunState.shared.run else {
            if presentingFollowActivity { liveActivity.end() }
            presentingFollowActivity = false
            return
        }
        let snapshot = followed.liveActivitySnapshot
        if presentingFollowActivity { liveActivity.update(snapshot) }
        else { liveActivity.start(snapshot) }
        presentingFollowActivity = true
    }

    /// Cloud sessions project into Live Activity without writing duplicate
    /// SwiftData sessions/actual blocks on either device.
    func syncCanonicalPresentation() {
        guard active == nil, background.isEmpty, pendingRunRestore == nil else {
            presentingCanonicalActivity = false; canonicalActivityID = nil; return
        }
        guard usesCanonicalTiming, let tasks = canonicalTasks, let session = tasks.primary else {
            if presentingCanonicalActivity { liveActivity.end() }
            #if os(macOS)
            if usesCanonicalTiming, let tasks = canonicalTasks, !tasks.isStale, tasks.sessions.isEmpty,
               canonicalProjectionSignature != nil {
                FocusFollow.publish(kind: "complete", active: nil, sampledAt: tasks.estimatedServerDate())
                canonicalProjectionSignature = nil
            }
            #endif
            presentingCanonicalActivity = false; canonicalActivityID = nil; return
        }
        let now = Date(), elapsed = tasks.elapsed(session, at: now)
        let displayTitle = (session.isExperiment ? "测试 · " : "") + (session.resolvedMode == .pomodoro ? "番茄\(session.focusMinutes ?? 25)分钟 · " : "") + session.title
        let snapshot = LiveActivitySnapshot(title: tasks.isStale ? "待同步 · " + displayTitle : displayTitle,
                                            timerStart: now.addingTimeInterval(-elapsed),
                                            pausedAt: session.status == .paused ? now : nil,
                                            mode: .light, phaseEndsAt: nil, phaseIsRest: false, isRemote: true,
                                            staleAt: tasks.presentationValidUntil)
        if presentingCanonicalActivity && canonicalActivityID == session.id { liveActivity.update(snapshot) }
        else { if presentingCanonicalActivity { liveActivity.end() }; liveActivity.start(snapshot) }
        presentingCanonicalActivity = true; canonicalActivityID = session.id
        #if os(macOS)
        // One Mac projects committed BC state into the existing CloudKit wake
        // channel. iPhone receivers do not republish the projection.
        guard !session.isExperiment, FocusFollowSettings.enabled, !tasks.isStale, let receivedAt = tasks.lastReadReceivedAt,
              receivedAt != canonicalProjectedReadAt else { return }
        let signature = "\(session.id):\(session.revision)"
        let phase = session.presentation(elapsed: elapsed)
        let a = FocusStateExporter.State.Active(title: session.title, timingStyle: phase.countingDown ? TimingStyle.pomodoro.rawValue : TimingStyle.light.rawValue,
                                               startedAt: now.addingTimeInterval(-elapsed), elapsedSec: Int(elapsed),
                                               pausedSec: 0, plannedSec: nil, endsAt: phase.countingDown ? now.addingTimeInterval(phase.remaining) : nil, inRest: false,
                                               segmentsRemaining: 0, workSec: session.focusMinutes.map { $0 * 60 }, restSec: 0)
        FocusFollow.publish(kind: canonicalProjectionHasPublished && canonicalProjectionSignature == signature ? "tick" : "canonical-state",
                            active: a, isPaused: session.status == .paused, elapsed: elapsed, sampledAt: tasks.estimatedServerDate(at: now))
        canonicalProjectionSignature = signature
        canonicalProjectionHasPublished = true; canonicalProjectedReadAt = receivedAt
        #endif
    }

    // MARK: - 读取今日

    /// 重建今日状态：计划与实际都以 **PlanStore 真相源**为准（实际再 ∪ 带章日历=迁移+跨设备兜底）。
    /// Imported cloud/maintenance data refreshes displays without triggering completion inference or writes.
    func reloadImportedData(now: Date = .now) {
        do {
            let label = DayContext.logicalStartOfDay(now)
            let blocks = try planStore.plannedBlocks(on: label)
            let actuals = try planStore.actualBlocks(on: label)
            planned = blocks.filter { !$0.isAnchor }.map {
                PlannedItem(id: $0.id, title: $0.title, start: $0.start, end: $0.end,
                            timingStyle: $0.timingStyle, isFixed: $0.isFixed, priority: $0.priority)
            }
            if let id = selected?.id { selected = planned.first { $0.id == id } }
            if let id = active?.plannedID, let item = planned.first(where: { $0.id == id }) { active?.title = item.title }
            if active == nil, background.isEmpty {
                done = actuals.filter { !runningIDs.contains($0.id) }
                    .map { ActualRecord(plannedID: $0.id, title: $0.title, start: $0.start, end: $0.end,
                                        isAuto: $0.state == .auto) }
            }
        } catch { DataSyncMonitor.shared.report("执行列表重读失败：\(error.localizedDescription)") }
    }

    func loadToday() async {
        restoreRunStateIfNeeded()   // 0.20：重启/清后台后，同逻辑日的计时原样接上
        do {
            // 计划块从 PlanStore（带 isFixed/timingStyle），不从日历（日历丢元数据）
            let label = DayContext.logicalStartOfDay(.now)
            let p = try planStore.plannedBlocks(on: label)
            let a = try await calendarStore.read(kind: .actual)
            let stored = (try? planStore.actualBlocks(on: label)) ?? []   // 蓝对账 A2：实际真相源=PlanStore(.actual)
            let clearedIDs = (try? planStore.clearedPlannedIDs(on: label)) ?? []   // 蓝对账 B：批量读 tombstone（循环里只查 Set）
            // 锚点块（午饭/通勤等）不进执行列表：占日程但不是"要完成的任务"，menu bar 不催你完成（0.17）
            planned = p.filter { !$0.isAnchor }
                       .sorted { $0.start < $1.start }
                       .map { PlannedItem(id: $0.id, title: $0.title, start: $0.start, end: $0.end,
                                          timingStyle: $0.timingStyle, isFixed: $0.isFixed,
                                          priority: $0.priority) }
            // 已采集的实际（菜单之前攒的 / 回填的）→ 同步进 done，避免重复呈现为「未做」。
            // 蓝对账 A2：以 PlanStore(.actual) 为真相；再并入日历里带章、真相源还没有的实际
            // （老数据迁移 + 跨设备日历同步来的；无章的留给 Stage B 认领弹窗）。
            // 正在做（或待恢复）的那件的「在长」实际不算做完（P4：它的绿色还要画剩下那段）
            var merged = stored.filter { !($0.state == .live && runningIDs.contains($0.id)) }
                .map { ActualRecord(plannedID: $0.id, title: $0.title,
                                    start: $0.start, end: $0.end, isAuto: $0.state == .auto) }
            let storedIDs = Set(stored.map(\.id))
            for c in a where DayContext.isSameLogicalDay(c.start, .now) {
                // 只并入**带章**、真相源还没有的实际（迁移+跨设备）。**无章事件与数据库无关 → 一律忽略**
                // （Jason 2026-07-09：用户在日历首建的裸蓝块太罕见，不认领/不改/不删，假装不存在——凡关联库的都带 ID 章）。
                guard let bid = c.blockID, !storedIDs.contains(bid) else { continue }
                merged.append(ActualRecord(plannedID: bid, title: c.title, start: c.start, end: c.end))
            }
            let collectedCount = merged.count

            // 被动信号（M6b）：会议到点(过去的固定块=按计划发生) + 提醒今天打勾 → 自动并入实际
            // 0.25.4 根治：提醒打勾**按 blockID 精确匹配**（不再按标题相似——同名任务被往日旧提醒误标完成的 bug）
            let completedIDs = await reminderStore.completedBlockIDs()
            let now = Date.now
            for item in planned where !merged.contains(where: {
                $0.plannedID == item.id
                    || ($0.plannedID == nil && TitleMatch.similarity($0.title, item.title) >= 0.6) }) {
                // 蓝对账 B：用户已在日历删过这块的蓝色实际（对账时盖了 tombstone）→ 不再自动重推断（删了 stick）。
                if clearedIDs.contains(item.id) { continue }
                let meetingHappened = item.isFixed && item.end < now && MeetingSettings.autoCompleteFixedBlocks
                let reminderChecked = completedIDs.contains(item.id)
                if meetingHappened || reminderChecked {
                    // P4 Q4c：固定块到点 = 被动推断，只记数据不画蓝；提醒事项里打勾 = 你的动作，照常画蓝
                    merged.append(ActualRecord(plannedID: item.id, title: item.title,
                                               start: item.start, end: item.end, isAuto: !reminderChecked))
                }
            }

            // 进行中的 active 不动；done 用合并后的为准
            if active == nil {
                done = merged
                if merged.count > collectedCount {
                    DevLog.shared.info("执行", "被动信号并入实际 \(merged.count - collectedCount) 件")
                    await flushActuals()
                }
            }
            loaded = true
            publishIntegrations()
        } catch {
            lastError = error.localizedDescription
            DevLog.shared.warn("执行", "读取今日计划/实际失败：\(error.localizedDescription)")
        }
    }

    /// 本机正在计时（含待恢复快照）的计划块 id：它们的「在长」实际行不并进 done。
    private var runningIDs: Set<UUID> {
        var ids = Set([active?.plannedID, pendingRunRestore?.active?.plannedID].compactMap { $0 })
        ids.formUnion(background.compactMap(\.plannedID))
        ids.formUnion(pendingRunRestore?.background.compactMap(\.plannedID) ?? [])
        return ids
    }

    /// 手动对账（蓝对账 Stage B）：把用户在 Apple 日历里对**蓝色实际**的删除同步进真相源。
    /// **手动触发**（用户点「同步日历改动」）：此刻用户本机日历是最新的 → 直接信任日历、不弹窗
    /// （区别于后台自动对账：跨设备同步延迟下，自动把"日历里暂缺"当删除会误删；手动无此风险，也合原则7=用户主动）。
    /// 逻辑：真相源里有、但日历里已无的带章蓝块 = 用户删了 → 删真相源实际 + 给对应计划块盖 tombstone
    /// （completion=.missed）→ loadToday 的自动完成不再重推断（删了 stick）。带章还在但时间/标题改了 → 回填。
    /// （无章新建认领待后续：需给日历事件盖章回写、防重复导入，CalendarStore 暂无改事件能力。）
    func reconcileCalendarActuals() async {
        let label = DayContext.logicalStartOfDay(.now)
        let stored: [ActualBlock]
        let calEvents: [CalendarEventDraft]
        do {
            stored = try planStore.actualBlocks(on: label)
            guard !stored.isEmpty else { return }
            calEvents = try await calendarStore.read(kind: .actual)
                .filter { DayContext.isSameLogicalDay($0.start, .now) }
        } catch {
            DataSyncMonitor.shared.report("实际日历读取失败，已保留全部记录：\(error.localizedDescription)")
            return
        }
        let calByID = Dictionary(calEvents.compactMap { e in e.blockID.map { ($0, e) } },
                                 uniquingKeysWith: { a, _ in a })
        var deleted: [UUID] = []
        var timeUpdates: [ActualBlock] = []
        for s in stored {
            if let c = calByID[s.id] {
                if c.start != s.start || c.end != s.end || c.title != s.title {   // 时间/标题回填：你在日历改了实际
                    timeUpdates.append(ActualBlock(id: s.id, title: c.title, start: c.start, end: c.end))
                }
            } else {
                deleted.append(s.id)   // 带章实际日历里没了 → 你删了
            }
        }
        guard !deleted.isEmpty || !timeUpdates.isEmpty else { return }
        if !timeUpdates.isEmpty { try? planStore.upsertActuals(timeUpdates) }
        if !deleted.isEmpty {
            try? planStore.deleteActuals(ids: deleted)
            let plannedIDs = Set((try? planStore.plannedBlocks(on: label))?.map(\.id) ?? [])
            for id in deleted where plannedIDs.contains(id) {
                try? planStore.latchCompletion(plannedID: id, .missed)   // tombstone：删了不再自动重推断
            }
        }
        DevLog.shared.info("对账", "蓝色实际对账：删 \(deleted.count) · 时间/标题回填 \(timeUpdates.count)")
        await loadToday()
    }

    /// 执行状态 → 主屏小组件快照（App Group JSON + 刷时间线）。iOS 专属，macOS no-op。
    private func publishWidgetSnapshot() {
        #if os(iOS)
        let snap = WidgetSnapshot(
            updatedAt: .now,
            doneCount: doneCount,
            activeTitle: active?.title,
            remaining: remaining.prefix(4).map {
                WidgetSnapshot.Item(title: $0.title, start: $0.start, end: $0.end)
            })
        WidgetSnapshotStore.save(snap)
        WidgetCenter.shared.reloadTimelines(ofKind: "BetterCalendarTodayWidget")
        #endif
    }

    // MARK: - 派生状态（给 UI）

    /// 完成判定按 **ID 优先**（重构：实际记录带 plannedID 章，跨设备也认得）；
    /// 只有**无章**记录（老数据/手写日历事件）才退回标题相似——同名两块不再互相污染、不再误标完成。
    func isDone(_ item: PlannedItem) -> Bool {
        done.contains { $0.plannedID == item.id
            || ($0.plannedID == nil && TitleMatch.similarity($0.title, item.title) >= 0.6) }
    }

    /// 某块是否正在后台并行进行。
    func isRunningInBackground(_ item: PlannedItem) -> Bool {
        background.contains { $0.plannedID == item.id }
    }

    /// 还没做、也不是当前块/待开始块/后台并行块的计划块。
    var remaining: [PlannedItem] {
        planned.filter { $0.id != active?.plannedID && $0.id != selected?.id
                         && !isDone($0) && !isRunningInBackground($0) }
    }

    /// 后台某并行块的净时长（休息期间冻结、扣掉休息累计）。
    func backgroundElapsed(_ run: BackgroundRun) -> TimeInterval {
        let endRef = isOnBreak ? (breakStart ?? .now) : .now
        return max(0, endRef.timeIntervalSince(run.start) - run.pausedTotal)
    }

    /// 建议的下一件 = 最早的剩余块（计划写入时已按策略排过序）。
    var nextSuggested: PlannedItem? { remaining.first }

    var doneCount: Int { planned.filter { isDone($0) }.count }

    /// 今日要紧事（★）——「兑现红利」执行侧：做成了打 🎯、没做成不罚（只是不亮）。
    var importantItems: [PlannedItem] { planned.filter { $0.priority == .important } }
    /// 要紧事是否已做成（复用 isDone 的被动信号判定）。
    func isImportantDone(_ item: PlannedItem) -> Bool { isDone(item) }

    /// 当前块已用时长（休息期间冻结、并扣掉休息累计）。实时算，由 UI 的 TimelineView 每秒刷新。
    var currentElapsed: TimeInterval {
        guard let a = active else { return 0 }
        let endRef = isOnBreak ? (breakStart ?? .now) : .now
        return max(0, endRef.timeIntervalSince(a.start) - a.pausedTotal)
    }

    /// 当前块的**计划时长**（轻计时的预算参照；从对应计划块的起止算）。nil=计划外 bonus / 无对应。
    var activePlannedDuration: TimeInterval? {
        guard let a = active else { return nil }
        if let fixed = a.plannedDuration { return fixed }   // W8：开始时定格（不读协调器写回、被预测拉长的那一行）
        return planned.first { $0.id == a.plannedID }.map { $0.end.timeIntervalSince($0.start) }
    }

    /// 计时显示（2026-07-09 敲定，去羞辱去滴答）：**轻计时 = 已 X · 计划 Y**（累积框架 + 预算参照，
    /// 超计划则撤掉「计划 Y」= 自然退化成不计时的样子、不留"你超了"尾巴）；**不计时 = 已 X**。
    /// 到分 XhYm、无秒（去滴答紧张感）；全程中性、无倒计时归零节拍、绝不变红/闹铃。
    var timerDisplay: String {
        guard active != nil else { return "" }
        let elapsed = "已 " + Self.hm(currentElapsed)
        guard activeStyle == .light, let planned = activePlannedDuration, currentElapsed < planned else {
            return elapsed
        }
        return elapsed + " · 计划 " + Self.hm(planned)
    }

    /// 时长 → 「XhYm」（到分、无秒）："1h15m" / "45m" / "2h" / "0m"。
    static func hm(_ ti: TimeInterval) -> String {
        let mins = max(0, Int(ti) / 60)
        let h = mins / 60, m = mins % 60
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(m)m"
    }

    // MARK: - 蓝色实时增长 + 橙色A（Jason 2026-07-10，周期 tick、不调 LLM）
    private var lastActualGrow: Date = .distantPast
    /// 到点该长一次了吗（正在做**计划内**任务且距上次 ≥5 分）。菜单栏 1 秒 tick 同步查，只到点才真干。
    /// v1 只长计划内任务（有稳定 plannedID）；计划外 bonus 无稳定 id、留后续。
    var shouldGrowActive: Bool { active?.plannedID != nil && Date.now.timeIntervalSince(lastActualGrow) >= 300 }

    /// 正在做一件事时把它的蓝色实际块延长到此刻（日历上看蓝色在长=实时进度、成就感）。不调 LLM。
    /// P4 Q2「一件事只画一次」：实际行标「正在做」，随后重画今天——这件的绿色只剩「蓝色尽头 → 计划结束」那段。
    /// （橙色预览日历已退役：不再清/写橙块。）
    func growActiveActual() async {
        guard let a = active, let id = a.plannedID else { return }
        lastActualGrow = .now
        let now = Date.now
        // 延长/建正在做那件的蓝色实际块（start..now）——盖对应计划块章
        do { try planStore.upsertActuals([ActualBlock(id: id, title: a.title, start: a.start, end: now, state: .live)]) }
        catch { DevLog.shared.warn("执行", "延长正在做的实际记录失败：\(error.localizedDescription)") }
        let draft = CalendarEventDraft(title: a.title, start: a.start, end: now, kind: .actual, blockID: id)
        do {
            let existing = try await calendarStore.read(kind: .actual)
            try await calendarStore.write(CalendarMerge.union(existing: existing, additions: [draft], kind: .actual))
        } catch { DevLog.shared.warn("执行", "延长蓝色实际失败：\(error.localizedDescription)") }
        await projection?.repaintToday(reason: "蓝色延长")
        exportFocusState(event: "tick")
    }

    /// 聪音联动（2026-07-10）：把当前专注状态写出 focus-state.json（仅设置开「聪音联动」时真写）。
    /// ⚠️ gate 在 persistsRunState：CLI 测试 host 与真 App 共享 UserDefaults/容器——不 gate 的话
    /// 联动开着时跑单测会把测试数据写进桥文件、驱动正在运行的游戏（幽灵番茄）。
    private func exportFocusState(event kind: String, completedTitle: String? = nil, completedSec: Int? = nil) {
        guard persistsRunState else { return }
        let a: FocusStateExporter.State.Active? = active.map { blk in
            // 终点对齐协议（Jason 2026-07-10）：BC 把"当前段/任务的结束钟点"算好推出去，游戏按终点反推。
            // 休息暂停/番茄段切换都被折进 endsAt；tick（≤5 分）刷新时终点自动顺延——对齐永远稳。
            var endsAt: Date?
            var inRest: Bool?
            var segRemain: Int?
            var workSec: Int?
            var restSec: Int?
            if let phase = pomodoroPhase {
                endsAt = Date.now.addingTimeInterval(max(0, phase.phaseLength - phase.elapsedInPhase))
                inRest = phase.kind == .rest
                workSec = Int(PomodoroTimer.work)
                restSec = Int(PomodoroTimer.rest)
                segRemain = Self.pomodoroSegmentsRemaining(target: pomoTargetSegments,
                                                           done: pomoWorkSegmentsDone,
                                                           inWork: phase.kind == .work)
            } else if blk.timingStyle == .light, let planned = activePlannedDuration {
                // 0.33.0：超时/「继续计时」转往上记后没有终点——此前 max(0,…) 让 endsAt 永远=now
                // （谎报终点，游戏没法跟正计时）。开放式一律导出 nil，mod 见 light 无终点走官方正计时。
                let remain = planned - currentElapsed
                endsAt = remain > 0 ? Date.now.addingTimeInterval(remain) : nil
            }
            // 0.66 时间戳授时：pausedSec = 墙钟总时长 − 净投入（含正在进行中的休息），
            // 游戏侧据此纯算术推净投入，不受 2 秒轮询延迟/游戏掉帧影响。
            let wall = Date.now.timeIntervalSince(blk.start)
            let paused = max(0, wall - currentElapsed)
            return .init(title: blk.title, timingStyle: blk.timingStyle.rawValue, startedAt: blk.start,
                         elapsedSec: Int(currentElapsed), pausedSec: Int(paused),
                         plannedSec: activePlannedDuration.map { Int($0) },
                         endsAt: endsAt, inRest: inRest, segmentsRemaining: segRemain,
                         workSec: workSec, restSec: restSec)
        }
        let ev: FocusStateExporter.State.Event
        if kind == "tick" {
            // 事件账本：tick 只刷 active/updatedAt，lastEvent 原样保留上一个重要事件（含 seq）——
            // 2 秒导出下 start/complete 绝不被 tick 冲掉（mod 按 seq 去重）。
            ev = chiyneLastSignificantEvent
                ?? .init(kind: "tick", title: active?.title ?? "", durationSec: nil)
        } else {
            ev = .init(kind: kind, title: completedTitle ?? active?.title ?? "",
                       durationSec: completedSec, seq: Int(Date.now.timeIntervalSince1970 * 1000))
            chiyneLastSignificantEvent = ev
        }
        FocusStateExporter.write(active: a, event: ev)
        // 多端跟随（#30）：同一份 runstate 也发布到 CloudKit（开关内部判；tick 内部 60 秒节流）。
        FocusFollow.publish(kind: kind, active: a, isPaused: isOnBreak, elapsed: currentElapsed)
    }

    /// 事件账本：本会话最近一次重要事件（start/complete），tick 导出时原样带上。
    private var chiyneLastSignificantEvent: FocusStateExporter.State.Event?

    /// 番茄"当前段之后还剩几个完整工作段"（纯函数、可单测）：nil 目标=不限段=-1；
    /// 工作段进行中=当前这段不算剩余（target−done−1）；休息段中=下一段起全是剩余（target−done）。
    static func pomodoroSegmentsRemaining(target: Int?, done: Int, inWork: Bool) -> Int {
        guard let target else { return -1 }
        return max(0, target - done - (inWork ? 1 : 0))
    }

    /// 番茄目标段数 = 计划时长 ÷ (工作段+休息段) **向上取整**（2026-07-12 Jason 定向上：番茄要陪到
    /// 任务收尾，宁多一段的头也不留尾巴没人陪；「段满转正计时/提前完成」权利一直在，不构成强制）。
    /// 无计划时长（计划外 bonus）/ 非正 → nil（不限段照旧）。纯函数、可单测。
    static func pomodoroAutoSegments(plannedSec: TimeInterval?) -> Int? {
        guard let p = plannedSec, p > 0 else { return nil }
        return max(1, Int(ceil(p / (PomodoroTimer.work + PomodoroTimer.rest))))
    }

    // MARK: - 执行守护（0.34：番茄段界自动推进 + 过逻辑日自动收尾）

    /// 1 秒守护 ticker——只在真 App 跑（persistsRunState 闸，单测不受扰）。
    private var guardianTimer: Timer?
    private func startGuardianTicker() {
        guard persistsRunState, guardianTimer == nil else { return }
        guardianTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.guardianTick() }
        }
    }

    func guardianTick() async {
        autoAdvancePomodoroIfDue()
        await autoCloseAtDayBoundaryIfNeeded()
        // E5b 分钟兜底脉冲（三层分频计算层）：搭现有 1s ticker、不新增定时器（菜单栏纪律）
        pulseCounter += 1
        if pulseCounter >= 60 { pulseCounter = 0; minutePulse?() }
    }

    /// 分钟脉冲出口（E5b）：组装点接 TimelineCoordinator.notePulse——过点未动的块靠它兜底重算。
    var minutePulse: (() -> Void)?
    private var pulseCounter = 0

    /// 段界自动推进（0.34 Jason 定：番茄自动跑完派生段数才收口，与聪音侧一致）：
    /// 段满自动 工作⇄休息；手动休息中冻结不推；「提前结束本段/转正计时」手动权照旧；
    /// 做满目标段走既有「转轻计时续走」温和收口。
    func autoAdvancePomodoroIfDue() {
        guard !isOnBreak, let phase = pomodoroPhase, phase.pendingConfirm else { return }
        confirmPomodoroNext()
    }

    /// 过逻辑日自动收尾（0.34 Jason 定：忘关的计时不跨天）：现在越过会话所属逻辑日的 4 点尾界 →
    /// 越界部分按休息扣除（投入诚实截到尾界，睡醒补收也不虚涨）、自动完成全部进行中
    /// （前台+并行后台，completeCurrent 的接替链会依次收干净）。语气=帮你收好，不是审计。
    func autoCloseAtDayBoundaryIfNeeded() async {
        let starts = (active.map { [$0.start] } ?? []) + background.map(\.start)
        guard let earliest = starts.min() else { return }
        let boundary = DayContext.endOfPlannableDay(earliest)
        guard Date.now >= boundary else { return }
        let over = Date.now.timeIntervalSince(boundary)
        if over > 1 {   // App 睡过 4 点才醒：越界时间按休息扣，投入截到日界线
            active?.pausedTotal += over
            for i in background.indices { background[i].pausedTotal += over }
        }
        DevLog.shared.info("执行", "过逻辑日（凌晨 4 点）——挂着的计时已帮你收好，投入截到日界线")
        if persistsRunState { BehaviorLog.record("完成", "过日界线自动收尾（投入截到 4:00）") }
        var hop = 0
        while (active != nil || !background.isEmpty), hop < 20 {
            hop += 1
            if active == nil { promoteFirstBackgroundIfAny() }
            if active != nil { await completeCurrent() }
        }
    }

    /// 当前这次休息已进行多久（仅休息中有意义）。
    var breakElapsed: TimeInterval {
        guard isOnBreak, let bs = breakStart else { return 0 }
        return max(0, Date.now.timeIntervalSince(bs))
    }

    /// 当前番茄钟段（仅 active 是番茄钟时；nil = 非番茄钟）。段满后停在满位、等点确定才切。
    /// 休息（手动 toggleBreak）期间**冻结**段内已用——与「休息=暂停当前块」契约一致；
    /// 休息结束时 toggleBreak 会把 pomoSegStart 后移相应时长，段内进度不被休息污染。
    var pomodoroPhase: PomodoroPhase? {
        guard let a = active, a.timingStyle == .pomodoro, let seg = pomoSegStart else { return nil }
        let endRef = isOnBreak ? (breakStart ?? .now) : .now
        let elapsed = max(0, endRef.timeIntervalSince(seg))
        let length = pomoIsRest ? PomodoroTimer.rest : PomodoroTimer.work
        return PomodoroPhase(kind: pomoIsRest ? .rest : .work, elapsedInPhase: elapsed, phaseLength: length)
    }

    /// 番茄钟段满后点「确定」/ 段中途「提前结束本段」，切下一段（工作 ⇄ 休息）。
    /// 0.17：不必等段满——用户可随时提前结束当前段（继续软化番茄的刚性）。
    /// 0.21：做满自设目标段数 → 温和落地：自动转轻计时续走（不是戛然而止）。
    func confirmPomodoroNext() {
        // 埋点（调研 D 组）：段满 vs 提前结束——pendingConfirm=段已满等确认
        let wasFull = pomodoroPhase?.pendingConfirm ?? false
        // 离开休息段(回到工作) → 累计这段休息时长，供「继续计时」算净专注（总时长扣掉番茄休息）
        if pomoIsRest, let seg = pomoSegStart {
            let endRef = isOnBreak ? (breakStart ?? .now) : .now
            pomoRestAccumulated += max(0, endRef.timeIntervalSince(seg))
        }
        if !pomoIsRest {
            pomoWorkSegmentsDone += 1   // 工作段→休息 = 完成一个工作段
            if persistsRunState {
                BehaviorLog.record("番茄", "工作段 \(pomoWorkSegmentsDone) 结束\(wasFull ? "（段满）" : "（提前）") → 休息")
            }
            if let target = pomoTargetSegments, pomoWorkSegmentsDone >= target {
                DevLog.shared.info("番茄", "做满自设的 \(target) 段 🎉 → 转轻计时续走")
                if persistsRunState { BehaviorLog.record("番茄", "做满 \(target) 段 → 转轻计时续走") }
                continueUntimed()
                return
            }
        } else if persistsRunState {
            BehaviorLog.record("番茄", "休息结束\(wasFull ? "（段满）" : "（提前）") → 第 \(pomoWorkSegmentsDone + 1) 个工作段")
        }
        pomoIsRest.toggle()
        pomoSegStart = .now
        persistRunState()
        if let s = liveSnapshot() { liveActivity.update(s) }
    }

    /// 实时改当前块的计时方式（0.21，Jason 拍板）：番茄**工作段进行中锁定**（预先承诺，工作段中不可逃）、
    /// 段满/休息中开放；非番茄随时可改。只改运行态（块存的 PlanBlock.timingStyle 不动）。
    var canChangeTimingNow: Bool {
        guard active != nil else { return false }
        guard let phase = pomodoroPhase else { return true }
        return phase.kind == .rest || phase.pendingConfirm
    }

    /// 转番茄可带目标段数（1/2/3；nil=不限），做满自动转轻计时续走。
    func changeTiming(to style: TimingStyle, pomodoroSegments: Int? = nil) {
        guard active != nil, canChangeTimingNow else { return }
        switch style {
        case .pomodoro:
            active?.timingStyle = .pomodoro
            pomoSegStart = .now      // 从现在起第一段专注
            pomoIsRest = false
            // 0.34：没显式给段数 → 按剩余计划时长派生（无计划时长/已超时 → 不限段照旧）
            pomoTargetSegments = pomodoroSegments
                ?? Self.pomodoroAutoSegments(plannedSec: activePlannedDuration.map { max(0, $0 - currentElapsed) })
            DevLog.shared.info("执行", "转番茄钟（\(pomoTargetSegments.map { "\($0) 段" } ?? "不限段")）")
        case .light, .none:
            if active?.timingStyle == .pomodoro {
                continueUntimed()    // 净专注折算 + 退出段循环（落到 .light）
            }
            active?.timingStyle = style
            DevLog.shared.info("执行", "转\(style == .light ? "轻计时" : "不计时")")
        }
        persistRunState()
        if let s = liveSnapshot() { liveActivity.update(s) }
        syncFocusShortcut()
    }

    /// 番茄段满/休息段中 →「继续计时」：转成往上记的计时（§5.10 到点行为，运行态非属性）。
    /// 从**净专注时长**起（总时长扣掉番茄休息段，与投入口径一致）；退出番茄段循环、从此不再打断。
    /// 只改运行态 active.timingStyle（块存的 PlanBlock.timingStyle 不动）。
    /// 0.20.5：休息段中也可切（段间=可改窗口）——当前这段还没结算的休息也要扣掉。
    func continueUntimed() {
        guard var a = active else { return }
        var restTotal = pomoRestAccumulated
        if pomoIsRest, let seg = pomoSegStart {
            let endRef = isOnBreak ? (breakStart ?? .now) : .now
            restTotal += max(0, endRef.timeIntervalSince(seg))
        }
        let netWork = max(0, currentElapsed - restTotal)
        a.timingStyle = .light        // 往上记显时长（不再有番茄段/提示）
        a.start = Date.now.addingTimeInterval(-(netWork + a.pausedTotal))   // 让 currentElapsed 续到净专注
        active = a
        pomoSegStart = nil
        pomoTargetSegments = nil
        if persistsRunState { BehaviorLog.record("番茄", "转继续计时（净专注续走）") }
        persistRunState()
        if let s = liveSnapshot() { liveActivity.update(s) }
        syncFocusShortcut()
    }

    /// 当前执行状态 → Live Activity 快照（无 active 则 nil）。
    private func liveSnapshot() -> LiveActivitySnapshot? {
        guard let a = active else { return nil }
        let mode: LiveActivityMode = a.timingStyle == .pomodoro ? .pomodoro : .light
        var phaseEndsAt: Date?
        if a.timingStyle == .pomodoro, let seg = pomoSegStart {
            phaseEndsAt = seg.addingTimeInterval(pomoIsRest ? PomodoroTimer.rest : PomodoroTimer.work)
        }
        return LiveActivitySnapshot(
            title: a.title,
            timerStart: Date.now.addingTimeInterval(-currentElapsed),
            pausedAt: isOnBreak ? (breakStart ?? .now) : nil,
            mode: mode, phaseEndsAt: phaseEndsAt, phaseIsRest: pomoIsRest)
    }

    /// active 块的计时风格（给 UI 决定显不显时长）。
    var activeStyle: TimingStyle? { active?.timingStyle }

    // MARK: - 动作

    // MARK: 并行接替（点子 #20，2026-07-10 过审）

    /// 前台完成后，「同时做」队首自动顶上「正在做」——计时无缝（沿用后台的 start/pausedTotal）、
    /// 其余并行块顺位前移。**只在完成时接替**（空档挂机=用户有意留空前台，不抢位）。
    /// 风格沿用计划块设置、但**绝不自动进番茄**（锁必须用户自己上，原则4④/7）→ 番茄降轻计时，转番茄用户手点。
    private func promoteFirstBackgroundIfAny() {
        guard active == nil, !background.isEmpty else { return }
        let run = background.removeFirst()
        let style = planned.first { $0.id == run.plannedID }?.timingStyle ?? .light
        active = ActiveBlock(plannedID: run.plannedID, title: run.title, start: run.start,
                             pausedTotal: run.pausedTotal,
                             timingStyle: style == .pomodoro ? .light : style,
                             cameFromBackground: true,
                             plannedDuration: planned.first { $0.id == run.plannedID }.map { $0.end.timeIntervalSince($0.start) })
        pomoRestAccumulated = 0   // 上一件的番茄残留不带给接替块
        pomoTargetSegments = nil
        DevLog.shared.info("执行", "并行接替：「\(run.title)」顶上前台续走（同时做剩 \(background.count) 件）")
        if persistsRunState { BehaviorLog.record("接替", run.title) }
    }

    /// 若当前前台块是并行接替自动顶上来的 → 放回「同时做」队首（计时保留），返回 true。
    /// 「开始别件/换一件」不该终结它（接替前这两个动作本不影响后台块）；明确点「完成」才落实际。
    private func demoteAutoPromotedActive() -> Bool {
        guard let a = active, a.cameFromBackground else { return false }
        background.insert(BackgroundRun(plannedID: a.plannedID, title: a.title,
                                        start: a.start, pausedTotal: a.pausedTotal), at: 0)
        active = nil
        if persistsRunState { BehaviorLog.record("接替回队", a.title) }   // 接替块被换走（≠被完成）
        return true
    }

    /// 真正开始某块（计时从现在起）。空档的「开始：下一件」/「开始任务」走这里。
    /// startAt（SPEC §19 W8）：审批通过的回溯起点（「你大概从 13:00 起就在做」）；nil = 从现在起。校验在审批执行器里做。
    func startBlock(_ item: PlannedItem, at startAt: Date? = nil) async {
        if usesCanonicalTiming, let tasks = canonicalTasks {
            await tasks.start(title: item.title, relatedRecordId: "PlanBlock:" + item.id.uuidString, mode: item.timingStyle == .pomodoro ? .pomodoro : .light, focusMinutes: item.timingStyle == .pomodoro ? Int(PomodoroTimer.work / 60) : nil, startedAt: startAt)
            selected = nil
            return
        }
        if !demoteAutoPromotedActive() { await recordActiveIfAny() }
        let begin = min(startAt ?? .now, .now)
        // 计划内的块：定格开始那一刻的计划时长（item 可能来自 selected/旧缓存，以 planned 里的当前行为准）。
        let plannedNow = planned.first { $0.id == item.id }
        active = ActiveBlock(plannedID: item.id, title: item.title, start: begin,
                             timingStyle: item.timingStyle,
                             plannedDuration: plannedNow.map { $0.end.timeIntervalSince($0.start) })
        selected = nil
        isOnBreak = false
        breakStart = nil
        pomoSegStart = (item.timingStyle == .pomodoro) ? begin : nil   // 番茄钟从工作段起
        pomoIsRest = false
        pomoWorkSegmentsDone = 0
        pomoRestAccumulated = 0
        // 0.34（Jason 定）：计划自带番茄 → 目标段数按计划时长派生并随运行态持久——跑完这些段才收口
        //（此前=nil 不限段+段满停等确认，2h 任务跑一段就像「结束」了）
        pomoTargetSegments = (item.timingStyle == .pomodoro)
            ? Self.pomodoroAutoSegments(plannedSec: item.end.timeIntervalSince(item.start)) : nil
        if let n = pomoTargetSegments {
            DevLog.shared.info("番茄", "「\(item.title)」按计划时长派生 \(n) 段（25+5，向上取整）")
        }
        breakCount = 0
        persistRunState()
        refreshPreview(enteringLiveMode: true)
        presentingFollowActivity = false
        if let s = liveSnapshot() { liveActivity.start(s) }
        exportFocusState(event: "start")   // 聪音：开始一件事→起番茄/专注
        syncFocusShortcut()
        if persistsRunState { BehaviorLog.record("开始", item.title) }
    }

    /// 计划外临时事项直接开始（menu bar「+ 新事项…」，SPEC §11 ① 连带、点子 #1，2026-07-09 过审）：
    /// **不写 PlanStore**（写计划只有 确认写入 + 对账回流 两个入口，menu bar 不当第三写者）——
    /// 它是 §3.5 的 bonus：计划外块 id 不在 planned 里，完成即记蓝色实际，复盘里无匹配计划 = 计划外高亮（算赢）。
    /// 默认轻计时；开始即进实时模式（同 startBlock）。
    func startAdHoc(title: String, timingStyle: TimingStyle = .light, at startAt: Date? = nil) async {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let begin = min(startAt ?? .now, .now)
        let item = PlannedItem(id: UUID(), title: name, start: begin,
                               end: begin.addingTimeInterval(3600), timingStyle: timingStyle)
        await startBlock(item, at: startAt)   // 复用前台开始：id 是新 UUID、不在 planned → 天然 bonus
    }

    /// 同时做一件计划外的事（后台并行 bonus）。
    func startAlsoAdHoc(title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let item = PlannedItem(id: UUID(), title: name, start: .now,
                               end: Date.now.addingTimeInterval(3600))
        startAlso(item)
    }

    /// 换一件：结束当前 → 把目标设为「待开始」（**不立即开始**）；要再点「开始任务」才计时。
    /// 接替上来的块例外：回「同时做」继续，不被结束（点子 #20 约束③）。
    func switchTo(_ item: PlannedItem) async {
        if !demoteAutoPromotedActive() { await recordActiveIfAny() }
        active = nil
        pomoSegStart = nil
        selected = item
        if persistsRunState { BehaviorLog.record("换一件", item.title) }
        persistRunState()
        refreshPreview()
        liveActivity.end()
        syncFocusShortcut()
    }

    /// 开始之前「换一件」选中的那件。
    func startSelected() async {
        guard let s = selected else { return }
        await startBlock(s)
    }

    /// 早通知 deep-link（0.23 A）：把下一件设为「待开始」，等用户点「开始任务」。
    /// **绝不自动开始计时**——点通知可能是误触，开始必须是明确动作。
    func primeNextForStart() async {
        if !loaded { await loadToday() }
        guard active == nil, selected == nil, let next = nextSuggested else { return }
        selected = next
        persistRunState()
    }

    /// 同时开始另一件（后台并行）：不动前台正在计时的块，这件在后台自己按墙钟跑。
    func startAlso(_ item: PlannedItem) {
        if usesCanonicalTiming, let tasks = canonicalTasks {
            tasks.queueStart(title: item.title, relatedRecordId: "PlanBlock:" + item.id.uuidString)
            return
        }
        guard item.id != active?.plannedID,
              !isRunningInBackground(item) else { return }
        background.append(BackgroundRun(plannedID: item.id, title: item.title, start: .now))
        if persistsRunState { BehaviorLog.record("同时做", item.title) }
        persistRunState()
        refreshPreview(enteringLiveMode: true)   // 从橙色预览里剔除它（正在做，不该再出现在"从现在起"）
    }

    /// 完成一件后台并行任务 → 记 [start, now] 进蓝色实际 → 移出后台。
    func completeBackground(_ id: UUID) async {
        guard let i = background.firstIndex(where: { $0.id == id }) else { return }
        let net = backgroundElapsed(background[i])   // 净时长（扣休息），在移除前算
        let run = background.remove(at: i)
        done.append(ActualRecord(plannedID: run.plannedID, title: run.title,
                                 start: run.start, end: run.start.addingTimeInterval(net)))
        // 后台块也是一次会话（墙钟粗计时，不计段数/休息）
        sessionStore?.record(blockID: run.plannedID, title: run.title,
                             start: run.start, end: .now,
                             timingStyle: TimingStyle.none,
                             pomodoroWorkSegments: nil, interruptions: 0)
        persistRunState()
        await flushActuals()
        refreshPreview()
        // 聪音（0.28.4 补协议缝）：后台完成也导出 complete——此前只有前台 completeCurrent 导出，
        // 后台做成的事游戏永远收不到经验。mod v0.5 按「title ≠ 正在驱动的标题」识别后台完成，
        // 手动按原生公式结算、不碰前台计时器。
        exportFocusState(event: "complete", completedTitle: run.title, completedSec: Int(net))
        if persistsRunState {
            let wasBonus = !planned.contains { $0.id == run.plannedID }   // 成就 A1：计划外后台块
            BehaviorLog.record("完成", run.title + "（后台）" + (wasBonus ? "（计划外）" : ""))
        }
    }

    /// 完成当前块 → 落盘 → 「同时做」队首自动接替（点子 #20）；没有并行块才回空档。
    /// 收尾信号用（0.38，#33）：最后一次完成的时刻（会话内存态即可——收尾卡只在当天使用中出现）。
    private(set) var lastCompletionAt: Date?

    /// SPEC §19 C1：做完一件事的回调（智能体桥接据此写事件；未开启时桥接自己不写）。参数=标题、已用秒数。
    var onBlockFinished: ((String, Int) -> Void)?

    func completeCurrent() async {
        if usesCanonicalTiming, let tasks = canonicalTasks, let session = tasks.primary {
            let title = active?.title, sec = Int(currentElapsed)
            await tasks.act(.finish, on: session)
            if let title { onBlockFinished?(title, sec) }
            return
        }
        lastCompletionAt = .now
        let doneTitle = active?.title           // 捕获（recordActiveIfAny 后 active 清空）
        let doneSec = Int(currentElapsed)
        let wasPromoted = active?.cameFromBackground ?? false   // 埋点：接替块的命运=被完成
        // 埋点（成就 A1）：计划外 bonus——active 的 id 不在今日计划里（startAdHoc 的新 UUID）＝§3.5 的赢
        let wasBonus = active.map { a in !planned.contains { $0.id == a.plannedID } } ?? false
        await recordActiveIfAny()
        active = nil
        pomoSegStart = nil
        promoteFirstBackgroundIfAny()           // 并行接替：B 顶上、C 前移（无并行块=原样回空档）
        persistRunState()
        refreshPreview()
        liveActivity.end()
        if let s = liveSnapshot() { liveActivity.start(s) }   // 接替块继续占灵动岛/锁屏
        exportFocusState(event: "complete", completedTitle: doneTitle, completedSec: doneSec)   // 聪音：完成→经验值+欢快
        syncFocusShortcut()
        if persistsRunState, let t = doneTitle {
            BehaviorLog.record("完成", t + (wasPromoted ? "（接替块）" : "") + (wasBonus ? "（计划外）" : ""))
        }
        if let t = doneTitle { onBlockFinished?(t, doneSec) }
    }

    /// Focus Filter 联动（§5.7，0.20.4）：进入配置了「自动休息」的系统专注 → 开始休息；
    /// 退出 → 只结束**我们开的**休息（focusBreakActive 标记）——用户手动开的休息不被误关。
    private var focusBreakActive = false
    func focusAutoBreak(_ enable: Bool) async {
        if enable {
            guard !isOnBreak else { return }   // 已在休息（用户手动开的）：不接管、退出时也不动它
            await toggleBreak()
            focusBreakActive = true
            DevLog.shared.info("专注联动", "进入专注 → 自动休息")
        } else {
            guard focusBreakActive else { return }
            focusBreakActive = false
            if isOnBreak { await toggleBreak() }
            DevLog.shared.info("专注联动", "退出专注 → 自动回来")
        }
    }

    // MARK: 分心自动休息（#26，0.30）：感知层（mac 感知器 / iOS 快捷指令自动化）→ 这里换挡。
    // 语义同 focusAutoBreak（外部信号→自动休息→只收自己开的休息），另有红线④的撤销回填。

    private var distractionBreakActive = false
    private var autoBreakStart: Date?
    private var autoBreakActiveID: UUID?
    /// 最近一次已结束的自动休息（「刚才不算休息」撤销窗口用）。
    private(set) var lastAutoBreak: (start: Date, end: Date)?

    func distractionAutoBreak(_ enable: Bool) async {
        if enable {
            guard active != nil, !isOnBreak else { return }   // 空档不休；手动休息不接管
            await toggleBreak()
            distractionBreakActive = true
            autoBreakStart = .now
            autoBreakActiveID = active?.plannedID
            if persistsRunState { BehaviorLog.record("自动休息", "开始（感知）") }   // 红线②：不记来源
            DevLog.shared.info("分心感知", "像是去休息了 → 计时自动暂停")
        } else {
            guard distractionBreakActive else { return }
            distractionBreakActive = false
            if isOnBreak { await toggleBreak() }
            if let s = autoBreakStart { lastAutoBreak = (s, .now) }
            autoBreakStart = nil
            if persistsRunState { BehaviorLog.record("自动休息", "结束（回来了）") }
            DevLog.shared.info("分心感知", "回来了 → 计时自动继续")
        }
    }

    /// 撤销入口是否可见：最近一段自动休息结束后 10 分钟内，且还在做同一件事（换了件就别改旧账）。
    var canUndoAutoBreak: Bool {
        guard let b = lastAutoBreak, active?.plannedID == autoBreakActiveID else { return false }
        return Date.now.timeIntervalSince(b.end) < 600
    }

    /// 「刚才不算休息」（红线④）：把最近那段自动休息从暂停里扣回来——净投入回填，
    /// 感知误判（比如在 B 站查资料）一键纠正，判定权永远在用户手里。
    func undoLastAutoBreak() {
        guard canUndoAutoBreak, let b = lastAutoBreak else { return }
        let dur = max(0, b.end.timeIntervalSince(b.start))
        if active != nil { active?.pausedTotal = max(0, (active?.pausedTotal ?? 0) - dur) }
        for i in background.indices { background[i].pausedTotal = max(0, background[i].pausedTotal - dur) }
        if let seg = pomoSegStart { pomoSegStart = seg.addingTimeInterval(-dur) }   // 撤销 toggleBreak 结束时的段点后移
        lastAutoBreak = nil
        if persistsRunState { BehaviorLog.record("自动休息", "撤销（刚才不算休息）") }
        persistRunState()
        if let s = liveSnapshot() { liveActivity.update(s) }
    }

    /// 单按钮 toggle：开始休息 ⇄ 结束休息。休息=暂停（保留当前块），结束后回来继续同一件。
    func toggleBreak() async {
        if usesCanonicalTiming, let tasks = canonicalTasks, let session = tasks.primary {
            await tasks.act(session.status == .paused ? .resume : .pause, on: session)
            return
        }
        if isOnBreak {
            if let bs = breakStart {
                let pause = Date.now.timeIntervalSince(bs)
                if active != nil { active?.pausedTotal += pause }
                // 后台并行块也一起把这段休息扣掉（rest=从所有正在做的事休息，0.17）
                for i in background.indices { background[i].pausedTotal += pause }
                // 番茄段起点同步后移，让「段内已用」把这段休息扣掉（休息=暂停，段不吃休息时间）
                if let seg = pomoSegStart { pomoSegStart = seg.addingTimeInterval(pause) }
            }
            isOnBreak = false
            breakStart = nil
        } else {
            isOnBreak = true
            breakStart = .now
            if active != nil { breakCount += 1 }   // 中途休息计入会话 interruptions
        }
        if persistsRunState { BehaviorLog.record("休息", isOnBreak ? "开始" : "结束") }
        exportFocusState(event: isOnBreak ? "pause" : "resume")
        persistRunState()
        if let s = liveSnapshot() { liveActivity.update(s) }
    }

    /// 按标题把某块标完成（App Intent「标记完成」/ Claude Code 完成信号 §2.1 路径c）。
    /// 相似度 ≥0.6 的最佳匹配：前台块 → completeCurrent（保真计时）；后台并行块 → completeBackground；
    /// 其余计划块 → 按计划时段记实际（同「提醒打勾」被动信号口径）。返回匹配标题，nil=没找到。
    @discardableResult
    func markDone(titleLike title: String) async -> String? {
        if !loaded { await loadToday() }
        if let a = active, TitleMatch.similarity(a.title, title) >= 0.6 {
            let t = a.title
            await completeCurrent()
            return t
        }
        if let run = background.first(where: { TitleMatch.similarity($0.title, title) >= 0.6 }) {
            await completeBackground(run.id)
            return run.title
        }
        let candidates = planned.filter { !isDone($0) }
        guard let best = candidates.max(by: {
                  TitleMatch.similarity($0.title, title) < TitleMatch.similarity($1.title, title) }),
              TitleMatch.similarity(best.title, title) >= 0.6 else {
            DevLog.shared.warn("执行", "标记完成：今日计划里没找到匹配「\(title)」的块")
            return nil
        }
        done.append(ActualRecord(plannedID: best.id, title: best.title,
                                 start: best.start, end: best.end))
        await flushActuals()
        // 进展信号（E5b 旁路修补）：外部信号入口也要发——排日程页徽标 + TimelineCoordinator 重算都靠它
        NotificationCenter.default.post(name: ExecutionProgressSignal.changed, object: nil)
        // 同步等预览更新（不 fire-and-forget）：Intent 返回时状态已就绪；
        // 也避免游离 Task 活过调用方作用域（单测里曾撞已析构的内存库 → SwiftData trap）。
        await updatePreview()
        DevLog.shared.info("执行", "标记完成：\(best.title)（来自快捷指令/外部信号）")
        return best.title
    }

    // MARK: - 落盘

    private func recordActiveIfAny() async {
        guard let a = active else { return }
        // 收尾休息（若正暂停）：先把这段休息计入 pausedTotal。
        // 后台并行块也一起扣（bug 修 0.26.15：之前只扣前台——休息中直接完成/换走的话，
        // isOnBreak 被清掉，这段冻结的休息会突然算进后台块的投入）。
        if isOnBreak, let bs = breakStart {
            let pause = Date.now.timeIntervalSince(bs)
            active?.pausedTotal += pause
            for i in background.indices { background[i].pausedTotal += pause }
            isOnBreak = false
            breakStart = nil
        }
        // 工程债5：实际块时长 = 净投入（扣掉中途休息），休息不计入有效投入。
        // 日历块写 [start, start+净]，结束时间会比墙钟早 pausedTotal——以"有效投入"为准。
        let paused = active?.pausedTotal ?? 0
        let effective = max(0, Date.now.timeIntervalSince(a.start) - paused)
        done.append(ActualRecord(plannedID: a.plannedID, title: a.title,
                                 start: a.start, end: a.start.addingTimeInterval(effective)))
        // 执行会话落库（M6b 细化）：净时长 + 番茄段数 + 休息次数，给趋势统计铺数据
        sessionStore?.record(blockID: a.plannedID, title: a.title,
                             start: a.start, end: a.start.addingTimeInterval(effective),
                             timingStyle: a.timingStyle,
                             pomodoroWorkSegments: a.timingStyle == .pomodoro ? pomoWorkSegmentsDone : nil,
                             interruptions: breakCount)
        pomoWorkSegmentsDone = 0
        breakCount = 0
        await flushActuals()
    }

    /// 把 done 写进蓝色「实际」日历——**合并不覆盖**（工程债修复 2026-07-04）：
    /// 先读日历已有实际、与 done 做 union 再写，别处产生的实际（复盘回填/另一台设备）不会被删。
    private func flushActuals() async {
        // 盖章：做的是计划块 → 盖计划块的 id（同一 UUID：绿色让位、蓝带同章出现）；
        // 计划外 bonus → 盖记录自己的 id（新章）。
        // P4 Q4c：被动推断的（固定块到点）只记数据、不画蓝。
        guard !done.isEmpty else { return }
        let drafts = done.filter { !$0.isAuto }.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .actual,
                               blockID: $0.plannedID ?? $0.id)
        }
        do {
            var merged: [CalendarEventDraft] = []
            if !drafts.isEmpty {
                let existing = (try? await calendarStore.read(kind: .actual)) ?? []
                merged = CalendarMerge.union(existing: existing, additions: drafts, kind: .actual)
                try await calendarStore.write(merged)
            }
            // 蓝对账 A2：实际同时落 PlanStore 真相源（日历成投影）；按 id 幂等，不堆重复。
            try? planStore.upsertActuals(done.map {
                ActualBlock(id: $0.plannedID ?? $0.id, title: $0.title, start: $0.start, end: $0.end,
                            state: $0.isAuto ? .auto : .recorded)
            })
            // P4 Q2：做完的只剩蓝 → 重画今天（这件的绿色让位）
            await projection?.repaintToday(reason: "记下实际")
            // 双向：App 内完成 → 回勾对应提醒事项完成（幂等；无对应提醒的 id 自动忽略）。
            await reminderStore.markCompleted(blockIDs: Set(done.compactMap(\.plannedID)))
            DevLog.shared.info("执行", "实际已更新：日历合并 \(merged.count) · 真相源 upsert \(done.count)")
        } catch {
            lastError = error.localizedDescription
            DevLog.shared.error("执行", "写入实际日历失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 橙色预览（全天连续 re-flow）

    /// 完成 / 开始某块后，把剩余从此刻重排、写橙色预览。后台跑，不挡按钮。
    /// Task 记在手里（非游离）：单测能 await 它落地——游离 Task 活过测试作用域撞已析构内存库会崩 host（踩过）。
    /// enteringLiveMode：真正**开始**一件事的动作传 true——某逻辑日第一次开始即进实时模式（0.23 A）。
    /// 串在同一个 Task 里保证时序：先淡绿（project），再铺"从现在起"的橙（updatePreview）。
    private var previewTask: Task<Void, Never>?
    private func refreshPreview(enteringLiveMode: Bool = false) {
        // 进展信号（0.24 C2）：每个改变执行态的动作都会走到这里——排日程页据此刷新精修台/亮新鲜度徽标
        NotificationCenter.default.post(name: ExecutionProgressSignal.changed, object: nil)
        previewTask = Task {
            if enteringLiveMode { await enterLiveModeIfNeeded() }
            await updatePreview()
        }
    }

    /// 实时模式合并（0.23 A，SPEC §11 ①）：「开始今天」按钮已退役——开始工作这个动作本身就是信号。
    /// 某逻辑日第一次 startBlock/startAlso 时：标记已开始（iCloud KV 两端同步）——时间线协调器（影子期）只在已开工的日子动真相。
    /// P4 Q2：开工后**不再清空绿色**（1b 实时态退役），日历画面不因开工而变。
    private func enterLiveModeIfNeeded() async {
        guard let startedDays else { return }
        let label = DayContext.logicalDay(offset: 0)
        guard !startedDays.isStarted(label) else { return }
        startedDays.markStarted(label)
    }

    /// 等最近一次预览刷新落地（单测用；正常运行无人等它、照旧不挡按钮）。
    func waitForPreview() async { await previewTask?.value }

    /// 每次动作后的刷新点（小组件 + 聪音投影）。
    /// P4 Q1：橙色「全天连续 reflow 预览」链退役（§13 E5f 呈现半）——不再另算一套排法写进预览日历；
    /// 「从现在起」的时间线由时间线协调器维护绿色真相，日历跟着它画（ProjectionService 跟随）。
    private func updatePreview() async {
        publishIntegrations()
    }

    // MARK: 聪音待办投影 + 回流（SPEC §11 过审 2026-07-10）

    /// 小组件快照 + 聪音待办投影：状态落定点统一从这里发布。
    private func publishIntegrations() {
        publishWidgetSnapshot()
        guard persistsRunState else { return }   // 测试 host 共享真容器：单测不写桥文件（见 exportFocusState 注释）
        FocusStateExporter.writeTodoProjection(
            Self.todoProjectionItems(planned: planned, isDone: isDone))
    }

    /// 投影内容（纯函数、可单测）：今天的计划事项 {id, title, done}（锚点在 loadToday 已剔除）。
    static func todoProjectionItems(planned: [PlannedItem],
                                    isDone: (PlannedItem) -> Bool) -> [FocusStateExporter.TodoItem] {
        planned.map { .init(id: $0.id.uuidString, title: $0.title, done: isDone($0)) }
    }

    /// 聪音回流：游戏里勾完成 → 记 BC 完成（=手动完成的又一入口，同「提醒打勾」先例；§5.13 仍是手动）。
    func consumeChiyneInbox() async {
        let ids = FocusStateExporter.consumeInbox()
        guard !ids.isEmpty else { return }
        if !loaded { await loadToday() }
        for id in ids { await complete(planID: id) }
        DevLog.shared.info("聪音", "游戏里勾完成回流 \(ids.count) 件")
    }

    /// 按计划块 id 完成：前台→completeCurrent（保真计时）；后台并行→completeBackground；
    /// 其余计划块→按计划时段记实际（同「提醒打勾」被动信号口径）。已完成/不认识的 id 忽略（幂等）。
    func complete(planID id: UUID) async {
        if active?.plannedID == id { await completeCurrent(); return }
        if let run = background.first(where: { $0.plannedID == id }) { await completeBackground(run.id); return }
        guard let item = planned.first(where: { $0.id == id }), !isDone(item) else { return }
        done.append(ActualRecord(plannedID: item.id, title: item.title, start: item.start, end: item.end))
        await flushActuals()
        // 进展信号（E5b 旁路修补②）：聪音回流完成也要发（此前只有 refreshPreview 一处发）
        NotificationCenter.default.post(name: ExecutionProgressSignal.changed, object: nil)
        await updatePreview()
    }

    /// 立即补写一份聪音状态（menu bar tick 发现"联动开着+有任务在进行+状态文件缺失"时调；
    /// 场景=任务进行中途才开联动开关，不用等下一个事件/5 分 tick）。
    func exportFocusStateNow() { exportFocusState(event: "tick") }

    // MARK: 番茄 ⇄ 系统专注（2026-07-10 初审通过 v1，macOS）

    /// 当前是否处于"番茄专注"状态（已跑过开始快捷指令、还没跑结束的）。
    private var pomodoroFocusActive = false

    /// 幂等状态机：进番茄 → 跑开始快捷指令；出番茄（完成/换件/转轻计时/不计时）→ 跑结束快捷指令。
    /// 在每个改变 active/计时风格的动作末尾调一次即可，重复调用无副作用。
    private func syncFocusShortcut() {
        #if os(macOS)
        guard persistsRunState else { return }   // 单测不跑真快捷指令（共享 UserDefaults 的老坑）
        let inPomodoro = active?.timingStyle == .pomodoro
        if inPomodoro, !pomodoroFocusActive {
            FocusShortcutRunner.pomodoroDidStart()
            pomodoroFocusActive = true
        } else if !inPomodoro, pomodoroFocusActive {
            FocusShortcutRunner.pomodoroDidEnd()
            pomodoroFocusActive = false
        }
        #endif
    }
}

// MARK: - 执行进展只读接缝（0.24 C2）：精修台的"过去只读"边界数据源

extension ExecutionViewModel: ExecutionProgressReading {
    var settledPlannedIDs: Set<UUID> {
        var ids = Set(done.compactMap(\.plannedID))
        if let a = active?.plannedID { ids.insert(a) }
        for run in background { if let p = run.plannedID { ids.insert(p) } }
        return ids
    }

    /// 活预报（E5b）：口径同 updatePreview ①——剩余 = 计划时长 − 已投入，下限 60s。
    var activePrediction: ActivePrediction? {
        guard let a = active, let pid = a.plannedID,
              let p = planned.first(where: { $0.id == pid }) else { return nil }
        let remain = max(60, (activePlannedDuration ?? p.end.timeIntervalSince(p.start)) - currentElapsed)
        return ActivePrediction(id: pid, start: a.start,
                                end: Date.now.addingTimeInterval(remain))
    }
}
