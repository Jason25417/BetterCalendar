//
//  SettingsSync.swift
//  BetterCalendar
//
//  设置跨端同步（#35，2026-07-15 Jason 要求「设置做成同步的」）：
//  把**平台中立的用户偏好**镜像到 iCloud KV（NSUbiquitousKeyValueStore），Mac / iPhone 两端一致。
//  机制：UserDefaults（本地即时读）↔ iCloud KV（跨端），双向镜像 + 值比较防回环。
//  W8（Jason 2026-10-18 原则：设置本来就该多端同步，不该同步的要先问他）：用户可见的设置默认都进白名单；
//  不同步的只剩本质上属于这台设备的（见 deviceLocalKeys 的逐条理由，已列给 Jason 确认）。
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
        // —— W8 审计补入（2026-10-18）——
        "agentEvents.enabled",                 // 关键时刻唤醒智能体：iPhone 上开，由 Mac 的桥接写事件
        "attention.settings.v1",               // 主动通知的总开关/频率上限/安静时段/一键静音：一端静音两端生效
        "approvals.alertPush.userDisabled",    // B5「手动关过」记号：订阅属于 iCloud 账户，一端关了别端启动不再自动打开
        "sharedTimer.icloud.enabled",          // iCloud 共享计时：两端同一后端才看得到彼此的计时；每台设备下次启动各自过闸门
        "execution.runRestorePolicy",          // 退出时有任务在进行 → 怎么恢复（偏好，两端一致）
        "push.muted",                          // 「别再提」的长期事项 id（事项随 iCloud 同步，id 两端相同）
    ]

    /// 用户能看到/改到、但**有意不同步**的设置（本质上属于这台设备）。只作审计清单与测试用，不参与同步逻辑。
    /// 改动前先问 Jason（W8 原则）。
    static let deviceLocalKeys: [String: String] = [
        "integration.focusFollowDeviceID": "设备 ID：每台必须唯一，同步会撞号",
        "devicelog.deviceID": "设备 ID：日志按设备区分",
        "agentBridge.folderBookmark": "智能体 bridge 文件夹的安全书签：只在这台 Mac 的这个路径有效",
        "integration.bridgeFolderBookmark": "聪音联动文件夹的安全书签：只在这台 Mac 有效",
        "dotStateBridge.folder": "已冻结 Dots：本机文件夹书签", "dotStateBridge.folders": "已冻结 Dots：本机文件夹书签",
        "dotStateBridge.historyFolder": "已冻结 Dots：本机文件夹书签",
        "focus.screenTimeShield": "番茄绝对专注（屏蔽 App）：只 iOS 有、系统授权按设备",
        "focus.screenTimeShieldMode": "屏蔽模式：与本机的屏蔽名单配套",
        "focus.screenTimeSelection": "屏蔽名单：系统给的 App 令牌只在这台设备有效",
        "focus.shortcut.start": "快捷指令名：Mac 与 iPhone 的快捷指令各自不同",
        "focus.shortcut.end": "快捷指令名：同上",
        "menubar.keepRunningOnQuit": "退出时保留在菜单栏：只 Mac 有",
        "integration.chiyneSync": "聪音联动：只这台 Mac 装了游戏 mod、写本机文件",
        "integration.chiyneTodoProjection": "聪音待办投影：同上",
        "development.dataBridge": "开发期数据文件桥：读写本机下载/文稿目录",
        "approvals.alertPush.enabled": "B5 订阅状态的本机缓存：真相在 iCloud 账户上（本来就全设备生效）",
        "calendar.backend": "已退役的日历后端开关（生产恒为系统日历）",
        "home.inputHeight": "窗口/输入框高度：界面布局状态",
        "execPanelExpanded": "执行面板折叠状态：界面布局状态",
        "bench.cloudModels": "开发工具（算法台）的模型勾选",
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
