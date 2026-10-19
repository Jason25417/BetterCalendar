//
//  W28MultiDeviceTests.swift
//  BetterCalendarTests
//
//  W28 iPad 作为第三台设备：活动记录带设备类别（iphone / ipad / mac，向后兼容旧记录）、摘要 / 哨兵 / 状态按设备分开、
//  设备名册带类别、晚间复盘按类别错开、动作描述里不写平台名。全部用固定时刻、临时目录与内存假实现。
//

import CloudKit
import Foundation
import Testing
@testable import BetterCalendar

private let cal = Calendar.current
private func at(_ h: Int, _ m: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: h, minute: m))!
}
private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("w28-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func opened(_ app: String, _ t: Date, device: String, kind: ActivityDeviceKind?) -> ActivityEvent {
    ActivityEvent(at: t, kind: .appOpened, source: .shortcut, deviceId: device, platform: "iOS", appName: app, deviceKind: kind?.rawValue)
}

@MainActor
struct W28MultiDeviceTests {

    // MARK: 设备类别

    @Test func deviceKindFromModelIdentifierAndLegacyResolution() {
        #expect(ActivityDeviceKind.fromModelIdentifier("iPad14,3") == .ipad)
        #expect(ActivityDeviceKind.fromModelIdentifier("iPhone17,1") == .iphone)
        #expect(ActivityDeviceKind.fromModelIdentifier("arm64", simulatorModel: "iPad16,3") == .ipad)   // 模拟器
        #expect(ActivityDeviceKind.fromModelIdentifier("arm64", simulatorModel: "") == .iphone)
        #expect(ActivityDeviceKind.current == .mac)   // 测试跑在 Mac 上

        let legacy = ActivityEvent(at: at(9), kind: .appOpened, deviceId: "p", platform: "iOS")
        #expect(legacy.resolvedDeviceKind.kind == .iphone && legacy.resolvedDeviceKind.inferred)
        let pad = opened("GoodNotes", at(9), device: "d", kind: .ipad)
        #expect(pad.resolvedDeviceKind.kind == .ipad && !pad.resolvedDeviceKind.inferred)
        let mac = ActivityEvent(at: at(9), kind: .appActivated, deviceId: "m", platform: "macOS")
        #expect(mac.resolvedDeviceKind.kind == .mac && !mac.resolvedDeviceKind.inferred)
        let junk = ActivityEvent(at: at(9), kind: .appOpened, deviceId: "p", platform: "iOS", deviceKind: "watch")
        #expect(junk.resolvedDeviceKind.kind == .iphone && junk.resolvedDeviceKind.inferred)   // 不认识的值 = 当旧记录
    }

    @Test func eventJSONIsBackwardCompatible() throws {
        // W28 之前写下的一行（没有 deviceKind）照常解出来
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","at":"2026-10-18T09:00:00.000-04:00","kind":"appOpened","source":"shortcut","deviceId":"p","platform":"iOS","appName":"微信"}"#
        let decoded = try ActivityCodec.decoder().decode(ActivityEvent.self, from: Data(old.utf8))
        #expect(decoded.deviceKind == nil && decoded.resolvedDeviceKind.kind == .iphone)
        // 没有类别时不写这个键（老版本读新文件也不受影响）；有类别时往返不丢
        let noKind = String(decoding: try ActivityCodec.line(decoded), as: UTF8.self)
        #expect(!noKind.contains("deviceKind"))
        var withKind = decoded; withKind.deviceKind = "ipad"
        let back = try ActivityCodec.decoder().decode(ActivityEvent.self, from: try ActivityCodec.line(withKind))
        #expect(back == withKind)
        // CloudKit 通道：类别在 payload JSON 里，不需要新字段
        let r = try ActivityCloudCodec.record(withKind)
        #expect(ActivityCloudCodec.event(r)?.deviceKind == "ipad")
        #expect(r["deviceKind"] == nil)
    }

    @Test func sinkStampsDeviceKindWithoutOverwriting() async throws {
        let log = FileActivityLog(root: tempDir())
        let sink = ActivityPhoneSink(log: log, outbox: nil, transport: nil, deviceKind: .ipad)
        let a = opened("GoodNotes", at(9), device: "d", kind: nil)
        let b = opened("微信", at(9, 1), device: "d", kind: .iphone)   // 已有类别的不改
        _ = try await sink.record([a, b])
        let rows = try await log.events(in: DateInterval(start: at(8), end: at(10)))
        #expect(rows.map(\.deviceKind) == ["ipad", "iphone"])
        // 不传类别的 sink（测试默认）原样写
        let plain = ActivityPhoneSink(log: FileActivityLog(root: tempDir()), outbox: nil, transport: nil)
        let o = try await plain.record([opened("X", at(9), device: "p", kind: nil)])
        #expect(o.written == 1)
        #expect(try await plain.log.events(in: DateInterval(start: at(8), end: at(10))).first?.deviceKind == nil)
    }

