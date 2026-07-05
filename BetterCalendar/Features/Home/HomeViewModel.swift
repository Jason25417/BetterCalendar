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

/// 草稿块（可编辑的中间态，与不可变的 ScheduledBlock 互转）。
struct EditableBlock: Identifiable {
    var id: UUID
    var title: String
    var start: Date
    var end: Date
    var isFixed: Bool
    var isAnchor: Bool = false
    var timingStyle: TimingStyle
    var priority: BlockPriority
    var deadline: Date?   // 硬 DDL（≠isFixed）：必须在此之前做完；LLM 解析给出，提醒 due 优先用它
    var fromPool: Bool = false   // 来自「未来任务」的建议块（M10-2：UI 标来源，删除零成本）
    var linkedTaskID: UUID?      // 精确归属：本块属于哪个未来任务（0.18.2：自动匹配 + 草稿行可手动改）

    init(from b: ScheduledBlock) {
        id = b.id; title = b.title; start = b.start; end = b.end
        isFixed = b.isFixed; isAnchor = b.isAnchor; timingStyle = b.timingStyle; priority = b.priority
        deadline = b.deadline; linkedTaskID = b.linkedTaskID
    }
    init(title: String, start: Date, end: Date,
         isFixed: Bool = false, isAnchor: Bool = false,
         timingStyle: TimingStyle = .light, priority: BlockPriority = .normal,
         deadline: Date? = nil, linkedTaskID: UUID? = nil) {
        id = UUID(); self.title = title; self.start = start; self.end = end
        self.isFixed = isFixed; self.isAnchor = isAnchor; self.timingStyle = timingStyle; self.priority = priority
        self.deadline = deadline; self.linkedTaskID = linkedTaskID
    }
    var scheduled: ScheduledBlock {
        ScheduledBlock(id: id, title: title, start: start, end: end,
                       isFixed: isFixed, isAnchor: isAnchor, timingStyle: timingStyle, priority: priority,
                       deadline: deadline, linkedTaskID: linkedTaskID)
    }
}

/// 草稿从哪来：决定切目标日/重进页面时怎么对待当前列表。
enum DraftSource: String {
    case empty       // 什么都没有
    case arranged    // 刚「排今天」出的新草稿，还没确认——切日走平移、不被自动加载覆盖
    case loaded      // 从真相源加载的已确认计划——切日即切内容；编辑防抖自动回写（0.15）
}

@Observable
final class HomeViewModel {
    private let arrangeDay: ArrangeDayUseCase
    private let refiner: PlanRefining
    private let calendarStore: CalendarStore
    private let reminderStore: ReminderStore
    private let exporter: ICSExporting
    private let planStore: PlanStore
    private let reschedule: RescheduleService
    private let notifier: NotificationScheduling
    private let longTaskStore: LongTaskStore?   // 「在途」池（M10）；nil=不入池（旧测试兼容）
    private let draftStore: DraftSnapshotStore? // 草稿快照（崩溃/重启还原）；nil=不持久化
    private let looseDays: LooseDayStore?        // 松散日：LLM 识别"想松散"→标目标日（§5.12）；nil=不标

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
    /// 解析识别到、待确认入池的长期事项（确认写入时入「在途」）。
    var pendingLongTasks: [ParsedLongTask] = []
    /// 晨间 reflow「排不下」时的冲突（非 nil → 弹压缩/跳过/分割）。
    var reflowConflict: ReflowConflict?
    /// 未保存修改（0.16 文件模型，D-f）：任何编辑/新草稿置真；「确认写入」=保存清零。
    private(set) var hasUnsavedChanges = false
    /// 上次退出时留下的未保存修改（D-g：不自动还原，顶部小字邀请「恢复/丢弃」）。
    private(set) var pendingRestore: DraftSnapshot?

    init(arrangeDay: ArrangeDayUseCase, refiner: PlanRefining,
         calendarStore: CalendarStore, reminderStore: ReminderStore, exporter: ICSExporting,
         planStore: PlanStore, reschedule: RescheduleService, notifier: NotificationScheduling,
         longTaskStore: LongTaskStore? = nil, draftStore: DraftSnapshotStore? = nil,
         looseDays: LooseDayStore? = nil) {
        self.arrangeDay = arrangeDay
        self.refiner = refiner
        self.calendarStore = calendarStore
        self.reminderStore = reminderStore
        self.exporter = exporter
        self.planStore = planStore
        self.reschedule = reschedule
        self.notifier = notifier
        self.longTaskStore = longTaskStore
        self.draftStore = draftStore
        self.looseDays = looseDays
        restoreDraftIfAny()
    }

    // MARK: - 草稿快照（崩溃/重启还原；Jason 定 2026-07-04）

