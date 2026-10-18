//
//  ExecutionViewModel+ProposalTimer.swift
//  BetterCalendar
//
//  SPEC §19 W1 ②：多端审批的计时动作走执行层现有路径（startBlock / startAdHoc / toggleBreak / completeCurrent），
//  本地计时与共享计时（usesCanonicalTiming）的分流仍由这些方法自己决定。结束计时 = 记下这段投入，不改事项状态。
//  W8（Jason 2026-10-18）：开始计时可带回溯起点（批准后从那一刻起算）；查重叠用 proposalBusySpans。
//

import Foundation

extension ExecutionViewModel: ProposalTimerControlling {
    var proposalTimerState: ProposalTimerState {
        if let a = active {
            return ProposalTimerState(phase: isOnBreak ? .paused : .running, title: a.title, blockId: a.plannedID,
                                      startedAt: a.start, elapsed: currentElapsed)
        }
        if usesCanonicalTiming, let s = canonicalTasks?.primary, s.status != .finished {
            let block = s.relatedRecordId.flatMap { $0.hasPrefix("PlanBlock:") ? UUID(uuidString: String($0.dropFirst(10))) : nil }
            return ProposalTimerState(phase: s.status == .paused ? .paused : .running, title: s.title, blockId: block,
                                      startedAt: s.startedAt, elapsed: canonicalTasks?.elapsed(s))
        }
        return .idle
    }

    func proposalPlanItemTitle(_ id: UUID) async -> String? {
        if !loaded { await loadToday() }
        return planned.first { $0.id == id }?.title
    }

    func proposalStartTimer(blockId: UUID?, title: String?, at startAt: Date?) async throws {
        if let blockId {
            if !loaded { await loadToday() }
            guard let item = planned.first(where: { $0.id == blockId }) else {
                throw ProposalExecutionError.conflict("这块已不在今天的执行列表里")
            }
            await startBlock(item, at: startAt)
        } else if let title {
            await startAdHoc(title: title, at: startAt)
        } else {
            throw ProposalExecutionError.invalid("开始计时缺少目标")
        }
    }

    func proposalPauseTimer() async throws {
        guard proposalTimerState.phase == .running else { throw ProposalExecutionError.conflict("现在没有进行中的计时") }
        await toggleBreak()
    }

    func proposalResumeTimer() async throws {
        guard proposalTimerState.phase == .paused else { throw ProposalExecutionError.conflict("现在没有暂停中的计时") }
        await toggleBreak()
    }

    func proposalStopTimer() async throws {
        guard proposalTimerState.phase != .idle else { throw ProposalExecutionError.conflict("现在没有在计时") }
        await completeCurrent()
    }

    func proposalBusySpans() async -> [ProposalBusySpan] {
        if !loaded { await loadToday() }
        let now = Date.now
        var spans = done.map { ProposalBusySpan(title: $0.title, start: $0.start, end: $0.end) }
        if let a = active { spans.append(ProposalBusySpan(title: a.title, start: a.start, end: now)) }
        spans += background.map { ProposalBusySpan(title: $0.title, start: $0.start, end: now) }
        if let tasks = canonicalTasks, tasks.isEnabled {
            spans += tasks.sessions.filter { !$0.isExperiment && $0.status != .finished }
                .map { ProposalBusySpan(title: $0.title, start: $0.startedAt, end: now) }
        }
        return spans
    }
}
