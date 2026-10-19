//
//  W19TodayPageTests.swift
//  BetterCalendarTests
//
//  W19（S-v2 结构层）：「今天」页直接操作即保存（没有「确认写入」这一步）、图钉只钉你亲手改了时间的块、
//  保存时底层已变只叠你的改动、切天先保存；提案卡同一组件在窄 / 宽两种宽度下的渲染。
//

import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import BetterCalendar
#if os(macOS)
import AppKit
#endif

@MainActor
@Suite struct W19TodayPageTests {
    private let cal = Calendar.current
    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    private struct Rig {
        let vm: HomeViewModel
        let store: PlanStore
        let container: ModelContainer   // 保活：容器与 store 同寿命
    }

    private func rig(now: Date, startedDays: StartedDayStore? = nil) throws -> Rig {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlanBlock.self, configurations: config)
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
            notifier: NoNotify(), startedDays: startedDays, now: { now })
        vm.autoCommit = true
        vm.autosaveDelay = .milliseconds(20)
        return Rig(vm: vm, store: store, container: container)
    }

    // MARK: 纯函数：只叠你的改动

    @Test func overlayAppliesMyEditsOntoTheNewestVersion() {
        let a = EditableBlock(title: "写论文", start: at(20, 9), end: at(20, 10))
        let b = EditableBlock(title: "健身", start: at(20, 15), end: at(20, 16))
        let c = EditableBlock(title: "读书", start: at(20, 20), end: at(20, 21))
        let shown = [a, b, c]
        // 我：把 a 挪到 11 点、删掉 c、加了 d
        var myA = a; myA.start = at(20, 11); myA.end = at(20, 12)
        let d = EditableBlock(title: "买菜", start: at(20, 18), end: at(20, 19))
        let mine = [myA, b, d]
        // 别处（智能体批准的改动）：把 b 改到 16 点，又加了 e
        var theirB = b; theirB.start = at(20, 16); theirB.end = at(20, 17)
        let e = EditableBlock(title: "回邮件", start: at(20, 13), end: at(20, 14))
        let fresh = [a, theirB, c, e]

        let out = HomeViewModel.overlay(mine: mine, shown: shown, onto: fresh)
        #expect(out.map(\.title) == ["写论文", "回邮件", "健身", "买菜"], "a 用我的、b 用别处的、c 我删了、d 我加的、e 别处加的")
        #expect(out.first { $0.id == a.id }?.start == at(20, 11))
        #expect(out.first { $0.id == b.id }?.start == at(20, 16), "我没动的块不被我眼前的旧版本盖回去")
    }

    // MARK: 直接操作即保存

    @Test func editsSaveThemselvesWithoutConfirm() async throws {
        let now = at(19, 12)
        let r = try rig(now: now)
        let day = cal.startOfDay(for: at(21, 12))
        try r.store.replacePlanned([
            ScheduledBlock(title: "写论文", start: at(21, 9), end: at(21, 11)),
            ScheduledBlock(title: "健身", start: at(21, 15), end: at(21, 16)),
        ], on: day)
        r.vm.targetDay = day
        r.vm.autoLoadOnAppear()
        #expect(r.vm.blocks.count == 2)

        r.vm.delete(id: r.vm.blocks[0].id)
        // 等自动保存落地（最多 3 秒；正常 20ms）
        for _ in 0..<150 where r.vm.hasUnsavedChanges { try await Task.sleep(for: .milliseconds(20)) }
        #expect(r.vm.hasUnsavedChanges == false, "改完不用点任何按钮就保存了")
        #expect(try r.store.plannedBlocks(on: day).map(\.title) == ["健身"])
    }

    @Test func switchingDaySavesPendingEditsFirst() async throws {
        let r = try rig(now: at(19, 12))
        let d1 = cal.startOfDay(for: at(21, 12)), d2 = cal.startOfDay(for: at(22, 12))
        try r.store.replacePlanned([ScheduledBlock(title: "写论文", start: at(21, 9), end: at(21, 11))], on: d1)
        try r.store.replacePlanned([ScheduledBlock(title: "开会", start: at(22, 9), end: at(22, 10), isFixed: true)], on: d2)
        r.vm.autosaveDelay = .seconds(60)   // 让自动保存「还在等」
        r.vm.targetDay = d1
        r.vm.autoLoadOnAppear()
        r.vm.binding(for: r.vm.blocks[0].id).wrappedValue.title = "写论文第二章"
        #expect(r.vm.hasUnsavedChanges)

        await r.vm.selectDay(d2)
        r.vm.targetDayDidChange()   // 视图里由 onChange 触发
        #expect(try r.store.plannedBlocks(on: d1).map(\.title) == ["写论文第二章"], "切走前先保存了这一天")
        #expect(try r.store.plannedBlocks(on: d2).map(\.title) == ["开会"], "另一天原样")
        #expect(r.vm.blocks.map(\.title) == ["开会"])
    }

    // MARK: 图钉只钉你亲手改了时间的块（实时日列表是重铺过的，和库里时间不同 ≠ 你改过）

    @Test func onlyTheBlockYouMovedBecomesAPin() async throws {
        let now = at(20, 13)
        let label = DayContext.logicalDay(offset: 0, from: now)
        let started = StartedDayStore(persisted: false)
        started.markStarted(label)
        let r = try rig(now: now, startedDays: started)
        // 两件撞在同一时段：实时日「从现在起」重铺时必有一件被往后排（库里时间 ≠ 眼前时间）
        let a = ScheduledBlock(title: "写论文", start: at(20, 14), end: at(20, 15))
        let b = ScheduledBlock(title: "健身", start: at(20, 14), end: at(20, 15))
        try r.store.replacePlanned([a, b], on: label)
        r.vm.targetDay = label
        r.vm.autoLoadOnAppear()
        #expect(r.vm.isLiveTargetDay)
        let shown = r.vm.blocks
        #expect(shown.count == 2)
        let storedStart = [a.id: a.start, b.id: b.start]
        let shifted = try #require(shown.first { $0.start != storedStart[$0.id] }, "实时日看到的是重铺过的时间")
        let mineID = try #require(shown.first { $0.id != shifted.id }).id

        // 你把另一件拖到 18 点
        var moved = try #require(shown.first { $0.id == mineID })
        moved.start = at(20, 18); moved.end = at(20, 19)
        r.vm.binding(for: mineID).wrappedValue = moved
        await r.vm.flushAutosave()

        let stored = try r.store.plannedBlocks(on: label)
        #expect(stored.first { $0.id == mineID }?.isPinned(at: now) == true, "你拖过的成为图钉")
        #expect(stored.first { $0.id == shifted.id }?.isPinned(at: now) == false, "只是被重铺过的不钉")
    }

    // MARK: 提案卡：同一组件，窄 / 宽都完整（「智能体」页置顶区与对话气泡共用）

    #if os(macOS)
    @Test func proposalCardRendersAtNarrowAndWideWidths() async throws {
        let center = ProposalCenter(transport: InMemoryProposalTransport(), executor: ExperimentOnlyExecutor(),
                                    notifier: SilentProposalNotifier(), ledger: MemoryOperationLedger(),
                                    deviceId: "mac", deviceLabel: "Mac")
        _ = await center.submit(ProposalDraft(
            origin: .agent, originLabel: "BetterCalendar 智能体", targetDeviceId: "mac",
            title: "把「整理笔记」挪到 15:00",
            changes: [ProposalChange(field: "开始时间", before: "14:00", after: "15:00")], reason: "午饭晚了",
            action: .experimentNoop(note: "W19 渲染"), experiment: true, lifetime: 3600))
        let p = try #require(center.pending.first)
        for width in [360.0, 720.0] {
            let rect = NSRect(x: 0, y: 0, width: width, height: 420)
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: VStack { ProposalCard(center: center, proposal: p); Spacer() }
                .padding(16).frame(width: width, height: 420).environment(\.colorScheme, .light).background(Color.white))
            host.frame = rect; host.appearance = NSAppearance(named: .aqua); window.contentView = host
            host.layoutSubtreeIfNeeded()
            for _ in 0..<20 { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(bitmap.pixelsWide == Int(width * window.backingScaleFactor))
            try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("w19-proposal-card-\(Int(width)).png"), options: .atomic)
            window.close()
        }
    }
    #endif
}

