//
//  ReviewViewModel.swift
//  BetterCalendar
//
//  晚间复盘（降级版）：menu bar 已无感采集实际后，这里只做两件轻事——
//  ① 正反馈展示（读回 绿/蓝 → PlanComparing）；② 30 秒补漏 + 计划外 bonus 的回填。
//  回填复用「解析 → 可编辑草稿 → 确认写入」那套，只是 kind=.actual，且**合并**进已采集实际（不覆盖）。
//

import Foundation
import Observation
import SwiftUI   // Binding

@Observable
final class ReviewViewModel {
    private let calendarStore: CalendarStore
    private let comparer: PlanComparing
    private let arrangeDay: ArrangeDayUseCase
    private let localStore: ReviewLocalStore
    private let longTasks: LongTaskStore?   // 长线推进行（M10-3）；nil=不显示
    // 复盘：读计划 + 读/写蓝色实际（A2 后真相在 PlanStore；补一笔写这里=即时可读、无 EventKit 缓存竞态）。nil=测试可省。
    private let planStore: (PlanReading & ActualReading & ActualWriting)?
    private let looseDays: LooseDayStore?    // 松散日 → 复盘转"休息肯定"（§5.12）；nil=不转

    /// 今天是否松散日 → 复盘转肯定（不显对比/完成率，措辞赋义）。
    var isLooseToday: Bool { looseDays?.isLoose(.now) ?? false }

    var comparison: DayComparison?
    var showDetails = false        // 完成率/缺口默认隐藏，主动点才看
    var isWorking = false
    var errorText: String?

    // 活跃天累计 + 今日「最有价值的一件」
    var activeDayCount = 0
    var mvpTitle: String?
    var mvpNote = ""
    /// 长线推进行（M10-3，今天动过的在途；nil=今天没动长线，不显示）。
    var longTaskProgress: String?
    /// 今日做成的要紧事（★兑现红利）——复盘特写"🎯 最要紧的X做成了"；没做成的不进（不罚、不留校）。
    var mitAccomplished: [String] = []

    // 降级回填：补今天 menu bar 没抓到的 / 计划外的
    var backfillText = ""
    var backfillBlocks: [EditableBlock] = []
    var backfillCommitted: Int?

    init(calendarStore: CalendarStore, comparer: PlanComparing,
         arrangeDay: ArrangeDayUseCase, localStore: ReviewLocalStore,
         longTasks: LongTaskStore? = nil, planStore: (PlanReading & ActualReading & ActualWriting)? = nil,
         looseDays: LooseDayStore? = nil) {
        self.calendarStore = calendarStore
        self.comparer = comparer
        self.arrangeDay = arrangeDay
        self.localStore = localStore
        self.longTasks = longTasks
        self.planStore = planStore
        self.looseDays = looseDays
    }

    /// 剥离锚点：午饭/通勤/午休这类作息不是"要完成的任务"，不进对比（否则会算成 missed）。
    /// 纯函数、可单测：标题与任一当日锚点相似(≥0.6)即剔除，绿蓝两侧都剔。
    static func stripAnchors(_ drafts: [CalendarEventDraft],
                            anchorTitles: [String]) -> [CalendarEventDraft] {
        guard !anchorTitles.isEmpty else { return drafts }
        return drafts.filter { d in
            !anchorTitles.contains { TitleMatch.similarity($0, d.title) >= 0.6 }
        }
    }

    /// 兑现红利：今日要紧事里，被"做成清单"命中的（≥0.6）= 兑现了。纯函数、可单测。
    /// 只回做成的——没做成的绝不进（不罚、不留校，红利是可领的奖赏非欠的罚单）。
    static func mitDone(importantTitles: [String], accomplishedTitles: [String]) -> [String] {
        importantTitles.filter { mit in
            accomplishedTitles.contains { TitleMatch.similarity($0, mit) >= 0.6 }
        }
    }

