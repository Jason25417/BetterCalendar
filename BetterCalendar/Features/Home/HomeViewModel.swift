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
    private let calendarStore: CalendarStore   // 只读用（排程上下文 busy）；写计划一律走 projection
    private let reminderStore: ReminderStore
    private let exporter: ICSExporting
    private let planStore: PlanStore           // ⚠️ 全 App 唯一的写者（PlanWriting）：只有「确认写入」落库
    private let projection: ProjectionService  // PlanStore→日历 单向投影（先写真相源、再投影）
    private let notifier: NotificationScheduling
    private let longTaskStore: LongTaskStore?   // 「在途」池（M10）；nil=不入池（旧测试兼容）
    private let draftStore: DraftSnapshotStore? // 草稿快照（崩溃/重启还原）；nil=不持久化
    private let looseDays: LooseDayStore?        // 松散日：LLM 识别"想松散"→标目标日（§5.12）；nil=不标
    private let startedDays: StartedDayStore?    // 绿色淡出：开始今天后进实时模式、绿色从日历淡出；nil=不淡出
    private let progress: ExecutionProgressReading?  // 0.24 C2：精修台"过去只读"边界（已完成/进行中）；nil=不感知

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
    var committedToReal: Bool = false
    /// 状态行 A（0.26 ABC）：排今天成功后的确定性状态「排好 N 件」（与模型 note=B 叠加显示）；编辑/确认/切日即清。
    private(set) var arrangedCount: Int?
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
         calendarStore: CalendarStore, reminderStore: ReminderStore, exporter: ICSExporting,
         planStore: PlanStore, projection: ProjectionService,
         notifier: NotificationScheduling,
         longTaskStore: LongTaskStore? = nil, draftStore: DraftSnapshotStore? = nil,
         looseDays: LooseDayStore? = nil, startedDays: StartedDayStore? = nil,
         progress: ExecutionProgressReading? = nil) {
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
                                              cadenceMinutesPerWeek: $0.cadenceMinutesPerWeek)
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
                           cadenceMinutesPerWeek: $0.cadenceMinutesPerWeek)
        }
        hasUnsavedChanges = true
        pendingRestore = nil
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
        arrangedCount = nil
        loadConfirmedPlan()
        persistDraft()
    }

    // MARK: - 自动加载目标日计划（2026-07-01 Jason 定）

    /// 收口信号（0.28 提案A）：实时日 且（剩余为空=都做完/都流逝 ∨ 已过收工线）——
    /// 强结束信号，收口卡据此出现（还要叠加「今天还没记录」，由视图查日记）。
    var wrapUpSignal: Bool {
        guard isLiveTargetDay else { return false }
        return blocks.isEmpty || Date.now >= WorkHoursSettings.effectiveWindDown(from: .now)
    }

    /// 目标日是否处于实时模式（0.24 C2）：已开始 且 是逻辑今天——精修台只对"正在过的这一天"生效。
    var isLiveTargetDay: Bool {
        (startedDays?.isStarted(targetDay) ?? false)
            && Calendar.current.startOfDay(for: targetDay) == DayContext.logicalDay(offset: 0)
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
            return
        }
        guard !base.isEmpty else {
            // 实时日剩余为空（都做完/都流逝）
            if draftSource == .loaded { blocks = []; draftSource = .empty }
            hasUnsavedChanges = false
            return
        }
        blocks = base
        draftSource = .loaded
        hasUnsavedChanges = false
        committedCount = nil
    }

    /// 「算最新底但不套用」（徽标 v2 重构，2026-07-10）：目标日**此刻**的最新底——
    /// 常规日=已确认计划；实时日=剩余从现在起 V2 铺排（=橙色预览同款口径，候补垫尾）。
    /// nil=这天没有已确认计划；[]=实时日剩余为空。只计算、不改任何状态——
    /// loadConfirmedPlan 拿它套用；徽标亮起时拿它做只读对比（freshBase）。
    private func computeFreshBase() -> [EditableBlock]? {
        let stored = (try? planStore.plannedBlocks(on: targetDay)) ?? []
        guard !stored.isEmpty else { return nil }
        guard isLiveTargetDay else { return stored.map(EditableBlock.init(from:)) }
        let settled = progress?.settledPlannedIDs ?? []
        let nowT = Date.now
        let remaining = stored.filter { !settled.contains($0.id) && $0.end > nowT }
        guard !remaining.isEmpty else { return [] }
        let laid = ReflowLayoutV2.layOut(
            flexible: remaining.filter { !$0.isFixed }.sorted { $0.start < $1.start },
            fixed: remaining.filter(\.isFixed), from: nowT,
            windDown: WorkHoursSettings.effectiveWindDown(from: nowT),
            graceMinutes: WorkHoursSettings.graceMinutes)
        return (laid.scheduled + laid.deferred.sorted { $0.start < $1.start })
            .map(EditableBlock.init(from:))
    }

    /// 进入排日程页时自动加载已保存计划（有未保存修改时绝不覆盖——文件模型）。
    func autoLoadOnAppear() {
        guard !hasUnsavedChanges else { return }
        loadConfirmedPlan()
    }

    /// 当前草稿 → ICS 文本（导出/分享）。
    func currentICS() -> String {
        let drafts = blocks.sorted { $0.start < $1.start }.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .planned)
        }
        return exporter.ics(for: drafts)
    }

    func arrange() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true; errorText = nil; committedCount = nil; arrangedCount = nil
        do {
            // 在途摘要给排程大脑（M10-2：LLM 可建议 0–2 块，标来源、删除零成本）
            let pool = (longTaskStore?.active() ?? []).map {
                LongTaskBrief(title: $0.title, deadline: $0.deadline,
                              cadenceMinutesPerWeek: $0.cadenceMinutesPerWeek)
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

    /// 微调防呆（端侧小模型爱过度概化：一次微调把所有块都改成 固定/★/番茄钟）：
    /// 命令里没提到相关词，就把 isFixed / priority / timingStyle 恢复为原值（按 id 配对、标题兜底）。
    /// 纯函数、可单测；新增块（原稿里没有的）不动。
    /// 微调防呆之二（0.23.1，点子簿 #9，试验台 R1 实锤）：模型偶尔**只返回改动的那块**（契约要求全量）。
    /// 部分返回按 标题相似度≥0.6 并回原清单：模型没回的 = 未改（不是删了）；匹配上的继承**原块 id**
    /// （盖章/归属稳定）；模型新增的块保留。命令含删除词（删/去掉/移除/取消）时信任模型的省略（删除仍可用）。
    /// 纯函数、模型无关（端侧/云端同吃）。
    static func mergePartialRefine(original: [ScheduledBlock], refined: [ScheduledBlock],
                                   command: String) -> [ScheduledBlock] {
        guard !refined.isEmpty else { return original }
        let deleteWords = ["删", "去掉", "移除", "取消"]
        let deleteIntent = deleteWords.contains { command.localizedCaseInsensitiveContains($0) }
        var usedRefined = Set<UUID>()
        var result: [ScheduledBlock] = []
        for o in original {
            let match = refined.first { !usedRefined.contains($0.id) && $0.id == o.id }
                ?? refined.first { !usedRefined.contains($0.id) && TitleMatch.similarity($0.title, o.title) >= 0.6 }
            if let r = match {
                usedRefined.insert(r.id)
                var nb = r
                nb.id = o.id   // 身份保持：投影盖章/完成判定不换章
                result.append(nb)
            } else if !deleteIntent {
                result.append(o)   // 没回 = 未改
            }
        }
        result += refined.filter { !usedRefined.contains($0.id) }   // 模型新增的块（"加一件"）保留
        return result
    }

    static func guardRefineFlags(original: [ScheduledBlock], refined: [ScheduledBlock],
                                 command: String) -> [ScheduledBlock] {
        let fixedWords = ["固定", "锁", "不能动", "雷打不动", "fix"]
        let priorityWords = ["星", "要紧", "重要", "优先"]
        let timingWords = ["番茄", "计时", "轻计", "不计"]
        let allowFixed = fixedWords.contains { command.localizedCaseInsensitiveContains($0) }
        let allowPriority = priorityWords.contains { command.localizedCaseInsensitiveContains($0) }
        let allowTiming = timingWords.contains { command.localizedCaseInsensitiveContains($0) }
        // isAnchor 永远守（作息锚点=结构性、无对应用户命令词；微调绝不能把午饭/晚饭悄悄变成「要完成的任务」）。
        // 只加不减：还原原块 isAnchor，或标题兜底（新加的午饭也锚）。独立于上面三个 allow——bug 修复 2026-07-09。
        func anchored(_ r: ScheduledBlock) -> ScheduledBlock {
            let o = original.first { $0.id == r.id } ?? original.first { TitleMatch.similarity($0.title, r.title) >= 0.6 }
            var nb = r
            nb.isAnchor = r.isAnchor || (o?.isAnchor ?? false) || ArrangeDayUseCase.isObviousAnchor(r.title)
            return nb
        }
        if allowFixed && allowPriority && allowTiming { return refined.map(anchored) }
        return refined.map { r in
            let base = anchored(r)
            guard let o = original.first(where: { $0.id == r.id })
                    ?? original.first(where: { TitleMatch.similarity($0.title, r.title) >= 0.6 })
            else { return base }
            var nb = base
            if !allowFixed { nb.isFixed = o.isFixed }
            if !allowPriority { nb.priority = o.priority }
            if !allowTiming { nb.timingStyle = o.timingStyle }
            // 微调防呆之三（0.23.1，点子簿 #9，试验台 R3 实锤）：命令既没提"固定"这类词、
            // 也没点名这个固定块 → 它的**起止时间**也还原（与 reflow「固定块绝不动」口径对齐）。
            // 局限：点名判定=命令包含完整标题；改固定块请带上它的名字。
            if o.isFixed, !allowFixed, !command.localizedCaseInsensitiveContains(o.title) {
                nb.start = o.start
                nb.end = o.end
            }
            return nb
        }
    }

    func refine() async {
        let cmd = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !blocks.isEmpty else { return }
        isWorking = true; committedCount = nil; arrangedCount = nil
        let scheduled = blocks.map(\.scheduled)
        // 归属按标题留存：LLM 微调重建块时会丢 linkedTaskID，refine 后按标题补回（自动+手动归属都不丢）
        var linkByTitle: [String: UUID] = [:]
        for b in blocks where b.linkedTaskID != nil { linkByTitle[b.title] = b.linkedTaskID }
        let raw = (try? await refiner.refine(scheduled, command: cmd,
                                             originalRequest: inputText, now: .now)) ?? scheduled
        // 防呆三连（模型无关）：①部分返回并回原清单（丢块=未改不是删）②没让改的属性不许批量翻转
        // ③没点名的固定块时间还原（②③在 guardRefineFlags 里）
        let merged = Self.mergePartialRefine(original: scheduled, refined: raw, command: cmd)
        let result = Self.guardRefineFlags(original: scheduled, refined: merged, command: cmd)
        // 并行组按标题留存（0.22）：LLM 微调重建块会丢 labels，按标题补回（同 linkedTaskID 的做法）
        var labelsByTitle: [String: [String]] = [:]
        for b in blocks where !b.labels.isEmpty { labelsByTitle[b.title] = b.labels }
        blocks = result.sorted { $0.start < $1.start }.map { b in
            var eb = EditableBlock(from: b)
            if eb.linkedTaskID == nil, let l = linkByTitle[b.title] { eb.linkedTaskID = l }
            if eb.labels.isEmpty, let ls = labelsByTitle[b.title] { eb.labels = ls }
            return eb
        }
        draftSource = .arranged   // AI 微调后 = 未确认草稿（含对已加载计划的微调）
        refineText = ""
        hasUnsavedChanges = true
        persistDraft()
        isWorking = false
    }

    func confirm() async {
        // 提醒重设计（2026-07-09）：只给**有具体 DDL** 的块写提醒事项——「尽早」不再发时钟提醒
        // （交给晨间/menu bar/nudge，因为它的开始时间是 reflow 的动态猜测、钉钟点=假精确+施压）。
        // 提醒响在 **p−m−N**（截止 − 时长 − 提前量）=「最迟该开始」的前向提醒（"现在做还来得及"）。
        let leadN = ReminderSettings.leadMinutes
        var reminders: [ReminderDraft] = []
        var pastDueNudges: [(title: String, ddl: Date, minutes: Int)] = []
        for b in blocks where b.deadline != nil {
            let ddl = b.deadline!
            let m = max(1, Int(b.end.timeIntervalSince(b.start) / 60))       // 时长(分)
            let fire = ddl.addingTimeInterval(TimeInterval(-(m + leadN) * 60))   // p−m−N
            if fire > .now {
                reminders.append(ReminderDraft(title: b.title, due: ddl, priority: 1, notes: nil,
                                               leadMinutes: m + leadN, blockID: b.id))   // 到期前 m+N 分响 = p−m−N
            } else {
                pastDueNudges.append((b.title, ddl, m))   // 已过 p−m−N（加得太晚）→ 不写 VTODO、直接发消息（clamp）
            }
        }
        // 带 DDL 的未来任务入池 → 系统提醒事项(due=DDL、响在 p−m−N)；已排成今天块的跳过、不重复
        reminders += Self.poolReminderDrafts(pending: pendingLongTasks, blockTitles: blocks.map(\.title),
                                             leadMinutes: leadN)
        let sorted = blocks.sorted { $0.start < $1.start }
        isWorking = true; errorText = nil; arrangedCount = nil
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
                let nowT = Date.now
                let preserved = stored.filter { settled.contains($0.id) || $0.end <= nowT }
                let preservedIDs = Set(preserved.map(\.id))
                let draftPart = (byLabel[targetLabel] ?? []).filter { !preservedIDs.contains($0.id) }
                let excluded = (byLabel[targetLabel]?.count ?? 0) - draftPart.count
                byLabel[targetLabel] = (preserved.map(EditableBlock.init(from:)) + draftPart)
                    .sorted { $0.start < $1.start }
                if excluded > 0 { note = "\(excluded) 件在你编辑期间已完成/进行中，保持原样。" }
            }
            for (label, dayBlocks) in byLabel {
                try planStore.replacePlanned(dayBlocks.map(\.scheduled), on: label)
                // 投影：常规日→绿；实时模式（已开始今天）→绿淡出、投橙。会前提醒规则在投影层统一挂。
                try await projection.project(label: label)
            }
            try await reminderStore.write(reminders)  // 有 DDL 的事项 → 提醒事项（响在 p−m−N）
            // 过点 clamp：p−m−N 已过去的（加得太晚），不写过期 VTODO（不会响），直接立刻发一条前向通知
            for n in pastDueNudges {
                await notifier.notifyNow(title: "「\(n.title)」该开始了",
                    body: "今天 \(n.ddl.formatted(.dateTime.hour().minute())) 前要完成、约需 \(n.minutes) 分，现在开始还来得及")
            }
            committedCount = sorted.count
            BehaviorLog.record("确认写入", "\(sorted.count) 件")
            committedToReal = (CalendarSettings.backend == .eventKit)
            draftSource = .loaded    // 写入后当前列表 = 已确认的计划
            // 长期事项入「在途」池（幂等：同名在途项只更新不重复）
            for p in pendingLongTasks {
                longTaskStore?.add(title: p.title, deadline: p.deadline,
                                   cadenceMinutesPerWeek: p.cadenceMinutesPerWeek,
                                   totalMinutes: p.totalMinutes, unitMinutes: p.unitMinutes)
            }
            pendingLongTasks = []
            hasUnsavedChanges = false   // 保存完成（文件模型的「保存」时刻）
            freshness = false           // 本页已成为最新（最后动作赢）
            freshBase = nil
            persistDraft()
            // 松散日：静音早晚提醒（传 nil → 清掉旧的、不排新的）——退场姿态之一，不催不算账
            if looseDays?.isLoose(targetDay) ?? false {
                await notifier.scheduleDailyReminders(morning: nil, evening: nil, summary: "")
            } else {
                // 早晚极简通知：时间据今日计划（首块前 / 末块后）算
                let times = RescheduleService.reminderTimes(for: sorted.map(\.scheduled))
                await notifier.requestAuthorizationIfNeeded()
                await notifier.scheduleDailyReminders(morning: times.morning, evening: times.evening,
                                                      summary: "今天安排了 \(sorted.count) 件，开始吧。")
            }
        } catch {
            errorText = "写入失败：\(error.localizedDescription)"
        }
        isWorking = false
    }

    // 「开始今天/晨间 reflow」已退役（0.23 A，SPEC §11 ①）：某逻辑日第一次真正开始一件事
    // （menu bar / 今天 tab 的 startBlock/startAlso）即进实时模式，重排由全天连续 reflow 后台完成；
    // 「塞不下」三选弹窗随之消失（产品债清偿——弹窗=羞辱，违 §3.3）。

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
            freshnessSource = .calendarEdit; freshness = true
            freshBase = computeFreshBase()   // 算最新底但不套用（v2 对比用）
        } else { loadConfirmedPlan() }
    }

    /// 执行进展变了（开始/完成/换件）：只影响实时日的精修台底。
    func noteExecutionProgress() {
        guard isLiveTargetDay else { return }
        if hasUnsavedChanges {
            freshnessSource = .reflow; freshness = true
            freshBase = computeFreshBase()
        } else { loadConfirmedPlan() }
    }

    /// 「载入最新」：放弃本页未确认修改，回到当下最新的底（干净、无羞辱的显式选择）。
    func reloadFreshBase() {
        freshness = false
        freshBase = nil
        discardDraft()
    }

    /// 对比后选「用最新的底」（=载入最新，语义同 reloadFreshBase，给对比视图一个明确动词）。
    func adoptFreshBase() { reloadFreshBase() }

    /// 对比后选「保留我的编辑」：熄徽标——最后动作赢，确认时以本页为准。
    func keepMyDraft() {
        freshness = false
        freshBase = nil
    }

    private var suppressNextDayChangeReload = false
    func targetDayDidChange() {
        if suppressNextDayChangeReload { suppressNextDayChangeReload = false; return }
        note = nil
        committedCount = nil
        arrangedCount = nil
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
        } else {
            inputText = draftStore?.load(day: targetDay)?.inputText ?? ""
            pendingLongTasks = []
            hasUnsavedChanges = false
            blocks = []
            draftSource = .empty
            loadConfirmedPlan()
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
        arrangedCount = nil   // A 状态行仅贴合"刚排好"的瞬间——一编辑即过期
    }

    func addBlock() {
        let start = blocks.map(\.end).max() ?? Date()
        blocks.append(EditableBlock(title: "新事项", start: start, end: start.addingTimeInterval(3600)))
        committedCount = nil; markEditedIfLoaded(); persistDraft()
    }

    /// 把一件「在途」排进当前草稿（过期三选的「今天排上」/ 抽屉「排进今天」）：加 1 小时块到尾部。
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
        let isToday = cal.isDateInToday(targetDay)
        let notBefore = isToday ? max(.now, dayStart) : dayStart.addingTimeInterval(9 * 3600)   // 今天从现在/未来日从9点
        let windDown = dayStart.addingTimeInterval(TimeInterval(WorkHoursSettings.windDownHour) * 3600)
        let dur = TimeInterval((task.unitMinutes ?? 60) * 60)   // 按单元定长，无单元退 60min
        let existing = blocks.map { (start: $0.start, end: $0.end) }
        let fit = Self.firstFreeStart(existing: existing, duration: dur, notBefore: notBefore, windDown: windDown)
        let start = fit ?? (blocks.map(\.end).max() ?? notBefore)
        var eb = EditableBlock(title: task.title, start: start, end: start.addingTimeInterval(dur),
                               linkedTaskID: task.id)
        eb.fromPool = true
        blocks.append(eb)
        blocks.sort { $0.start < $1.start }
        committedCount = nil; markEditedIfLoaded()
        if draftSource == .empty { draftSource = .arranged }
        note = fit != nil
            ? "已把「\(task.title)」排进空档（\(start.formatted(.dateTime.hour().minute()))）——微调后确认写入。"
            : "今天收工前空档不够了，先接在末尾——你可以改期或挪到明天。"
        persistDraft()
    }

    /// 手动切松散（右上开关）：标上时顺手静音当日早晚提醒（退场姿态；即使昨晚已排今早的也清掉）。
    func toggleLoose() {
        looseDays?.toggle(targetDay)
        if looseDays?.isLoose(targetDay) ?? false { notifier.cancelDailyReminders() }
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
        withAnimation { blocks.sort { $0.start < $1.start } }
        committedCount = nil; markEditedIfLoaded(); persistDraft()
    }

    func delete(id: UUID) {
        blocks.removeAll { $0.id == id }
        committedCount = nil; markEditedIfLoaded(); persistDraft()
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
        withAnimation { blocks.sort { $0.start < $1.start } }
        committedCount = nil; markEditedIfLoaded(); persistDraft()
    }

    /// 复制某块，插在其后（右键菜单用）。新块自带新 id，归属/时间沿用原块。
    func duplicate(id: UUID) {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        var copy = blocks[i]; copy.id = UUID()
        blocks.insert(copy, at: i + 1)
        committedCount = nil; markEditedIfLoaded(); persistDraft()
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
                    if startChanged { withAnimation { self.blocks.sort { $0.start < $1.start } } }
                    self.persistDraft()
                }
            }
        )
    }
}
