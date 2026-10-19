//
//  W19bFixTests.swift
//  BetterCalendarTests
//
//  W19b：发 0.70.0 前的修补——
//  ① 待确认提案只在「等你拍板」置顶区画整卡，对话气泡里只留一行指路；有结论后气泡显示结果卡（P1 单射）；
//  ② 今天页时间线拖动排序（iPhone/Mac 同一个 onMove → HomeViewModel.move）：按新邻居填时间、保时长、自动保存、成为图钉。
//

import Foundation
import SwiftData
import Testing
@testable import BetterCalendar

@MainActor
@Suite struct W19bFixTests {
    private let cal = Calendar.current
    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    // MARK: ① 气泡里的提案卡不重复置顶卡

    @Test func pendingProposalIsPointerInBubbleAndResultCardAfterDecision() async throws {
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(),
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(),
                                    deviceId: "mac", deviceLabel: "Mac")
        let submitted = try #require(await center.submit(ProposalDraft(
            origin: .agent, originLabel: "BetterCalendar 智能体", targetDeviceId: "mac",
            title: "把「健身」挪到 18:30",
            changes: [ProposalChange(field: "开始时间", before: "17:00", after: "18:30")], reason: "组会拖堂",
            action: .experimentNoop(note: "W19b"), experiment: true, lifetime: 3600)))
        let missing = UUID()
        func cards() -> [AgentChatCard] { AgentChatCard.resolve([submitted.id, missing], in: center.proposals) }
        func pinned() -> Set<UUID> { Set(center.pending.map(\.id)) }

        // 待确认：置顶区有它 → 气泡里是一行指路；还没同步到的 id → 同步中
        #expect(pinned() == [submitted.id])
        #expect(cards().map { $0.presentation(pinnedIds: pinned()) } == [.pointerToPinned, .syncing])

        // 拍板后：离开置顶区 → 气泡显示结果卡
        _ = await center.decide(submitted.id, .decline)
        #expect(pinned().isEmpty)
        #expect(cards().first?.presentation(pinnedIds: pinned()) == .fullCard)
    }

    // MARK: ② 拖动排序

    private struct Rig {
        let vm: HomeViewModel
        let store: PlanStore
        let container: ModelContainer   // 保活：容器与 store 同寿命
    }

    private func rig(now: Date) throws -> Rig {
        let container = try ModelContainer(for: PlanBlock.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = PlanStore(context: container.mainContext)
        struct NoRefine: PlanRefining {
            func refine(_ blocks: [ScheduledBlock], command: String,
                        originalRequest: String, now: Date) async throws -> [ScheduledBlock] { blocks }
        }
        struct NoNotify: NotificationScheduling {
            func requestAuthorizationIfNeeded() async {}
            func scheduleDailyReminders(morning: Date?, evening: Date?, summary: String) async {}
        }
        let calendar = FakeCalendarStore()
        let vm = HomeViewModel(
            arrangeDay: ArrangeDayUseCase(parser: FailedScheduleParser(), planner: NaivePlanningEngine()),
            refiner: NoRefine(), calendarStore: calendar, reminderStore: FakeReminderStore(),
            exporter: ICSExporter(), planStore: store,
            projection: ProjectionService(planStore: store, calendarStore: calendar),
            notifier: NoNotify(), startedDays: nil, now: { now })
        vm.autoCommit = true
        vm.autosaveDelay = .milliseconds(20)
        return Rig(vm: vm, store: store, container: container)
    }

    @Test func dragReorderFillsTimeKeepsDurationSavesAndPins() async throws {
        let now = at(19, 12)
        let r = try rig(now: now)
        let day = cal.startOfDay(for: at(21, 12))
        try r.store.replacePlanned([
            ScheduledBlock(title: "写论文", start: at(21, 9), end: at(21, 11)),
            ScheduledBlock(title: "健身", start: at(21, 15), end: at(21, 16)),
            ScheduledBlock(title: "读书", start: at(21, 20), end: at(21, 20, 30)),
        ], on: day)
        r.vm.targetDay = day
        r.vm.autoLoadOnAppear()
        #expect(r.vm.blocks.map(\.title) == ["写论文", "健身", "读书"])

        // 把「读书」拖到「写论文」后面（List.onMove 给的参数：from [2] to 1）
        r.vm.move(IndexSet(integer: 2), 1)
        #expect(r.vm.blocks.map(\.title) == ["写论文", "读书", "健身"])
        let read = try #require(r.vm.blocks.first { $0.title == "读书" })
        #expect(read.start == at(21, 11), "接在上一件结束后")
        #expect(read.end == at(21, 11, 30), "保时长 30 分钟")

        // 把「健身」拖到最顶：结束对齐原第一件的开始、时长往前推
        r.vm.move(IndexSet(integer: 2), 0)
        let gym = try #require(r.vm.blocks.first)
        #expect(gym.title == "健身")
        #expect(gym.start == at(21, 8) && gym.end == at(21, 9))

        await r.vm.flushAutosave()
        #expect(r.vm.hasUnsavedChanges == false, "拖完自动保存")
        let stored = try r.store.plannedBlocks(on: day)
        #expect(stored.sorted { $0.start < $1.start }.map(\.title) == ["健身", "写论文", "读书"])
        #expect(stored.first { $0.title == "健身" }?.isPinned(at: now) == true, "你亲手拖的成为图钉")
        #expect(stored.first { $0.title == "读书" }?.isPinned(at: now) == true)
        #expect(stored.first { $0.title == "写论文" }?.isPinned(at: now) == false, "没动的不钉")
    }
}
