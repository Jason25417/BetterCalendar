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

@Observable
final class HomeViewModel {
    private let arrangeDay: ArrangeDayUseCase
    private let refiner: PlanRefining
    private let calendarStore: CalendarStore

    var inputText: String = ""
    var refineText: String = ""
    var note: String?
    var blocks: [EditableBlock] = []
    var isWorking: Bool = false
    var errorText: String?
    var committedCount: Int?
    var committedToReal: Bool = false

    init(arrangeDay: ArrangeDayUseCase, refiner: PlanRefining, calendarStore: CalendarStore) {
        self.arrangeDay = arrangeDay
        self.refiner = refiner
        self.calendarStore = calendarStore
    }

    func arrange() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true; errorText = nil; committedCount = nil
        do {
            let decision = try await arrangeDay(text: trimmed)
            blocks = decision.orderedBlocks.map(EditableBlock.init(from:))
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
        refineText = ""
        isWorking = false
    }

    func confirm() async {
        let drafts = blocks.sorted { $0.start < $1.start }.map {
            CalendarEventDraft(title: $0.title, start: $0.start, end: $0.end, kind: .planned)
        }
        isWorking = true; errorText = nil
        do {
            try await calendarStore.write(drafts)   // 路由：假日历 或 真 Apple 日历
            committedCount = drafts.count
            committedToReal = (CalendarSettings.backend == .eventKit)
        } catch {
            errorText = "写入失败：\(error.localizedDescription)"
        }
        isWorking = false
    }

    func addBlock() {
        let start = blocks.map(\.end).max() ?? Date()
        blocks.append(EditableBlock(title: "新事项", start: start, end: start.addingTimeInterval(3600)))
        committedCount = nil
    }

    func move(_ source: IndexSet, _ destination: Int) {
        blocks.move(fromOffsets: source, toOffset: destination); committedCount = nil
    }

    func delete(id: UUID) {
        blocks.removeAll { $0.id == id }
        committedCount = nil
    }

    /// 按 id 的元素绑定——避免 `ForEach($:)` 在删除时的「独占访问」崩溃。
    func binding(for id: UUID) -> Binding<EditableBlock> {
        Binding(
            get: { self.blocks.first { $0.id == id }
                   ?? EditableBlock(title: "", start: .now, end: .now) },
            set: { newValue in
                if let i = self.blocks.firstIndex(where: { $0.id == id }) {
                    self.blocks[i] = newValue
                }
            }
        )
    }
}
