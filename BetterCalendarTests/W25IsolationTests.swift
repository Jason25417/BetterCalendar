//
//  W25IsolationTests.swift
//  BetterCalendarTests
//
//  W25：单测宿主与 Jason 日用版是同一个 bundle（同沙盒容器、同 UserDefaults、同 iCloud KV、同通知中心、同钥匙串服务名）。
//  守卫：测试宿主里这些全局入口一律是本次运行的替身（TestHostIsolation），真状态读不到、也写不进。
//  另有源码级架构守卫：SecItem / CKContainer / JSONSerialization.data(withJSONObject:) 只许出现在白名单文件里。
//

import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import BetterCalendar

@MainActor
@Suite struct W25IsolationTests {
    private static let realDomain = Bundle.main.bundleIdentifier ?? "com.jason.BetterCalendar"

    @Test func isolationIsInstalledBeforeAnyTestRuns() {
        #expect(TestHost.isActive)
        #expect(TestHostIsolation.isInstalled, "App 入口第一行就该装好")
        #expect(TestHostIsolation.installProblems.isEmpty, "有入口没换成：\(TestHostIsolation.installProblems)")
    }

    @Test func standardDefaultsAreAThrowawaySuiteNotTheDailyAppsDomain() throws {
        let key = "bc.w25.probe." + UUID().uuidString
        UserDefaults.standard.set("probe", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let isolated = UserDefaults.standard.persistentDomain(forName: TestHostIsolation.defaultsSuiteName) ?? [:]
        #expect(isolated[key] as? String == "probe", ".standard 写进了本次运行的一次性 suite")
        // 只读核对日用版的真域：探针绝不能出现在那里
        let real = UserDefaults.standard.persistentDomain(forName: Self.realDomain) ?? [:]
        #expect(real[key] == nil, "测试写进了日用版的真 UserDefaults")
    }

    @Test func appStorageDefaultStoreIsIsolatedToo() {
        let key = "bc.w25.appstorage." + UUID().uuidString
        let storage = AppStorage(wrappedValue: "default", key)
        storage.wrappedValue = "changed"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(UserDefaults.standard.persistentDomain(forName: TestHostIsolation.defaultsSuiteName)?[key] as? String == "changed")
        #expect(UserDefaults.standard.persistentDomain(forName: Self.realDomain)?[key] == nil)
    }

    @Test func iCloudKeyValueStoreIsInMemory() {
        #expect(NSUbiquitousKeyValueStore.default is TestHostKeyValueStore, "iCloud KV 写进去会同步到 Jason 的 iPhone")
        let key = "bc.w25.kv." + UUID().uuidString
        let kv = NSUbiquitousKeyValueStore.default
        kv.set(Data([1, 2, 3]), forKey: key)
        kv.set(["a"], forKey: key + ".array")
        #expect(kv.data(forKey: key) == Data([1, 2, 3]))
        #expect(kv.array(forKey: key + ".array") as? [String] == ["a"])
        #expect(kv.dictionaryRepresentation[key] != nil)
        kv.removeObject(forKey: key); kv.removeObject(forKey: key + ".array")
        #expect(kv.object(forKey: key) == nil)
    }

    @Test func userDirectoriesAndAppGroupAreRedirectedToThisRun() throws {
        let root = TestHostIsolation.directoryRoot.standardizedFileURL.path
        for directory: FileManager.SearchPathDirectory in [.applicationSupportDirectory, .cachesDirectory, .documentDirectory,
                                                           .downloadsDirectory, .desktopDirectory] {
            let url = try #require(FileManager.default.urls(for: directory, in: .userDomainMask).first)
            #expect(url.standardizedFileURL.path.hasPrefix(root), "\(directory) 没换到临时目录：\(url.path)")
        }
        let group = try #require(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppChannel.current.appGroupID))
        #expect(group.standardizedFileURL.path.hasPrefix(root), "App Group 容器（小组件读的那份）没换：\(group.path)")
    }

    @Test func keychainIsInMemory() {
        let account = "bc-w25-" + UUID().uuidString
        #expect(KeychainStore.loadAPIKey(account: account) == nil)
        KeychainStore.saveAPIKey("sk-test", account: account)
        #expect(KeychainStore.loadAPIKey(account: account) == "sk-test")
        KeychainStore.deleteAPIKey(account: account)
        #expect(KeychainStore.loadAPIKey(account: account) == nil)
    }

    @Test func notificationCenterWritesAreRefused() async throws {
        let center = UNUserNotificationCenter.current()
        let id = "bc.w25.probe." + UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = "不该出现在 Jason 的通知中心"
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        center.removePendingNotificationRequests(withIdentifiers: [id])
        #expect(TestHostIsolation.refusedCalls.contains("通知.排定 \(id)"))
        #expect(TestHostIsolation.refusedCalls.contains { $0.hasPrefix("通知.删除") && $0.contains(id) })
        #expect(await center.pendingNotificationRequests().isEmpty, "测试看不到日用版排着的通知")
    }

    @Test func safeJSONThrowsInsteadOfRaisingAnObjCException() throws {
        #expect(throws: SafeJSON.InvalidObject.self) { try SafeJSON.data(withJSONObject: ["k": Data([1])]) }
        #expect(throws: SafeJSON.InvalidObject.self) { try SafeJSON.data(withJSONObject: ["k": Date(timeIntervalSince1970: 0)]) }
        #expect(throws: SafeJSON.InvalidObject.self) { try SafeJSON.data(withJSONObject: ["k": Double.nan]) }
        #expect(throws: SafeJSON.InvalidObject.self) { try SafeJSON.data(withJSONObject: "bare string") }
        #expect(try SafeJSON.data(withJSONObject: "s", options: [.fragmentsAllowed]) == Data("\"s\"".utf8))
        #expect(try SafeJSON.data(withJSONObject: ["k": 1], options: [.sortedKeys]) == Data("{\"k\":1}".utf8))
    }

    // MARK: 源码级架构守卫

    private func appSources() -> [(name: String, code: String)] {
        let appRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BetterCalendar")
        var out: [(String, String)] = []
        let files = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let code = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                .joined(separator: "\n")
            out.append((url.lastPathComponent, code))
        }
        return out
    }

