import Foundation
import Testing
@testable import BetterCalendar

/// W17：日用版 / Dev 版并排安装的命名隔离、桥接目录通道标记、新功能开关约定、自动快照列表。
@Suite struct AppChannelTests {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-channel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func dailyKeepsHistoricalNamesSoExistingDataStaysFound() {
        // 日用版的日历/提醒/钥匙串/App Group 名字是历史值，改了就认不出 Jason 已有的日历与 key。
        let d = AppChannel.daily
        #expect(d.calendarTitle("计划") == "BetterCalendar · 计划 (Dev)")
        #expect(d.remindersListTitle == "BetterCalendar · 要紧事 (Dev)")
        #expect(d.keychainService == "com.jason.BetterCalendar")
        #expect(d.stateBridgeKeychainService == "com.jason.BetterCalendar.StateBridge")
        #expect(d.appGroupID == "group.com.jason.BetterCalendar")
        #expect(d.handoffActivityType == "com.jason.BetterCalendar.handoff")
        #expect(d.dataFolderName == "BetterCalendar-Data")
        #expect(d.cloudKitContainerID == "iCloud.com.jason.BetterCalendar")
    }

    @Test func devNamesNeverCollideWithDaily() {
        let d = AppChannel.daily, v = AppChannel.dev
        #expect(v.calendarTitle("计划") == "BetterCalendar Dev · 计划")
        for label in ["计划", "实际", "预览", "要紧事"] { #expect(d.calendarTitle(label) != v.calendarTitle(label)) }
        #expect(d.keychainService != v.keychainService)
        #expect(d.appGroupID != v.appGroupID)
        #expect(d.handoffActivityType != v.handoffActivityType)
        #expect(d.dataFolderName != v.dataFolderName)
    }

    @Test func siblingCalendarsAreTheOtherChannelsOwn() {
        let labels = EventKitCalendarStore.calendarLabels.map(\.1)
        #expect(AppChannel.daily.siblingCalendarTitles(labels) == Set(EventKitCalendarStore.calendarTitles(for: .dev).values))
        #expect(AppChannel.dev.siblingCalendarTitles(labels) == Set(EventKitCalendarStore.calendarTitles(for: .daily).values))
    }

    @Test func testHostBuildIsDailyChannel() {
        // 门控跑的是主 scheme（Debug）：必须编出日用通道，名字与 TestFlight 版一致。
        #expect(AppChannel.current == .daily)
    }

    @Test func bridgeMarkerKeepsChannelsApart() throws {
        let legacy = try tempDir()   // 日用版历史目录：没有 CHANNEL 文件
        #expect(AppChannel.bridgeChannel(of: legacy) == .daily)
        #expect(AppChannel.daily.bridgeMismatch(legacy) == nil)
        #expect(AppChannel.dev.bridgeMismatch(legacy) != nil)

        let dev = try tempDir()
        try "dev\n".write(to: dev.appendingPathComponent(AppChannel.bridgeMarkerFile), atomically: true, encoding: .utf8)
        #expect(AppChannel.bridgeChannel(of: dev) == .dev)
        #expect(AppChannel.dev.bridgeMismatch(dev) == nil)
        #expect(AppChannel.daily.bridgeMismatch(dev) != nil)

        let junk = try tempDir()
        try "staging".write(to: junk.appendingPathComponent(AppChannel.bridgeMarkerFile), atomically: true, encoding: .utf8)
        #expect(AppChannel.bridgeChannel(of: junk) == nil)
        #expect(AppChannel.daily.bridgeMismatch(junk) != nil && AppChannel.dev.bridgeMismatch(junk) != nil)
    }

    @Test func newFeaturesDefaultOffInDailyOnInDevAndRespectUserChoice() throws {
        let suite = "bc-test-newfeature-" + UUID().uuidString
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(ExperimentDefaults.newFeature("x.enabled", in: d, channel: .daily) == false)
        #expect(ExperimentDefaults.newFeature("x.enabled", in: d, channel: .dev) == true)
        d.set(true, forKey: "x.enabled")
        #expect(ExperimentDefaults.newFeature("x.enabled", in: d, channel: .daily) == true)
        d.set(false, forKey: "x.enabled")
        #expect(ExperimentDefaults.newFeature("x.enabled", in: d, channel: .dev) == false)
    }

    @Test func autoSnapshotListingIsNewestFirstAndOnlyAutoFiles() throws {
        let dir = try tempDir()
        let fm = FileManager.default
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for (name, offset) in [("auto-a.json", 0.0), ("auto-b.json", 3600), ("snapshot-c.json", 7200), ("auto-d.txt", 9000)] {
            let url = dir.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: base.addingTimeInterval(offset)], ofItemAtPath: url.path)
        }
        let list = DataMaintenance.autoSnapshots(in: dir)
        #expect(list.map(\.url.lastPathComponent) == ["auto-b.json", "auto-a.json"])
        #expect(DataMaintenance.autoSnapshots(in: dir.appendingPathComponent("missing")).isEmpty)
    }
}
