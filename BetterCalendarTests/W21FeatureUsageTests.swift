import Foundation
import Testing
@testable import BetterCalendar

/// W21 功能使用探针：记录与汇总、seen 节流、回一句 / 调数值的「没做完」、假设与证据、保留期、桥接镜像守 CHANNEL、plist 安全。
/// 每个测试一个独立的 FeatureUsageStore（临时目录 + 独立 UserDefaults suite + 注入时钟）；不碰 FeatureUsage.shared。
@MainActor @Suite struct W21FeatureUsageTests {
    final class Clock: @unchecked Sendable { var now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10))! }

    func suite() -> UserDefaults { UserDefaults(suiteName: "bc-w21-" + UUID().uuidString)! }
    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bc-w21-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func store(_ c: Clock, root: URL? = nil, defaults: UserDefaults? = nil) throws -> FeatureUsageStore {
        FeatureUsageStore(root: try root ?? tempRoot(), defaults: defaults ?? suite(), now: { c.now })
    }
    func report(_ s: FeatureUsageStore, _ c: Clock) -> FeatureUsageReport {
        FeatureUsageAggregator.report(records: s.records(), marks: s.marks(), trackingSince: s.trackingSince(), now: c.now)
    }

    // MARK: 1. 记录与汇总

    @Test func recordsAggregatePerDayWeekMonthWithMilestonesAndSurfaces() throws {
        let c = Clock()
        let start = c.now
        let s = try store(c)
        s.record(.nowNextFinish, .used, detail: "菜单栏")          // 10 天前
        c.now = start.addingTimeInterval(-10 * 86400)
        s.record(.nowNextFinish, .used, detail: "菜单栏")
        c.now = start.addingTimeInterval(-3 * 86400)
        s.record(.nowNextFinish, .used, detail: "今天页")
        s.record(.nowNextPanel, .seen)
        c.now = start
        s.record(.nowNextPanel, .seen)
        s.record(.nowNextFinish, .used, detail: "今天页")
        let r = report(s, c)
        let st = try #require(r.stats[.nowNextFinish])
        #expect(st.today[.used] == 2 && st.week[.used] == 3 && st.month[.used] == 4 && st.total[.used] == 4)
        #expect(st.usedLifetime == 4 && st.usedDays == 3)
        #expect(st.bySurface == ["今天页": 2, "菜单栏": 2])
        #expect(st.marks.lastUsed == start)
        #expect(st.marks.firstUsed == start.addingTimeInterval(-10 * 86400))   // 写入顺序不影响「首次」
        #expect(r.stats[.nowNextPanel]?.seenDays == 2)
        #expect(r.trackingDays >= 1)
        // 新实例读回同一目录：坏行跳过
        let root = try tempRoot(), d = suite()
        let s1 = try store(c, root: root, defaults: d)
        s1.record(.agentChatSend, .used)
        let file = root.appendingPathComponent(DayContext.dayKey(c.now) + ".jsonl")
        let h = try FileHandle(forWritingTo: file); try h.seekToEnd(); try h.write(contentsOf: Data("{坏行\n".utf8)); try h.close()
        s1.record(.agentChatSend, .used)
        let s2 = try store(c, root: root, defaults: d)
        #expect(s2.records().count == 2 && report(s2, c).stats[.agentChatSend]?.usedLifetime == 2)
    }

    // MARK: 2. seen 节流

    @Test func seenIsThrottledButUsedIsNot() throws {
        let c = Clock()
        let s = try store(c)
        s.record(.todayPage, .seen)
        c.now += 600
        s.record(.todayPage, .seen)                       // 10 分钟内：不记
        s.record(.todayDrag, .used); s.record(.todayDrag, .used)   // used 不节流
        c.now += FeatureUsageStore.seenThrottle
        s.record(.todayPage, .seen)                       // 过了节流窗：记
        s.record(.todayEdit, .used, throttle: 120); c.now += 30; s.record(.todayEdit, .used, throttle: 120)   // 打字类：节流
        let recs = s.records()
        #expect(recs.filter { $0.f == "today.page" }.count == 2)
        #expect(recs.filter { $0.f == "today.drag" }.count == 2)
        #expect(recs.filter { $0.f == "today.edit" }.count == 1)
        // 新实例（重启）沿用已记的最后一次 seen，不立刻再记
        let root = try tempRoot(), d = suite()
        let a = try store(c, root: root, defaults: d); a.record(.journalPage, .seen)
        let b = try store(c, root: root, defaults: d); c.now += 60; b.record(.journalPage, .seen)
        #expect(b.records().filter { $0.f == "journal.page" }.count == 1)
    }

    // MARK: 3. 没做完：回一句

    @Test func replyFieldOpenedAndClosedWithoutSendingIsAbandonedSendingIsUsed() async throws {
        let w10 = W10ApprovalUXTests()
        let p = w10.pair()
        let c = Clock()
        let usage = try store(c)
        p.phone.usage = usage
        let one = try #require(await p.mac.submit(w10.draft(title: "挪笔记")))
        await p.phone.refresh()
        p.phone.toggleReplying(one.id)                      // 展开
        #expect(usage.isOpen(.proposalReply, key: one.id.uuidString))
        p.phone.toggleReplying(one.id)                      // 没发就收起
        #expect(usage.records().map(\.e) == [.abandoned])
        p.phone.toggleReplying(one.id)
        #expect(await p.phone.reply(one.id, text: "改成 9 点吧"))   // 发了：做完，refresh 不会把它算成没做完
        #expect(usage.records().filter { $0.f == "proposal.reply" }.map(\.e) == [.abandoned, .used])
        // 展开了，提案却被另一台设备批准了 → 这里刷新时算没做完
        let two = try #require(await p.mac.submit(w10.draft(title: "挪跑步")))
        await p.phone.refresh()
        p.phone.toggleReplying(two.id)
        _ = await p.mac.decide(two.id, .approve)
        await p.phone.refresh()
        #expect(usage.records().filter { $0.f == "proposal.reply" }.map(\.e) == [.abandoned, .used, .abandoned])
        // 通知上的直接回复（没展开过卡片输入框）不算卡片「回一句」
        let three = try #require(await p.mac.submit(w10.draft(title: "挪写作")))
        await p.phone.refresh()
        #expect(await p.phone.reply(three.id, text: "不用了"))
        #expect(usage.records().filter { $0.f == "proposal.reply" }.count == 3)
        // 撤销批准的结果 = 批准被撤销（结果不合预期的信号）
        let four = try #require(await p.mac.submit(w10.draft(title: "挪阅读")))
        await p.mac.refresh()
        _ = await p.mac.decide(four.id, .approve)
        await p.mac.refresh()
        p.mac.usage = usage
        #expect(await p.mac.undo(four.id))
        #expect(usage.records().contains { $0.f == "proposal.approve" && $0.e == .undone })
    }

    // MARK: 4. 没做完：调数值

    @Test func tuningStartedThenDeclinedIsAbandonedTunedApprovalIsUsed() async throws {
        let w11 = W11CardInputsTests()
        let r = try w11.rig()
        let ids = try w11.seedDay(r)
        let c = Clock()
        let usage = try store(c)
        r.phone.usage = usage
        let a = try #require(await r.mac.submit(w11.draft(.moveBlock(id: ids.flex, start: w11.at(16, 0, r.clock), end: nil, expectedRevision: nil),
                                                         parameters: [w11.startParam()])))
        await r.phone.refresh()
        r.phone.noteTuningStarted(a.id, option: 0)
        r.phone.noteTuningStarted(a.id, option: 0)                 // 拖滑块多次：只算一次开头
        _ = await r.phone.decide(a.id, .decline)
        #expect(usage.records().filter { $0.f == "proposal.tune" }.map(\.e) == [.abandoned])
        let b = try #require(await r.mac.submit(w11.draft(.moveBlock(id: ids.flex, start: w11.at(16, 0, r.clock), end: nil, expectedRevision: nil),
                                                         parameters: [w11.startParam()])))
        await r.phone.refresh()
        r.phone.noteTuningStarted(b.id, option: 0)
        guard case .won? = await r.phone.decide(b.id, .approve, values: ["start": .date(w11.at(20, 0, r.clock))]) else { Issue.record("应批准"); return }
        #expect(usage.records().filter { $0.f == "proposal.tune" }.map(\.e) == [.abandoned, .used])
        #expect(usage.openKeys(.proposalTune).isEmpty)
        // 开了头一直没结论 → 超时也算没做完
        usage.begin(.proposalTune, key: "x#0")
        c.now += FeatureUsageStore.staleAttempt + 1
        usage.sweepStaleAttempts()
        #expect(usage.records().filter { $0.f == "proposal.tune" }.map(\.e) == [.abandoned, .used, .abandoned])
    }

    // MARK: 5. 假设与证据

    @Test func hypothesesCoverEachPatternWithNumbersAsEvidence() throws {
        let c = Clock()
        let start = c.now
        let s = try store(c)
        // 第 0 天开始统计；连续 10 天每天打开今天页、长期页、日记页；智能体页一次都没出现
        for day in 0..<10 {
            c.now = start.addingTimeInterval(Double(day) * 86400)
            s.record(.todayPage, .seen); s.record(.longtermPage, .seen); s.record(.journalPage, .seen)
            s.record(.proposalCard, .seen)
        }
        c.now = start
        s.record(.journalAutoJournal, .used)                                   // 用过一次，之后 9 天不用
        for _ in 0..<3 { s.record(.agentChatSend, .abandoned) }; s.record(.agentChatSend, .used)   // 3/4 没做完
        for _ in 0..<4 { s.record(.proposalApprove, .used) }; for _ in 0..<2 { s.record(.proposalApprove, .undone) }
        for _ in 0..<2 { s.record(.autoAdjust, .undone) }
        for _ in 0..<3 { s.record(.longtermSay, .failed) }
        c.now = start.addingTimeInterval(20 * 86400)
        let r = report(s, c)
        let byFeature = Dictionary(uniqueKeysWithValues: FeatureUsageInterpreter.hypotheses(r).map { ($0.feature, $0) })
        func kind(_ f: FeatureID) -> FeatureHypothesis.Kind? { byFeature[f]?.kind }
        #expect(kind(.agentPage) == .neverSeen)
        #expect(byFeature[.agentPage]?.evidence.contains("开始统计 21 天") == true)
        #expect(kind(.todayDaySwitch) == .seenNotUsed)                          // 今天页打开 10 天、它 0 次
        #expect(byFeature[.todayDaySwitch]?.evidence.contains("打开过 10 天") == true)
        #expect(kind(.todayLoose) == .neverSeen)                                // 收在菜单里
        #expect(byFeature[.todayLoose]?.evidence.contains("收在「今天页」") == true)
        #expect(kind(.journalAutoJournal) == .triedNotKept)
        #expect(byFeature[.journalAutoJournal]?.evidence == "一共用过 1 次，最近一次在 20 天前")
        #expect(kind(.agentChatSend) == .hardToUse)
        #expect(byFeature[.agentChatSend]?.evidence.contains("没做完 3 次（75%）") == true)
        #expect(kind(.proposalApprove) == .unexpectedResult)
        #expect(byFeature[.proposalApprove]?.evidence.contains("被撤销 2 次") == true)
        #expect(kind(.autoAdjust) == .unexpectedResult)
        #expect(kind(.longtermSay) == .oftenFails)
        #expect(byFeature[.todayPage] == nil)                                   // 页面本身只记 seen：不说「不需要」
        #expect(byFeature[.notificationMorning] == nil)                         // 没有「看见」的功能不推断不知道 / 不需要
        #expect(byFeature[.autoBreak] == nil)                                   // 自动行为只看撤销
        // 统计不到 7 天：不说「不知道」
        let fresh = FeatureUsageAggregator.report(records: s.records(), marks: [:], trackingSince: start, now: start.addingTimeInterval(2 * 86400))
        #expect(FeatureUsageInterpreter.hypotheses(fresh).allSatisfy { $0.kind != .neverSeen })
        // 措辞：不出现「你从没」
        #expect(FeatureHypothesis.Kind.allCases.allSatisfy { !$0.text.contains("你") })
        // context.json 精简段：开关关 → 只一句；开 → 有假设与用法提示
        let off = FeatureUsageExport.contextSection(r, enabled: false)
        #expect(off["included"] as? Bool == false && off["hypotheses"] == nil)
        let on = FeatureUsageExport.contextSection(r, enabled: true)
        let hyps = try #require(on["hypotheses"] as? [[String: Any]])
        #expect(hyps.count <= FeatureUsageExport.contextHypotheses && hyps.allSatisfy { ($0["evidence"] as? String)?.isEmpty == false })
        #expect((on["howToUse"] as? String)?.contains("绝不说「你从没用过 X」") == true)
        #expect(JSONSerialization.isValidJSONObject(on))
    }

    // MARK: 6. 保留期

    @Test func retentionDropsOldDayFilesButKeepsMilestones() throws {
        let c = Clock()
        let start = c.now
        let root = try tempRoot(), d = suite()
        let s = try store(c, root: root, defaults: d)
        c.now = start.addingTimeInterval(-Double(FeatureUsageStore.retentionDays + 5) * 86400)
        s.record(.journalExport, .used)
        let oldFile = root.appendingPathComponent(DayContext.dayKey(c.now) + ".jsonl")
        #expect(FileManager.default.fileExists(atPath: oldFile.path))
        c.now = start
        s.record(.journalPage, .seen)                     // 新的一天第一条 → 自动清理
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(s.records().allSatisfy { $0.f != "journal.export" })
        let fresh = try store(c, root: root, defaults: d)
        let r = report(fresh, c)
        #expect(r.stats[.journalExport]?.total.isEmpty == true)
        #expect(r.stats[.journalExport]?.usedLifetime == 1 && r.stats[.journalExport]?.marks.firstUsed != nil)   // 里程碑不丢
        // 不会把它说成「从没用过」
        #expect(FeatureUsageInterpreter.hypotheses(r).first { $0.feature == .journalExport }?.kind != .seenNotUsed)
    }

    // MARK: 7. 桥接镜像守 CHANNEL

    @Test func bridgeMirrorRespectsChannelAndOnlyRewritesOnChange() throws {
        let c = Clock()
        let s = try store(c)
        s.record(.nowNextStart, .used, detail: "菜单栏")
        let r = report(s, c)
        // 日用版目录（没有 CHANNEL）+ Dev 版 App → 拒写
        let daily = try tempRoot()
        #expect(throws: AgentBridgeError.self) { try FeatureUsageExport.writeBridge(r, io: AgentBridgeIO(root: daily), channel: .dev) }
        #expect(!FileManager.default.fileExists(atPath: daily.appendingPathComponent("usage.json").path))
        // Dev 目录 + 日用版 App → 拒写
        let dev = try tempRoot()
        try Data("dev\n".utf8).write(to: dev.appendingPathComponent(AppChannel.bridgeMarkerFile))
        #expect(throws: AgentBridgeError.self) { try FeatureUsageExport.writeBridge(r, io: AgentBridgeIO(root: dev), channel: .daily) }
        // 通道相符 → 写；内容没变 → 不重写
        #expect(try FeatureUsageExport.writeBridge(r, io: AgentBridgeIO(root: dev), channel: .dev))
        #expect(try FeatureUsageExport.writeBridge(r, io: AgentBridgeIO(root: dev), channel: .dev) == false)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dev.appendingPathComponent("usage.json"))) as! [String: Any]
        #expect(json["channel"] as? String == "dev")
        let rows = try #require(json["features"] as? [[String: Any]])
        let row = try #require(rows.first { $0["id"] as? String == "nowNext.start" })
        #expect(row["used7d"] as? Int == 1 && (row["usedBySurface30d"] as? [String: Int]) == ["菜单栏": 1])
        // 镜像器：开关关 → 不写、删掉旧的；通道不符 → 报错可见
        let mirror = FeatureUsageBridgeMirror(reporter: FeatureUsageReporter(store: s))
        mirror.channel = .dev; mirror.now = { c.now }
        mirror.enabled = { false }
        mirror.mirror(to: AgentBridgeIO(root: dev))
        #expect(!FileManager.default.fileExists(atPath: dev.appendingPathComponent("usage.json").path))
        mirror.enabled = { true }
        mirror.mirror(to: AgentBridgeIO(root: daily))
        #expect(mirror.lastError?.contains("不能连") == true)
        mirror.mirror(to: AgentBridgeIO(root: dev))
        #expect(mirror.lastError == nil && FileManager.default.fileExists(atPath: dev.appendingPathComponent("usage.json").path))
    }

    // MARK: 8. plist 安全 + 隐私

    @Test func defaultsHoldOnlyPlistTypesAndRecordsHoldNoContent() throws {
        let c = Clock()
        let d = suite()
        let s = try store(c, defaults: d)
        s.record(.todayPage, .seen); s.record(.proposalApprove, .used); s.record(.agentChatSend, .abandoned)
        s.record(.settingsSkin, .used, detail: String(repeating: "长", count: 200))
        let marks = d.object(forKey: FeatureUsageStore.marksKey)
        #expect(marks is [String: Double])
        #expect(PropertyListSerialization.propertyList(marks as Any, isValidFor: .binary))
        #expect(d.object(forKey: FeatureUsageStore.trackingSinceKey) is Double)
        #expect(s.records().allSatisfy { ($0.d?.count ?? 0) <= FeatureUsageStore.detailMaxChars })   // detail 截短
        // 新功能开关：W17 约定 + 同步白名单
        #expect(SettingsSync.syncedKeys.contains(FeatureUsageSettings.shareKey))
        let flags = suite()
        #expect(ExperimentDefaults.newFeature(FeatureUsageSettings.shareKey, in: flags, channel: .daily) == false)
        #expect(ExperimentDefaults.newFeature(FeatureUsageSettings.shareKey, in: flags, channel: .dev) == true)
        // 登记表：id 唯一、都有中文名；快捷指令映射
        #expect(Set(FeatureID.allCases.map(\.rawValue)).count == FeatureID.allCases.count)
        #expect(FeatureID.allCases.allSatisfy { !$0.label.isEmpty && $0.area != "其它" })
        #expect(FeatureID.intent("completeCurrent", source: "control") == .controlCompleteCurrent)
        #expect(FeatureID.intent("openSchedule", source: nil) == .intentOpenToday)
        // 关闭的 store（测试宿主里的 shared）什么都不记
        let off = FeatureUsageStore(root: try tempRoot(), defaults: suite(), now: { c.now }, enabled: false)
        off.record(.todayPage, .used); off.begin(.proposalReply)
        #expect(off.records().isEmpty && !off.isOpen(.proposalReply))
        #expect(FeatureUsage.shared.records().isEmpty)
    }
}
