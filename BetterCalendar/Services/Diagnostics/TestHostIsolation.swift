//
//  TestHostIsolation.swift
//  BetterCalendar
//
//  W25（2026-10-19）：单测宿主 = 主 App 本身（bundle com.jason.BetterCalendar），与 Jason 日用版共用同一个沙盒容器、
//  同一份 UserDefaults、同一个 iCloud 键值存储（写进去会同步到他的 iPhone）、同一个通知中心、同一个钥匙串服务名。
//  事故：一条测试的结果取决于 Jason 真实的 `approvals.preauthRules.v1`；更早还有测试把块写进他的真日历（W23b 已堵）。
//
//  做法 = **一个集中开关**：App 入口（BetterCalendarMain）第一行调 `installIfTestHost()`，只在 TestHost.isActive 时
//  用 ObjC runtime 把几个「全局单例入口」换成本进程专属的替身，调用点一行不改：
//    ① `UserDefaults.standard`（含 @AppStorage 默认存储）→ 本次运行专属的一次性 suite（退出时清掉）；
//    ② `NSUbiquitousKeyValueStore.default` → 纯内存 KV（绝不进 iCloud）；
//    ③ FileManager 的用户目录（Application Support / Caches / 文稿 / 下载 / 桌面）与 App Group 容器 → 本次运行的临时目录；
//    ④ 通知中心的写入口（排通知 / 删通知 / 注册类别 / 请求授权 / 读待发）→ 拒绝并记一笔（通知中心按 bundle id 共用，
//       测试删掉的就是 Jason 日用版排好的早晚提醒）。
//  钥匙串不走 swizzle：只有 KeychainStore（及已门控的 StateBridgeClient）调 SecItem，KeychainStore 自己在测试宿主里走内存。
//  CloudKit：各 CKContainer 构造点都在测试宿主外的分支里，由架构测试按文件白名单守住（W25IsolationTests）。
//
//  生产：`installIfTestHost()` 第一行就返回，什么都不换——行为与改动前逐字一致。只按 TestHost 判断，**不是设置开关**。
//

import Foundation
import ObjectiveC
import UserNotifications

