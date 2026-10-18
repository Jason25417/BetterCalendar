//
//  SettingsSync.swift
//  BetterCalendar
//
//  设置跨端同步（#35，2026-07-15 Jason 要求「设置做成同步的」）：
//  把**平台中立的用户偏好**镜像到 iCloud KV（NSUbiquitousKeyValueStore），Mac / iPhone 两端一致。
//  机制：UserDefaults（本地即时读）↔ iCloud KV（跨端），双向镜像 + 值比较防回环。
//  白名单制：**只同步平台中立的偏好**；设备专属项绝不同步——
//    - `integration.focusFollowDeviceID`：每台设备必须唯一（同步了会撞号→「自己发的不跟」失效、去重全废）
//    - 屏蔽名单/模式（iOS FamilyActivitySelection=设备绑定 token）、快捷指令名、菜单栏常驻、聪音桥、开机自启=平台/设备专属
//    - 各类瞬时计数（番茄周用量、onboarding 计数、pending IPC）=本地状态
//  依赖 entitlement `com.apple.developer.ubiquity-kvstore-identifier`（两端 .entitlements 已配；同 MilestoneStore）。
//

import Foundation

enum SettingsSync {
    /// 同步白名单：仅含平台中立的用户偏好。增减同步项改这里一处。
    static let syncedKeys: Set<String> = [
        "cloud.model", "cloud.provider", "cloud.sfModel", "cloud.useCloud", "cloud.onDeviceParser",
        "journal.privacyLock", "meeting.autoComplete", "reminder.lead", "push.intensity",
        "workHours.windDown", "pomo.earlyEndLimit", "theme.id", "disclosure.style", "placeholder.mode",
        "reconcile.additionPolicy", "reconcile.deletionPolicy",
        "distraction.enabled", "distraction.keywords",
        "integration.focusFollow",
        "agentContext.allowRecentJournal",   // SPEC §19 A2：允许智能体读最近日记（隐私偏好，两端一致；默认关）
        "agentChat.eveningReview.enabled", "agentChat.eveningReview.minute",   // SPEC §19 F1：iPhone 上设、Mac 触发
    ]

    /// 远程设置到达通知（设置页据此重读 @State 刷新）。
    static let didSyncRemotely = Notification.Name("SettingsSync.didSyncRemotely")

    private static let kv = NSUbiquitousKeyValueStore.default
    /// 拉取远程写本地期间抑制回推（配合值比较，双保险防回环）。
    private static var applyingRemote = false
    private static var lastLocal: [String: NSObject] = [:]

    /// App 启动时调用一次（组装点）：挂双向监听 + 初次全量拉取远程。
    static func start() {
        guard !TestHost.isActive else { return }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv, queue: .main
        ) { note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            applyRemote(changedKeys: changed)
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard, queue: .main
        ) { _ in
            pushLocalToCloud()
        }
        lastLocal = localSnapshot()
        kv.synchronize()
        applyRemote(changedKeys: nil)   // 初次全量：远程有值即以远程为准落到本地
    }

    /// 本地 → 云：白名单项，仅值不同才写（防回环；kv.set 不会在本机触发 didChangeExternally）。
    private static func pushLocalToCloud() {
        guard !applyingRemote else { return }
        let ud = UserDefaults.standard
        for key in syncedKeys {
            let local = ud.object(forKey: key)
            guard !valuesEqual(local, lastLocal[key]) else { continue }
            if let value = local as? NSObject { lastLocal[key] = value } else { lastLocal.removeValue(forKey: key) }
            let remote = kv.object(forKey: key)
            guard !valuesEqual(local, remote) else { continue }
            if let local { kv.set(local, forKey: key) } else { kv.removeObject(forKey: key) }
        }
    }

    /// 云 → 本地：白名单∩变更项（nil=全量），仅值不同才写；写完发通知刷新视图。
    private static func applyRemote(changedKeys: [String]?) {
        let keys = changedKeys.map { syncedKeys.intersection($0) } ?? syncedKeys
        guard !keys.isEmpty else { return }
        let ud = UserDefaults.standard
        var applied = false
        applyingRemote = true
        for key in keys {
            guard let remote = kv.object(forKey: key) else {
                if changedKeys != nil {
                    ud.removeObject(forKey: key); lastLocal.removeValue(forKey: key); applied = true
                }
                continue
            }
            guard !valuesEqual(ud.object(forKey: key), remote) else { continue }
            ud.set(remote, forKey: key)
            lastLocal[key] = remote as? NSObject
            applied = true
        }
        applyingRemote = false
        if applied {
            NotificationCenter.default.post(name: didSyncRemotely, object: nil)
            DevLog.shared.info("设置同步", "已从 iCloud 拉取设置变更")
        }
    }

    private static func localSnapshot() -> [String: NSObject] {
        var values: [String: NSObject] = [:]
        for key in syncedKeys { values[key] = UserDefaults.standard.object(forKey: key) as? NSObject }
        return values
    }

    /// UserDefaults 存的都是 property-list 标量（Bool/Int/Double→NSNumber、String→NSString）→ NSObject 相等即值相等。
    private static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return (x as? NSObject) == (y as? NSObject)
        default: return false
        }
    }
}
