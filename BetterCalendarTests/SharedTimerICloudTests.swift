import Foundation
import Testing
import SwiftData
@testable import BetterCalendar

/// W5：共享计时 iCloud 后端（docs/bc-shared-timer-icloud.md §10）。全部走内存「云」，不碰网络与真实数据。
@MainActor struct SharedTimerICloudTests {
    final class Clock { var t = Date(timeIntervalSince1970: 1_790_000_000) }

    private func device(_ cloud: MemorySharedTimerCloud, _ clock: Clock, id: String,
                        disk: BridgeTaskMemoryPersistence? = nil) -> BridgeTaskViewModel {
        let service = ICloudSharedTimerService(store: MemorySharedTimerStore(cloud: cloud), deviceId: id, now: { clock.t })
        return BridgeTaskViewModel(service: service, persistence: disk ?? BridgeTaskMemoryPersistence(), enabled: { true }, now: { clock.t },
                                   backend: .icloud, activePoll: 10, idlePoll: 30)
    }

    private func command(_ action: BridgeTaskCommand.Action, id: String, on session: SharedTimerSession? = nil,
                         at: Date, title: String? = nil, mode: BridgeTaskSession.Mode? = nil, minutes: Int? = nil) -> BridgeTaskCommand {
        BridgeTaskCommand(commandId: id, action: action, title: title, sessionId: session?.id,
                          expectedRevision: session?.revision, occurredAt: at, mode: mode, focusMinutes: minutes)
    }

    private func written(_ outcome: SharedTimerReducer.Outcome) throws -> SharedTimerSession {
        guard case let .write(s) = outcome else { throw SharedTimerRejection(code: 0, message: "expected write") }
        return s
    }

    // MARK: 数据结构

    @Test func payloadRoundTripsAndSessionIdIsDerivedFromStartCommand() throws {
        let at = Clock().t
        let s = try written(SharedTimerReducer.apply(command(.start, id: "cmd-1", at: at, title: "写论文", mode: .pomodoro, minutes: 25),
                                                     to: nil, deviceId: "mac", now: at))
        #expect(s.id == SharedTimerReducer.sessionId(forStart: "cmd-1"))
        #expect(s.id.hasPrefix("timer_") && s.id.count == 38)
        #expect(SharedTimerReducer.sessionId(forStart: "cmd-1") == SharedTimerReducer.sessionId(forStart: "cmd-1"))
        #expect(SharedTimerReducer.sessionId(forStart: "cmd-2") != s.id)
        let raw = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        let decoded = try SharedTimerRecordCodec.decode(payload: raw, recordName: s.id)
        #expect(decoded == s)
        #expect(decoded.events.count == 1 && decoded.events[0].deviceId == "mac" && decoded.revision == 1)
        #expect(throws: SharedTimerRejection.self) { try SharedTimerRecordCodec.decode(payload: raw, recordName: "timer_other") }
        #expect(throws: SharedTimerRejection.self) { try SharedTimerRecordCodec.decode(payload: "{not json", recordName: s.id) }
        #expect(throws: SharedTimerRejection.self) { try SharedTimerRecordCodec.decode(payload: nil, recordName: s.id) }
        var broken = s; broken.revision = 5   // 版本号与事件历史不符 = 不完整记录
        #expect(throws: SharedTimerRejection.self) { try broken.validate() }
        // 视图投影：运行中折算到 readAt
        let view = s.view(readAt: at.addingTimeInterval(42))
        #expect(view.elapsedMs == 42_000 && view.resolvedMode == .pomodoro && view.focusMinutes == 25 && view.validMode)
    }