nonisolated enum TestHostIsolation {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var refused: [String] = []
    nonisolated(unsafe) private static var problems: [String] = []

    /// 本次运行的标识（pid + 随机段）：一次性 defaults suite 名与临时目录都用它，退出时按它清理。
    static let runID = "\(getpid())-\(UUID().uuidString.prefix(8))"
    static let defaultsPrefix = "bc-testhost."
    /// 替身 `UserDefaults.standard` 的 suite 名。
    static let defaultsSuiteName = defaultsPrefix + runID
    /// 替身用户目录的根（沙盒 tmp 下）。
    static let directoryRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("bc-testhost-\(runID)", isDirectory: true)

    nonisolated(unsafe) private static var isolatedDefaults: UserDefaults?

    /// 这个进程里被拒的通知中心写入（测试断言用；与 EventKitWriteGuard.refusedWrites 同一思路）。
    static var refusedCalls: [String] { lock.withLock { refused } }
    /// 安装时没换成的入口（应恒为空；守卫测试断言）。
    static var installProblems: [String] { lock.withLock { problems } }
    static var isInstalled: Bool { lock.withLock { installed } }

    /// App 入口第一行调。生产里直接返回。
    static func installIfTestHost() {
        guard TestHost.isActive else { return }
        let first = lock.withLock { () -> Bool in
            guard !installed else { return false }
            installed = true
            return true
        }
        guard first else { return }
        sweepStaleRuns()
        try? FileManager().createDirectory(at: directoryRoot, withIntermediateDirectories: true)   // 建立时刻 = 本次运行开始（下次清理的依据）
        installDefaults()
        installKeyValueStore()
        installDirectories()
        installNotificationCenter()
        atexit { TestHostIsolation.cleanUpThisRun() }
    }

    static func recordRefusal(_ what: String) { lock.withLock { refused.append(what) } }
    private static func problem(_ what: String) { lock.withLock { problems.append(what) } }

    // MARK: ① UserDefaults.standard

    private static func installDefaults() {
        guard let suite = UserDefaults(suiteName: defaultsSuiteName) else { return problem("建不出一次性 defaults suite") }
        suite.removePersistentDomain(forName: defaultsSuiteName)
        isolatedDefaults = suite
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in suite }
        replaceClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"), block)
    }

    // MARK: ② iCloud KV

    private static func installKeyValueStore() {
        let store = TestHostKeyValueStore.shared
        let block: @convention(block) (AnyObject) -> NSUbiquitousKeyValueStore = { _ in store }
        replaceClassMethod(NSUbiquitousKeyValueStore.self, NSSelectorFromString("defaultStore"), block)
    }

    // MARK: ③ 用户目录 / App Group 容器

    /// 只换用户域里这几个（rawValue 稳定）：文稿 9、桌面 12、Caches 13、Application Support 14、下载 15。
    static let redirectedDirectories: [UInt: String] = [9: "Documents", 12: "Desktop", 13: "Caches",
                                                         14: "Application Support", 15: "Downloads"]

    static func redirectedURL(_ directory: UInt) -> URL? {
        guard let name = redirectedDirectories[directory] else { return nil }
        let url = directoryRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager().createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func installDirectories() {
        let cls: AnyClass = FileManager.self
        let urlsSel = NSSelectorFromString("URLsForDirectory:inDomains:")
        if let original = class_getInstanceMethod(cls, urlsSel) {
            typealias Fn = @convention(c) (AnyObject, Selector, UInt, UInt) -> NSArray
            let call = unsafeBitCast(method_getImplementation(original), to: Fn.self)
            let block: @convention(block) (AnyObject, UInt, UInt) -> NSArray = { manager, directory, domains in
                if domains & 1 != 0, let url = redirectedURL(directory) { return [url] as NSArray }
                return call(manager, urlsSel, directory, domains)
            }
            replaceInstanceMethod(cls, urlsSel, block)
        } else { problem("FileManager.URLsForDirectory:inDomains: 不存在") }

        let groupSel = NSSelectorFromString("containerURLForSecurityApplicationGroupIdentifier:")
        let group: @convention(block) (AnyObject, NSString) -> NSURL? = { _, identifier in
            let url = directoryRoot.appendingPathComponent("Group Containers/\(identifier)", isDirectory: true)
            try? FileManager().createDirectory(at: url, withIntermediateDirectories: true)
            return url as NSURL
        }
        replaceInstanceMethod(cls, groupSel, group)
    }

    // MARK: ④ 通知中心

    private static func installNotificationCenter() {
        let cls: AnyClass = UNUserNotificationCenter.self
        let add: @convention(block) (AnyObject, UNNotificationRequest, (@convention(block) (NSError?) -> Void)?) -> Void = { _, request, done in
            recordRefusal("通知.排定 \(request.identifier)")
            done?(nil)
        }
        replaceInstanceMethod(cls, NSSelectorFromString("addNotificationRequest:withCompletionHandler:"), add)
        let removeIDs: @convention(block) (AnyObject, NSArray) -> Void = { _, ids in recordRefusal("通知.删除 \(ids)") }
        replaceInstanceMethod(cls, NSSelectorFromString("removePendingNotificationRequestsWithIdentifiers:"), removeIDs)
        replaceInstanceMethod(cls, NSSelectorFromString("removeDeliveredNotificationsWithIdentifiers:"), removeIDs)
        let removeAll: @convention(block) (AnyObject) -> Void = { _ in recordRefusal("通知.全部删除") }
        replaceInstanceMethod(cls, NSSelectorFromString("removeAllPendingNotificationRequests"), removeAll)
        replaceInstanceMethod(cls, NSSelectorFromString("removeAllDeliveredNotifications"), removeAll)
        let categories: @convention(block) (AnyObject, NSSet) -> Void = { _, _ in recordRefusal("通知.注册类别") }
        replaceInstanceMethod(cls, NSSelectorFromString("setNotificationCategories:"), categories)
        let authorize: @convention(block) (AnyObject, UInt, @convention(block) (Bool, NSError?) -> Void) -> Void = { _, _, done in
            recordRefusal("通知.请求授权"); done(false, nil)
        }
        replaceInstanceMethod(cls, NSSelectorFromString("requestAuthorizationWithOptions:completionHandler:"), authorize)
        // 读：不让测试看见日用版排着 / 送达的通知（结果不能取决于真实状态）
        let none: @convention(block) (AnyObject, @convention(block) (NSArray) -> Void) -> Void = { _, done in done([] as NSArray) }
        replaceInstanceMethod(cls, NSSelectorFromString("getPendingNotificationRequestsWithCompletionHandler:"), none)
        replaceInstanceMethod(cls, NSSelectorFromString("getDeliveredNotificationsWithCompletionHandler:"), none)
    }

    // MARK: runtime 工具

    private static func replaceClassMethod(_ cls: AnyClass, _ selector: Selector, _ block: Any) {
        guard let meta = object_getClass(cls), let method = class_getClassMethod(cls, selector) else {
            return problem("\(cls).\(selector) 不存在")
        }
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(meta, selector, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
    }

    private static func replaceInstanceMethod(_ cls: AnyClass, _ selector: Selector, _ block: Any) {
        guard let method = class_getInstanceMethod(cls, selector) else { return problem("\(cls).\(selector) 不存在") }
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
    }

    // MARK: 清理（只清本机制自己建的：bc-testhost.* suite 与 bc-testhost-* 临时目录）

    private static var preferencesFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    /// 退出时清空本次的一次性 suite（测试宿主常被直接杀掉、atexit 不一定跑）。文件与临时目录留给下次 sweepStaleRuns：
    /// 临时目录的建立时刻是本次运行的开始，下次靠它圈定「本次运行期间新建的测试 suite」。
    private static func cleanUpThisRun() {
        isolatedDefaults?.removePersistentDomain(forName: defaultsSuiteName)
    }

    /// 启动时补清已死的测试宿主留下的东西。三类，都只认本机制能证明是测试产物的：
    /// ① 死掉的运行的 `bc-testhost.<pid>-…` suite；② 死掉的运行的 `bc-testhost-<pid>-…` 临时目录（它的建立时刻 = 那次运行的开始）；
    /// ③ 各测试自己建的 `UserDefaults(suiteName: "bc-…-<UUID>")`（落在同一个真容器的 Preferences 里，没人清就越积越多）：
    ///    只删「最早一个已死运行开始之后、任何仍活着的测试宿主开始之前」新建的、名字带 UUID 的；
    ///    本机制上线前的存量一个不碰（要清由 Jason 决定），日用版自己的域 / App Group / 系统域一律不碰。
    private static func sweepStaleRuns() {
        let fm = FileManager()
        func pid(of id: Substring) -> Int32? { Int32(id.split(separator: "-").first ?? "") }
        func alive(_ pid: Int32) -> Bool { pid == getpid() || kill(pid, 0) == 0 || errno != ESRCH }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        var deadStart = Date.distantFuture, liveStart = Date()
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("bc-testhost-") {
            guard let p = pid(of: name.dropFirst("bc-testhost-".count)) else { continue }
            let url = tmp.appendingPathComponent(name)
            let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
            if p == getpid() { continue }
            if alive(p) { if let created { liveStart = min(liveStart, created) }; continue }
            if let created { deadStart = min(deadStart, created) }
            try? fm.removeItem(at: url)
        }
        let uuid = try? NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        let protected: Set<String> = [Bundle.main.bundleIdentifier ?? "", AppChannel.current.appGroupID]
        for name in (try? fm.contentsOfDirectory(atPath: preferencesFolder.path)) ?? [] where name.hasSuffix(".plist") {
            let suite = String(name.dropLast(".plist".count))
            let url = preferencesFolder.appendingPathComponent(name)
            if suite.hasPrefix(defaultsPrefix) {
                guard let p = pid(of: suite.dropFirst(defaultsPrefix.count)), !alive(p) else { continue }
            } else {
                guard !protected.contains(suite), !suite.hasPrefix("com.apple."),
                      uuid?.firstMatch(in: suite, range: NSRange(suite.startIndex..., in: suite)) != nil,
                      let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date,
                      created >= deadStart, created < liveStart else { continue }
            }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: url)
        }
    }
}

