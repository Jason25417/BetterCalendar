//
//  W23bEventKitGuardTests.swift
//  BetterCalendarTests
//
//  W23b：测试宿主里绝不写真 EventKit（W23 截图测试曾把测试块写进 Jason 日用版的「BetterCalendar · 计划 / 实际 (Dev)」日历）。
//  ① 最底层闸：真 EventKit 日历 / 提醒的每个写入口在测试宿主里直接抛错（不建 EKEventStore、不碰系统）；
//  ② 组装点：AppContainer() 在测试宿主里拿的是内存日历 / 内存提醒，保存 + 投影一圈下来，真 EventKit 写入次数为零。
//

import Foundation
import Testing
@testable import BetterCalendar

@MainActor
@Suite struct W23bEventKitGuardTests {
    @Test func realEventKitWritesAreRefusedInTheTestHost() async throws {
        #expect(TestHost.isActive)
        let before = EventKitWriteGuard.refusedWrites.count
        let calendar = EventKitCalendarStore()
        let draft = CalendarEventDraft(title: "不该写进真日历", start: .now, end: .now.addingTimeInterval(600), kind: .planned)
        await #expect(throws: EventKitWriteRefused.self) { try await calendar.write([draft]) }
        await #expect(throws: EventKitWriteRefused.self) {
            try await calendar.apply([draft], kind: .planned, window: DateInterval(start: .now, duration: 3600))
        }
        await #expect(throws: EventKitWriteRefused.self) { try await calendar.clear(kind: .actual) }
        let reminders = EventKitReminderStore()
        await #expect(throws: EventKitWriteRefused.self) {
            try await reminders.apply(ReminderListChanges(creates: [ReminderDraft(title: "不该写进真提醒事项")]))
        }
        #expect(EventKitWriteGuard.refusedWrites.count == before + 4)
    }

    @Test func appContainerInTheTestHostNeverReachesRealEventKit() async throws {
        let c = AppContainer()
        let fake = try #require(c.calendarStore as? TestHostCalendarStore, "测试宿主里组装点注入的是内存日历")
        // 保存 + 投影一圈（W23 事故里就是这条路写进了真日历）
        let today = DayContext.logicalDay(offset: 0)
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        try c.planStore.replacePlanned([ScheduledBlock(title: "W23b 测试块", start: start, end: start.addingTimeInterval(3600))], on: today)
        try await c.projection.project(label: today)
        #expect(fake.writeCount > 0, "投影写进了内存日历")
        // 不再比对全进程共享的拒绝计数：全量并行时别的测试撞闸也会让它变（那是闸在起作用），断言在并行下站不住。
        // 「投影写进内存日历」+ 组装点拿到的就是内存日历，已足以证明这条路没走到真 EventKit。
    }
}