    @Test func reducerMatchesStateBridgeRules() throws {
        let t0 = Clock().t
        let start = try written(SharedTimerReducer.apply(command(.start, id: "s", at: t0, title: "读书"), to: nil, deviceId: "a", now: t0))
        let paused = try written(SharedTimerReducer.apply(command(.pause, id: "p", on: start, at: t0 + 60), to: start, deviceId: "a", now: t0 + 60))
        #expect(paused.status == .paused && paused.revision == 2 && paused.elapsedMs == 60_000 && paused.activeSince == nil)
        // 暂停对已暂停、版本过期、未来动作、开始后改模式 → 拒绝
        #expect(throws: SharedTimerRejection(code: 409, message: "当前状态不能执行此动作")) {
            try SharedTimerReducer.apply(self.command(.pause, id: "p2", on: paused, at: t0 + 70), to: paused, deviceId: "a", now: t0 + 70)
        }
        #expect(throws: SharedTimerRejection(code: 409, message: "状态已变，请先重新读取")) {
            try SharedTimerReducer.apply(self.command(.resume, id: "r-stale", on: start, at: t0 + 70), to: paused, deviceId: "b", now: t0 + 70)
        }
        #expect(throws: SharedTimerRejection.self) {
            try SharedTimerReducer.apply(self.command(.resume, id: "r-future", on: paused, at: t0 + 600), to: paused, deviceId: "a", now: t0 + 70)
        }
        var withMode = command(.resume, id: "r-mode", on: paused, at: t0 + 70); withMode.mode = .pomodoro; withMode.focusMinutes = 25
        #expect(throws: SharedTimerRejection.self) { try SharedTimerReducer.apply(withMode, to: paused, deviceId: "a", now: t0 + 70) }
        // 另一端时钟慢 3 秒：夹紧到上一状态时间，不让时长倒流；慢 10 分钟：拒绝
        let resumed = try written(SharedTimerReducer.apply(command(.resume, id: "r", on: paused, at: t0 + 57), to: paused, deviceId: "b", now: t0 + 57))
        #expect(resumed.activeSince == t0 + 60 && resumed.updatedAt == t0 + 60 && resumed.revision == 3)
        #expect(throws: SharedTimerRejection.self) {
            try SharedTimerReducer.apply(self.command(.finish, id: "f-old", on: resumed, at: t0 - 600), to: resumed, deviceId: "b", now: t0 + 61)
        }
        let finished = try written(SharedTimerReducer.apply(command(.finish, id: "f", on: resumed, at: t0 + 90), to: resumed, deviceId: "a", now: t0 + 90))
        #expect(finished.status == .finished && finished.elapsedMs == 90_000 && finished.revision == 4 && finished.events.map(\.action) == [.start, .pause, .resume, .finish])
        #expect(throws: SharedTimerRejection.self) {
            try SharedTimerReducer.apply(self.command(.resume, id: "after", on: finished, at: t0 + 95), to: finished, deviceId: "a", now: t0 + 95)
        }
        // 幂等：同一命令重来 → replay；同 commandId 不同内容 → 拒绝
        #expect(try SharedTimerReducer.apply(command(.pause, id: "p", on: start, at: t0 + 60), to: finished, deviceId: "a", now: t0 + 99) == .replay)
        #expect(throws: SharedTimerRejection(code: 409, message: "commandId 不能复用于不同命令")) {
            try SharedTimerReducer.apply(self.command(.pause, id: "p", on: start, at: t0 + 61), to: finished, deviceId: "a", now: t0 + 99)
        }
        #expect(try SharedTimerReducer.apply(command(.start, id: "s", at: t0, title: "读书"), to: finished, deviceId: "b", now: t0 + 99) == .replay)
        // 番茄时长越界、空标题
        #expect(throws: SharedTimerRejection.self) {
            try SharedTimerReducer.apply(self.command(.start, id: "bad", at: t0, title: "x", mode: .pomodoro, minutes: 241), to: nil, deviceId: "a", now: t0)
        }
        #expect(throws: SharedTimerRejection.self) {
            try SharedTimerReducer.apply(self.command(.start, id: "blank", at: t0, title: "  "), to: nil, deviceId: "a", now: t0)
        }
    }

    // MARK: 计时语义

    @Test func pauseFreezesAndResumeContinuesFromFrozenValue() async {
        let cloud = MemorySharedTimerCloud(), clock = Clock(), model = device(cloud, clock, id: "mac")
        await model.refresh()
        await model.start(title: "整理笔记")
        #expect(model.sessions.count == 1 && model.lastError == nil)
        clock.t += 60
        await model.act(.pause, on: model.primary!)
        #expect(model.primary?.status == .paused)
        #expect(model.elapsed(model.primary!) == 60)
        clock.t += 600                                       // 暂停 10 分钟：不增长
        await model.refresh()
        #expect(model.elapsed(model.primary!) == 60)
        await model.act(.resume, on: model.primary!)
        clock.t += 30
        #expect(model.elapsed(model.primary!) == 90)
        #expect(model.message == "已同步；两端共用 iCloud 计时")
    }

    @Test func pomodoroSilentlyTurnsIntoCountUpWithoutFinishing() async {
        let cloud = MemorySharedTimerCloud(), clock = Clock(), model = device(cloud, clock, id: "iphone")
        await model.refresh()
        await model.start(title: "背单词", mode: .pomodoro, focusMinutes: 1)
        clock.t += 30
        var phase = model.primary!.presentation(elapsed: model.elapsed(model.primary!))
        #expect(phase.countingDown && phase.remaining == 30 && phase.label == "番茄剩余")
        clock.t += 60                                        // 到时 30 秒后
        await model.refresh()
        let session = model.primary!
        phase = session.presentation(elapsed: model.elapsed(session))
        #expect(!phase.countingDown && phase.elapsed == 90 && phase.displaySeconds == 90 && phase.label == "已用")
        #expect(session.status == .running && session.revision == 1)   // 没有结束、没有休息、没有新事件
        #expect(await cloud.session(session.id)?.events.count == 1)
    }

    // MARK: 多端并发

    @Test func twoDevicesPausingSameRevisionOnlyOneWinsAndLoserNeverOverwrites() async {
        let cloud = MemorySharedTimerCloud(), clock = Clock()
        let mac = device(cloud, clock, id: "mac"), phone = device(cloud, clock, id: "iphone")
        await mac.refresh(); await mac.start(title: "跑步")
        await phone.refresh()
        let seenByPhone = phone.primary!
        #expect(seenByPhone.id == mac.primary!.id && seenByPhone.revision == 1)
        clock.t += 10
        await mac.act(.finish, on: mac.primary!)              // Mac 先结束
        await phone.act(.pause, on: seenByPhone)              // iPhone 拿旧版本暂停
        #expect(phone.reviewCount == 1 && phone.pendingCount == 0)
        #expect(phone.lastError?.contains("另一端已改变状态") == true)
        #expect(phone.sessions.isEmpty)                       // 读回服务器：已结束，不复活
        let stored = await cloud.session(seenByPhone.id)
        #expect(stored?.status == .finished && stored?.events.map(\.action) == [.start, .finish])
    }

    @Test func conditionalSaveConflictRejudgesAgainstServerVersion() async {
        let cloud = MemorySharedTimerCloud(), clock = Clock()
        let mac = device(cloud, clock, id: "mac"), phone = device(cloud, clock, id: "iphone")
        await mac.refresh(); await mac.start(title: "做饭")
        await phone.refresh()
        let id = mac.primary!.id
        clock.t += 20
        // iPhone 读完、保存之前，Mac 的暂停抢先落库（真正的竞态：两边读到同一版本）。
        let at = clock.t
        await cloud.setBeforeSave {
            guard let current = await cloud.session(id),
                  case let .write(next)? = try? SharedTimerReducer.apply(
                    BridgeTaskCommand(commandId: "mac-pause", action: .pause, sessionId: id, expectedRevision: current.revision, occurredAt: at),
                    to: current, deviceId: "mac", now: at) else { return }
            await cloud.forceWrite(next)
        }
        await phone.act(.finish, on: phone.primary!)
        #expect(phone.reviewCount == 1)                       // 重判后版本已过期 → 拒绝，不覆盖
        let stored = await cloud.session(id)
        #expect(stored?.status == .paused && stored?.revision == 2 && stored?.lastCommandId == "mac-pause")
        #expect(phone.primary?.status == .paused)
    }

    // MARK: 离线与恢复

    @Test func hangingICloudReadShowsTheRealReasonInsteadOfWaitingForever() async {
        let clock = Clock()
        let model = BridgeTaskViewModel(service: HangingICloudService(), persistence: BridgeTaskMemoryPersistence(), enabled: { true },
                                        now: { clock.t }, backend: .icloud, activePoll: 10, idlePoll: 30)
        model.cloudTimeout = 0.2
        await model.refresh()
        #expect(model.lastError?.contains("计时同步暂未完成") == true)
        #expect(model.lastError?.contains("没有回应") == true, "写出真实原因，不只说「暂未完成」")
        #expect(!model.hasEverRead && !model.busy)
    }

    @Test func offlineCommandStaysQueuedAndReplaysWithSameCommandId() async {
        let cloud = MemorySharedTimerCloud(), clock = Clock(), disk = BridgeTaskMemoryPersistence()
        let model = device(cloud, clock, id: "mac", disk: disk)
        await model.refresh()
        await cloud.failNextCall(URLError(.notConnectedToInternet))
        await model.start(title: "离线开始")
        #expect(model.pendingCount == 1 && model.reviewCount == 0 && model.sessions.isEmpty)
        #expect(model.lastError?.contains("计时同步暂未完成") == true)
        let queuedId = disk.file.pending.first?.command.commandId
        // 重启：同一本机文件，恢复联网后用原 commandId 重放
        clock.t += 5
        let restarted = device(cloud, clock, id: "mac", disk: disk)
        await restarted.refresh()
        #expect(restarted.pendingCount == 0 && restarted.sessions.count == 1)
        #expect(restarted.primary?.lastCommandId == queuedId)
        #expect(restarted.primary?.startedAt == clock.t - 5)  // 记的是当初按下的时间，不是联网时间
        #expect(await cloud.saveCount == 1)
    }

    @Test func savedButLostReplyIsNotAppliedTwice() async {
        let cloud = MemorySharedTimerCloud(), clock = Clock(), model = device(cloud, clock, id: "mac")
        await model.refresh(); await model.start(title: "写周报")
        clock.t += 15
        await cloud.loseNextReply()
        await model.act(.pause, on: model.primary!)           // 已落库，但回包丢了
        #expect(model.pendingCount == 1)
        await model.refresh()                                  // 原命令重试 → 事件历史里已有 → 原回执
        #expect(model.pendingCount == 0 && model.reviewCount == 0)
        #expect(model.primary?.status == .paused && model.primary?.revision == 2)
        #expect(await cloud.saveCount == 2)                    // start + pause，各一次
    }

    // MARK: 开关关闭 = 零行为变化

    @Test func switchIsOffByDefaultAndOffPathNeverTouchesICloud() {
        let suite = "bc-test-shared-timer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SharedTimerSettings.requested(defaults) == true)    // W8：从没设过 = 开（启动闸门照旧）
        SharedTimerSettings.setRequested(false, defaults)
        #expect(SharedTimerSettings.requested(defaults) == false)   // 手动关过的保留
        var legacyRead = false
        let decision = SharedTimerSettings.launchDecision(requested: false, legacy: { legacyRead = true; return BridgeTaskLocalFile() })
        #expect(decision.backend == .stateBridge && decision.note == nil && !legacyRead)
        // 旧通道 ViewModel 的默认值与改动前一致
        let legacy = BridgeTaskViewModel(service: LegacyService(), persistence: BridgeTaskMemoryPersistence(), enabled: { true })
        #expect(legacy.backend == .stateBridge)
        #expect(legacy.syncedMessage == "已同步；与 Dots 共用 BC 计时")
        #expect(BridgeTaskViewModel.isPermanentRejection(NSError(domain: "StateBridge.HTTP", code: 409)))
        #expect(BridgeTaskViewModel.isPermanentRejection(NSError(domain: "StateBridge.HTTP", code: 422)))
        #expect(!BridgeTaskViewModel.isPermanentRejection(NSError(domain: "StateBridge.HTTP", code: 500)))
        #expect(!BridgeTaskViewModel.isPermanentRejection(URLError(.notConnectedToInternet) as NSError))
    }

    @Test func legacyBackendKeepsOriginalMessagesAndConflictHandling() async {
        let service = LegacyService(), model = BridgeTaskViewModel(service: service, persistence: BridgeTaskMemoryPersistence(), enabled: { true }, now: { service.clock })
        await model.refresh()
        #expect(model.message == "已同步；与 Dots 共用 BC 计时")
        service.rejectNext = true
        await model.start(title: "旧通道")
        #expect(model.reviewCount == 1)
        #expect(model.message == "另一端已改变状态，未覆盖它的操作；请根据当前状态重新选择")
    }

    // MARK: 切换闸门

    @Test func launchGateDefersSwitchWhileLegacyTimerIsActive() {
        let at = Clock().t
        let running = BridgeTaskSession(id: "task_x", title: "旧计时", status: .running, startedAt: at, activeSince: at,
                                        elapsedMs: 0, updatedAt: at, revision: 1, provenance: "user")
        var experiment = running; experiment.id = "task_e"; experiment.experiment = true
        func file(_ sessions: [BridgeTaskSession], pending: [BridgeTaskLocalFile.Pending] = []) -> BridgeTaskLocalFile {
            BridgeTaskLocalFile(pending: pending, state: BridgeTaskState(schemaVersion: 1, authority: "bettercalendar", readAt: at, sessions: sessions, hasMore: false))
        }
        let blocked = SharedTimerSettings.launchDecision(requested: true, legacy: { file([running]) })
        #expect(blocked.backend == .stateBridge && blocked.note?.contains("旧计时") == true)
        #expect(SharedTimerSettings.launchDecision(requested: true, legacy: { file([experiment]) }).backend == .icloud)
        let queued = BridgeTaskLocalFile.Pending(command: .init(commandId: "c", action: .start, title: "t", occurredAt: at))
        #expect(SharedTimerSettings.launchDecision(requested: true, legacy: { file([], pending: [queued]) }).backend == .stateBridge)
        var rejected = queued; rejected.needsReview = true
        #expect(SharedTimerSettings.launchDecision(requested: true, legacy: { file([], pending: [rejected]) }).backend == .icloud)
        #expect(SharedTimerSettings.launchDecision(requested: true, legacy: { throw CocoaError(.fileReadCorruptFile) }).backend == .stateBridge)
        #expect(SharedTimerSettings.launchDecision(requested: true, legacy: { BridgeTaskLocalFile() }).backend == .icloud)
    }

    @Test func toggleRefusesWhileCurrentBackendHasActiveTimer() async {
        let suite = "bc-test-shared-timer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = MemorySharedTimerCloud(), clock = Clock(), tasks = device(cloud, clock, id: "mac")
        await tasks.refresh(); await tasks.start(title: "正在做")
        SharedTimerSettings.setRequested(true, defaults)
        let refreshed = SharedTimerBackendControl(active: .icloud, launchNote: nil, defaults: defaults)
        refreshed.tasks = tasks
        refreshed.setRequested(false)                          // 想切回旧通道，但 iCloud 里还在计时
        #expect(refreshed.requested && SharedTimerSettings.requested(defaults))
        #expect(refreshed.notice?.contains("正在做") == true)
        await tasks.act(.finish, on: tasks.primary!)
        refreshed.setRequested(false)
        #expect(!refreshed.requested && !SharedTimerSettings.requested(defaults) && refreshed.restartPending)
        refreshed.setRequested(true)                           // 改回当前后端 = 撤销请求，总是允许
        #expect(refreshed.requested && !refreshed.restartPending && refreshed.notice == nil)
    }

    // MARK: 上层不变：执行面板/Live Activity 走同一份 iCloud 计时

    @Test func executionButtonsUseICloudSessionWithoutSecondLocalHistory() async throws {
        final class Activity: ExecutionLiveActivity {
            var snapshot: LiveActivitySnapshot?
            func start(_ snapshot: LiveActivitySnapshot) { self.snapshot = snapshot }
            func update(_ snapshot: LiveActivitySnapshot) { self.snapshot = snapshot }
            func end() { snapshot = nil }
        }
        let container = try ModelContainer(for: PlanBlock.self, ExecutionSession.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let plans = PlanStore(context: container.mainContext), activity = Activity()
        let cloud = MemorySharedTimerCloud(), clock = Clock(), tasks = device(cloud, clock, id: "mac")
        let execution = ExecutionViewModel(calendarStore: FakeCalendarStore(),
                                           reschedule: RescheduleService(planStore: plans, planner: NaivePlanningEngine()),
                                           planStore: plans, reminderStore: FakeReminderStore(), liveActivity: activity,
                                           sessionStore: ExecutionSessionStore(context: container.mainContext),
                                           persistsRunState: false, canonicalTasks: tasks)
        tasks.onChange = { [weak execution] in execution?.syncCanonicalPresentation() }
        await tasks.refresh()
        #expect(execution.usesCanonicalTiming)
        await execution.startAdHoc(title: "同一份 iCloud 计时")
        #expect(execution.active == nil && tasks.sessions.count == 1)
        #expect(activity.snapshot?.title == "同一份 iCloud 计时")
        clock.t += 30
        await execution.toggleBreak()
        #expect(tasks.sessions[0].status == .paused && activity.snapshot?.pausedAt != nil)
        await execution.completeCurrent()                       // 结束计时 ≠ 完成事项：不写本地执行记录/蓝色实际
        #expect(tasks.sessions.isEmpty && activity.snapshot == nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ExecutionSession>()) == 0)
        #expect(try plans.actualBlocks(on: clock.t).isEmpty)
        let all = await cloud.saveCount
        #expect(all == 3)
    }
}

/// W31b：没登录 iCloud 时 CloudKit 读状态永远不回（不响应取消）的替身。
@MainActor private final class HangingICloudService: BridgeTaskServing {
    func readTasks() async throws -> BridgeTaskState {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { c.resume() }
        }
        throw URLError(.timedOut)
    }
    func submitTask(_ command: BridgeTaskCommand) async throws -> BridgeTaskReceipt { BridgeTaskReceipt(commandId: command.commandId, saved: true) }
}

/// 旧通道替身：只用于确认开关关闭时旧路径的文案与 409 处理不变。
@MainActor private final class LegacyService: BridgeTaskServing {
    var clock = Date(timeIntervalSince1970: 1_790_000_000)
    var rejectNext = false
    func readTasks() async throws -> BridgeTaskState {
        BridgeTaskState(schemaVersion: 1, authority: "bettercalendar", readAt: clock, sessions: [], hasMore: false)
    }
    func submitTask(_ command: BridgeTaskCommand) async throws -> BridgeTaskReceipt {
        if rejectNext { rejectNext = false; throw NSError(domain: "StateBridge.HTTP", code: 409) }
        return BridgeTaskReceipt(commandId: command.commandId, saved: true)
    }
}