    /// 每次草稿变更即整份落盘（几 KB JSON，无感）；HomeView 对 inputText 变化也会调它。
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
            dirty: hasUnsavedChanges))
    }

    /// 启动检查（0.16，D-g）：**永远先显示已保存态**；上次退出时若留有未保存修改，
    /// 只存入 pendingRestore——顶部一行小字邀请「恢复/丢弃」，点了恢复才应用。
    /// （取代旧的自动还原：消灭「过期快照盖住已保存计划」整类问题，新鲜度检查随之删除。）
    private func restoreDraftIfAny() {
        guard let snap = draftStore?.load() else { return }
        inputText = snap.inputText
        let wasDirty = snap.dirty ?? (snap.draftSourceRaw == DraftSource.arranged.rawValue)
        if wasDirty, !snap.blocks.isEmpty {
            pendingRestore = snap
        }
    }

    /// 用户点「恢复」：应用上次未保存的修改。
    func applyPendingRestore() {
        guard let snap = pendingRestore else { return }
        blocks = snap.blocks.map(\.editable)
        targetDay = snap.targetDay
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
        loadConfirmedPlan()
        persistDraft()
    }

    // MARK: - 自动加载目标日计划（2026-07-01 Jason 定）

    /// 从真相源读**所选目标日**的已确认计划 → 可编辑列表。
    /// 加载后的编辑**自动保存**（0.15：防抖回写真相源+日历，不再要求二次确认）。
    /// 不显示完成状态——完成态归执行/复盘页，排日程页保持纯规划面。
    func loadConfirmedPlan() {
        let stored = (try? planStore.plannedBlocks(on: targetDay)) ?? []
        if stored.isEmpty {
            // 这天没有已确认计划：之前显示的是别天加载来的就清掉；别动用户排的新草稿
            if draftSource == .loaded { blocks = []; draftSource = .empty }
            return
        }
        blocks = stored.map(EditableBlock.init(from:))
        draftSource = .loaded
        hasUnsavedChanges = false
        committedCount = nil
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
        isWorking = true; errorText = nil; committedCount = nil
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
                    // 精确归属：池建议块一次性按标题匹配到具体未来任务的 id，之后统计锚 id 不再靠标题
                    if eb.fromPool, eb.linkedTaskID == nil {
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
            persistDraft()
        } catch {
            errorText = "排程失败：\(error.localizedDescription)"
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
            return ReminderDraft(title: p.title, due: due, priority: 5,
                                 notes: "未来任务截止", leadMinutes: leadMinutes)
        }
    }

    func refine() async {
        let cmd = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !blocks.isEmpty else { return }
        isWorking = true; committedCount = nil
        let scheduled = blocks.map(\.scheduled)
        // 归属按标题留存：LLM 微调重建块时会丢 linkedTaskID，refine 后按标题补回（自动+手动归属都不丢）
        var linkByTitle: [String: UUID] = [:]
        for b in blocks where b.linkedTaskID != nil { linkByTitle[b.title] = b.linkedTaskID }
        let result = (try? await refiner.refine(scheduled, command: cmd,
                                                originalRequest: inputText, now: .now)) ?? scheduled
        blocks = result.sorted { $0.start < $1.start }.map { b in
            var eb = EditableBlock(from: b)
            if eb.linkedTaskID == nil, let l = linkByTitle[b.title] { eb.linkedTaskID = l }
            return eb
        }
        draftSource = .arranged   // AI 微调后 = 未确认草稿（含对已加载计划的微调）
        refineText = ""
        hasUnsavedChanges = true
        persistDraft()
        isWorking = false
    }

    func confirm() async {
        // 固定块=会议/外部承诺 → 挂会前提醒（原则4「仅固定块提醒」；⑤会议自动化）；普通块 nil=不弹
        let drafts = blocks.sorted { $0.start < $1.start }.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .planned,
                               alarmLeadMinutes: $0.isFixed ? MeetingSettings.leadMinutes : nil)
        }
        // ★要紧事 与 带硬DDL 的块都进提醒事项；due 优先用 DDL（"必须何时前做完"），否则用开始时间
        var reminders = blocks.filter { $0.priority == .important || $0.deadline != nil }.map {
            ReminderDraft(title: $0.title, due: $0.deadline ?? $0.start,
                          priority: $0.priority == .important ? 1 : 5, notes: nil,
                          leadMinutes: ReminderSettings.leadMinutes)
        }
        // 带 DDL 的未来任务入池 → 也写一条系统提醒(due=DDL)，得到系统级 DDL 提醒（已排成今天块的跳过、不重复）
        reminders += Self.poolReminderDrafts(pending: pendingLongTasks, blockTitles: blocks.map(\.title),
                                             leadMinutes: ReminderSettings.leadMinutes)
        let sorted = blocks.sorted { $0.start < $1.start }
        isWorking = true; errorText = nil
        do {
            // 真相源：计划块（带 isFixed/priority）写 SwiftData，reflow 才有元数据可读。
            // 按日历日分组逐日 replace——草稿跨日（如排到次日凌晨）时不残留/不误删别天的块。
            let cal = Calendar.current
            let targetDayStart = cal.startOfDay(for: targetDay)
            var byDay = Dictionary(grouping: sorted) { cal.startOfDay(for: $0.start) }
            // 删光最后一件也要能保存：目标日即使无块也纳入 replace（清空真相源那天）。
            if byDay[targetDayStart] == nil { byDay[targetDayStart] = [] }
            for (day, dayBlocks) in byDay {
                try planStore.replacePlanned(dayBlocks.map(\.scheduled), on: day)
            }
            try await calendarStore.write(drafts)     // 路由：假/真 日历
            // 目标日被清空 → write(空)会早退不清绿色事件，显式按日清那天，避免残留与真相源不一致。
            if (byDay[targetDayStart] ?? []).isEmpty {
                try await calendarStore.clear(kind: .planned, on: targetDay)
            }
            try await reminderStore.write(reminders)  // ★要紧事 → 提醒事项（含提前提醒）
            committedCount = drafts.count
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
            persistDraft()
            // 松散日：静音早晚提醒（传 nil → 清掉旧的、不排新的）——退场姿态之一，不催不算账
            if looseDays?.isLoose(targetDay) ?? false {
                await notifier.scheduleDailyReminders(morning: nil, evening: nil, summary: "")
            } else {
                // 早晚极简通知：时间据今日计划（首块前 / 末块后）算
                let times = RescheduleService.reminderTimes(for: sorted.map(\.scheduled))
                await notifier.requestAuthorizationIfNeeded()
                await notifier.scheduleDailyReminders(morning: times.morning, evening: times.evening,
                                                      summary: "今天安排了 \(drafts.count) 件，开始吧。")
            }
        } catch {
            errorText = "写入失败：\(error.localizedDescription)"
        }
        isWorking = false
    }

    /// 晨间「开始今天」：从此刻 reflow 今日计划（开工晚了整体平移、固定块锚住）→ 可编辑预览草稿。
    /// 微调后用「确认写入」回写绿色 + 真相源（方案 A：晨间定稿即绿色基线）。
    func startToday(resolution: ReflowResolution? = nil) async {
        isWorking = true; errorText = nil; committedCount = nil
        do {
            let decision = try await reschedule.morningReflow(day: targetDay, now: .now, resolution: resolution)
            if decision.orderedBlocks.isEmpty {
                note = "这天还没有「确认写入」的计划可重排——先说一句、确认写入，再开始今天。"
            } else {
                blocks = decision.orderedBlocks.map(EditableBlock.init(from:))
                draftSource = .arranged   // reflow 结果也是待确认草稿
                let flex = decision.orderedBlocks.filter { !$0.isFixed }.count
                note = flex == 0
                    ? "这些都是固定块、reflow 不会挪动（任务别标「固定」就能被重排）。"
                    : "已把 \(flex) 件弹性事项从现在起重排好；微调后「确认写入」即可。"
            }
            reflowConflict = decision.conflict   // 仍排不下 → 再弹；nil → 收起
            hasUnsavedChanges = true
            persistDraft()
        } catch {
            errorText = "重排失败：\(error.localizedDescription)"
        }
        isWorking = false
    }

    /// 用户对「排不下」的选择 → 带解法重排。
    func resolveConflict(_ r: ReflowResolution) async {
        await startToday(resolution: r)
    }

    /// 改目标日时，把已有草稿的日期平移到新日（保留时分），而不是丢弃草稿。
    func shiftDraftsToDay(_ day: Date) {
        guard !blocks.isEmpty else { return }
        let cal = Calendar.current
        func onDay(_ time: Date) -> Date {
            let t = cal.dateComponents([.hour, .minute], from: time)
            return cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: day) ?? time
        }
        blocks = blocks.map { var b = $0; b.start = onDay(b.start); b.end = onDay(b.end); return b }
        persistDraft()
    }

    /// 标记未保存修改（0.16 文件模型：任何来源的编辑都不自动写库——「确认写入」才保存）。
    private func markEditedIfLoaded() {
        hasUnsavedChanges = true
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
        blocks.move(fromOffsets: source, toOffset: destination); committedCount = nil; markEditedIfLoaded(); persistDraft()
    }

    func delete(id: UUID) {
        blocks.removeAll { $0.id == id }
        committedCount = nil; markEditedIfLoaded(); persistDraft()
    }

    /// 按 id 的元素绑定——避免 `ForEach($:)` 在删除时的「独占访问」崩溃。
    func binding(for id: UUID) -> Binding<EditableBlock> {
        Binding(
            get: { self.blocks.first { $0.id == id }
                   ?? EditableBlock(title: "", start: .now, end: .now) },
            set: { newValue in
                if let i = self.blocks.firstIndex(where: { $0.id == id }) {
                    self.blocks[i] = newValue
                    self.markEditedIfLoaded()   // 内联改标题/时间/星标 → 变未确认草稿
                    self.persistDraft()
                }
            }
        )
    }
}
