//
//  ExecutionSessionStore.swift
//  BetterCalendar
//
//  执行会话落库（M6b 细化，2026-07-04）：每次「完成/切走」一个前台块、或完成一个后台并行块，
//  记一条 ExecutionSession（净时长/计时风格/番茄工作段数/休息次数）。
//  用途：给日后趋势统计（累计投入、专注段数——正向口径）铺数据；SwiftData 随 CloudKit 跨端。
//

import Foundation
import SwiftData

@MainActor
final class ExecutionSessionStore {
    private let context: ModelContext

    init(context: ModelContext? = nil) {
        self.context = context ?? SharedModelContainer.shared.mainContext
    }

    /// 记一条会话。completedCount = 番茄工作段数（非番茄给 nil）；interruptions = 中途休息次数。
    func record(blockID: UUID?, title: String, start: Date, end: Date,
                timingStyle: TimingStyle, pomodoroWorkSegments: Int?, interruptions: Int) {
        let s = ExecutionSession(blockID: blockID, start: start, end: end,
                                 timingStyle: timingStyle,
                                 completedCount: pomodoroWorkSegments,
                                 interruptions: interruptions)
        s.title = title
        context.insert(s)
        do { try context.save() }
        catch { DevLog.shared.warn("计时历史", "会话保存失败，未声称已落库：\(error.localizedDescription)") }
    }

    /// 某逻辑日的会话（趋势统计/复盘细化用）。
    func sessions(onLogicalDay day: Date) -> [ExecutionSession] {
        ((try? context.fetch(FetchDescriptor<ExecutionSession>())) ?? [])
            .filter { DayContext.isSameLogicalDay($0.start, day) }
            .sorted { $0.start < $1.start }
    }
}