    @Test func shortcutRecorderOnPadProducesPadEvents() async throws {
        let name = "w28-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name)
        let sink = ActivityPhoneSink(log: FileActivityLog(root: tempDir()), outbox: nil, transport: nil, deviceKind: .ipad)
        let r = try await ActivityShortcutRecorder.recordOpened(appName: "GoodNotes", at: at(15), deviceId: "pad-1", platform: "iOS",
                                                               sink: sink, defaults: d)
        guard case let .recorded(events, _) = r else { Issue.record("应记下"); return }
        #expect(events.count == 1)
        let stored = try await sink.log.events(in: DateInterval(start: at(14), end: at(16)))
        #expect(stored.first?.resolvedDeviceKind.kind == .ipad && stored.first?.appName == "GoodNotes")
    }

    // MARK: context 摘要 / 哨兵 / 状态按设备分开

    @Test func contextSummarySplitsIphoneAndIpad() {
        let now = at(16)
        let events = [
            opened("微信", at(13), device: "phone-old", kind: nil),        // 旧记录：按 iPhone 计
            opened("小红书", at(14), device: "phone-1", kind: .iphone),
            opened("GoodNotes", at(15), device: "pad-1", kind: .ipad),
            opened("Notability", at(15, 30), device: "pad-1", kind: .ipad),
        ]
        let s = ActivityContextSummary.build(events: events, now: now, recording: true, pausedUntil: nil,
                                             deviceLabels: ["pad-1": "Jason 的 iPad", "phone-1": "Jason 的 iPhone"])
        let iphone = s["iphone"] as! [String: Any], ipad = s["ipad"] as! [String: Any]
        #expect(iphone["total"] as? Int == 2 && ipad["total"] as? Int == 2)
        let padApps = (ipad["items"] as! [[String: Any]]).compactMap { $0["app"] as? String }
        #expect(padApps == ["GoodNotes", "Notability"])
        #expect(((iphone["items"] as! [[String: Any]]).compactMap { $0["app"] as? String }).contains("GoodNotes") == false)
        let padDevices = ipad["devices"] as! [[String: Any]]
        #expect(padDevices.count == 1 && padDevices[0]["label"] as? String == "Jason 的 iPad")
        // iPhone 段有两台（旧 id + 新 id）：每条带设备名
        #expect((iphone["items"] as! [[String: Any]]).allSatisfy { $0["device"] != nil })
        #expect((s["deviceKindNote"] as? String)?.contains("按 iPhone 计") == true)
        #expect(iphone["emptyNote"] == nil)
        // 没有 iPad 记录时也有 ipad 段（显式说没有，而不是缺键让人猜）
        let none = ActivityContextSummary.build(events: [], now: now, recording: true, pausedUntil: nil)
        #expect((none["ipad"] as? [String: Any])?["emptyNote"] != nil && none["deviceKindNote"] == nil)
        #expect((try? SafeJSON.data(withJSONObject: s)) != nil)
    }

    @Test func sentinelCountsIpadOpensSeparately() {
        let now = at(16)
        let events = [
            opened("小红书", at(15, 50), device: "phone-1", kind: .iphone),
            opened("GoodNotes", at(15, 52), device: "pad-1", kind: .ipad),
            opened("GoodNotes", at(15, 55), device: "pad-1", kind: .ipad),
            opened("微信", at(15, 56), device: "phone-old", kind: nil),
        ]
        let sum = SentinelActivitySummary.summarize(events, window: DateInterval(start: at(15, 30), end: now), now: now)
        #expect(sum.phoneOpens.map(\.name).sorted() == ["小红书", "微信"])
        #expect(sum.padOpens.map(\.name) == ["GoodNotes"] && sum.padOpens.first?.count == 2)
        let ctx = AgentContextInput(now: now)
        let digest = SentinelDigestBuilder.build(SentinelDigestInput(now: now, context: ctx, activity: events))
        #expect(digest.text.contains("iPad 打开：GoodNotes 2 次"))
        #expect(digest.text.contains("iPhone 打开："))
        // 指纹：iPad 上换了 App 也算变化，iPhone 的最近一条不变
        let before = SentinelDigestBuilder.changeFingerprint(context: ctx, activity: events, now: now)
        let after = SentinelDigestBuilder.changeFingerprint(context: ctx, activity: events + [opened("Safari", at(15, 57), device: "pad-1", kind: .ipad)], now: now)
        #expect(before != after)
    }

