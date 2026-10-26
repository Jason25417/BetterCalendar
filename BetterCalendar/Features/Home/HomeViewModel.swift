//
//  HomeViewModel.swift
//  BetterCalendar
//
//  排今天 → 可编辑草稿（拖排序/改标题时间/标固定要紧/删加）→ 自然语言微调 → 确认写入。
//  写入走假日历（开发期常用），不碰系统。
//

import Foundation
import Observation
import SwiftUI   // Array.move(fromOffsets:toOffset:) 来自 SwiftUI

// EditableBlock 已挪到 Models/EditableBlock.swift（架构修缮 2026-07-08：
// Services 层的 DraftSnapshotStore 引用它曾构成 Services→Features 反向依赖——模型就该住 Models）。

/// 草稿从哪来：决定切目标日/重进页面时怎么对待当前列表。
enum DraftSource: String {
    case empty       // 什么都没有
    case arranged    // 刚「排今天」出的新草稿，还没确认——切日走平移、不被自动加载覆盖
    case loaded      // 从真相源加载的已确认计划——切日即切内容；编辑只标未保存，「确认写入」才落库（0.16 文件模型）
}

@Observable
final class HomeViewModel {
    private let arrangeDay: ArrangeDayUseCase
    private let refiner: PlanRefining
    private let calendarStore: CalendarReading   // 只读角色（排程上下文 busy）；写日历一律走 projection（CalendarSyncEngine）
    private let reminderStore: ReminderStore
    private let exporter: ICSExporting
    private let planStore: PlanStore           // ⚠️ 全 App 唯一的写者（PlanWriting）：只有「确认写入」落库
    private let projection: ProjectionService  // PlanStore→日历 单向投影（先写真相源、再投影）
    private let notifier: NotificationScheduling
    private let longTaskStore: LongTaskStore?   // 「在途」池（M10）；nil=不入池（旧测试兼容）
    private let routines: RoutineTemplateStore?  // K1 例行模板；nil=不物化（旧测试兼容）
    private let draftStore: DraftSnapshotStore? // 草稿快照（崩溃/重启还原）；nil=不持久化
    private let looseDays: LooseDayStore?        // 松散日：LLM 识别"想松散"→标目标日（§5.12）；nil=不标
    private let startedDays: StartedDayStore?    // 绿色淡出：开始今天后进实时模式、绿色从日历淡出；nil=不淡出
    private let progress: ExecutionProgressReading?  // 0.24 C2：精修台"过去只读"边界（已完成/进行中）；nil=不感知
    /// 时钟注入缝（2026-07-14，根治深夜测试炸弹）：实时日语义（isLive/精修底/收口/过去只读/智能插空）
    /// 一律从这里取「现在」；产品默认真实时钟（行为不变），测试注入固定时刻与真实时间解耦。
    /// 通知的过点守卫（fire > .now）保持真实墙钟——通知按墙钟响，不随注入。
    private let now: () -> Date

    var inputText: String = ""
    var refineText: String = ""
    /// 排哪天（无感默认：晚上→明天 / 白天·凌晨→今天；可点标签改）。
    var targetDay: Date = DayContext.defaultTargetDay(.now)
    var note: String?
    var blocks: [EditableBlock] = []
    var draftSource: DraftSource = .empty
    var isWorking: Bool = false
    var errorText: String?
    var committedCount: Int?
    /// 状态行 A（0.26 ABC）：排今天成功后的确定性状态「排好 N 件」（与模型 note=B 叠加显示）；编辑/确认/切日即清。
    private(set) var arrangedCount: Int?
    /// 状态行 C（#15，2026-07-11 审核定稿）：AI 微调完成后的**确定性**反馈——N=本地 diff 出的事实。
    /// 审核结论：模型自由回复通道不开（可能违措辞红线且无法事前保证）；模型嗓音只走宪法约束的 note(B)。
    /// 生命周期同 A：新操作/编辑/确认/切日即清。
    private(set) var refinedChangeCount: Int?
    /// 解析识别到、待确认入池的长期事项（确认写入时入「在途」）。
    var pendingLongTasks: [ParsedLongTask] = []
    /// 未保存修改（0.16 文件模型，D-f）：任何编辑/新草稿置真；「确认写入」=保存清零。
    private(set) var hasUnsavedChanges = false
    /// 上次退出时留下的未保存修改（D-g：不自动还原，顶部小字邀请「恢复/丢弃」）。
    private(set) var pendingRestore: DraftSnapshot?
    /// 新鲜度徽标（0.24 C2，SPEC §11 ④）：编辑期间底层（真相源/执行进展）变了 → 亮中性小条，
    /// 出路两个：「载入最新」（放弃本页）或什么都不点继续编辑（确认时以本页为准=最后动作赢）。绝不弹窗、不自动合并。
    private(set) var freshness = false
    /// 新鲜度来源（v2，Jason 2026-07-10）：告诉用户"和你草稿对不上的最新内容从哪来"，
    /// 在预览两边前先给个判断锚、降理解压力。
    enum FreshnessSource { case calendarEdit, reflow, external
        var label: String {
            switch self {
            case .calendarEdit: return "你在系统日历里改了这天"
            case .reflow: return "你的执行进展触发了重排"
            case .external: return "别的设备同步来的更新"
            }
        }
    }
    private(set) var freshnessSource: FreshnessSource = .external

    init(arrangeDay: ArrangeDayUseCase, refiner: PlanRefining,
         calendarStore: CalendarReading, reminderStore: ReminderStore, exporter: ICSExporting,
         planStore: PlanStore, projection: ProjectionService,
         notifier: NotificationScheduling,
         longTaskStore: LongTaskStore? = nil, draftStore: DraftSnapshotStore? = nil,
         looseDays: LooseDayStore? = nil, startedDays: StartedDayStore? = nil,
         progress: ExecutionProgressReading? = nil,
         routines: RoutineTemplateStore? = nil,
         now: @escaping () -> Date = { .now }) {
        self.arrangeDay = arrangeDay
        self.refiner = refiner
        self.calendarStore = calendarStore
        self.reminderStore = reminderStore
        self.exporter = exporter
        self.planStore = planStore
        self.projection = projection
        self.notifier = notifier
        self.longTaskStore = longTaskStore
        self.draftStore = draftStore
        self.looseDays = looseDays
        self.startedDays = startedDays
        self.progress = progress
        self.routines = routines
        self.now = now
        self.targetDay = DayContext.defaultTargetDay(now())   // 重锚默认目标日到注入时钟（默认闭包下与原值等价）
        restoreDraftIfAny()
    }

    // MARK: - 草稿快照（崩溃/重启还原；Jason 定 2026-07-04）

    /// 每次草稿变更即整份落盘（几 KB JSON，无感）；HomeView 对 inputText 变化也会调它。
    /// 0.23 C：按日落盘——每个目标日一页草稿本（SPEC §11 ③）。
    func persistDraft() {
        guard let draftStore else { return }
        draftStore.save(DraftSnapshot(
            inputText: inputText,
            targetDay: targetDay,
            draftSourceRaw: draftSource.rawValue,
            blocks: blocks.map(DraftSnapshot.Block.init(from:)),
            pendingLongTasks: pendingLongTasks.map {
                DraftSnapshot.PendingLongTask(title: $0.title, deadline: $0.deadline,
                                              cadenceMinutesPerWeek: $0.cadenceMinutesPerWeek,
                                              checkpoints: $0.checkpoints)
            },
            savedAt: .now,
            dirty: hasUnsavedChanges), day: targetDay)
    }

    /// 启动检查（0.16，D-g）：**永远先显示已保存态**；上次退出时若这一页留有未保存修改，
    /// 只存入 pendingRestore——顶部一行小字邀请「恢复/丢弃」，点了恢复才应用。
    /// 0.23 C：只查启动目标日那一页；别的日子的草稿等切过去时静默还原（切日=换页，页本来就在）。
    private func restoreDraftIfAny() {
        guard let snap = draftStore?.load(day: targetDay) else { return }
        inputText = snap.inputText
        let wasDirty = snap.dirty ?? (snap.draftSourceRaw == DraftSource.arranged.rawValue)
        if wasDirty, !snap.blocks.isEmpty {
            pendingRestore = snap
        }
    }

    /// 用户点「恢复」：应用上次未保存的修改（快照即当前目标日这一页，无需再跳日）。
    func applyPendingRestore() {
        guard let snap = pendingRestore else { return }
        blocks = snap.blocks.map(\.editable)
        draftSource = DraftSource(rawValue: snap.draftSourceRaw) ?? .arranged
        pendingLongTasks = snap.pendingLongTasks.map {
            ParsedLongTask(title: $0.title, deadline: $0.deadline,
                           cadenceMinutesPerWeek: $0.cadenceMinutesPerWeek,
                           checkpoints: $0.checkpoints)
        }
        hasUnsavedChanges = true
        pendingRestore = nil
        scheduleAutosave()   // W19：恢复回来的改动照样自动保存
    }

