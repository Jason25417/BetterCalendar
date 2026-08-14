//
//  ResidualFolderTests.swift
//  BetterCalendarTests
//
//  残差折算器（E4）：匹配/准入三排除/live-recall 判定 + 快照 save-once 语义（内存库，CloudKit 关——竞态教训）。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

@Suite struct ResidualFolderTests {
    private let cal = Calendar.current
    private func at(_ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: h, minute: mi))!
    }
    private func item(_ title: String, id: UUID = UUID(), start: Int, minutes: Int,
                      isFixed: Bool = false) -> SnapshotItem {
        SnapshotItem(id: id, title: title, plannedStart: at(start), plannedMinutes: minutes,
                     isFixed: isFixed, isAnchor: false, linkedTaskID: nil, labels: [])
    }

    /// 正常完成块：产样本，倍率原始量正确，有会话=live。
    @Test func foldsCompletedBlockWithLiveSource() {
        let id = UUID()
        let snap = [item("写作", id: id, start: 9, minutes: 60)]
        let actual = [ActualBlock(id: id, title: "写作", start: at(9, 20), end: at(10, 55))]
        let out = ResidualFolder.fold(dayLabel: at(0), snapshot: snap, actuals: actual,
                                      sessionBlockIDs: [id])
        #expect(out.count == 1)
        #expect(out[0].actualMinutes == 95)
        #expect(out[0].source == .live)
    }

    /// 无会话 = recall（复盘补记）。
    @Test func noSessionMeansRecall() {
        let id = UUID()
        let out = ResidualFolder.fold(dayLabel: at(0),
                                      snapshot: [item("阅读", id: id, start: 14, minutes: 45)],
                                      actuals: [ActualBlock(id: id, title: "阅读", start: at(15), end: at(16))],
                                      sessionBlockIDs: [])
        #expect(out.count == 1 && out[0].source == .recall)
    }

    /// 准入排除①：自动完成的固定块（无会话 + 实际起止照抄计划）不产样本。
    @Test func autoCompletedFixedBlockExcluded() {
        let id = UUID()
        let out = ResidualFolder.fold(dayLabel: at(0),
                                      snapshot: [item("会议", id: id, start: 10, minutes: 60, isFixed: true)],
                                      actuals: [ActualBlock(id: id, title: "会议", start: at(10), end: at(11))],
                                      sessionBlockIDs: [])
        #expect(out.isEmpty, "倍率恒 1 的假样本必须排除")
        // 但有会话（真去开了且计时了）的固定块照收
        let out2 = ResidualFolder.fold(dayLabel: at(0),
                                       snapshot: [item("会议", id: id, start: 10, minutes: 60, isFixed: true)],
                                       actuals: [ActualBlock(id: id, title: "会议", start: at(10), end: at(11, 20))],
                                       sessionBlockIDs: [id])
        #expect(out2.count == 1)
    }

    /// 准入排除②：无实际的块不产样本（结局待 E5）；③残缺时长不产样本。
    @Test func missingActualOrDurationExcluded() {
        let done = UUID(); let notDone = UUID()
        let out = ResidualFolder.fold(dayLabel: at(0),
                                      snapshot: [item("做了", id: done, start: 9, minutes: 30),
                                                 item("没做", id: notDone, start: 11, minutes: 60),
                                                 item("零时长", start: 13, minutes: 0)],
                                      actuals: [ActualBlock(id: done, title: "做了", start: at(9), end: at(9, 40))],
                                      sessionBlockIDs: [done])
        #expect(out.count == 1 && out[0].item.id == done)
    }

    /// 快照 save-once：同日第二次确认不覆盖（内存库验证）。
    @Test @MainActor func snapshotSaveOnce() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: DayPlanSnapshot.self, ResidualSample.self, configurations: config)
        let store = LearningStore(context: container.mainContext)
        let day = cal.startOfDay(for: at(12))
        let b1 = ScheduledBlock(title: "第一版", start: at(9), end: at(10))
        store.snapshotIfFirst(dayLabel: day, blocks: [b1])
        let b2 = ScheduledBlock(title: "改过的版", start: at(9), end: at(11))
        store.snapshotIfFirst(dayLabel: day, blocks: [b2, b1])
        let snap = store.snapshot(for: day)
        #expect(snap?.items.count == 1, "第二次确认不覆盖")
        #expect(snap?.items.first?.title == "第一版")
    }
}