#if os(macOS)
/// 页面截图（只在显式要求时跑：`TEST_RUNNER_BC_W19_SHOTS=<输出目录>`；门控全量测试里不跑）。
/// 测试宿主里建一份 AppContainer（内存 SwiftData、无 CloudKit），塞几条假数据，把四页按正常 / 小窗两种尺寸离屏渲染成 PNG。
@MainActor
@Suite struct W19PageShots {
    static let outDir = ProcessInfo.processInfo.environment["BC_W19_SHOTS"]

    @Test(.enabled(if: W19PageShots.outDir != nil)) func renderPages() async throws {
        let dir = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = AppContainer()
        let today = DayContext.logicalDay(offset: 0)
        let cal = Calendar.current
        func t(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: today)! }
        try c.planStore.replacePlanned([
            ScheduledBlock(title: "写论文第二章", start: t(9), end: t(11)),
            ScheduledBlock(title: "组会", start: t(13), end: t(14), isFixed: true),
            ScheduledBlock(title: "健身", start: t(17), end: t(18)),
            ScheduledBlock(title: "读书", start: t(21), end: t(22)),
        ], on: today)
        _ = await c.proposals.submit(ProposalDraft(
            origin: .agent, originLabel: "BetterCalendar 智能体", targetDeviceId: c.proposals.deviceId,
            title: "把「健身」挪到 18:30",
            changes: [ProposalChange(field: "开始时间", before: "17:00", after: "18:30")], reason: "下午组会可能拖堂",
            action: .experimentNoop(note: "截图"), experiment: true, lifetime: 3600))
        _ = await c.agentChat.send("明天上午帮我排三小时写论文")
        _ = await c.agentChat.receiveAgent(AgentChatReplyDraft(id: UUID(), text: "好，明天 9:00–12:00 写论文，已经提了一个提案，等你批准。"))

        let theme = ThemeSettings.current
        let pages: [(String, AnyView)] = [
            ("1-today", AnyView(HomeView(deps: c.homeDeps))),
            ("2-agent", AnyView(NavigationStack { AgentChatView(chat: c.agentChat, proposals: c.proposals) })),
            ("3-longterm", AnyView(LongTermView(store: c.longTasks, router: c.router, parser: c.parser, refiner: c.longTaskRefiner))),
            ("4-journal", AnyView(JournalView(deps: c.journalDeps))),
            // 设置页不在这里渲染：离屏宿主里它的系统服务查询（开机自启 / 活动记录状态）会挂住测试宿主
        ]
        for (name, view) in pages {
            for (sizeName, size) in [("normal", CGSize(width: 1000, height: 760)), ("small", CGSize(width: 520, height: 460))] {
                let rect = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                    .environment(\.appTheme, theme).tint(theme.accent)
                    .environment(\.colorScheme, .light).background(Color.white))
                host.frame = rect; host.appearance = NSAppearance(named: .aqua); window.contentView = host
                host.layoutSubtreeIfNeeded()
                for _ in 0..<40 { await Task.yield() }
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
                host.cacheDisplay(in: rect, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: dir.appendingPathComponent("\(name)-\(sizeName).png"), options: .atomic)
                window.close()
            }
        }
    }
}
#endif