    /// 用户点「丢弃」：清掉恢复入口并以当前（已保存）状态覆盖快照。
    func dismissPendingRestore() {
        pendingRestore = nil
        persistDraft()
    }

    /// 放弃未保存修改 → 回到该目标日的已保存计划（文件模型的「不保存关闭」）。
    func discardDraft() {
        blocks = []
        pendingLongTasks = []
        note = nil
        draftSource = .empty
        hasUnsavedChanges = false
        arrangedCount = nil; refinedChangeCount = nil
        loadConfirmedPlan()
        persistDraft()
    }

    // MARK: - 自动加载目标日计划（2026-07-01 Jason 定）

    /// 收口信号（0.28 提案A）：实时日 且（剩余为空=都做完/都流逝 ∨ 已过收工线）——
    /// 强结束信号，收口卡据此出现（还要叠加「今天还没记录」，由视图查日记）。
    var wrapUpSignal: Bool {
        guard isLiveTargetDay else { return false }
        // 剩余为空：重铺口径下 blocks 本来就只有剩余；W23 原样口径下按「还没落定、还没过去」数（两种口径结果一致）
        let settled = progress?.settledPlannedIDs ?? []
        let remaining = blocks.contains { $0.end > now() && !settled.contains($0.id) }
        return !remaining || now() >= WorkHoursSettings.effectiveWindDown(from: now())
    }

    /// 目标日是否处于实时模式（0.24 C2）：已开始 且 是逻辑今天——精修台只对"正在过的这一天"生效。
    var isLiveTargetDay: Bool {
        (startedDays?.isStarted(targetDay) ?? false)
            && Calendar.current.startOfDay(for: targetDay) == DayContext.logicalDay(offset: 0, from: now())
    }

    /// 从真相源读**所选目标日**（逻辑日）的已确认计划 → 可编辑列表。
    /// 加载后的编辑只标未保存（0.16 文件模型），「确认写入」才落库+投影。
    /// 不显示完成状态——完成态归执行/复盘页，排日程页保持纯规划面。
    /// **实时日 = 剩余精修台**（0.24 C2，「过去只读、未来可编」）：只加载未尘埃落定的块，
    /// 且以"从现在起"的现实为底（本地 V2 铺排，瞬时无 LLM）——所见即所改；候补块附在尾部照样可编辑。
    func loadConfirmedPlan() {
        guard let base = computeFreshBase() else {
            // 这天没有已确认计划：之前显示的是别天加载来的就清掉；别动用户排的新草稿
            if draftSource == .loaded { blocks = []; draftSource = .empty }
            loadedBase = []
            return
        }
        guard !base.isEmpty else {
            // 实时日剩余为空（都做完/都流逝）
            if draftSource == .loaded { blocks = []; draftSource = .empty }
            hasUnsavedChanges = false
            loadedBase = []
            return
        }
        blocks = base
        loadedBase = base
        draftSource = .loaded
        hasUnsavedChanges = false
        committedCount = nil
    }

    // MARK: - W19 今天页：直接操作即保存（2026-10-19，S-v2 老排程链退役——「确认写入」按钮不再出现在日用界面）

    /// 你看到的那一版（加载/保存后的列表）。两个用途：
    /// ① 图钉只钉「你亲手改了时间」的块——对比的是你眼前那一版，不是库里的版本
    ///   （实时日列表是「从现在起」重新铺排过的，库里的时间本来就和眼前不同，那不是你改的）；
    /// ② 保存前底层被别处改过（智能体批准的改动 / 日历回流 / 另一台设备）→ 只把你的改动叠到最新版上，不整天覆盖。
    private(set) var loadedBase: [EditableBlock] = []

    /// 打开 = 编辑后自动保存（今天页设 true）；关着 = 旧「文件模型」（编辑只标未保存，confirm 才落库；单测沿用）。
    var autoCommit = false
    /// 自动保存的等待时长（打字时不逐字写库）。
    var autosaveDelay: Duration = .milliseconds(1200)
    private var autosaveTask: Task<Void, Never>?

