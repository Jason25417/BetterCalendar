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
    private let planStore: PlanStore?       // 读当日锚点标题（午饭/通勤等），复盘对比跳过它们；nil=不跳

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
         longTasks: LongTaskStore? = nil, planStore: PlanStore? = nil) {
        self.calendarStore = calendarStore
        self.comparer = comparer
        self.arrangeDay = arrangeDay
        self.localStore = localStore
        self.longTasks = longTasks
        self.planStore = planStore
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

    // MARK: - 对比

    func load() async {
        isWorking = true; errorText = nil
        do {
            let planned = try await calendarStore.read(kind: .planned)
                .filter { DayContext.isSameLogicalDay($0.start, .now) }
            let actual = try await calendarStore.read(kind: .actual)
                .filter { DayContext.isSameLogicalDay($0.start, .now) }
            // 当日计划块（真相源 PlanStore 有 isAnchor/priority；日历读回丢了这元数据）
            let todayPlanned = ((try? planStore?.plannedBlocks(on: .now)) ?? [])
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
            let decision = try await arrangeDay(text: t)   // referenceDate 默认今天
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
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .actual)
        }
        do {
            let existing = try await calendarStore.read(kind: .actual)
            // union 去重（同 标题+起始分钟 = 同一事件），比裸拼接稳：重复确认不产生双份
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