    @Test func globalStateEntryPointsStayInAuditedFiles() {
        let sources = appSources()
        #expect(sources.count > 100, "源码目录没读到（\(sources.count) 个文件）")
        func offenders(_ needle: String, allowed: Set<String>) -> [String] {
            sources.filter { !allowed.contains($0.name) && $0.code.contains(needle) }.map(\.name).sorted()
        }
        // 钥匙串：KeychainStore（测试宿主走内存）+ StateBridgeClient（已冻结，测试宿主整段跳过）
        #expect(offenders("SecItem", allowed: ["KeychainStore.swift", "StateBridgeClient.swift"]).isEmpty,
                "新的钥匙串调用点要先过 TestHost 闸，再加进白名单：\(offenders("SecItem", allowed: ["KeychainStore.swift", "StateBridgeClient.swift"]))")
        // CloudKit：这些文件里的 CKContainer 只在测试宿主之外构造（组装点分支 / TestHost 闸）——新增要先审再加
        let cloudKit: Set<String> = ["DevelopmentSchemaApp.swift", "AgentMessage.swift", "AgentChat.swift", "ActivityCloudSync.swift",
                                     "FocusFollow.swift", "CloudKitSharedTimerStore.swift", "DataSyncMonitor.swift",
                                     "CloudKitProposalStore.swift"]
        #expect(offenders("CKContainer(", allowed: cloudKit).isEmpty,
                "新的 CloudKit 容器构造点：确认测试宿主里不会走到后再加白名单：\(offenders("CKContainer(", allowed: cloudKit))")
        // JSON：一律 SafeJSON（ObjC 异常 Swift 接不住）
        #expect(offenders("JSONSerialization.data(withJSONObject", allowed: ["SafeJSON.swift"]).isEmpty,
                "改用 SafeJSON.data(withJSONObject:)：\(offenders("JSONSerialization.data(withJSONObject", allowed: ["SafeJSON.swift"]))")
    }
}