    /// 聪音日历·日记槽摘要（2026-07-10 过审，含清单版）：只写做成的（含计划外标注）+ 尽早兑现 +
    /// MVP + 有效投入。纯函数、可单测；空天返回空串（mod 不写）。绝不出现"没做成/完成率/逾期"。
    static func chiyneDailySummary(comparison c: DayComparison?, mitDone: [String], mvpTitle: String?) -> String {
        guard let c, c.accomplishedCount > 0 else { return "" }
        var lines: [String] = []
        let names = c.accomplished.map { $0.displayTitle + ($0.status == .extra ? "（计划外）" : "") }
        lines.append("今天做成 \(c.accomplishedCount) 件：" + names.joined(separator: "、"))
        if !mitDone.isEmpty { lines.append("🎯 想尽早的「\(mitDone.joined(separator: "」「"))」做成了") }
        if let mvp = mvpTitle, !mvp.isEmpty { lines.append("⭐ 今日最有价值：\(mvp)") }
        let m = c.effectiveMinutes
        if m > 0 { lines.append(m >= 60 ? "有效投入 \(m / 60) 小时 \(m % 60) 分" : "有效投入 \(m) 分钟") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 对比

    func load() async {
        isWorking = true; errorText = nil
        do {
            // 实际：A2 后真相在 PlanStore（读它=补一笔即时可见、无 EventKit 缓存竞态）；再并入带章、真相源还没有的日历实际。
            let label = DayContext.logicalStartOfDay(.now)
            let stored = (try? planStore?.actualBlocks(on: label)) ?? []
            var actual = stored.map { CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end,
                                                         kind: .actual, blockID: $0.id) }
            let storedIDs = Set(stored.map(\.id))
            for c in ((try? await calendarStore.read(kind: .actual)) ?? [])
            where DayContext.isSameLogicalDay(c.start, .now) {
                if let bid = c.blockID, !storedIDs.contains(bid) { actual.append(c) }
            }
            // 绿色淡出地基（§5.10 原则6.4）：绿色计划从 PlanStore **真相源**读，不再从日历读——
            // 这样绿色即使从 Apple 日历常驻淡出，签名功能「计划×实际」对比依然成立。
            // 传**逻辑日标签**（凌晨 1 点复盘=复盘昨晚这一天）：计划与实际两侧同一逻辑日窗口，完成度不错位。
            let todayPlanned = (try? planStore?.plannedBlocks(on: DayContext.logicalStartOfDay(.now))) ?? []
            let planned = todayPlanned.map {
                CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .planned,
                                   blockID: $0.id)
            }
            let anchorTitles = todayPlanned.filter(\.isAnchor).map(\.title)
            comparison = comparer.compare(
                planned: Self.stripAnchors(planned, anchorTitles: anchorTitles),
                actual: Self.stripAnchors(actual, anchorTitles: anchorTitles))
            // 兑现红利：今日要紧事被"做成清单"命中的 → 复盘特写；没做成的不进
            let importantTitles = todayPlanned.filter { $0.priority == .important }.map(\.title)
            mitAccomplished = Self.mitDone(
                importantTitles: importantTitles,
                accomplishedTitles: comparison?.accomplished.map(\.displayTitle) ?? [])
            // 当天做成 ≥1 件 → 计入活跃日（极低门槛）
            if let c = comparison, c.accomplishedCount > 0 { localStore.markActive() }
        } catch {
            errorText = "读取失败：\(error.localizedDescription)"
            DevLog.shared.warn("复盘", "读取对比失败：\(error.localizedDescription)")
        }
        activeDayCount = localStore.activeDayCount
        mvpTitle = localStore.todayMVP
        mvpNote = localStore.todayMVPNote
        longTaskProgress = longTasks?.progressLine()
        // 聪音日历·日记槽：复盘摘要出口（与待办投影同一把开关；测试 host 在 exporter 内部有防呆闸）
        FocusStateExporter.writeDailySummary(
            Self.chiyneDailySummary(comparison: comparison, mitDone: mitAccomplished, mvpTitle: mvpTitle),
            logicalDay: DayContext.logicalStartOfDay(.now))
        isWorking = false
    }

    /// 设/取消「今日最有价值的一件」（再点同一项＝取消）。
    func toggleMVP(_ title: String) {
        mvpTitle = (mvpTitle == title) ? nil : title
        localStore.todayMVP = mvpTitle
    }

    func saveMVPNote() {
        localStore.todayMVPNote = mvpNote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 回填（解析 → 草稿）

    func parseBackfill() async {
        let t = backfillText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        isWorking = true; backfillCommitted = nil; errorText = nil
        do {
            // 补一笔=记过去做的事 → isBackfill 关掉 now+5min 起排下限（否则约束把过去的事推到未来/丢弃）
            let decision = try await arrangeDay.full(text: t, context: ParseContext(isBackfill: true)).decision
            backfillBlocks = decision.orderedBlocks.map(EditableBlock.init(from:))
        } catch {
            errorText = "解析失败：\(error.localizedDescription)"
        }
        isWorking = false
    }

    /// 写蓝色实际日历：与已采集实际**合并**（保留 menu bar 攒的），再刷新对比。
    func confirmBackfill() async {
        guard !backfillBlocks.isEmpty else { return }
        isWorking = true; errorText = nil
        let newDrafts = backfillBlocks.sorted { $0.start < $1.start }.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .actual,
                               blockID: $0.id)   // 回填的实际也盖章（草稿块 id）
        }
        do {
            // A2 真相源：补一笔先 upsert 进 PlanStore（即时可读、load() 立刻能对比出来，无 EventKit 竞态）
            try? planStore?.upsertActuals(backfillBlocks.map {
                ActualBlock(id: $0.id, title: $0.title, start: $0.start, end: $0.end)
            })
            let existing = try await calendarStore.read(kind: .actual)
            // 再投影日历（union 去重：同 标题+起始分钟=同一事件，重复确认不双份）
            try await calendarStore.write(
                CalendarMerge.union(existing: existing, additions: newDrafts, kind: .actual))
            backfillCommitted = newDrafts.count
            backfillBlocks = []
            backfillText = ""
            await load()
        } catch {
            errorText = "写入失败：\(error.localizedDescription)"
        }
        isWorking = false
    }

    // MARK: - 草稿编辑（与首页同模式：按值遍历 + 按 id 绑定/删除，避开独占访问崩溃）

    func addBackfillBlock() {
        let start = backfillBlocks.map(\.end).max() ?? Date()
        backfillBlocks.append(EditableBlock(title: "做了点别的", start: start,
                                            end: start.addingTimeInterval(1800)))
        backfillCommitted = nil
    }

    func deleteBackfill(id: UUID) {
        backfillBlocks.removeAll { $0.id == id }
        backfillCommitted = nil
    }

    func binding(for id: UUID) -> Binding<EditableBlock> {
        Binding(
            get: { self.backfillBlocks.first { $0.id == id }
                   ?? EditableBlock(title: "", start: .now, end: .now) },
            set: { newValue in
                if let i = self.backfillBlocks.firstIndex(where: { $0.id == id }) {
                    self.backfillBlocks[i] = newValue
                }
            }
        )
    }
}