    @Test func remoteDeviceStatusPerDevice() {
        let board = ActivityStatusBoard(); board.logsFailures = false
        board.noteRemote([opened("微信", at(9), device: "p", kind: nil)])
        #expect(board.remoteDevices["p"]?.kind == .iphone && board.remoteDevices["p"]?.kindInferred == true)
        board.noteRemote([opened("微信", at(10), device: "p", kind: .iphone),
                          opened("GoodNotes", at(11), device: "d", kind: .ipad),
                          ActivityEvent(at: at(12), kind: .other, source: .history, deviceId: "d", platform: "iOS",
                                        detail: ["signal": "network"], deviceKind: "ipad"),
                          ActivityEvent(at: at(12), kind: .appActivated, deviceId: "m", platform: "macOS")])   // Mac 不算远端
        #expect(board.remoteDevices.count == 2)
        #expect(board.remoteDevices["p"]?.kindInferred == false && board.remoteDevices["p"]?.lastShortcutAt == at(10))
        let pad = board.remoteDevices["d"]
        #expect(pad?.kind == .ipad && pad?.lastShortcutAt == at(11) && pad?.lastEventAt == at(12))
        let list = board.remoteDeviceList(labels: ["d": "Jason 的 iPad"])
        #expect(list.map(\.label) == ["Jason 的 iPad", "iPhone"])   // ipad < iphone（按类别名排序，稳定）
        let snap = board.remoteSnapshot(labels: [:])
        #expect(snap.count == 2 && (try? SafeJSON.data(withJSONObject: snap)) != nil)
    }

    @Test func importerTracksEachRemoteDevice() async throws {
        let name = "w28-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name)
        let cloud = MemoryActivityCloud(), board = ActivityStatusBoard(); board.logsFailures = false
        let log = FileActivityLog(root: tempDir())
        try await cloud.upload([opened("小红书", at(9), device: "phone-1", kind: .iphone),
                                opened("GoodNotes", at(9, 5), device: "pad-1", kind: .ipad)])
        let importer = ActivityCloudImporter(transport: cloud, log: log, status: board, defaults: d)
        #expect(await importer.importOnce(now: at(9, 10)) == 2)
        #expect(Set(board.remoteDevices.keys) == ["phone-1", "pad-1"])
        #expect(board.remoteDevices["pad-1"]?.kind == .ipad)
    }

    // MARK: 设备名册 / 晚间复盘

    @Test func knownDevicesCarryKindAndDecodeOldEntries() throws {
        let old = #"[{"id":"a","label":"Jason 的 iPhone","platform":"iOS","seenAt":813974400}]"#
        let list = KnownDevicesCodec.decode(Data(old.utf8))
        #expect(list.count == 1 && list[0].kind == nil && list[0].deviceKind == .iphone && list[0].isIOSDevice)
        let pad = KnownDevice(id: "b", label: "Jason 的 iPad", platform: "iOS", seenAt: at(9), kind: "ipad")
        let mac = KnownDevice(id: "c", label: "MacBook", platform: "macOS", seenAt: at(9))
        #expect(pad.deviceKind == .ipad && pad.isIOSDevice && mac.deviceKind == .mac && !mac.isIOSDevice)
        // 三台都留在名册里（不假设只有两台）
        var roster = KnownDevicesCodec.merge(list, adding: pad, now: at(10))
        roster = KnownDevicesCodec.merge(roster, adding: mac, now: at(10))
        #expect(Set(roster.map(\.id)) == ["a", "b", "c"])
    }

    @Test func eveningGraceIsStaggeredByDeviceKind() {
        #expect(AgentHub.eveningGrace(.mac) == 0)
        #expect(AgentHub.eveningGrace(.iphone) < AgentHub.eveningGrace(.ipad))
    }

    // MARK: 源码守卫：动作的标题 / 描述里不写平台名（ITMS-90626：曾因描述含「mac」被拒）

    @Test func appIntentTextsNameNoPlatform() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BetterCalendar")
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let code = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard code.contains("AppIntent") else { continue }
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // 审核看的是动作标题与描述（ITMS-90626）。IntentDescription( 常常换行写正文：本行没有引号时连同下一行一起看。
                // （参数标题不在此列：已上架的 SubmitPersonalStateIntent 参数里有「ios.app」这类来源代号）
                let isDescription = line.contains("IntentDescription(")
                guard isDescription || line.contains("static var title: LocalizedStringResource") else { continue }
                let next = isDescription && !line.contains("\"") && i + 1 < lines.count ? lines[i + 1] : ""
                let text = (line + next).lowercased()
                for name in ["iphone", "ipad", "mac", "ios"] where text.contains(name) {
                    offenders.append("\(url.lastPathComponent):\(i + 1) 含「\(name)」")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