    private func scheduleAutosave() {
        guard autoCommit else { return }
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.commitEdits()
        }
    }

    /// 等着的自动保存立刻做完（切日 / 回后台 / 离开页面前调）。没有待保存的改动 = 什么都不做。
    func flushAutosave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await commitEdits()
    }

    // MARK: - W23 时间轴（2026-10-19）：一根连续的轴上直接拖 / 改；写入仍走上面这条 W19b 原路

    /// 实时日是否按「从现在起」重铺列表（W19 卡片列表 = true）。时间轴设 false：轴自己按闸门呈现，
    /// 这里拿库里原样——拖一块只改那一块（保存时其余块原样写回），不会因为保存把别的块悄悄挪了。
    var relayoutLiveDay = true

    /// 当前列表装的是哪一个逻辑日（加载 / 切页后才有）。时间轴用它判断：这一天的块该用编辑中的版本。
    private(set) var pageDay: Date?

    /// 时间轴要改某一天的块：这一页不是那天 → 先保存这一页、再切过去加载那天（同 selectDay + 切页）。
    func focusDay(_ day: Date) async {
        let label = Calendar.current.startOfDay(for: day)
        guard pageDay != label || Calendar.current.startOfDay(for: targetDay) != label else { return }
        await flushAutosave()
        targetDay = label
        targetDayDidChange()
    }

    /// 视图的 onChange(targetDay) 用：这一页已经是那天（focusDay 刚切过）就不再重复加载。
    func targetDayDidChangeIfNeeded() {
        guard pageDay != Calendar.current.startOfDay(for: targetDay) else { return }
        targetDayDidChange()
    }

    /// 0.76：时间轴拖动连带顺延的块——保存时不钉成图钉（只钉你亲手拖的）。
    private var axisNoPin: Set<UUID> = []

    /// 时间轴拖动 / 拉长缩短的落地：改列表里这一块的起止 → 立即保存（confirm：写 PlanStore、按「你眼前那一版」
    /// 对比钉成图钉、请 CalendarSyncEngine 重投影）。调用方已按 PlanEditRules 校验过、并已 focusDay 到这一天。
    /// 返回 false = 这一页里没有这块（不写任何东西）。
    @discardableResult
    func applyAxisSpan(id: UUID, start: Date, end: Date, pushed: [(id: UUID, start: Date, end: Date)] = []) async -> Bool {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else {
            DevLog.shared.warn("今天页", "时间轴改动没落地：这一页里找不到那一块（可能刚被别处删掉）")
            return false
        }
        let pushedIdx = pushed.compactMap { p in blocks.firstIndex { $0.id == p.id }.map { ($0, p) } }
        guard pushedIdx.count == pushed.count else {
            DevLog.shared.warn("今天页", "时间轴连带顺延没落地：这一页里找不到要顺延的块")
            return false
        }
        blocks[i].start = start
        blocks[i].end = end
        // 0.76：撞上后面的块 → 那几块跟着往后顺延（时长不变）；只钉你亲手拖的那一块，顺延的不钉
        for (j, p) in pushedIdx { blocks[j].start = p.start; blocks[j].end = p.end }
        axisNoPin = Set(pushed.map(\.id))
        defer { axisNoPin = [] }
        blocks.sort { $0.start < $1.start }
        committedCount = nil; markEditedIfLoaded(); persistDraft()
        await flushAutosave()
        return true
    }

    /// W26 时间轴**跨天**拖动的落地（2026-10-19）：一天一页的保存路径（confirm）按天整页 replacePlanned——
    /// 把一块写进另一天会把那天整页覆盖掉，所以跨天走**按 ID 单块写**（同 W18 ApprovedPlanMover 的跨天挪：updatePlanned），
    /// 两天的其它块一律不碰。调用方已按 PlanEditRules 校验过（不进过去 / 不撞固定与你的日历 / 在可排范围 / 不跨 4:00）。
    /// 写后：① 你亲手拖的 = 图钉（钉到它新那天结束，与同一天拖动同一语义；批准智能体的挪动不钉，那条路不经这里）；
    /// ② 请 CalendarSyncEngine 重投影两天（它仍是唯一的日历写者）；③ 发「计划编辑」（时间线协调器重算、时间轴重读）；
    /// ④ 这一页若正是涉及的两天之一，按库重新加载（不然页里的旧版本会在下次自动保存时把它写回原处）。
    /// 返回 nil = 已落地；否则 = 没改的原因（什么都没写）。
    func applyAxisCrossDayMove(id: UUID, start: Date, end: Date) async -> String? {
        await flushAutosave()
        // 上一处改动还在保存（isWorking 时 commitEdits 只是再排一次）：先不动，免得两条写入交错
        guard !hasUnsavedChanges, !isWorking else { return "上一处改动还在保存，稍等一下再拖" }
        let today = DayContext.logicalStartOfDay(now())
        let labels = (0...PlanEditRules.horizonDays).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        let block: ScheduledBlock
        do {
            guard let b = try planStore.plannedBlocks(onLabels: labels).first(where: { $0.id == id }) else {
                DevLog.shared.warn("今天页", "时间轴跨天拖动没落地：库里找不到那一块（可能刚被别处删掉）")
                return "这一块刚被别处改过或删掉了，没有改动"
            }
            block = b
            try planStore.updatePlanned(id: id, start: start, end: end, title: b.title, reason: .userEdit)
        } catch {
            DevLog.shared.error("今天页", "时间轴跨天拖动写入失败：\(error.localizedDescription)")
            return "这次没挪成（写入失败）：\(error.localizedDescription)"
        }
        let from = DayContext.logicalStartOfDay(block.start), to = DayContext.logicalStartOfDay(start)
        do {
            try planStore.setPinned(ids: [id], until: ScheduledBlock.pinExpiry(forStart: start))
        } catch {
            // 挪已经写进去了；钉不上只是少了「自动调整绕开它」——要可见，但不把挪动算失败
            DevLog.shared.warn("今天页", "跨天挪好了，但没钉住：\(error.localizedDescription)")
            errorText = "已挪到\(PlanEditRules.relativeDayName(to, now: now()))；这次没钉住（自动调整可能会动它）：\(error.localizedDescription)"
        }
        for label in Set([from, to]).sorted() {
            do { try await projection.project(label: label) } catch {
                DevLog.shared.warn("今天页", "跨天挪已写入，但 \(PlanEditRules.dayName(label)) 的日历画面刷新失败：\(error.localizedDescription)")
                errorText = "已挪好；\(PlanEditRules.dayName(label)) 的日历画面这次没刷新：\(error.localizedDescription)"
            }
        }
        // 早晚通知若正属于这两天之一：按新计划重排（首块前 / 末块后的时刻可能变了）
        await dailyReminderRefresher().refresh(affecting: [from, to])
        NotificationCenter.default.post(name: TimelineCoordinator.planEdited, object: nil)
        if let page = pageDay, page == from || page == to {
            loadConfirmedPlan()
            persistDraft()
        }
        return nil
    }

    /// 切到另一天：先把这一天没来得及保存的改动保存掉，再切（防止改动被丢、或被写到别的日子）。
    func selectDay(_ day: Date) async {
        await flushAutosave()
        targetDay = day
    }

    /// 保存你的改动。底层在你编辑期间变过 → 先把你的改动叠到最新版上（你的改动赢，别处的改动也保留）。
    func commitEdits() async {
        guard hasUnsavedChanges else { return }
        if isWorking { scheduleAutosave(); return }
        if freshness, let fresh = freshBase {
            blocks = Self.overlay(mine: blocks, shown: loadedBase, onto: fresh)
            DevLog.shared.info("今天页", "保存时底层已更新（\(freshnessSource.label)）：只把你的改动叠到最新版上")
            freshness = false
            freshBase = nil
        }
        await confirm(celebrate: false)
    }

    /// 你的改动 = 眼前列表相对「你看到的那一版」的差：新加的、改过的、删掉的。纯函数、可单测。
    static func overlay(mine: [EditableBlock], shown: [EditableBlock], onto fresh: [EditableBlock]) -> [EditableBlock] {
        let shownByID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mineIDs = Set(mine.map(\.id))
        let deleted = Set(shown.map(\.id)).subtracting(mineIDs)
        let edited = mine.filter { shownByID[$0.id] != $0 }
        let editedIDs = Set(edited.map(\.id))
        var out = fresh.filter { !deleted.contains($0.id) && !editedIDs.contains($0.id) }
        out.append(contentsOf: edited)
        return out.sorted { $0.start < $1.start }
    }

    /// 时间线「＋ 加一项」：只用你写的标题，在空档放一小时（不经 AI、不猜时间——时间你在列表里直接改）。
    func admitPlain(_ title: String) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        await flushAutosave()
        let start = await freeSlotStart(duration: 3600)
        FeatureUsage.used(.todayAdd)   // W21：今天页写入路径（换成时间轴视图后照样记）
        await admitDirect(ScheduledBlock(title: t, start: start, end: start.addingTimeInterval(3600)))
    }

    /// 「算最新底但不套用」（徽标 v2 重构，2026-07-10）：目标日**此刻**的最新底——
    /// 常规日=已确认计划；实时日=剩余从现在起 V2 铺排（=橙色预览同款口径，候补垫尾）。
    /// nil=这天没有已确认计划；[]=实时日剩余为空。只计算、不改任何状态——
    /// loadConfirmedPlan 拿它套用；徽标亮起时拿它做只读对比（freshBase）。
    private func computeFreshBase() -> [EditableBlock]? {
        let stored = (try? planStore.plannedBlocks(on: targetDay)) ?? []
        guard !stored.isEmpty else { return nil }
        // W23 时间轴：轴自己按闸门呈现（过去只画蓝、绿色从现在起），这里给库里原样——编辑只改你动的那块，别的块不被悄悄重铺
        guard isLiveTargetDay, relayoutLiveDay else { return stored.map(EditableBlock.init(from:)) }
        let settled = progress?.settledPlannedIDs ?? []
        let nowT = now()
        let remaining = stored.filter { !settled.contains($0.id) && $0.end > nowT }
        guard !remaining.isEmpty else { return [] }
        let laid = ReflowLayoutV2.layOut(
            flexible: remaining.filter { !$0.isFixed }.sorted { $0.start < $1.start },
            fixed: remaining.filter(\.isFixed), from: nowT,
            windDown: WorkHoursSettings.effectiveWindDown(from: nowT),
            graceMinutes: WorkHoursSettings.graceMinutes)
        // 埋点（调研 E 组）：块进候补——按天按标题去重（本函数高频重算，只记首次进候补）
        for d in laid.deferred {
            BehaviorLog.recordOncePerDay(key: "候补-\(d.title)", "候补", "进候补：\(d.title)")
        }
        return (laid.scheduled + laid.deferred.sorted { $0.start < $1.start })
            .map(EditableBlock.init(from:))
    }

    /// 进入排日程页时自动加载已保存计划（有未保存修改时绝不覆盖——文件模型）。
    func autoLoadOnAppear() {
        guard !hasUnsavedChanges else { return }
        loadConfirmedPlan()
        pageDay = Calendar.current.startOfDay(for: targetDay)
    }

    /// 当前草稿 → ICS 文本（导出/分享）。
    func currentICS() -> String { ics(for: blocks.map(\.scheduled)) }

    /// 任意一组计划块 → ICS 文本（W26：时间轴的「这一天」菜单导出视口里那一天，不必先切页）。
    func ics(for planned: [ScheduledBlock]) -> String {
        let drafts = planned.sorted { $0.start < $1.start }.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .planned)
        }
        return exporter.ics(for: drafts)
    }

    func arrange() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true; errorText = nil; committedCount = nil; arrangedCount = nil; refinedChangeCount = nil
        do {
            // 在途摘要给排程大脑（M10-2：LLM 可建议 0–2 块，标来源、删除零成本）
            let pool = (longTaskStore?.active() ?? []).map {
                LongTaskBrief(title: $0.title, deadline: $0.deadline,
                              cadenceMinutesPerWeek: $0.cadenceMinutesPerWeek,
                              nextCheckpoint: $0.nextCheckpoint?.title)   // #40 批3：块名可带阶段
            }
            // 现实上下文（0.13.1）：目标日已有日程 + 到期提醒 → 排程避开/纳入考虑
            async let busy = calendarStore.existingEvents(on: targetDay)
            async let due = reminderStore.dueReminders(on: targetDay)
            let context = ParseContext(busy: await busy, dueReminders: await due, pool: pool)  // C：池给解析器识别委托
            if !context.isEmpty {
                DevLog.shared.info("排程", "上下文：已有日程 \(context.busy.count) · 到期提醒 \(context.dueReminders.count)")
            }
            // referenceDate = 目标日 → 不写日期时也排到对的那天（晚上默认明天）
            let outcome = try await arrangeDay.full(text: trimmed, referenceDate: targetDay,
                                                    pool: pool, context: context)
            // 草稿按时间从早到晚显示（完整 Date 排序：凌晨块带次日日期自然垫底，不会窜到最前）。
            // 「推荐顺序」信息不丢——要紧事有 ★、note 里有先做什么的建议。
            blocks = outcome.decision.orderedBlocks
                .sorted { $0.start < $1.start }
                .map { b in
                    var eb = EditableBlock(from: b)
                    eb.fromPool = outcome.decision.poolSuggestedTitles.contains(b.title)
                    // 精确归属：**所有**块都按标题匹配未来任务并归属（不只池建议块）——归属更积极，
                    // 用户说的「学习量化」也会自动接到池里的「量化学习」名下（投入统计精确、改名不丢）。
                    if eb.linkedTaskID == nil {
                        eb.linkedTaskID = longTaskStore?.items
                            .first { TitleMatch.similarity($0.title, b.title) >= 0.6 }?.id
                    }
                    return eb
                }
            // E5e 族定案（三重一致性，§14.3）：LLM 标注的入账 Ledger+归属继承上溯；
            // 没标注的走 归属继承/历史复用；都不中=族未知（引擎中性），下次解析再试
            blocks = blocks.map { eb in
                var eb = eb
                if let fam = eb.scheduled.family {
                    FamilyLedger.record(eb.title, family: fam)
                    if let linked = eb.linkedTaskID,
                       let t = longTaskStore?.items.first(where: { $0.id == linked }), t.family == nil {
                        t.family = fam   // 长期任务经块标注拿族（下次归属继承直接命中）
                    }
                } else {
                    let fam = FamilyResolver.resolve(title: eb.title, linkedTaskID: eb.linkedTaskID,
                                                     parsedFamily: nil, longTasks: longTaskStore)
                    if fam != FamilyTaxonomy.fallback {
                        eb.labels.append(ScheduledBlock.familyPrefix + fam)
                    }
                }
                return eb
            }
            SmokeLog.hit("族标注", "\(blocks.filter { $0.scheduled.family != nil }.count)/\(blocks.count) 块带族（UI 不呈现）")
            // K1 例行模板物化（进草稿走确认制）：启用且当日生效的模板补插实例；
            // 与已有块（含 parser 补排的午饭/晚饭锚点）TitleMatch 重复的跳过——不重复补
            for t in routines?.enabled(on: targetDay) ?? [] {
                let inst = RoutineTemplateStore.instantiate(t, on: targetDay)
                let dup = blocks.contains { TitleMatch.similarity($0.title, inst.title) >= 0.6 }
                if !dup { blocks.append(EditableBlock(from: inst)) }
            }
            blocks.sort { $0.start < $1.start }
            draftSource = .arranged
            note = outcome.decision.note
            // LLM 识别到"想松散"的显式意图 → 标目标日松散（解析明说的意愿，非 App 自判；可手动撕）
            if outcome.isLoose {
                looseDays?.setLoose(targetDay, true)
                notifier.cancelDailyReminders()   // 松散日静音早晚提醒（即使已排的也清掉）
                note = (note.map { $0 + "\n" } ?? "") + "已把这天标为松散——App 退场陪你，不催不算账（想恢复点右上「结束松散」）。"
            }
            pendingLongTasks = outcome.longTasks   // 确认写入时入「在途」
            hasUnsavedChanges = true
            arrangedCount = blocks.count   // A：确定性状态行「排好 N 件」
            PlaceholderSettings.recordArrangeSuccess()   // 排今天成功计数（教程满 10 次自动毕业换小提示）
            persistDraft()
        } catch {
            // C 干净失败态（0.26 删 Stub 后）：端云全失败 → 保留输入原文，给可操作的下一步（不给错误码/垃圾草稿）
            errorText = "没能排出来——检查网络连接，或在 设置→云端 填好 API key，再点一次「排今天」。你说的话还在。"
            DevLog.shared.warn("排程", "解析全失败（干净失败态）：\(error.localizedDescription)")
        }
        isWorking = false
    }

    // MARK: 单件入线（E5e 投放管道·微投放：加一件事就是加一件事，不惊动其他块）

    /// 已确认态/空态的「加一件」：解析取首块 → 归属/族定案 → 直接写真相 + 触发协调器。
    /// 草稿态不走这里（入口分流在 HomeView：有未确认草稿 → addBlockSmart 照旧进草稿确认制）。
    func admitOne(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        let parsed = try? await arrangeDay.parser.parse(t, referenceDate: targetDay,
                                                        context: ParseContext())
        let pb = parsed?.blocks.first
        var sb: ScheduledBlock
        if let pb, let s = pb.start, let e = pb.end {
            let (cs, ce) = ArrangeDayUseCase.clampToDay(start: s, end: e, referenceDate: targetDay)
            sb = ScheduledBlock(title: pb.title, start: cs, end: ce, isFixed: pb.isFixed,
                                isAnchor: pb.isAnchor || RefineGuards.isObviousAnchor(pb.title),
                                timingStyle: pb.timingStyle, priority: pb.priority,
                                deadline: pb.deadline, labels: pb.labels)
            // 弹性块撞已排块 → 就近寻空档（用户给了明确时刻的固定/锚点块按用户说的）
            if !sb.isFixed, !sb.isAnchor, overlapsExistingTruth(sb) {
                let dur = sb.end.timeIntervalSince(sb.start)
                let start = await freeSlotStart(duration: dur)
                sb.start = start; sb.end = start.addingTimeInterval(dur)
            }
        } else {
            // 解析失败/无时刻：本地兜底 60 分钟寻空档投放（用户的字绝不丢）
            let dur = TimeInterval((pb?.durationMinutes ?? 60) * 60)
            let start = await freeSlotStart(duration: dur)
            sb = ScheduledBlock(title: pb?.title ?? t, start: start,
                                end: start.addingTimeInterval(dur), labels: pb?.labels ?? [])
        }
        await admitDirect(sb)
    }

    /// 池条目一键入线（提名/晨间摘要/长期页共用）：长期区带归属；待办区上线即离池（再溢出会回来）。
    func admitFromPool(_ task: LongTask) async {
        let next = task.nextCheckpoint
        let dur = TimeInterval((next?.estimatedMinutes ?? task.unitMinutes ?? 60) * 60)
        let start = await freeSlotStart(duration: dur)
        var sb = ScheduledBlock(title: next.map { "\(task.title) · \($0.title)" } ?? task.title,
                                start: start, end: start.addingTimeInterval(dur))
        if task.poolZone == .longterm { sb.linkedTaskID = task.id }
        if let fam = task.family { sb.labels.append(ScheduledBlock.familyPrefix + fam) }
        await admitDirect(sb)
        if task.poolZone == .todo { longTaskStore?.discard(task) }
    }

    /// 投放落库（管道后三步）：归属自动匹配 → 族定案 → insertPlanned + 重投影 + 捅协调器 + 刷视图。
    private func admitDirect(_ raw: ScheduledBlock) async {
        var sb = raw
        if sb.linkedTaskID == nil {
            sb.linkedTaskID = longTaskStore?.items
                .first { TitleMatch.similarity($0.title, sb.title) >= 0.6 }?.id
        }
        if let fam = sb.family {
            FamilyLedger.record(sb.title, family: fam)
        } else {
            let fam = FamilyResolver.resolve(title: sb.title, linkedTaskID: sb.linkedTaskID,
                                             parsedFamily: nil, longTasks: longTaskStore)
            if fam != FamilyTaxonomy.fallback { sb.labels.append(ScheduledBlock.familyPrefix + fam) }
        }
        try? planStore.insertPlanned([sb], reason: .poolAdmit)
        try? await projection.project(label: DayContext.logicalStartOfDay(sb.start))
        NotificationCenter.default.post(name: TimelineCoordinator.planEdited, object: nil)
        DevLog.shared.info("投放", "单件入线：「\(sb.title)」\(sb.start.formatted(date: .omitted, time: .shortened))")
        SmokeLog.hit("单件入线", "「\(sb.title)」直写真相")
        if !hasUnsavedChanges { loadConfirmedPlan() }   // 已确认视图即时可见
    }

    /// 寻空档（今天从现在起、未来日从 9 点起，收工线为界；排不下接末尾）——smartInsert 同款口径。
    /// W31 自测修：①避开你自己日历里的安排（原来只看本 App 的块，「加一项」会叠在你的课上——P4 说空档却撞课）；
    /// ②「今天」按逻辑日判断（凌晨 0–4 点加到今天原来落在已过去的 9 点）。
    private func freeSlotStart(duration: TimeInterval) async -> Date {
        let planned = ((try? planStore.plannedBlocks(on: targetDay)) ?? [])
            .map { (start: $0.start, end: $0.end) }
        let busy = await calendarStore.existingEvents(on: targetDay).map { (start: $0.start, end: $0.end) }
        return Self.plainSlotStart(targetDay: targetDay, now: now(), duration: duration,
                                   planned: planned, busy: busy,
                                   windDownHour: WorkHoursSettings.windDownHour)
    }

    /// 纯函数（可单测）：目标日的第一个空档起点。planned + busy 都算占用；排不下 → 接在最后一块后面，
    /// 但绝不早于 notBefore（不落进过去）。
    static func plainSlotStart(targetDay: Date, now: Date, duration: TimeInterval,
                               planned: [(start: Date, end: Date)], busy: [(start: Date, end: Date)],
                               windDownHour: Int) -> Date {
        let dayStart = Calendar.current.startOfDay(for: targetDay)
        let isToday = DayContext.logicalStartOfDay(now) == dayStart
        let notBefore = isToday ? max(now, dayStart) : dayStart.addingTimeInterval(9 * 3600)
        let windDown = dayStart.addingTimeInterval(TimeInterval(windDownHour) * 3600)
        let existing = planned + busy
        return firstFreeStart(existing: existing, duration: duration,
                              notBefore: notBefore, windDown: windDown)
            ?? max(notBefore, existing.map(\.end).max() ?? notBefore)
    }

    private func overlapsExistingTruth(_ sb: ScheduledBlock) -> Bool {
        ((try? planStore.plannedBlocks(on: targetDay)) ?? [])
            .contains { $0.start < sb.end && sb.start < $0.end }
    }

    /// 剩余地形一行（E5e，空间事实无评判）：只对逻辑今天有意义；已过收工线/非今天返回 nil。
    var terrainLine: String? {
        let today = DayContext.logicalStartOfDay(now())
        guard Calendar.current.startOfDay(for: targetDay) == today else { return nil }
        let workEnd = PinSchedule.workEnd(forLabel: today)
        guard now() < workEnd else { return nil }
        let spans = blocks.map { (start: $0.start, end: $0.end) }
        return TerrainSummary.line(freeMinutes:
            TerrainSummary.freeMinutes(spans: spans, from: now(), until: workEnd))
    }

    /// W12（SPEC §19.13 Q5 投影最小集）：确认时投进提醒事项的只有**截止时间**——带 DDL 的计划块 + 带 DDL 的待办池条目。
    /// 计划块本身（日历里已有，再投会重复响）、没截止的块/待办都不投。纯函数、可单测。
    /// 返回：要同步的提醒草稿 + 已过「最迟该开始」时刻的（不写 VTODO，改发一条前向通知）。
    static func reminderProjection(blocks: [EditableBlock], pending: [ParsedLongTask], leadMinutes leadN: Int,
                                   now: Date) -> (drafts: [ReminderDraft], pastDue: [(title: String, ddl: Date, minutes: Int)]) {
        var reminders: [ReminderDraft] = []
        var pastDueNudges: [(title: String, ddl: Date, minutes: Int)] = []
        for b in blocks {
            guard let ddl = b.deadline else { continue }   // 没截止 = 不投（计划块本身在日历里）
            let m = max(1, Int(b.end.timeIntervalSince(b.start) / 60))       // 时长(分)
            let fire = ddl.addingTimeInterval(TimeInterval(-(m + leadN) * 60))   // p−m−N
            if fire > now {
                reminders.append(ReminderDraft(title: b.title, due: ddl, priority: 1, notes: nil,
                                               leadMinutes: m + leadN, blockID: b.id))   // 到期前 m+N 分响 = p−m−N
            } else {
                pastDueNudges.append((b.title, ddl, m))   // 已过 p−m−N（加得太晚）→ 不写 VTODO、直接发消息（clamp）
            }
        }
        // 带 DDL 的未来任务入池 → 系统提醒事项(due=DDL、响在 p−m−N)；已排成今天块的跳过、不重复
        reminders += poolReminderDrafts(pending: pending, blockTitles: blocks.map(\.title), leadMinutes: leadN)
        return (reminders, pastDueNudges)
    }

    /// 带 DDL 的未来任务入池 → 系统提醒事项(due=DDL)。纯函数、可单测。
    /// 去重：已被排成今天块的（块已自带 DDL 提醒）跳过，避免两条重复提醒。priority 5=中，同带 DDL 块口径。
    static func poolReminderDrafts(pending: [ParsedLongTask], blockTitles: [String],
                                   leadMinutes: Int?) -> [ReminderDraft] {
        pending.compactMap { p in
            guard let due = p.deadline else { return nil }
            if blockTitles.contains(where: { TitleMatch.similarity($0, p.title) >= 0.6 }) { return nil }
            // p−m−N：未来任务估算 m=totalMinutes → 提醒响在「最迟该开始」，而非刚好到截止
            let lead = (p.totalMinutes ?? 0) + (leadMinutes ?? 0)
            return ReminderDraft(title: p.title, due: due, priority: 5,
                                 notes: "未来任务截止", leadMinutes: lead)
        }
    }

    // 微调防呆纯函数（mergePartialRefine / guardRefineFlags）已下沉到 Services/Planning/RefineGuards.swift
    // ——试验台（Services/AlgoBench）也要用，Services 引 Features 是反向依赖（架构地图清零 2026-07-12）。

    func refine() async {
        let cmd = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !blocks.isEmpty else { return }
        isWorking = true; committedCount = nil; arrangedCount = nil; refinedChangeCount = nil
        let scheduled = blocks.map(\.scheduled)
        // 归属按标题留存：LLM 微调重建块时会丢 linkedTaskID，refine 后按标题补回（自动+手动归属都不丢）
        var linkByTitle: [String: UUID] = [:]
        for b in blocks where b.linkedTaskID != nil { linkByTitle[b.title] = b.linkedTaskID }
        let raw = (try? await refiner.refine(scheduled, command: cmd,
                                             originalRequest: inputText, now: now())) ?? scheduled
        // 防呆三连（模型无关）：①部分返回并回原清单（丢块=未改不是删）②没让改的属性不许批量翻转
        // ③没点名的固定块时间还原（②③在 guardRefineFlags 里）
        let merged = RefineGuards.mergePartialRefine(original: scheduled, refined: raw, command: cmd)
        let result = RefineGuards.guardRefineFlags(original: scheduled, refined: merged, command: cmd)
        // 并行组按标题留存（0.22）：LLM 微调重建块会丢 labels，按标题补回（同 linkedTaskID 的做法）
        var labelsByTitle: [String: [String]] = [:]
        for b in blocks where !b.labels.isEmpty { labelsByTitle[b.title] = b.labels }
        blocks = result.sorted { $0.start < $1.start }.map { b in
            var eb = EditableBlock(from: b)
            if eb.linkedTaskID == nil, let l = linkByTitle[b.title] { eb.linkedTaskID = l }
            if eb.labels.isEmpty, let ls = labelsByTitle[b.title] { eb.labels = ls }
            // E5e 改名丢族的缓解（核查已知边界）：标题补回落空的块走 归属/Ledger 模糊再解一次
            if eb.scheduled.family == nil {
                let fam = FamilyResolver.resolve(title: b.title, linkedTaskID: eb.linkedTaskID,
                                                 parsedFamily: nil, longTasks: longTaskStore)
                if fam != FamilyTaxonomy.fallback {
                    eb.labels.append(ScheduledBlock.familyPrefix + fam)
                }
            }
            return eb
        }
        // C 状态行（#15）：本地 diff 出「改了几处」的确定性事实——不是模型的话，零措辞风险
        refinedChangeCount = Self.countRefineChanges(before: scheduled, after: result)
        draftSource = .arranged   // AI 微调后 = 未确认草稿（含对已加载计划的微调）
        refineText = ""
        hasUnsavedChanges = true
        persistDraft()
        isWorking = false
    }

    /// 微调前后差异计数（纯函数、可单测）：以「标题|起|止|固定|计时|优先级」为块签名做多重集合差，
    /// 改动数 = max(新增签名数, 消失签名数)——改一个块=旧签名消失+新签名出现，算 1 处；加/删块也各算 1 处。
    static func countRefineChanges(before: [ScheduledBlock], after: [ScheduledBlock]) -> Int {
        func sig(_ b: ScheduledBlock) -> String {
            "\(b.title)|\(b.start.timeIntervalSince1970)|\(b.end.timeIntervalSince1970)|\(b.isFixed)|\(b.timingStyle.rawValue)|\(b.priority.rawValue)"
        }
        var beforeCounts: [String: Int] = [:]
        for b in before { beforeCounts[sig(b), default: 0] += 1 }
        var afterCounts: [String: Int] = [:]
        for b in after { afterCounts[sig(b), default: 0] += 1 }
        var added = 0, removed = 0
        for (s, c) in afterCounts { added += max(0, c - (beforeCounts[s] ?? 0)) }
        for (s, c) in beforeCounts { removed += max(0, c - (afterCounts[s] ?? 0)) }
        return max(added, removed)
    }

    func confirm(celebrate: Bool = true) async {
        // 提醒重设计（2026-07-09）：只给**有具体 DDL** 的块写提醒事项——「尽早」不再发时钟提醒
        // （交给晨间/menu bar/nudge，因为它的开始时间是 reflow 的动态猜测、钉钟点=假精确+施压）。
        // 提醒响在 **p−m−N**（截止 − 时长 − 提前量）=「最迟该开始」的前向提醒（"现在做还来得及"）。
        let (reminders, pastDueNudges) = Self.reminderProjection(blocks: blocks, pending: pendingLongTasks,
                                                                 leadMinutes: ReminderSettings.leadMinutes, now: .now)   // 过点守卫按真实墙钟（通知按墙钟响）
        let sorted = blocks.sorted { $0.start < $1.start }
        isWorking = true; errorText = nil; arrangedCount = nil; refinedChangeCount = nil
        do {
            // 单一真相源（重构 P2）：先写 PlanStore，再由投影层画日历——本方法不再直接写日历。
            // 按**逻辑日**分组逐日 replace：跨午夜块（睡前看书 00:30）随前一逻辑日走，不再被拆到次日。
            let targetLabel = Calendar.current.startOfDay(for: targetDay)
            var byLabel = Dictionary(grouping: sorted) { DayContext.logicalStartOfDay($0.start) }
            // 删光最后一件也要能保存：目标日即使无块也纳入 replace（清空真相源那天）。
            if byLabel[targetLabel] == nil { byLabel[targetLabel] = [] }
            // 0.24 C2「过去只读」：实时日确认只替换未来——已完成/进行中/已流逝的块原样保留
            // （复盘基线不被中途改写）；编辑期间被完成的块从草稿版剔除并中性带一句。
            if isLiveTargetDay {
                let stored = (try? planStore.plannedBlocks(on: targetLabel)) ?? []
                let settled = progress?.settledPlannedIDs ?? []
                let nowT = now()
                let preserved = stored.filter { settled.contains($0.id) || $0.end <= nowT }
                let preservedIDs = Set(preserved.map(\.id))
                let draftPart = (byLabel[targetLabel] ?? []).filter { !preservedIDs.contains($0.id) }
                let excluded = (byLabel[targetLabel]?.count ?? 0) - draftPart.count
                byLabel[targetLabel] = (preserved.map(EditableBlock.init(from:)) + draftPart)
                    .sorted { $0.start < $1.start }
                if excluded > 0 { note = "\(excluded) 件在你编辑期间已完成/进行中，保持原样。" }
            }
            // 提醒按章差量（P4.0-9）：这次确认负责的块 = 涉及的逻辑日上确认前后的所有块；别的日子的提醒不动
            var reminderScope = Set(sorted.map(\.id))
            for label in byLabel.keys {
                reminderScope.formUnion(((try? planStore.plannedBlocks(on: label)) ?? []).map(\.id))
            }
            // P4 Q6：你在 App 里改过时间的已有块 = 图钉（当天有效）——确认前后对比，只钉「原来就有、时间被你改了」的
            var storedSpans: [UUID: (Date, Date)] = [:]
            for label in byLabel.keys {
                for b in (try? planStore.plannedBlocks(on: label)) ?? [] { storedSpans[b.id] = (b.start, b.end) }
            }
            // W19：参照优先取「你眼前那一版」——实时日列表是从现在起重铺过的，和库里时间不同≠你改过
            let shownSpans = Dictionary(loadedBase.map { ($0.id, ($0.start, $0.end)) }, uniquingKeysWith: { a, _ in a })
            for (label, dayBlocks) in byLabel {
                try planStore.replacePlanned(dayBlocks.map(\.scheduled), on: label)
                for b in dayBlocks.map(\.scheduled) {
                    guard let old = shownSpans[b.id] ?? storedSpans[b.id], old.0 != b.start || old.1 != b.end,
                          !axisNoPin.contains(b.id) else { continue }
                    try planStore.setPinned(ids: [b.id], until: ScheduledBlock.pinExpiry(forStart: b.start))
                }
                // 投影：常规日→绿；实时模式（已开始今天）→绿淡出、投橙。会前提醒规则在投影层统一挂。
                try await projection.project(label: label)
            }
            // 有 DDL 的事项 → 提醒事项（响在 p−m−N）。W12：提醒事项只是展示面——没同步成不拦计划保存，但要可见
            do { try await reminderStore.sync(reminders, scope: reminderScope, now: now()) } catch {
                errorText = "计划已保存；提醒事项这次没同步：\(error.localizedDescription)"
                DevLog.shared.error("提醒", "计划已保存，提醒事项这次没同步：\(error.localizedDescription)")
            }
            // 过点 clamp：p−m−N 已过去的（加得太晚），不写过期 VTODO（不会响），直接立刻发一条前向通知
            for n in pastDueNudges {
                await notifier.notifyNow(title: "「\(n.title)」该开始了",
                    body: "今天 \(n.ddl.formatted(.dateTime.hour().minute())) 前要完成、约需 \(n.minutes) 分，现在开始还来得及")
            }
            committedCount = sorted.count
            BehaviorLog.record(celebrate ? "确认写入" : "今天页保存", "\(sorted.count) 件")
            // E4：当日「最初计划」快照——该逻辑日第一次确认写入时存一份，之后不覆盖（残差基准/复盘基线）
            LearningStore().snapshotIfFirst(dayLabel: targetDay, blocks: sorted.map(\.scheduled))
            // E5b：确认写入=计划编辑事件 → 时间线协调器重算（一行 post，不引依赖）
            NotificationCenter.default.post(name: TimelineCoordinator.planEdited, object: nil)
            draftSource = .loaded    // 写入后当前列表 = 已确认的计划
            // 长期事项入「在途」池（幂等：同名在途项只更新不重复）
            for p in pendingLongTasks {
                let task = longTaskStore?.add(title: p.title, deadline: p.deadline,
                                              cadenceMinutesPerWeek: p.cadenceMinutesPerWeek,
                                              totalMinutes: p.totalMinutes, unitMinutes: p.unitMinutes)
                // #40 批3：解析出的阶段落库（幂等——已有同名阶段不重复加，重复确认/两端并发都安全）
                if let task, !p.checkpoints.isEmpty {
                    let existing = Set(task.sortedCheckpoints.map(\.title))
                    for name in p.checkpoints where !existing.contains(name) {
                        longTaskStore?.addCheckpoint(to: task, title: name)
                    }
                }
            }
            pendingLongTasks = []
            hasUnsavedChanges = false   // 保存完成（文件模型的「保存」时刻）
            // 第二仪式（0.38，#33 拍板③）：今天已盖收尾章 且 这次确认的是明天 → 「明天也就位了」
            if celebrate, Calendar.current.startOfDay(for: targetDay) == DayContext.logicalDay(offset: 1, from: now()),
               WrapUpSeal.isSealedToday {
                tomorrowReadyCelebration = true
            }
            freshness = false           // 本页已成为最新（最后动作赢）
            freshBase = nil
            loadedBase = blocks         // W19：保存后的这一版 = 你眼前的那一版（下一次改动的图钉参照）
            persistDraft()
            // W26b：记住已排的早晚通知属于哪一天（跨天挪不经过这里，改动涉及这一天时据此重排，见 DailyReminderRefresher）
            DailyReminderDay.record(targetLabel, in: reminderDefaults)
            // 松散日：静音早晚提醒（传 nil → 清掉旧的、不排新的）——退场姿态之一，不催不算账
            if looseDays?.isLoose(targetDay) ?? false {
                await notifier.scheduleDailyReminders(morning: nil, evening: nil, summary: "")
            } else {
                // 早晚极简通知：时间据今日计划（首块前 / 末块后）算
                let times = RescheduleService.reminderTimes(for: sorted.map(\.scheduled))
                await notifier.requestAuthorizationIfNeeded()
                // E5d：早通知带待办区露脸计数——排明天时今天的溢出已收池（收工盖章在前），
                // 明早的「昨天」正是此刻的池里溢出物
                // W26b：正文带上「给明天的一句话」（原来重新保存会把日记里并进去的那一行冲掉）
                await notifier.scheduleDailyReminders(morning: times.morning, evening: times.evening,
                                                      summary: DailyReminderContent.morningBody(
                                                        summary: Self.morningSummary(for: sorted, pooledFromYesterday: pooledFromYesterday()),
                                                        note: TomorrowNote.note(for: targetLabel.addingTimeInterval(12 * 3600))))
            }
        } catch {
            errorText = "写入失败：\(error.localizedDescription)"
        }
        isWorking = false
    }

    // 「开始今天/晨间 reflow」已退役（0.23 A，SPEC §11 ①）：某逻辑日第一次真正开始一件事
    // （menu bar / 今天 tab 的 startBlock/startAlso）即进实时模式，重排由全天连续 reflow 后台完成；
    // 「塞不下」三选弹窗随之消失（产品债清偿——弹窗=羞辱，违 §3.3）。

    /// 早通知小总结（0.28.1，Jason 定：带件数/重点）：件数只数任务（锚点不算）、有尽早★则点名、
    /// 落点=第一件任务（前向：指向下一步动作）。纯函数、可单测。
    /// pooledFromYesterday（E5d）：待办区露脸计数——中性事实一行，不写「没做完」。
    static func morningSummary(for blocks: [EditableBlock], pooledFromYesterday: Int = 0) -> String {
        DailyReminderContent.morningSummary(for: blocks.map(\.scheduled), pooledFromYesterday: pooledFromYesterday)
    }

    /// E5d：待办区里「昨天留下的」件数（早通知露脸计数）。
    private func pooledFromYesterday() -> Int {
        longTaskStore?.todoItems()
            .filter { $0.spilledFromDay.map { DayContext.isSameLogicalDay($0, .now) } ?? false }
            .count ?? 0
    }

    /// 早晚通知「属于哪一天」的存处（测试换独立 suite，不碰标准存储）。
    var reminderDefaults: UserDefaults = DailyReminderDay.defaultStore

    /// 早晚通知的重排器（跨天挪后用；与 confirm 同一套时刻 / 正文口径）。
    func dailyReminderRefresher() -> DailyReminderRefresher {
        DailyReminderRefresher(plans: planStore, notifier: notifier,
                               isLoose: { [looseDays] in looseDays?.isLoose($0) ?? false },
                               pooledFromYesterday: { [weak self] in self?.pooledFromYesterday() ?? 0 },
                               defaults: reminderDefaults, now: now)
    }

    /// 把时刻重锚到 day 所在日历日的逻辑日：时分不变；凌晨时分（0–4 点）落**次日**日历日
    /// （跨午夜段属同一逻辑日）。切目标日平移和行内时间编辑共用——编辑器只改时分不改日期，
    /// 把 0:30 留在当天会归到前一逻辑日、还排到列表最上面（2026-07-07 Jason 报）。纯函数、可单测。
    static func anchored(_ time: Date, toLogicalDayOf day: Date) -> Date {
        let cal = Calendar.current
        let label = cal.startOfDay(for: day)
        let t = cal.dateComponents([.hour, .minute], from: time)
        let base = (t.hour ?? 0) < DayContext.dayBoundaryHour
            ? (cal.date(byAdding: .day, value: 1, to: label) ?? label) : label
        return cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: base) ?? time
    }

    /// 0.23 C（SPEC §11 ③）：切目标日 = 切草稿本。旧的「未保存修改自动平移跟人走」已退役——
    /// 聪明但意外（只想看看明天，今天的草稿却跟着搬家）；换页符合"每天一页纸"的心智模型。
    /// 该日有未保存草稿页 → 静默还原那一页；否则加载该日已确认计划。
    // MARK: - 新鲜度（0.24 C2）

    /// 徽标 v2「预览两边再选」（2026-07-10）：亮徽标那一刻的最新底快照（只算不套用，供只读对比）。
    /// nil=没在对比状态。对比后二选一：adoptFreshBase（用最新）/ keepMyDraft（保留本页、熄标）。
    private(set) var freshBase: [EditableBlock]?

    /// 真相源被外部改了（日历手改回流 / 他端同步）：干净 → 直接刷新；编辑中 → 亮徽标不打扰。
    func noteExternalPlanChange() {
        if hasUnsavedChanges {
            if !freshness { BehaviorLog.record("徽标", "亮起：\(FreshnessSource.calendarEdit.label)") }
            freshnessSource = .calendarEdit; freshness = true
            freshBase = computeFreshBase()   // 算最新底但不套用（v2 对比用）
        } else { loadConfirmedPlan() }
    }

    /// 执行进展变了（开始/完成/换件）：只影响实时日的精修台底。
    func noteExecutionProgress() {
        guard isLiveTargetDay else { return }
        if hasUnsavedChanges {
            if !freshness { BehaviorLog.record("徽标", "亮起：\(FreshnessSource.reflow.label)") }
            freshnessSource = .reflow; freshness = true
            freshBase = computeFreshBase()
        } else { loadConfirmedPlan() }
    }

    /// 「载入最新」：放弃本页未确认修改，回到当下最新的底（干净、无羞辱的显式选择）。
    func reloadFreshBase() {
        if freshness { BehaviorLog.record("徽标", "用最新的（放弃本页）") }
        freshness = false
        freshBase = nil
        discardDraft()
    }

    /// 对比后选「用最新的底」（=载入最新，语义同 reloadFreshBase，给对比视图一个明确动词）。
    func adoptFreshBase() { reloadFreshBase() }

    /// 对比后选「保留我的编辑」：熄徽标——最后动作赢，确认时以本页为准。
    func keepMyDraft() {
        BehaviorLog.record("徽标", "保留我的编辑")
        freshness = false
        freshBase = nil
    }

    private var suppressNextDayChangeReload = false
    func targetDayDidChange() {
        if suppressNextDayChangeReload { suppressNextDayChangeReload = false; return }
        // #29（2026-07-11 审核过）：**没排出去的口述跟人走**——打了一段话才发现目标日选错，
        // 切过去不该重打。只带「还没变成草稿的输入」（已排出的留在原页=防重复安排），
        // 且只填**空页**、绝不覆盖目标页已有内容（草稿本页模型不破，0.23 C）。
        let pendingSay = draftSource == .arranged ? "" : inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        note = nil
        committedCount = nil
        arrangedCount = nil; refinedChangeCount = nil
        freshness = false
        freshBase = nil
        if let snap = draftStore?.load(day: targetDay),
           snap.dirty ?? false, !snap.blocks.isEmpty {
            blocks = snap.blocks.map(\.editable)
            inputText = snap.inputText
            draftSource = DraftSource(rawValue: snap.draftSourceRaw) ?? .arranged
            pendingLongTasks = snap.pendingLongTasks.map {
                ParsedLongTask(title: $0.title, deadline: $0.deadline,
                               cadenceMinutesPerWeek: $0.cadenceMinutesPerWeek)
            }
            hasUnsavedChanges = true
            loadedBase = []
            pageDay = Calendar.current.startOfDay(for: targetDay)
            scheduleAutosave()   // W19：那一天上次没来得及保存的改动，切过去就保存
        } else {
            let pageText = draftStore?.load(day: targetDay)?.inputText ?? ""
            inputText = pageText.isEmpty && !pendingSay.isEmpty ? pendingSay : pageText
            pendingLongTasks = []
            hasUnsavedChanges = false
            blocks = []
            draftSource = .empty
            loadConfirmedPlan()
            pageDay = Calendar.current.startOfDay(for: targetDay)
        }
    }

    /// 显式「整体挪到某天」（0.23 C：取代退役的自动平移，同时服务"昨晚没排完想推明天"的真实需求）：
    /// 当前草稿重锚到 day（保留时分、凌晨块归次日）、旧页清空、切到新页。用户明确下的指令——主权动作。
    func moveDraft(to day: Date) {
        guard !blocks.isEmpty else { targetDay = day; return }
        let moved = blocks.map { b in
            var nb = b
            nb.start = Self.anchored(b.start, toLogicalDayOf: day)
            nb.end = Self.anchored(b.end, toLogicalDayOf: day)
            return nb
        }
        draftStore?.clear(day: targetDay)   // 内容带走，旧页撕掉
        suppressNextDayChangeReload = true  // 切日回调别用新页的旧内容盖掉带来的草稿
        targetDay = day
        blocks = moved
        hasUnsavedChanges = true
        persistDraft()
    }

    /// 标记未保存修改（0.16 文件模型：任何来源的编辑都不自动写库——「确认写入」才保存）。
    private func markEditedIfLoaded() {
        hasUnsavedChanges = true
        arrangedCount = nil; refinedChangeCount = nil   // A/C 状态行仅贴合"刚完成"的瞬间——一编辑即过期
        scheduleAutosave()   // W19：今天页 = 直接操作即保存
    }

    /// 第二仪式（0.38，#33）：收尾章后顺手排完明天 → 一次性庆祝（视图消费后清）。
    var tomorrowReadyCelebration = false

    func addBlock() {
        let start = blocks.map(\.end).max() ?? Date()
        blocks.append(EditableBlock(title: "新事项", start: start, end: start.addingTimeInterval(3600)))
        committedCount = nil; markEditedIfLoaded(); persistDraft()
    }

    /// AI 加一项（0.36.0，Jason 定：加任务也走 LLM——名字/时长/该怎么分块交给解析，不再只落一个裸名字）。
    /// 草稿非空 → 复用微调链（「加一项：…」指令，防呆三连全在）；草稿为空 → 走整段解析（等于只说了这一件）。
    /// LLM 没加上（失败/没 key/零变化）→ 回退老路：按原文落一个 1 小时块，用户的字绝不丢。
    func addBlockSmart(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { addBlock(); return }
        if blocks.isEmpty {
            inputText = t
            await arrange()
            if blocks.isEmpty {   // 解析也没排出来 → 老路兜底
                blocks.append(EditableBlock(title: t, start: Date(), end: Date().addingTimeInterval(3600)))
                committedCount = nil; markEditedIfLoaded(); persistDraft()
            }
            return
        }
        let before = blocks.count
        refineText = "加一项：" + t
        await refine()
        if blocks.count <= before {   // 模型没加块（失败/拒绝）→ 老路兜底
            let start = blocks.map(\.end).max() ?? Date()
            blocks.append(EditableBlock(title: t, start: start, end: start.addingTimeInterval(3600)))
            committedCount = nil; markEditedIfLoaded(); persistDraft()
            DevLog.shared.warn("微调", "AI 加一项没生效，已按原文落块（可再用 AI 调整修）")
        }
    }

    /// 把一件「在途」排进当前草稿（过期三选的「今天排上」/ 长期页「排进今天」）：加 1 小时块到尾部。
    /// 从未来任务「排进今天」：生成的块精确归属到该任务（linkedTaskID），投入统计锚 id 不靠标题。
    /// 找第一个能容下 duration 的空档起点（不与已排块重叠、落在 notBefore 与 windDown 之间）。
    /// 纯函数、可单测；返回 nil = 收工前排不下。
    static func firstFreeStart(existing: [(start: Date, end: Date)], duration: TimeInterval,
                               notBefore: Date, windDown: Date) -> Date? {
        let sorted = existing.filter { $0.end > notBefore }.sorted { $0.start < $1.start }
        var cursor = notBefore
        for b in sorted {
            if b.start.timeIntervalSince(cursor) >= duration,
               cursor.addingTimeInterval(duration) <= windDown { return cursor }
            cursor = max(cursor, b.end)
        }
        return cursor.addingTimeInterval(duration) <= windDown ? cursor : nil
    }

    /// L2「帮我排进今天」：把某未来任务智能插进目标日空档（按单元定长、精确归属），产未保存修改。
    /// 收工前有空档就插空档；排不下就接末尾（不硬塞、给提示）。
    func smartInsertFromLongTask(_ task: LongTask) {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: targetDay)
        let isToday = cal.isDate(targetDay, inSameDayAs: now())
        let notBefore = isToday ? max(now(), dayStart) : dayStart.addingTimeInterval(9 * 3600)   // 今天从现在/未来日从9点
        let windDown = dayStart.addingTimeInterval(TimeInterval(WorkHoursSettings.windDownHour) * 3600)
        // #40 批2：有检查点则按「下一个」定块——时长优先取该检查点的预估，标题带上阶段名
        //（执行时知道具体干什么）；用户在草稿里照常可改可删。
        let next = task.nextCheckpoint
        let dur = TimeInterval((next?.estimatedMinutes ?? task.unitMinutes ?? 60) * 60)
        let existing = blocks.map { (start: $0.start, end: $0.end) }
        let fit = Self.firstFreeStart(existing: existing, duration: dur, notBefore: notBefore, windDown: windDown)
        let start = fit ?? (blocks.map(\.end).max() ?? notBefore)
        let blockTitle = next.map { "\(task.title) · \($0.title)" } ?? task.title
        var eb = EditableBlock(title: blockTitle, start: start, end: start.addingTimeInterval(dur),
                               linkedTaskID: task.id)
        eb.fromPool = true
        blocks.append(eb)
        blocks.sort { $0.start < $1.start }
        committedCount = nil; markEditedIfLoaded()
        if draftSource == .empty { draftSource = .arranged }
        note = fit != nil
            ? (autoCommit ? "已把「\(blockTitle)」排进空档（\(start.formatted(.dateTime.hour().minute()))），时间可以直接改。"
                          : "已把「\(blockTitle)」排进空档（\(start.formatted(.dateTime.hour().minute()))）——微调后确认写入。")
            : "今天收工前空档不够了，先接在末尾——你可以改期或挪到明天。"
        persistDraft()
    }

    /// 手动切松散（右上开关）：标上时顺手静音当日早晚提醒（退场姿态；即使昨晚已排今早的也清掉）。
    func toggleLoose() {
        looseDays?.toggle(targetDay)
        let nowLoose = looseDays?.isLoose(targetDay) ?? false
        if nowLoose { notifier.cancelDailyReminders() }
        BehaviorLog.record("松散日", nowLoose ? "标记" : "结束")
        FeatureUsage.used(.todayLoose, nowLoose ? "标记" : "结束")
    }

    func move(_ source: IndexSet, _ destination: Int) {
        let movedIDs = source.map { blocks[$0].id }
        blocks.move(fromOffsets: source, toOffset: destination)
        // #6：拖到某位置后按新邻居自动填时间（Jason 定：**保时长**，start=上一个块的结束；
        // 拖到最顶则 end=下一个块的开始、时长往前推）。允许短暂重叠，后续 reflow 会理。
        for id in movedIDs {
            guard let i = blocks.firstIndex(where: { $0.id == id }) else { continue }
            let dur = max(60, blocks[i].end.timeIntervalSince(blocks[i].start))   // 至少 1 分钟
            if i > 0 {
                let s = blocks[i - 1].end
                blocks[i].start = s
                blocks[i].end = s.addingTimeInterval(dur)
            } else if blocks.count > 1 {
                let e = blocks[1].start
                blocks[i].end = e
                blocks[i].start = e.addingTimeInterval(-dur)
            }
        }
        // 填完时间按 start 排序（与 #5 一致：时间决定最终顺序，落到该在的位置）
        withAnimation(Motion.emphasis) { blocks.sort { $0.start < $1.start } }
        committedCount = nil; markEditedIfLoaded(); persistDraft()
        FeatureUsage.used(.todayDrag)   // W21：拖动的唯一写入口（哪个视图调都记）
    }

    func delete(id: UUID) {
        blocks.removeAll { $0.id == id }
        committedCount = nil; markEditedIfLoaded(); persistDraft()
        FeatureUsage.used(.todayDelete)
    }

    // MARK: - 并行组（0.22：同组=同时段，reflow 绑定；手动建/解组）

    /// 某块的并行伙伴标题（徽章 hover 用）。
    func parallelPeerTitles(of id: UUID) -> [String] {
        guard let b = blocks.first(where: { $0.id == id }), let g = b.parallelGroup else { return [] }
        return blocks.filter { $0.id != id && $0.parallelGroup == g }.map(\.title)
    }

    /// 把两块设为并行（入对方组/建新组），并把时间对齐到较早者（同组=同时段）；
    /// 若两者已同组 → 解除 other 的并行（组只剩一人时顺带清空）。
    func toggleParallel(_ id: UUID, with otherID: UUID) {
        guard let i = blocks.firstIndex(where: { $0.id == id }),
              let j = blocks.firstIndex(where: { $0.id == otherID }) else { return }
        let mine = blocks[i].parallelGroup
        let theirs = blocks[j].parallelGroup
        if let g = mine, g == theirs {
            // 已同组 → 把 other 摘出去；组只剩自己则自己也清
            blocks[j].labels.removeAll { $0.hasPrefix(EditableBlock.parallelPrefix) }
            if blocks.filter({ $0.parallelGroup == g }).count < 2 {
                blocks[i].labels.removeAll { $0.hasPrefix(EditableBlock.parallelPrefix) }
            }
        } else {
            let group = theirs ?? mine ?? (EditableBlock.parallelPrefix + String(UUID().uuidString.prefix(8)))
            for k in [i, j] {
                blocks[k].labels.removeAll { $0.hasPrefix(EditableBlock.parallelPrefix) }
                blocks[k].labels.append(group)
            }
            // 同组=同时段：对齐到组内最早起点（各自保时长）
            if let earliest = blocks.filter({ $0.parallelGroup == group }).map(\.start).min() {
                for k in blocks.indices where blocks[k].parallelGroup == group {
                    let dur = blocks[k].end.timeIntervalSince(blocks[k].start)
                    blocks[k].start = earliest
                    blocks[k].end = earliest.addingTimeInterval(dur)
                }
            }
        }
        withAnimation(Motion.emphasis) { blocks.sort { $0.start < $1.start } }
        committedCount = nil; markEditedIfLoaded(); persistDraft()
        FeatureUsage.usedThrottled(.todayEdit, "并行")
    }

    /// 复制某块，插在其后（右键菜单用）。新块自带新 id，归属/时间沿用原块。
    func duplicate(id: UUID) {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        var copy = blocks[i]; copy.id = UUID()
        blocks.insert(copy, at: i + 1)
        committedCount = nil; markEditedIfLoaded(); persistDraft()
        FeatureUsage.usedThrottled(.todayEdit, "复制")
    }

    /// 按 id 的元素绑定——避免 `ForEach($:)` 在删除时的「独占访问」崩溃。
    func binding(for id: UUID) -> Binding<EditableBlock> {
        Binding(
            get: { self.blocks.first { $0.id == id }
                   ?? EditableBlock(title: "", start: .now, end: .now) },
            set: { newValue in
                if let i = self.blocks.firstIndex(where: { $0.id == id }) {
                    let startChanged = self.blocks[i].start != newValue.start
                    // 时间编辑器只改时分不改日期 → 重锚到目标日的逻辑日：
                    // 0–3:59 自动落次日日历日（跨午夜块），不再把 0:30 当"今天凌晨"排到最上面
                    var nv = newValue
                    nv.start = Self.anchored(nv.start, toLogicalDayOf: self.targetDay)
                    nv.end = Self.anchored(nv.end, toLogicalDayOf: self.targetDay)
                    if nv.end < nv.start { nv.end = nv.start.addingTimeInterval(30 * 60) }   // 防倒挂
                    self.blocks[i] = nv
                    self.markEditedIfLoaded()   // 内联改标题/时间/星标 → 变未确认草稿
                    // #5：改了开始时间 → 按 start 自动重排（动画滑到该去的位置）；只在 start 变时排，改标题/结束/星标不动位
                    if startChanged { withAnimation(Motion.emphasis) { self.blocks.sort { $0.start < $1.start } } }
                    self.persistDraft()
                    // W21：直接改块（时间 / 标题 / 属性）的唯一写入口；打字逐字触发 → 2 分钟内只记一次
                    FeatureUsage.usedThrottled(.todayEdit, startChanged ? "时间" : "其它")
                }
            }
        )
    }
}
