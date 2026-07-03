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
    var timingStyle: TimingStyle
    var priority: BlockPriority

    init(from b: ScheduledBlock) {
        id = b.id; title = b.title; start = b.start; end = b.end
        isFixed = b.isFixed; timingStyle = b.timingStyle; priority = b.priority
    }
    init(title: String, start: Date, end: Date,
         isFixed: Bool = false, timingStyle: TimingStyle = .light, priority: BlockPriority = .normal) {
        id = UUID(); self.title = title; self.start = start; self.end = end
        self.isFixed = isFixed; self.timingStyle = timingStyle; self.priority = priority
    }
    var scheduled: ScheduledBlock {
        ScheduledBlock(id: id, title: title, start: start, end: end,
                       isFixed: isFixed, timingStyle: timingStyle, priority: priority)
    }
}

/// 草稿从哪来：决定切目标日/重进页面时怎么对待当前列表。
enum DraftSource {
    case empty       // 什么都没有
    case arranged    // 刚「排今天」出的新草稿，还没确认——切日走平移、不被自动加载覆盖
    case loaded      // 从真相源加载的已确认计划——切日即切内容，编辑后需再「确认写入」
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
    /// 晨间 reflow「排不下」时的冲突（非 nil → 弹压缩/跳过/分割）。
    var reflowConflict: ReflowConflict?

    init(arrangeDay: ArrangeDayUseCase, refiner: PlanRefining,
         calendarStore: CalendarStore, reminderStore: ReminderStore, exporter: ICSExporting,
         planStore: PlanStore, reschedule: RescheduleService, notifier: NotificationScheduling) {
        self.arrangeDay = arrangeDay
        self.refiner = refiner
        self.calendarStore = calendarStore
        self.reminderStore = reminderStore
        self.exporter = exporter
        self.planStore = planStore
        self.reschedule = reschedule
        self.notifier = notifier
    }

    // MARK: - 自动加载目标日计划（2026-07-01 Jason 定）

    /// 从真相源读**所选目标日**的已确认计划 → 可编辑列表。
    /// 加载后的一切编辑都是「对计划日历的修改」，仍需点「确认写入」才生效（幂等覆盖当天）。
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
        committedCount = nil
    }

    /// 进入排日程页时自动加载（不覆盖还没确认的新草稿）。
    func autoLoadOnAppear() {
        guard draftSource != .arranged else { return }
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
            // referenceDate = 目标日 → 不写日期时也排到对的那天（晚上默认明天）
            let decision = try await arrangeDay(text: trimmed, referenceDate: targetDay)
            blocks = decision.orderedBlocks.map(EditableBlock.init(from:))
            draftSource = .arranged
            note = decision.note
        } catch {
            errorText = "排程失败：\(error.localizedDescription)"
        }
        isWorking = false
    }

    func refine() async {
        let cmd = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !blocks.isEmpty else { return }
        isWorking = true; committedCount = nil
        let scheduled = blocks.map(\.scheduled)
        let result = (try? await refiner.refine(scheduled, command: cmd, now: .now)) ?? scheduled
        blocks = result.map(EditableBlock.init(from:))
        draftSource = .arranged   // AI 微调后 = 未确认草稿（含对已加载计划的微调）
        refineText = ""
        isWorking = false
    }

    func confirm() async {
        let drafts = blocks.sorted { $0.start < $1.start }.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .planned)
        }
        let reminders = blocks.filter { $0.priority == .important }.map {
            ReminderDraft(title: $0.title, due: $0.start, priority: 1, notes: nil,
                          leadMinutes: ReminderSettings.leadMinutes)
        }
        let sorted = blocks.sorted { $0.start < $1.start }
        isWorking = true; errorText = nil
        do {
            // 真相源：计划块（带 isFixed/priority）写 SwiftData，reflow 才有元数据可读。
            // 按日历日分组逐日 replace——草稿跨日（如排到次日凌晨）时不残留/不误删别天的块。
            let byDay = Dictionary(grouping: sorted) { Calendar.current.startOfDay(for: $0.start) }
            for (day, dayBlocks) in byDay {
                try planStore.replacePlanned(dayBlocks.map(\.scheduled), on: day)
            }
            try await calendarStore.write(drafts)     // 路由：假/真 日历
            try await reminderStore.write(reminders)  // ★要紧事 → 提醒事项（含提前提醒）
            committedCount = drafts.count
            committedToReal = (CalendarSettings.backend == .eventKit)
            draftSource = .loaded    // 写入后当前列表 = 已确认的计划
            // 早晚极简通知：时间据今日计划（首块前 / 末块后）算
            let times = RescheduleService.reminderTimes(for: sorted.map(\.scheduled))
            await notifier.requestAuthorizationIfNeeded()
            await notifier.scheduleDailyReminders(morning: times.morning, evening: times.evening,
                                                  summary: "今天安排了 \(drafts.count) 件，开始吧。")
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
    }

    /// 用户编辑了「已加载的确认计划」→ 它变成未确认草稿：不再被 autoLoad/切日静默覆盖
    /// （与 .arranged 同待遇：切日平移不丢、需再「确认写入」才回写）。徽章也随之从「已确认」变回「草稿」。
    private func markEditedIfLoaded() {
        if draftSource == .loaded { draftSource = .arranged }
    }

    func addBlock() {
        let start = blocks.map(\.end).max() ?? Date()
        blocks.append(EditableBlock(title: "新事项", start: start, end: start.addingTimeInterval(3600)))
        committedCount = nil; markEditedIfLoaded()
    }

    func move(_ source: IndexSet, _ destination: Int) {
        blocks.move(fromOffsets: source, toOffset: destination); committedCount = nil; markEditedIfLoaded()
    }

    func delete(id: UUID) {
        blocks.removeAll { $0.id == id }
        committedCount = nil; markEditedIfLoaded()
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
                }
            }
        )
    }
}