/// 测试宿主里的 `NSUbiquitousKeyValueStore.default`：纯内存，绝不碰 iCloud（不发 didChangeExternally）。
nonisolated final class TestHostKeyValueStore: NSUbiquitousKeyValueStore, @unchecked Sendable {
    static let shared = TestHostKeyValueStore()
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    override func object(forKey aKey: String) -> Any? { lock.withLock { values[aKey] } }
    override func set(_ anObject: Any?, forKey aKey: String) {
        lock.withLock { if let anObject { values[aKey] = anObject } else { values.removeValue(forKey: aKey) } }
    }
    override func removeObject(forKey aKey: String) { _ = lock.withLock { values.removeValue(forKey: aKey) } }
    override func string(forKey aKey: String) -> String? { object(forKey: aKey) as? String }
    override func array(forKey aKey: String) -> [Any]? { object(forKey: aKey) as? [Any] }
    override func dictionary(forKey aKey: String) -> [String: Any]? { object(forKey: aKey) as? [String: Any] }
    override func data(forKey aKey: String) -> Data? { object(forKey: aKey) as? Data }
    override func longLong(forKey aKey: String) -> Int64 { (object(forKey: aKey) as? NSNumber)?.int64Value ?? 0 }
    override func double(forKey aKey: String) -> Double { (object(forKey: aKey) as? NSNumber)?.doubleValue ?? 0 }
    override func bool(forKey aKey: String) -> Bool { (object(forKey: aKey) as? NSNumber)?.boolValue ?? false }
    override func set(_ aString: String?, forKey aKey: String) { set(aString as Any?, forKey: aKey) }
    override func set(_ aData: Data?, forKey aKey: String) { set(aData as Any?, forKey: aKey) }
    override func set(_ anArray: [Any]?, forKey aKey: String) { set(anArray as Any?, forKey: aKey) }
    override func set(_ aDictionary: [String: Any]?, forKey aKey: String) { set(aDictionary as Any?, forKey: aKey) }
    override func set(_ value: Int64, forKey aKey: String) { set(NSNumber(value: value) as Any?, forKey: aKey) }
    override func set(_ value: Double, forKey aKey: String) { set(NSNumber(value: value) as Any?, forKey: aKey) }
    override func set(_ value: Bool, forKey aKey: String) { set(NSNumber(value: value) as Any?, forKey: aKey) }
    override var dictionaryRepresentation: [String: Any] { lock.withLock { values } }
    override func synchronize() -> Bool { true }
}
