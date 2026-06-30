//
//  CalendarSyncService.swift
//  BetterCalendar
//
//  日历 → 真相库反向同步：你在 Apple 日历里直接改绿色「计划」事件（挪时间/改标题）后，
//  把改动同步回 SwiftData 真相源 PlanBlock，让 reflow 读到的元数据与日历一致。
//  - 元数据保留：日历事件没存 isFixed/priority，按**标题匹配**现有 PlanBlock 保留。
//  - 防循环：我们自己写日历也会触发同一通知 → 用去抖 + 「无差异不写」兜住（写完读回与库一致→不更新）。
//

import Foundation
import EventKit

@MainActor
final class CalendarSyncService {
    private let calendarStore: CalendarStore
    private let planStore: PlanStore
    private var listenTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    init(calendarStore: CalendarStore, planStore: PlanStore) {
        self.calendarStore = calendarStore
        self.planStore = planStore
    }

    /// 开始监听系统日历变化。
    func start() {
        listenTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                self?.scheduleSync()
            }
        }
    }

    private func scheduleSync() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))   // 合并连续通知
            if Task.isCancelled { return }
            await self?.syncToday()
        }
    }

    private func syncToday() async {
        guard CalendarSettings.backend == .eventKit else { return }   // 只有真日历会被外部改
        let day = Date.now
        do {
            let cal = try await calendarStore.read(kind: .planned)
                .filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
            let db = try planStore.plannedBlocks(on: day)
            // 用日历的时间 + 按标题匹配的库内元数据（isFixed/priority/timingStyle），合并成新真相
            let merged = cal.map { c -> ScheduledBlock in
                let meta = db.first { TitleMatch.similarity($0.title, c.title) >= 0.6 }
                return ScheduledBlock(title: c.title, start: c.start, end: c.end,
                                      isFixed: meta?.isFixed ?? false,
                                      timingStyle: meta?.timingStyle ?? .light,
                                      priority: meta?.priority ?? .normal,
                                      deadline: meta?.deadline)
            }
            guard Self.differs(db, merged) else { return }   // 无差异不写（防无谓写 + 切断循环）
            try planStore.replacePlanned(merged, on: day)
            DevLog.shared.info("同步", "日历改动 → 真相库更新 \(merged.count) 块")
        } catch {
            DevLog.shared.warn("同步", "日历→真相库同步失败：\(error.localizedDescription)")
        }
    }

    private static func differs(_ a: [ScheduledBlock], _ b: [ScheduledBlock]) -> Bool {
        func key(_ s: ScheduledBlock) -> String {
            "\(s.title)#\(Int(s.start.timeIntervalSinceReferenceDate / 60))#\(Int(s.end.timeIntervalSinceReferenceDate / 60))"
        }
        return Set(a.map(key)) != Set(b.map(key))
    }
}
